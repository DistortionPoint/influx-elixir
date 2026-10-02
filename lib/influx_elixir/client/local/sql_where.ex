defmodule InfluxElixir.Client.Local.SQLWhere do
  @moduledoc """
  The `WHERE` clause of a SQL text: a boolean expression over predicates
  (verified against InfluxDB 3 Core).

      expr   := term (OR term)*
      term   := factor (AND factor)*
      factor := NOT factor | '(' expr ')' | predicate

  AND binds tighter than OR, as in SQL. The result is a conjunction list; OR
  and NOT appear as nodes inside it, so a plain `a AND b` is still the flat
  list every executor path already understands. A predicate is a comparison,
  `IN`, `BETWEEN`, `LIKE` / `ILIKE`, a regular-expression match, `IS [NOT]
  NULL` or a bare boolean column; a `$name` is kept as a node for
  `InfluxElixir.Client.Local.SQLBind`.
  """

  alias InfluxElixir.Client.Local.{
    Format,
    SQLError,
    SQLExpr,
    SQLLimit,
    SQLLiteral,
    SQLMask,
    SQLTime
  }

  @typedoc "The comparison, set and pattern operators of a predicate."
  @type op ::
          :eq
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

  @typedoc "A predicate: operator, left operand, right side."
  @type clause :: {op(), binary() | {:expr, SQLExpr.t()}, term()}

  @typedoc """
  A WHERE conjunction is a list of nodes: a predicate, an `{:or, branches}`
  node whose branches are conjunctions, or a `{:not, conjunction}` node.
  """
  @type node_t :: clause() | {:or, [[node_t()]]} | {:not, [node_t()]}

  @typedoc """
  A `WHERE` operand: a column name, or an arithmetic expression over columns
  and literals (`price <= med * 3`).
  """
  @type operand :: binary() | {:expr, SQLExpr.t()}

  @limit_start SQLLimit.start_source()

  @doc """
  Parses the `WHERE ...` clause (if any) out of the text after `FROM <table>`.
  """
  @spec nodes(binary()) :: {:ok, [node_t()]} | {:error, SQLError.t()}
  def nodes(rest) do
    case SQLMask.run(
           ~r/(?i)WHERE\s+(.+?)(?:\s+GROUP\b|\s+ORDER\b|\s+#{@limit_start}|$)/su,
           rest
         ) do
      [_full_match, clauses_str] -> parse_clauses(clauses_str)
      _no_match -> {:ok, []}
    end
  end

  @spec parse_clauses(binary()) :: {:ok, [node_t()]} | {:error, map()}
  defp parse_clauses(str) do
    with {:ok, tokens} <- tokenize_where(str),
         {:ok, conj, []} <- where_or(tokens) do
      {:ok, conj}
    else
      {:ok, _conj, _leftover} -> {:error, SQLError.refusal("unsupported WHERE clause: #{str}")}
      {:error, _reason} = error -> error
    end
  end

  @typep where_token :: :lparen | :rparen | :and | :or | :not | {:pred, binary()}

  # Scans the clause text into grouping parentheses, the three keywords and
  # predicate text. Parentheses that belong to a predicate (`IN (...)`,
  # `now()`) and keywords that belong to one (`NOT IN`, `NOT LIKE`, the AND of
  # `BETWEEN a AND b`) stay inside its text; string literals are opaque.
  @spec tokenize_where(binary()) :: {:ok, [where_token()]} | {:error, map()}
  defp tokenize_where(str) do
    scan_where(str, %{buf: "", depth: 0, between: false, tokens: []})
  end

  @spec scan_where(binary(), map()) :: {:ok, [where_token()]} | {:error, map()}
  defp scan_where(<<>>, state),
    do: {:ok, state |> flush_pred() |> Map.fetch!(:tokens) |> Enum.reverse()}

  defp scan_where(<<q, rest::binary>>, state) when q in [?', ?"] do
    case take_literal(rest, q, []) do
      {:ok, literal, after_quote} -> scan_where(after_quote, append(state, <<q>> <> literal))
      :error -> {:error, SQLError.refusal("unterminated string literal in WHERE: #{rest}")}
    end
  end

  defp scan_where(<<"(", rest::binary>>, %{depth: 0} = state) do
    if String.trim(state.buf) == "",
      do: scan_where(rest, emit(state, :lparen)),
      else: scan_where(rest, %{append(state, "(") | depth: 1})
  end

  defp scan_where(<<"(", rest::binary>>, state),
    do: scan_where(rest, %{append(state, "(") | depth: state.depth + 1})

  defp scan_where(<<")", rest::binary>>, %{depth: 0} = state),
    do: scan_where(rest, state |> flush_pred() |> emit(:rparen))

  defp scan_where(<<")", rest::binary>>, state),
    do: scan_where(rest, %{append(state, ")") | depth: state.depth - 1})

  defp scan_where(str, %{depth: 0} = state) do
    case {word_boundary?(state.buf), Regex.run(~r/^(AND|OR|NOT)(?=\s|\(|$)/iu, str)} do
      {true, [keyword, _word]} ->
        rest = binary_part(str, byte_size(keyword), byte_size(str) - byte_size(keyword))
        scan_keyword(String.upcase(keyword), rest, state)

      _not_a_keyword ->
        <<c::utf8, rest::binary>> = str
        scan_where(rest, append(state, <<c::utf8>>))
    end
  end

  defp scan_where(<<c::utf8, rest::binary>>, state),
    do: scan_where(rest, append(state, <<c::utf8>>))

  # The rest of a quoted literal, through its closing quote; a doubled quote
  # does not close it.
  @spec take_literal(binary(), char(), iodata()) :: {:ok, binary(), binary()} | :error
  defp take_literal(<<q, q, rest::binary>>, q, acc), do: take_literal(rest, q, [q, q | acc])

  defp take_literal(<<q, rest::binary>>, q, acc),
    do: {:ok, [q | acc] |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_literal(<<byte, rest::binary>>, q, acc), do: take_literal(rest, q, [byte | acc])
  defp take_literal(<<>>, _q, _acc), do: :error

  @spec scan_keyword(binary(), binary(), map()) :: {:ok, [where_token()]} | {:error, map()}
  defp scan_keyword("AND", rest, %{between: true} = state),
    do: scan_where(rest, %{append(state, "AND") | between: false})

  defp scan_keyword("AND", rest, state), do: scan_where(rest, state |> flush_pred() |> emit(:and))
  defp scan_keyword("OR", rest, state), do: scan_where(rest, state |> flush_pred() |> emit(:or))

  # A leading NOT negates; one inside a predicate is `NOT IN` / `NOT LIKE` /
  # `NOT BETWEEN`.
  defp scan_keyword("NOT", rest, state) do
    if String.trim(state.buf) == "",
      do: scan_where(rest, emit(state, :not)),
      else: scan_where(rest, append(state, "NOT"))
  end

  @spec word_boundary?(binary()) :: boolean()
  defp word_boundary?(""), do: true
  defp word_boundary?(buf), do: String.ends_with?(buf, [" ", "\n", "\t", "("])

  @spec append(map(), binary()) :: map()
  defp append(state, text) do
    buf = state.buf <> text
    between = state.between or Regex.match?(~r/\bBETWEEN\s*$/iu, buf)
    %{state | buf: buf, between: between}
  end

  @spec emit(map(), where_token()) :: map()
  defp emit(state, token), do: %{state | tokens: [token | state.tokens]}

  @spec flush_pred(map()) :: map()
  defp flush_pred(state) do
    case String.trim(state.buf) do
      "" -> %{state | buf: "", between: false}
      text -> %{state | buf: "", between: false, tokens: [{:pred, text} | state.tokens]}
    end
  end

  @spec where_or([where_token()]) :: {:ok, [node_t()], [where_token()]} | {:error, map()}
  defp where_or(tokens) do
    with {:ok, first, rest} <- where_and(tokens) do
      where_collect_or(rest, [first])
    end
  end

  defp where_collect_or([:or | rest], branches) do
    with {:ok, branch, rest} <- where_and(rest), do: where_collect_or(rest, [branch | branches])
  end

  defp where_collect_or(rest, [single]), do: {:ok, single, rest}
  defp where_collect_or(rest, branches), do: {:ok, [{:or, Enum.reverse(branches)}], rest}

  @spec where_and([where_token()]) :: {:ok, [node_t()], [where_token()]} | {:error, map()}
  defp where_and(tokens) do
    with {:ok, first, rest} <- where_factor(tokens) do
      where_collect_and(rest, first)
    end
  end

  defp where_collect_and([:and | rest], conj) do
    with {:ok, next, rest} <- where_factor(rest), do: where_collect_and(rest, conj ++ next)
  end

  defp where_collect_and(rest, conj), do: {:ok, conj, rest}

  @spec where_factor([where_token()]) :: {:ok, [node_t()], [where_token()]} | {:error, map()}
  defp where_factor([:not | rest]) do
    with {:ok, conj, rest} <- where_factor(rest), do: {:ok, [{:not, conj}], rest}
  end

  defp where_factor([:lparen | rest]) do
    case where_or(rest) do
      {:ok, conj, [:rparen | rest]} -> {:ok, conj, rest}
      {:ok, _conj, _rest} -> {:error, SQLError.refusal("unbalanced parenthesis in WHERE")}
      {:error, _reason} = error -> error
    end
  end

  # A constant predicate is no condition (`[]`, true for every row) or one no
  # row meets (an OR of nothing).
  defp where_factor([{:pred, text} | rest]) do
    case parse_single_where_clause(text) do
      {:ok, :always} -> {:ok, [], rest}
      {:ok, :never} -> {:ok, [{:or, []}], rest}
      {:ok, clause} -> {:ok, [clause], rest}
      {:error, _reason} = error -> error
    end
  end

  defp where_factor(_tokens), do: {:error, SQLError.refusal("unsupported WHERE clause")}

  # ---------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------

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

  @spec parse_single_where_clause(binary()) ::
          {:ok, clause() | :always | :never} | {:error, map()}
  defp parse_single_where_clause(clause) do
    trimmed = String.trim(clause)

    with :nomatch <- null_predicate(trimmed),
         :nomatch <- list_predicate(trimmed),
         :nomatch <- between_predicate(trimmed),
         :nomatch <- pattern_predicate(trimmed),
         :nomatch <- constant_predicate(trimmed),
         :nomatch <- column_predicate(trimmed) do
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
    with {:ok, values} <- parse_in_values(key, list_str), do: {:ok, {op, key, values}}
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
    with {:ok, operand} <- parse_operand(String.trim(left)) do
      regex = like_regex(SQLLiteral.unescape(pattern), String.upcase(kind) == "ILIKE")
      {:ok, {like_op(negated != ""), operand, regex}}
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

  # `WHERE true` and `WHERE false` are conditions that hold for every row or
  # none. Any other lone literal is not a boolean, which the engine's
  # planner refuses (verified), naming the literal in its own rendering.
  @spec constant_predicate(binary()) :: {:ok, :always | :never} | {:error, map()} | :nomatch
  defp constant_predicate(text) do
    cond do
      String.upcase(text) == "TRUE" -> {:ok, :always}
      String.upcase(text) == "FALSE" -> {:ok, :never}
      Regex.match?(~r/^-?[0-9]+$/u, text) -> non_boolean_filter("Int64(#{text})", "Int64")
      match?({_float, ""}, SQLLiteral.parse_float(text)) -> float_filter(text)
      SQLLiteral.string?(text) -> non_boolean_filter(~s|Utf8("#{SQLLiteral.body(text)}")|, "Utf8")
      true -> :nomatch
    end
  end

  @spec float_filter(binary()) :: {:error, map()}
  defp float_filter(text) do
    {value, ""} = SQLLiteral.parse_float(text)
    non_boolean_filter("Float64(#{Format.render_decimal(value)})", "Float64")
  end

  @spec non_boolean_filter(binary(), binary()) :: {:error, map()}
  defp non_boolean_filter(expression, type) do
    {:error,
     SQLError.planning(
       "Cannot create filter with non-boolean predicate '#{expression}' returning #{type}"
     )}
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
      else: SQLTime.between(op, low, high)
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
    case Regex.compile(pattern, if(String.ends_with?(op, "*"), do: "iu", else: "u")) do
      {:ok, regex} ->
        {:ok, regex}

      {:error, {reason, _position}} ->
        {:error,
         SQLError.simplify(
           "Invalid regex\ncaused by\nExternal error: regex parse error: #{reason}"
         )}
    end
  end

  @spec like_op(boolean()) :: :like | :not_like
  defp like_op(true), do: :not_like
  defp like_op(false), do: :like

  # SQL LIKE: `%` is any run, `_` any single character (a code point:
  # `'caf_'` matches "café", and `ILIKE 'éa'` matches "Éa", verified), `\`
  # makes the next character literal (`'al\%%'` matches "al%pha"); everything
  # else is literal. LIKE is case-sensitive on the engine, ILIKE is not.
  @doc "A LIKE (or, with `case_insensitive`, ILIKE) pattern as an anchored regular expression."
  @spec like_regex(binary(), boolean()) :: Regex.t()
  def like_regex(pattern, case_insensitive) do
    source = pattern |> String.codepoints() |> like_source([])

    Regex.compile!("\\A" <> source <> "\\z", if(case_insensitive, do: "isu", else: "su"))
  end

  @spec like_source([binary()], [binary()]) :: binary()
  defp like_source([], acc), do: acc |> Enum.reverse() |> Enum.join()
  defp like_source(["\\", char | rest], acc), do: like_source(rest, [Regex.escape(char) | acc])
  defp like_source(["%" | rest], acc), do: like_source(rest, [".*" | acc])
  defp like_source(["_" | rest], acc), do: like_source(rest, ["." | acc])
  defp like_source([char | rest], acc), do: like_source(rest, [Regex.escape(char) | acc])

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
        {:error, SQLError.refusal("unsupported WHERE clause: #{trimmed}")}

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
  defp comparison_clause(text, "time", right, _trimmed) do
    op = Map.fetch!(@comparison_operators, text)

    case SQLTime.comparand(right) do
      {:ok, value} ->
        {:ok, {op, "time", value}}

      {:error, {:number, type}} ->
        {:error, SQLTime.comparison_type_error("Timestamp(ns)", text, type)}

      {:error, _reason} = error ->
        error
    end
  end

  # A literal on the left (`1 < abs(x)`, `'2024-01-01' <= time`) is the
  # same comparison turned around, and a `$name` there is kept as standing
  # on the left, for the engine's wording of a type error.
  defp comparison_clause(text, left, "time", trimmed) do
    op = Map.fetch!(@comparison_operators, text)

    with true <- SQLLiteral.literal?(left) or SQLLiteral.param?(left) or null?(left),
         {:ok, value} <- SQLTime.comparand(left) do
      {:ok, {mirror(op), "time", on_the_left(value)}}
    else
      {:error, {:number, type}} ->
        {:error, SQLTime.comparison_type_error(type, text, "Timestamp(ns)")}

      false ->
        {:error, SQLError.refusal("unsupported WHERE clause: #{trimmed}")}

      {:error, _reason} = error ->
        error
    end
  end

  defp comparison_clause(text, left, right, trimmed) do
    op = Map.fetch!(@comparison_operators, text)

    cond do
      null?(left) ->
        null_comparison(mirror(op), right, trimmed)

      SQLLiteral.literal?(left) and SQLLiteral.literal?(right) ->
        constant_comparison(op, left, right, trimmed)

      SQLLiteral.param?(left) and (SQLLiteral.param?(right) or SQLLiteral.literal?(right)) ->
        unsupported_where(trimmed)

      SQLLiteral.literal?(left) and SQLLiteral.param?(right) ->
        unsupported_where(trimmed)

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
      SQLLiteral.param?(right) -> unsupported_where(trimmed)
      true -> comparison(op, right, "NULL")
    end
  end

  @spec on_the_left(term()) :: term()
  defp on_the_left({:param, name}), do: {:param, name, :left}
  defp on_the_left(value), do: value

  @spec unsupported_where(binary()) :: {:error, map()}
  defp unsupported_where(text),
    do: {:error, SQLError.refusal("unsupported WHERE clause: #{text}")}

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
    {l, r} = {SQLLiteral.value(left), SQLLiteral.value(right)}

    if (is_number(l) and is_number(r)) or (is_binary(l) and is_binary(r)) or
         (is_boolean(l) and is_boolean(r)),
       do: {:ok, if(compare_constants(op, l, r), do: :always, else: :never)},
       else: unsupported_where(trimmed)
  end

  @spec compare_constants(op(), term(), term()) :: boolean()
  defp compare_constants(:eq, l, r), do: l == r
  defp compare_constants(:ne, l, r), do: l != r
  defp compare_constants(:gt, l, r), do: l > r
  defp compare_constants(:lt, l, r), do: l < r
  defp compare_constants(:gte, l, r), do: l >= r
  defp compare_constants(:lte, l, r), do: l <= r

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

  @doc "The SQL symbol of a comparison operator."
  @spec symbol(op()) :: binary()
  def symbol(:eq), do: "="
  def symbol(:ne), do: "!="
  def symbol(:gt), do: ">"
  def symbol(:lt), do: "<"
  def symbol(:gte), do: ">="
  def symbol(:lte), do: "<="

  # The left side is a column — a quoted one holds any name — or an
  # arithmetic expression over columns (`2 * price > volume`).
  @spec parse_operand(binary()) :: {:ok, operand()} | {:error, map()}
  defp parse_operand(text) do
    cond do
      Regex.match?(~r/^\w+$/u, text) ->
        {:ok, text}

      SQLLiteral.identifier?(text) ->
        {:ok, SQLLiteral.identifier_name(text)}

      match?({:ok, _expr}, SQLExpr.parse(text)) ->
        {:ok, expr} = SQLExpr.parse(text)
        {:ok, {:expr, expr}}

      true ->
        unsupported_where(text)
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

      match?({:ok, _expr}, SQLExpr.parse(text)) ->
        {:ok, expr} = SQLExpr.parse(text)
        {:ok, {:expr, expr}}

      true ->
        unsupported_where(text)
    end
  end

  @spec parse_in_values(binary(), binary()) :: {:ok, [term()]} | {:error, map()}
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

  @spec parse_time_set([binary()]) :: {:ok, [SQLTime.bound()]} | {:error, map()}
  defp parse_time_set(items) do
    bounds = Enum.map(items, &(&1 |> SQLTime.comparand() |> SQLTime.bound()))

    if Enum.any?(bounds, &SQLTime.param_bound?/1),
      do: {:ok, bounds},
      else: SQLTime.in_list(bounds)
  end
end
