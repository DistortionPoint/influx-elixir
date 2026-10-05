defmodule InfluxElixir.Client.Local.SQLPredicate do
  @moduledoc false
  # One predicate of a `WHERE`, read from its text for `InfluxElixir.Client.Local`
  # (verified against InfluxDB 3 Core): a comparison, `IN`, `BETWEEN`,
  # `LIKE` / `ILIKE`, a regular-expression match, `IS [NOT] NULL` or a bare
  # boolean column. The left side is a column or an arithmetic expression, the
  # right a literal, a `$name` (kept for `InfluxElixir.Client.Local.SQLBind`),
  # a column or an expression.
  #
  # `InfluxElixir.Client.Local.SQLWhere` reads the `AND`, `OR`, `NOT` and
  # parentheses around the predicates and hands each one here.

  alias InfluxElixir.Client.Local.{
    Format,
    SQLCompare,
    SQLError,
    SQLExpr,
    SQLLiteral,
    SQLMask,
    SQLNumber,
    SQLRustRegex,
    SQLTime
  }

  @typedoc "The comparison, set and pattern operators of a predicate."
  @type op ::
          :non_boolean
          | :truthy_expr
          | :eq
          | :gt
          | :lt
          | :gte
          | :lte
          | :ne
          | :in
          | :not_in
          | :is_null
          | :is_not_null
          | :between
          | :not_between
          | :like
          | :not_like
          | :regex
          | :not_regex
          | :time_type_error

  @typedoc "A predicate: operator, left operand, right side."
  @type clause :: {op(), binary() | {:expr, SQLExpr.t()}, term()}

  @typedoc """
  A `WHERE` operand: a column name, or an arithmetic expression over columns
  and literals (`price <= med * 3`).
  """
  @type operand :: binary() | {:expr, SQLExpr.t()}

  # IN / NOT IN must be matched before binary operators because they don't
  # contain any of {=, <, >, !} characters that the binary-op scanner looks
  # for. Order: NOT IN before IN (NOT IN substring contains IN).
  # The left side of these is a column or an expression (`abs(x) IS NULL`,
  # `price * 2 IN (...)`); a match whose left side is neither (the words
  # inside a string literal, say) is not one of them.
  @not_in_pattern ~r/^(.+?)\s+NOT\s+IN\s*\((.*)\)\s*$/isu
  @in_pattern ~r/^(.+?)\s+IN\s*\((.*)\)\s*$/isu
  @is_not_null_pattern ~r/^(.+?)\s+IS\s+NOT\s+NULL$/isu
  @is_null_pattern ~r/^(.+?)\s+IS\s+NULL$/isu
  @between_pattern ~r/^(.+?)\s+(NOT\s+)?BETWEEN\s+(.+?)\s+AND\s+(.+)$/isu
  @like_pattern ~r/^(.+?)\s+(NOT\s+)?(I?LIKE)\s+'(.*)'$/isu
  @like_param_pattern ~r/^(.+?)\s+(NOT\s+)?(I?LIKE)\s+\$(\w+)$/isu
  @regex_pattern ~r/^(.+?)\s*(!?~\*?)\s*'(.*)'$/su
  @regex_param_pattern ~r/^(.+?)\s*(!?~\*?)\s*\$(\w+)$/su

  @doc """
  Reads one predicate's text. `:always` and `:never` are a constant that
  holds for every row or for none; an error is the engine's (a lone literal
  that is not a boolean) or the double's refusal.
  """
  @spec parse(binary()) :: {:ok, clause() | :always | :never} | {:error, map()}
  def parse(clause) do
    trimmed = String.trim(clause)

    with :nomatch <- null_predicate(trimmed),
         :nomatch <- list_predicate(trimmed),
         :nomatch <- between_predicate(trimmed),
         :nomatch <- pattern_predicate(trimmed),
         :nomatch <- constant_predicate(trimmed),
         :nomatch <- column_predicate(trimmed),
         :nomatch <- distinct_predicate(trimmed),
         :nomatch <- boolean_test_predicate(trimmed),
         :nomatch <- expression_predicate(trimmed) do
      parse_binary_where_clause(trimmed)
    end
  end

  @spec null_predicate(binary()) :: {:ok, clause()} | :nomatch
  defp null_predicate(text) do
    cond do
      match = operand_match(@is_not_null_pattern, text) ->
        [key] = match
        {:ok, {:is_not_null, key, nil}}

      match = operand_match(@is_null_pattern, text) ->
        [key] = match
        {:ok, {:is_null, key, nil}}

      true ->
        :nomatch
    end
  end

  @spec list_predicate(binary()) :: {:ok, clause()} | {:error, map()} | :nomatch
  defp list_predicate(text) do
    cond do
      match = operand_match(@not_in_pattern, text) -> in_clause(:not_in, match)
      match = operand_match(@in_pattern, text) -> in_clause(:in, match)
      true -> :nomatch
    end
  end

  @spec in_clause(:in | :not_in, [term()]) :: {:ok, clause()} | {:error, map()}
  defp in_clause(op, [key, list_str]) do
    case parse_in_values(key, list_str) do
      {:ok, values} -> {:ok, {op, key, values}}
      {:type_error, error} -> {:ok, {:time_type_error, "time", error}}
      {:error, _reason} = error -> error
    end
  end

  @spec between_predicate(binary()) :: {:ok, clause()} | {:error, map()} | :nomatch
  defp between_predicate(text) do
    case SQLMask.run(@between_pattern, text) do
      [_full, left, negated, low, high] ->
        with {:ok, operand} <- parse_operand(String.trim(left)),
             do: parse_between(operand, negated != "", String.trim(low), String.trim(high))

      nil ->
        :nomatch
    end
  end

  # LIKE, ILIKE and the regex operators, against a literal pattern or a
  # `$name` whose pattern `bind/2` compiles.
  @spec pattern_predicate(binary()) :: {:ok, clause()} | {:error, map()} | :nomatch
  defp pattern_predicate(text) do
    cond do
      match = SQLMask.run(@like_pattern, text) -> like_clause(match)
      match = SQLMask.run(@like_param_pattern, text) -> like_param_clause(match)
      match = SQLMask.run(@regex_pattern, text) -> regex_clause(match)
      match = SQLMask.run(@regex_param_pattern, text) -> regex_param_clause(match)
      true -> :nomatch
    end
  end

  @spec like_clause([binary()]) :: {:ok, clause()} | {:error, map()}
  defp like_clause([_full, left, negated, kind, pattern]) do
    with {:ok, operand} <- parse_operand(String.trim(left)),
         {:ok, regex} <-
           like_regex(SQLLiteral.unescape(pattern), String.upcase(kind) == "ILIKE") do
      {:ok, {like_op(negated != ""), operand, regex}}
    else
      {:error, :pattern_too_large} -> {:error, SQLCompare.pattern_too_large()}
      {:error, _error} = error -> error
    end
  end

  @spec like_param_clause([binary()]) :: {:ok, clause()} | {:error, map()}
  defp like_param_clause([_full, left, negated, kind, name]) do
    with {:ok, operand} <- parse_operand(String.trim(left)) do
      {:ok,
       {like_op(negated != ""), operand, {:like_param, name, String.upcase(kind) == "ILIKE"}}}
    end
  end

  @spec regex_clause([binary()]) :: {:ok, clause()} | {:error, map()}
  defp regex_clause([_full, left, op, pattern]) do
    with {:ok, operand} <- parse_operand(String.trim(left)),
         {:ok, regex} <- compile_regex(SQLLiteral.unescape(pattern), op) do
      {:ok, {regex_op(op), operand, {regex, op}}}
    end
  end

  @spec regex_param_clause([binary()]) :: {:ok, clause()} | {:error, map()}
  defp regex_param_clause([_full, left, op, name]) do
    with {:ok, operand} <- parse_operand(String.trim(left)) do
      {:ok, {regex_op(op), operand, {:regex_param, name, op}}}
    end
  end

  # A bare column — or a quoted one, whatever its name — is a boolean
  # predicate (`WHERE b`, `NOT b`).
  @spec column_predicate(binary()) :: {:ok, clause()} | :nomatch
  defp column_predicate(text) do
    cond do
      Regex.match?(~r/^[\p{L}_]\w*$/u, text) and String.upcase(text) not in ~w(TRUE FALSE NULL) ->
        {:ok, {:truthy, text, nil}}

      SQLLiteral.identifier?(text) ->
        {:ok, {:truthy, SQLLiteral.identifier_name(text), nil}}

      true ->
        :nomatch
    end
  end

  @distinct_pattern ~r/^(.+?)\s+IS\s+(NOT\s+)?DISTINCT\s+FROM\s+(.+)$/isu
  @boolean_test_pattern ~r/^(.+?)\s+IS\s+(NOT\s+)?(TRUE|FALSE)$/isu

  # `a IS [NOT] DISTINCT FROM b`: equality that counts a null as a value. It
  # is evaluated as the expression it is (see `InfluxElixir.Client.Local.SQLEval`);
  # `time` is not read here.
  @spec distinct_predicate(binary()) :: {:ok, clause()} | {:error, map()} | :nomatch
  defp distinct_predicate(text) do
    case SQLMask.run(@distinct_pattern, text) do
      [_full, left, negated, right] ->
        with {:ok, left} <- parse_value(String.trim(left)),
             {:ok, right} <- parse_boolean_value(String.trim(right)) do
          expression_clause({:is_distinct, left, right, negated != ""})
        end

      nil ->
        :nomatch
    end
  end

  # `a IS [NOT] TRUE` and `IS [NOT] FALSE`.
  @spec boolean_test_predicate(binary()) :: {:ok, clause()} | {:error, map()} | :nomatch
  defp boolean_test_predicate(text) do
    case SQLMask.run(@boolean_test_pattern, text) do
      [_full, operand, negated, value] ->
        with {:ok, operand} <- parse_value(String.trim(operand)) do
          expression_clause({:is_bool, operand, String.upcase(value) == "TRUE", negated != ""})
        end

      nil ->
        :nomatch
    end
  end

  # A call, a `CASE` or any other expression that is no comparison stands as a
  # condition: it must be a boolean (`WHERE starts_with(s, 'x')`).
  @spec expression_predicate(binary()) :: {:ok, clause()} | :nomatch
  defp expression_predicate(text) do
    case SQLExpr.parse_arithmetic(text) do
      {:ok, {kind, _a} = expr} when kind == :neg ->
        expression_clause(expr)

      {:ok, {kind, _name, _args} = expr} when kind == :call ->
        expression_clause(expr)

      {:ok, {kind, _op, _left, _right} = expr} when kind == :op ->
        expression_clause(expr)

      {:ok, {kind, _operand, _whens, _otherwise} = expr} when kind == :case ->
        expression_clause(expr)

      {:ok, {kind, _left, _right} = expr} when kind == :concat ->
        expression_clause(expr)

      _other ->
        :nomatch
    end
  end

  # The operand text as an expression: a column, a literal or an expression.
  @spec parse_value(binary()) :: {:ok, SQLExpr.t()} | {:error, map()}
  defp parse_value(text) do
    with {:ok, operand} <- parse_operand(text) do
      case operand do
        "time" -> unsupported_where("time in IS [NOT] DISTINCT FROM or IS [NOT] TRUE: " <> text)
        {:expr, expr} -> {:ok, expr}
        column -> {:ok, {:field, column}}
      end
    end
  end

  # The right side of `IS DISTINCT FROM` is a whole expression, with the `AND`
  # and `OR` that follow it.
  @spec parse_boolean_value(binary()) :: {:ok, SQLExpr.t()} | {:error, map()}
  defp parse_boolean_value(text) do
    case SQLExpr.parse(text) do
      {:ok, expr} -> {:ok, expr}
      {:error, _reason} -> {:error, SQLExpr.refusal("WHERE clause", text, text)}
    end
  end

  @spec expression_clause(SQLExpr.t()) :: {:ok, clause()}
  defp expression_clause(expr), do: {:ok, {:truthy_expr, {:expr, expr}, nil}}

  # `WHERE true` and `WHERE false` are conditions that hold for every row or
  # none. Any other lone literal is not a boolean, which the engine's
  # planner refuses (verified), naming the literal in its own rendering.
  @spec constant_predicate(binary()) ::
          {:ok, :always | :never | clause()} | {:error, map()} | :nomatch
  defp constant_predicate(text) do
    cond do
      String.upcase(text) == "TRUE" -> {:ok, :always}
      String.upcase(text) == "FALSE" -> {:ok, :never}
      String.upcase(text) == "NULL" -> expression_clause({:lit, nil})
      Regex.match?(~r/^-?[0-9]+$/u, text) -> non_boolean_filter("Int64(#{text})", "Int64")
      match?({_float, ""}, SQLLiteral.parse_float(text)) -> float_filter(text)
      SQLLiteral.string?(text) -> non_boolean_filter(~s|Utf8("#{SQLLiteral.body(text)}")|, "Utf8")
      true -> :nomatch
    end
  end

  @spec float_filter(binary()) :: {:ok, clause()}
  defp float_filter(text) do
    {value, ""} = SQLLiteral.parse_float(text)
    non_boolean_filter("Float64(#{Format.render_decimal(value)})", "Float64")
  end

  # A literal that is no condition. Alone it is the planner's error (see
  # `non_boolean_error/2`); beside an `AND`, an `OR` or a `NOT` it is that
  # operator's type error, which the plan finds once the columns are typed.
  @spec non_boolean_filter(binary(), binary()) :: {:ok, clause()}
  defp non_boolean_filter(expression, type),
    do: {:ok, {:non_boolean, {:expr, {:lit, nil}}, {expression, type}}}

  @doc """
  The planner's error for a `WHERE` that is one literal, or one column, that
  is not a boolean.
  """
  @spec non_boolean_error(binary(), binary()) :: SQLError.t()
  def non_boolean_error(expression, type) do
    SQLError.planning(
      "Cannot create filter with non-boolean predicate '#{expression}' returning #{type}"
    )
  end

  # The pattern's captures, cut from the unmasked text, with the first parsed
  # as an operand; nil when the pattern does not match or its left side is not
  # an operand.
  @spec operand_match(Regex.t(), binary()) :: [term()] | nil
  defp operand_match(pattern, text) do
    with [_full, left | rest] <- SQLMask.run(pattern, text),
         {:ok, operand} <- parse_operand(String.trim(left)) do
      [operand | rest]
    else
      _no_match -> nil
    end
  end

  @spec parse_between(operand(), boolean(), binary(), binary()) ::
          {:ok, clause()} | {:error, map()}
  defp parse_between("time", negated, low, high) do
    op = if negated, do: :not_between, else: :between
    low = low |> SQLTime.comparand() |> SQLTime.bound()
    high = high |> SQLTime.comparand() |> SQLTime.bound()

    if SQLTime.param_bound?(low) or SQLTime.param_bound?(high),
      do: {:ok, {op, "time", {low, high}}},
      else: op |> SQLTime.between(low, high) |> deferred()
  end

  # Each bound is a comparand: a literal, NULL (the comparison is unknown),
  # a `$name`, or — as in SQL — a column or an expression.
  defp parse_between(operand, negated, low, high) do
    op = if negated, do: :not_between, else: :between

    with {:ok, low} <- parse_comparand(low),
         {:ok, high} <- parse_comparand(high),
         do: {:ok, {op, operand, {low, high}}}
  end

  # `~` / `~*` match and `!~` / `!~*` do not match a regular expression,
  # anywhere in the value (unanchored); `*` ignores case. As on the engine
  # (verified): a null is unknown and an invalid pattern fails the query.
  # The engine's regexes are Rust's; the double compiles with Erlang's PCRE,
  # which also accepts backreferences and lookaround the engine refuses.
  @spec regex_op(binary()) :: :regex | :not_regex
  defp regex_op("!" <> _rest), do: :not_regex
  defp regex_op(_match), do: :regex

  @doc """
  Compiles a SQL regular expression for the match operator `op` (`~`, `~*`,
  `!~`, `!~*`); an invalid pattern is the optimizer's error.
  """
  @spec compile_regex(binary(), binary()) :: {:ok, Regex.t()} | {:error, SQLError.t()}
  def compile_regex(pattern, op) do
    flags = if String.ends_with?(op, "*"), do: "iu", else: "u"

    case {SQLRustRegex.check(pattern), Regex.compile(pattern, flags)} do
      {:differs, _pcre} ->
        {:error,
         SQLError.refusal(
           "a regular expression with \\< or \\>, word boundaries in the engine's crate that PCRE " <>
             "reads as the characters"
         )}

      {{:error, message}, _pcre} ->
        {:error, SQLError.simplify("Invalid regex\ncaused by\nExternal error: " <> message)}

      {:unknown, {:ok, regex}} ->
        {:ok, regex}

      {:ok, {:ok, regex}} ->
        {:ok, regex}

      {:ok, {:error, _pcre}} ->
        {:error,
         SQLError.refusal(
           "a regular expression the engine's crate reads and the double's PCRE rejects"
         )}

      {:unknown, {:error, _pcre}} ->
        {:error,
         SQLError.refusal(
           "a regular expression with a fault the double does not word as the engine's " <>
             "crate does"
         )}
    end
  end

  @spec like_op(boolean()) :: :like | :not_like
  defp like_op(true), do: :not_like
  defp like_op(false), do: :like

  @doc "A LIKE (or, with `case_insensitive`, ILIKE) pattern as an anchored regular expression."
  @spec like_regex(binary(), boolean()) :: {:ok, Regex.t()} | {:error, :pattern_too_large}
  defdelegate like_regex(pattern, case_insensitive), to: SQLCompare

  # What a predicate has after its first operand when it holds none of the operators the double
  # reads: the word or symbol that is none.
  @spec no_operator(binary()) :: binary()
  defp no_operator(text) do
    case String.split(text, ~r/\s+/u, parts: 3) do
      [_operand, second | _rest] ->
        if String.upcase(second) in ~w(LIKE ILIKE NOT IN BETWEEN IS),
          do:
            "#{second} of these operands: the double reads it only beside a column and a literal",
          else: "#{second} is not an operator the double reads"

      _alone ->
        "it holds no operator the double reads"
    end
  end

  # What a placeholder beside a literal or another placeholder is typed by: the engine takes it
  # from the other side, which the double does not.
  @placeholder_side "a $name beside a literal, NULL or another $name: the engine types it from " <>
                      "the other side, which is not modelled"

  @comparison_operators %{
    ">=" => :gte,
    "<=" => :lte,
    "!=" => :ne,
    "<>" => :ne,
    ">" => :gt,
    "<" => :lt,
    "=" => :eq
  }

  @spec parse_binary_where_clause(binary()) ::
          {:ok, clause() | :always | :never} | {:error, map()}
  defp parse_binary_where_clause(trimmed) do
    # The first operator outside a string literal, the two-character ones
    # before their one-character prefixes.
    case Regex.run(~r/>=|<=|!=|<>|>|<|=/u, SQLMask.mask(trimmed), return: :index) do
      nil ->
        unsupported_where(trimmed, no_operator(trimmed))

      [{start, length}] ->
        text = binary_part(trimmed, start, length)
        left = trimmed |> binary_part(0, start) |> String.trim()

        right =
          trimmed
          |> binary_part(start + length, byte_size(trimmed) - start - length)
          |> String.trim()

        comparison_clause(text, left, right, trimmed)
    end
  end

  @spec comparison_clause(binary(), binary(), binary(), binary()) ::
          {:ok, clause() | :always | :never} | {:error, map()}
  defp comparison_clause(text, left, right, trimmed) do
    op = Map.fetch!(@comparison_operators, text)

    case {left, right} do
      {"time", _right} -> time_comparison(op, text, right)
      {_left, "time"} -> mirrored_time_comparison(op, text, left, trimmed)
      _no_time -> value_comparison(op, left, right, trimmed)
    end
  end

  @spec time_comparison(op(), binary(), binary()) ::
          {:ok, clause() | :always | :never} | {:error, map()}
  defp time_comparison(op, text, right) do
    case SQLTime.comparand(right) do
      {:ok, value} ->
        {:ok, {op, "time", value}}

      {:error, {:number, type}} ->
        {:ok, deferred_clause(SQLTime.comparison_type_error("Timestamp(ns)", text, type))}

      {:error, _reason} = error ->
        error
    end
  end

  # A literal on the left (`1 < abs(x)`, `'2024-01-01' <= time`) is the
  # same comparison turned around, and a `$name` there is kept as standing
  # on the left, for the engine's wording of a type error.
  @spec mirrored_time_comparison(op(), binary(), binary(), binary()) ::
          {:ok, clause() | :always | :never} | {:error, map()}
  defp mirrored_time_comparison(op, text, left, trimmed) do
    with true <- SQLLiteral.literal?(left) or SQLLiteral.param?(left) or null?(left),
         {:ok, value} <- SQLTime.comparand(left) do
      {:ok, {mirror(op), "time", on_the_left(value)}}
    else
      {:error, {:number, type}} ->
        {:ok, deferred_clause(SQLTime.comparison_type_error(type, text, "Timestamp(ns)"))}

      false ->
        unsupported_where(
          trimmed,
          "the left of a comparison with time is neither a literal, a $name nor NULL"
        )

      {:error, _reason} = error ->
        error
    end
  end

  @spec value_comparison(op(), binary(), binary(), binary()) ::
          {:ok, clause() | :always | :never} | {:error, map()}
  defp value_comparison(op, left, right, trimmed) do
    cond do
      null?(left) ->
        null_comparison(mirror(op), right, trimmed)

      SQLLiteral.literal?(left) and SQLLiteral.literal?(right) ->
        constant_comparison(op, left, right, trimmed)

      SQLLiteral.param?(left) and (SQLLiteral.param?(right) or SQLLiteral.literal?(right)) ->
        unsupported_where(trimmed, @placeholder_side)

      SQLLiteral.literal?(left) and SQLLiteral.param?(right) ->
        unsupported_where(trimmed, @placeholder_side)

      SQLLiteral.literal?(left) or SQLLiteral.param?(left) ->
        turned_around(mirror(op), right, left, trimmed)

      true ->
        comparison(op, left, right)
    end
  end

  @spec null?(binary()) :: boolean()
  defp null?(text), do: String.upcase(text) == "NULL"

  # `NULL = x` is unknown for every row, whatever `x` is. Against a constant
  # that is `time` compared with NULL; against a column the comparison
  # turned around.
  @spec null_comparison(op(), binary(), binary()) :: {:ok, clause()} | {:error, map()}
  defp null_comparison(op, right, trimmed) do
    cond do
      SQLLiteral.literal?(right) or null?(right) -> {:ok, {:eq, "time", nil}}
      SQLLiteral.param?(right) -> unsupported_where(trimmed, @placeholder_side)
      true -> comparison(op, right, "NULL")
    end
  end

  @spec on_the_left(term()) :: term()
  defp on_the_left({:param, name}), do: {:param, name, :left}
  defp on_the_left(value), do: value

  @spec unsupported_where(binary(), binary() | nil) :: {:error, map()}
  defp unsupported_where(text, reason \\ nil),
    do: {:error, SQLError.refusal("unsupported WHERE clause: #{text}#{because(reason)}")}

  @spec because(binary() | nil) :: binary()
  defp because(nil), do: ""
  defp because(reason), do: " (#{reason})"

  # The column is the comparison's left side. The engine words a type error
  # in the order the sides are written, which a boolean turned around would
  # lose, so it is refused by name.
  @spec turned_around(op(), binary(), binary(), binary()) ::
          {:ok, clause()} | {:error, map()}
  defp turned_around(_op, _operand, value, trimmed) when value in ["true", "false"] do
    {:error,
     SQLError.refusal(
       "a boolean on the left of a comparison is outside the double's subset; " <>
         "write the column first: #{trimmed}"
     )}
  end

  defp turned_around(op, operand, value, _trimmed) do
    with {:ok, left} <- parse_operand(operand) do
      case SQLLiteral.param_name(value) do
        nil -> with {:ok, comparand} <- parse_comparand(value), do: {:ok, {op, left, comparand}}
        name -> {:ok, {op, left, {:param, name, :left}}}
      end
    end
  end

  # Two literals compare to a constant: every row or none. Numbers compare as
  # numbers, strings as text; the engine casts across the two, which the
  # double does not.
  @spec constant_comparison(op(), binary(), binary(), binary()) ::
          {:ok, :always | :never} | {:error, map()}
  defp constant_comparison(op, left, right, trimmed) do
    {l, r} = {constant_value(left), constant_value(right)}

    if (SQLNumber.numeric?(l) and SQLNumber.numeric?(r)) or (is_binary(l) and is_binary(r)) or
         (is_boolean(l) and is_boolean(r)),
       do: {:ok, if(compare_constants(op, l, r), do: :always, else: :never)},
       else:
         unsupported_where(
           trimmed,
           "two literals of kinds the engine casts to one another, which the double does not"
         )
  end

  # A literal's value; a number past the range of a double is an infinity.
  @spec constant_value(binary()) :: term()
  defp constant_value(text) do
    case SQLLiteral.value(text) do
      value when is_binary(value) ->
        cond do
          SQLLiteral.string?(text) -> value
          SQLLiteral.float?(text) and String.starts_with?(text, "-") -> :neg_inf
          SQLLiteral.float?(text) -> :inf
          true -> value
        end

      value ->
        value
    end
  end

  @spec compare_constants(op(), term(), term()) :: boolean()
  defp compare_constants(op, l, r) do
    if SQLNumber.numeric?(l) and SQLNumber.numeric?(r),
      do: ordered(op, SQLNumber.compare(l, r)),
      else: compare_values(op, l, r)
  end

  @spec ordered(op(), :lt | :eq | :gt) :: boolean()
  defp ordered(:eq, order), do: order == :eq
  defp ordered(:ne, order), do: order != :eq
  defp ordered(:gt, order), do: order == :gt
  defp ordered(:lt, order), do: order == :lt
  defp ordered(:gte, order), do: order != :lt
  defp ordered(:lte, order), do: order != :gt

  @spec compare_values(op(), term(), term()) :: boolean()
  defp compare_values(:eq, l, r), do: l == r
  defp compare_values(:ne, l, r), do: l != r
  defp compare_values(:gt, l, r), do: l > r
  defp compare_values(:lt, l, r), do: l < r
  defp compare_values(:gte, l, r), do: l >= r
  defp compare_values(:lte, l, r), do: l <= r

  @spec comparison(op(), binary(), binary()) :: {:ok, clause()} | {:error, map()}
  defp comparison(op, operand, comparand) do
    with {:ok, left} <- parse_operand(operand),
         {:ok, value} <- parse_comparand(comparand),
         do: {:ok, {op, left, value}}
  end

  @doc "The operator that holds when the two sides of a comparison swap places."
  @spec mirror(op()) :: op()
  def mirror(:gt), do: :lt
  def mirror(:lt), do: :gt
  def mirror(:gte), do: :lte
  def mirror(:lte), do: :gte
  def mirror(op), do: op

  # The left side is a column — a quoted one holds any name — or an
  # arithmetic expression over columns (`2 * price > volume`), or a literal
  # (`1 IS NULL`, `'a' IN ('a')`), which holds the same for every row.
  @spec parse_operand(binary()) :: {:ok, operand()} | {:error, map()}
  defp parse_operand(text) do
    cond do
      SQLLiteral.string?(text) ->
        {:ok, {:expr, {:lit, SQLLiteral.body(text)}}}

      String.downcase(text) in ["null", "true", "false"] ->
        {:ok, {:expr, {:lit, keyword(text)}}}

      Regex.match?(~r/^[\p{L}_]\w*$/u, text) ->
        {:ok, text}

      SQLLiteral.identifier?(text) ->
        {:ok, SQLLiteral.identifier_name(text)}

      true ->
        arithmetic_operand(text)
    end
  end

  # An expression over columns and literals, or the refusal that says why it is not read.
  @spec arithmetic_operand(binary()) :: {:ok, {:expr, SQLExpr.t()}} | {:error, map()}
  defp arithmetic_operand(text) do
    case SQLExpr.parse_arithmetic(text) do
      {:ok, expr} -> {:ok, {:expr, expr}}
      {:error, _reason} -> {:error, SQLExpr.refusal("WHERE clause", text, text)}
    end
  end

  @spec keyword(binary()) :: boolean() | nil
  defp keyword(text) do
    case String.downcase(text) do
      "null" -> nil
      "true" -> true
      "false" -> false
    end
  end

  # The right side is a literal, a `$name`, or an expression over columns
  # and literals. A bare word, or a double-quoted name, is a column
  # reference, as in SQL — never a string.
  @spec parse_comparand(binary()) :: {:ok, term()} | {:error, map()}
  defp parse_comparand(text) do
    cond do
      SQLLiteral.string?(text) or text in ["true", "false"] ->
        {:ok, SQLLiteral.value(text)}

      String.upcase(text) == "NULL" ->
        {:ok, nil}

      is_number(SQLLiteral.coerce(text)) ->
        {:ok, SQLLiteral.coerce(text)}

      SQLLiteral.param?(text) ->
        {:ok, {:param, SQLLiteral.param_name(text)}}

      SQLLiteral.identifier?(text) ->
        {:ok, {:expr, {:field, SQLLiteral.identifier_name(text)}}}

      true ->
        arithmetic_operand(text)
    end
  end

  @spec parse_in_values(binary(), binary()) ::
          {:ok, [term()]} | {:error, map()} | {:type_error, map()}
  defp parse_in_values(key, str) do
    items =
      str
      |> SQLMask.split_commas()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if key == "time", do: parse_time_set(items), else: parse_value_set(items)
  end

  # Each item is a comparand: a literal, or — as in SQL — a column
  # reference or expression (`v IN (1, other)`). Source order is kept so
  # the schema check names the first unknown column, as the engine does.
  @spec parse_value_set([binary()]) :: {:ok, [term()]} | {:error, map()}
  defp parse_value_set(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case parse_comparand(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  @spec parse_time_set([binary()]) :: {:ok, [SQLTime.bound()]} | {:type_error, map()}
  defp parse_time_set(items) do
    bounds = Enum.map(items, &(&1 |> SQLTime.comparand() |> SQLTime.bound()))

    if Enum.any?(bounds, &SQLTime.param_bound?/1) do
      {:ok, bounds}
    else
      case SQLTime.in_list(bounds) do
        {:error, error} -> {:type_error, error}
        ok -> ok
      end
    end
  end

  # The planner finds a `time` compared with a number when it types the
  # query, after it has found the columns, so the clause is kept to be
  # raised then (see `InfluxElixir.Client.Local.SQLPlan`).
  @doc """
  A type error found in a `time` clause, kept as a clause for the planner to
  raise when it types the query.
  """
  @spec deferred_clause(SQLError.t()) :: clause()
  def deferred_clause(error), do: {:time_type_error, "time", error}

  @spec deferred({:ok, clause()} | {:error, SQLError.t()}) :: {:ok, clause()}
  defp deferred({:error, error}), do: {:ok, deferred_clause(error)}
  defp deferred({:ok, _clause} = ok), do: ok
end
