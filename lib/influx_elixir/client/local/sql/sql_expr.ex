defmodule InfluxElixir.Client.Local.SQLExpr do
  @moduledoc false
  # The expressions of a SQL text: a column, a literal, a `$name` placeholder,
  # an operation, a unary minus, a `CAST`, a call of one of
  # `InfluxElixir.Client.Local.SQLFunctions`, a `CASE`, and the boolean
  # operators (`AND`, `OR`, `NOT`, comparisons, `IS [NOT] NULL`, `IS [NOT]
  # DISTINCT FROM`, `IS [NOT] TRUE`, `[NOT] IN`, `[NOT] BETWEEN`, `[NOT] LIKE`)
  # and `||`. They stand in an aggregate's argument, a projection, a `WHERE`
  # operand and an `ORDER BY` term.
  #
  # A `$name` is kept as `{:param, name}` and replaced by
  # `InfluxElixir.Client.Local.SQLBind`; a bound non-negative integer is
  # `{:uint, n}`, the engine's `UInt64`.
  #
  # A number is typed as the engine types it (verified against InfluxDB 3
  # Core): an integer that fits `Int64` is one, a larger one that fits `UInt64`
  # is a `{:uint, n}`, anything else is a `Float64`; a `-` written directly
  # before a number is part of it (`-9223372036854775808` is an `Int64`, while
  # `-(9223372036854775808)` negates a `UInt64`, which the engine refuses). A
  # float too large for a double is `{:lit, :inf}` or `{:lit, :neg_inf}`, which the engine
  # answers as a JSON `null` and compares as infinity.
  #
  # `render/3` writes an expression as the engine names a column: the name
  # that stands for a select item without an alias. The engine writes no
  # parentheses in it, whatever the grouping of the text was.

  alias InfluxElixir.Client.Local.{Format, SQLCompare, SQLFunctions, SQLLimits, SQLLiteral}

  require SQLLimits

  @typedoc """
  A column an expression reads: its name, or a reference to a relation the
  query does not have (`"XQA".v`, `foo.v`), kept as it was written so the
  engine's error can print it.
  """
  @type column_ref :: binary() | {:qualified, binary(), binary()}

  @typedoc "The comparison operators."
  @type comparison :: :eq | :ne | :gt | :lt | :gte | :lte

  @typedoc """
  An expression: a column, a literal, a `$name` placeholder (`{:param, name}`,
  replaced by `InfluxElixir.Client.Local.SQLBind`) or a bound non-negative
  integer parameter (`{:uint, n}`, the engine's `UInt64`), or an operation
  over expressions. The parser reads a column as `{:field, name}`;
  `InfluxElixir.Client.Local.SQLTyping` reads one the store holds as `UInt64`
  as `{:uint_col, name}`.
  """
  @type t ::
          {:field, column_ref()}
          | {:lit, number() | binary() | boolean() | nil | :inf | :neg_inf}
          | {:uint_col, binary()}
          | {:uint, non_neg_integer()}
          | {:param, binary()}
          | {:op, :+ | :- | :* | :/ | :rem, t(), t()}
          | {:neg, t()}
          | {:pos, t()}
          | {:cast, t(), cast_type()}
          | {:call, SQLFunctions.name(), [t()]}
          | {:cmp, comparison(), t(), t()}
          | {:and, t(), t()}
          | {:or, t(), t()}
          | {:not, t()}
          | {:is_null, t(), boolean()}
          | {:is_distinct, t(), t(), boolean()}
          | {:is_bool, t(), boolean(), boolean()}
          | {:in, t(), [t()], boolean()}
          | {:between, t(), t(), t(), boolean()}
          | {:like, t(), t(), boolean(), boolean(), Regex.t() | nil}
          | {:concat, t(), t()}
          | {:case, t() | nil, [{t(), t()}], t() | nil}
          | {:unreadable, binary()}
          | {:raw, binary()}

  @typedoc """
  `CAST(expr AS type)` targets (and their synonyms): the integer types by
  width (`INTEGER` is 32 bits), `DOUBLE`, and text.
  """
  @type cast_type :: :int8 | :int16 | :int32 | :int64 | :float | :string | :decimal

  @typedoc "How `render/3` treats a `CAST`: written as the engine names it (gone), or refused."
  @type casts :: :drop | :refuse | :display

  @int64_min SQLLimits.int64_min()
  @int64_max SQLLimits.int64_max()
  @uint64_max SQLLimits.uint64_max()

  @number "(?:[0-9]+\\.[0-9]*|\\.[0-9]+|[0-9]+)(?:[eE][+-]?[0-9]+)?"
  @quoted ~S{"(?:[^"]|"")*"}
  @name "(?:\\w+|#{@quoted})"
  @token ~r/\A\s*(?:(#{@number})|'((?:[^']|'')*)'|\$(\w+)|(#{@name}(?:\.#{@name})?)|(<=|>=|<>|!=|\|\||::|[()+\-*\/%,=<>]))/u

  @doc """
  Parses an expression, boolean operators included (recursive descent,
  standard precedence):

      or     := and ('OR' and)*
      and    := not ('AND' not)*
      not    := 'NOT' not | test
      test   := concat (comparison concat | 'IS' ... | 'NOT'? 'IN' ... | ...)*
      concat := sum
      sum    := term   (('+' | '-') term)*
      term   := factor (('*' | '/' | '%' | '||') factor)*
      factor := '-' factor | number | string | identifier | '(' or ')'
              | 'CASE' ... 'END' | function '(' [or (',' or)*] ')'

  `function` is one of `InfluxElixir.Client.Local.SQLFunctions`; any number of
  arguments parses, and the executor answers a wrong count or type as the
  engine's planner does. A call of any other function is
  `{:error, {:unsupported_function, name}}`.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(str), do: parse_with(str, &parse_or/1)

  @doc """
  Parses an arithmetic expression: `parse/1` without the boolean operators
  at its top, which the `WHERE` reads itself (they stand inside parentheses,
  a `CASE` and a call all the same).
  """
  @spec parse_arithmetic(binary()) :: {:ok, t()} | {:error, term()}
  def parse_arithmetic(str), do: parse_with(str, &parse_concat/1)

  @spec parse_with(binary(), ([term()] -> {:ok, t(), [term()]} | {:error, term()})) ::
          {:ok, t()} | {:error, term()}
  defp parse_with(str, entry) do
    with {:ok, tokens} <- tokenize_expr(str),
         {:ok, ast, []} <- entry.(tokens) do
      {:ok, ast}
    else
      {:ok, _ast, _leftover} -> {:error, :trailing_tokens}
      {:error, _reason} = error -> error
    end
  end

  # Every non-blank byte must belong to a token; anything the scanner skipped
  # (a quote, a stray symbol) makes the expression invalid.
  @spec tokenize_expr(binary()) :: {:ok, [term()]} | {:error, term()}
  defp tokenize_expr(str), do: tokenize(String.trim(str), [])

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(rest, acc) do
    case Regex.run(@token, rest) do
      [full | groups] ->
        after_token = binary_part(rest, byte_size(full), byte_size(rest) - byte_size(full))
        tokenize(String.trim_leading(after_token), [expr_token(groups) | acc])

      nil ->
        {:error, :unexpected_character}
    end
  end

  # A match's groups are a number, a string, a `$name`, a name or a (possibly
  # qualified) quoted name, or an operator; the groups after the last one
  # that matched are not in the list.
  @spec expr_token([binary()]) :: term()
  defp expr_token(groups) do
    case groups ++ List.duplicate("", 5 - length(groups)) do
      [num, "", "", "", ""] when num != "" -> {:num, num}
      ["", string, "", "", ""] when string != "" -> {:str, string}
      ["", "", name, "", ""] when name != "" -> {:param, name}
      ["", "", "", ident, ""] when ident != "" -> name_token(ident)
      ["", "", "", "", op] when op != "" -> {:tok, op}
      ["", "", "", "", ""] -> {:str, ""}
    end
  end

  @spec name_token(binary()) :: term()
  defp name_token(text) do
    case split_qualified(text) do
      [qualifier, column] -> {:qualified, qualifier, column}
      [single] -> if SQLLiteral.identifier?(single), do: {:quoted, single}, else: {:word, single}
    end
  end

  # `a.b`, `"A".b`, `a."B"`: the dot outside the quotes.
  @spec split_qualified(binary()) :: [binary()]
  defp split_qualified(text) do
    case Regex.run(~r/\A("(?:[^"]|"")*"|\w+)\.("(?:[^"]|"")*"|\w+)\z/u, text) do
      [_full, qualifier, column] -> [qualifier, column]
      nil -> [text]
    end
  end

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  @typep parsed :: {:ok, t(), [term()]} | {:error, term()}

  @spec parse_or([term()]) :: parsed()
  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens), do: parse_or_tail(left, rest)
  end

  defp parse_or_tail(left, [{:word, word} | rest] = tokens) do
    if keyword?(word, "OR") do
      with {:ok, right, rest} <- parse_and(rest), do: parse_or_tail({:or, left, right}, rest)
    else
      {:ok, left, tokens}
    end
  end

  defp parse_or_tail(left, rest), do: {:ok, left, rest}

  @spec parse_and([term()]) :: parsed()
  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_not(tokens), do: parse_and_tail(left, rest)
  end

  defp parse_and_tail(left, [{:word, word} | rest] = tokens) do
    if keyword?(word, "AND") do
      with {:ok, right, rest} <- parse_not(rest), do: parse_and_tail({:and, left, right}, rest)
    else
      {:ok, left, tokens}
    end
  end

  defp parse_and_tail(left, rest), do: {:ok, left, rest}

  @spec parse_not([term()]) :: parsed()
  defp parse_not([{:word, word} | rest] = tokens) do
    if keyword?(word, "NOT") do
      with {:ok, inner, rest} <- parse_not(rest), do: {:ok, {:not, inner}, rest}
    else
      parse_test(tokens)
    end
  end

  defp parse_not(tokens), do: parse_test(tokens)

  # A comparison, `IS`, `IN`, `BETWEEN` or `LIKE` of the operands to either
  # side, applied left to right.
  @spec parse_test([term()]) :: parsed()
  defp parse_test(tokens) do
    with {:ok, left, rest} <- parse_concat(tokens), do: parse_test_tail(left, rest)
  end

  @comparisons %{
    "=" => :eq,
    "<>" => :ne,
    "!=" => :ne,
    "<" => :lt,
    ">" => :gt,
    "<=" => :lte,
    ">=" => :gte
  }

  defp parse_test_tail(left, [{:tok, op} | rest]) when is_map_key(@comparisons, op) do
    with {:ok, right, rest} <- parse_concat(rest),
         do: parse_test_tail({:cmp, Map.fetch!(@comparisons, op), left, right}, rest)
  end

  defp parse_test_tail(left, [{:word, word} | rest] = tokens) do
    case String.upcase(word) do
      "IS" ->
        continue_test(parse_is(left, rest), tokens)

      "IN" ->
        continue_test(parse_in(left, rest, false), tokens)

      "BETWEEN" ->
        continue_test(parse_between(left, rest, false), tokens)

      like when like in ["LIKE", "ILIKE"] ->
        continue_test(parse_like(left, rest, like, false), tokens)

      "NOT" ->
        parse_negated(left, rest, tokens)

      _other ->
        {:ok, left, tokens}
    end
  end

  defp parse_test_tail(left, rest), do: {:ok, left, rest}

  defp continue_test({:ok, node, rest}, _tokens), do: parse_test_tail(node, rest)
  defp continue_test({:error, _reason} = error, _tokens), do: error

  defp parse_negated(left, [{:word, word} | rest], tokens) do
    case String.upcase(word) do
      "IN" ->
        continue_test(parse_in(left, rest, true), tokens)

      "BETWEEN" ->
        continue_test(parse_between(left, rest, true), tokens)

      like when like in ["LIKE", "ILIKE"] ->
        continue_test(parse_like(left, rest, like, true), tokens)

      _other ->
        {:ok, left, tokens}
    end
  end

  defp parse_negated(left, _rest, tokens), do: {:ok, left, tokens}

  defp parse_is(left, [{:word, word} | rest]) do
    {negated, rest} =
      if keyword?(word, "NOT"), do: {true, rest}, else: {false, [{:word, word} | rest]}

    case rest do
      [{:word, kind} | more] -> parse_is_kind(left, String.upcase(kind), negated, more)
      _other -> {:error, :unexpected_token}
    end
  end

  defp parse_is(_left, _rest), do: {:error, :unexpected_token}

  defp parse_is_kind(left, "NULL", negated, rest), do: {:ok, {:is_null, left, negated}, rest}

  defp parse_is_kind(left, "TRUE", negated, rest),
    do: {:ok, {:is_bool, left, true, negated}, rest}

  defp parse_is_kind(left, "FALSE", negated, rest),
    do: {:ok, {:is_bool, left, false, negated}, rest}

  # What follows `IS [NOT] DISTINCT FROM` is the whole rest of the expression, down to an `OR`
  # (verified against Core: `1 IS DISTINCT FROM 2 OR true` is `1 IS DISTINCT FROM (2 OR true)`,
  # the error of an `Int64 OR Boolean`).
  defp parse_is_kind(left, "DISTINCT", negated, [{:word, from} | rest]) do
    if keyword?(from, "FROM") do
      with {:ok, right, rest} <- parse_or(rest),
           do: {:ok, {:is_distinct, left, right, negated}, rest}
    else
      {:error, :unexpected_token}
    end
  end

  defp parse_is_kind(_left, _kind, _negated, _rest), do: {:error, :unsupported_is}

  defp parse_in(left, [{:tok, "("} | rest], negated) do
    with {:ok, items, rest} <- parse_list(rest, []), do: {:ok, {:in, left, items, negated}, rest}
  end

  defp parse_in(_left, _rest, _negated), do: {:error, :unexpected_token}

  defp parse_list(tokens, acc) do
    case parse_or(tokens) do
      {:ok, item, [{:tok, ","} | rest]} -> parse_list(rest, [item | acc])
      {:ok, item, [{:tok, ")"} | rest]} -> {:ok, Enum.reverse([item | acc]), rest}
      {:ok, _item, _rest} -> {:error, :unbalanced_parenthesis}
      {:error, _reason} = error -> error
    end
  end

  defp parse_between(left, tokens, negated) do
    with {:ok, low, [{:word, word} | rest]} <- parse_concat(tokens),
         true <- keyword?(word, "AND"),
         {:ok, high, rest} <- parse_concat(rest) do
      {:ok, {:between, left, low, high, negated}, rest}
    else
      {:error, _reason} = error -> error
      _shape -> {:error, :unexpected_token}
    end
  end

  defp parse_like(left, tokens, kind, negated) do
    with {:ok, pattern, rest} <- parse_concat(tokens),
         ilike = kind == "ILIKE",
         {:ok, regex} <- literal_regex(pattern, ilike) do
      {:ok, {:like, left, pattern, negated, ilike, regex}, rest}
    end
  end

  @spec literal_regex(t(), boolean()) :: {:ok, Regex.t() | nil} | {:error, term()}
  defp literal_regex({:lit, text}, ilike) when is_binary(text) do
    SQLCompare.like_regex(text, ilike)
  end

  defp literal_regex(_dynamic, _ilike), do: {:ok, nil}

  # The operand of a comparison, `BETWEEN`, `LIKE` and `IN`: the sums. `||` is read
  # with the products, as the engine's parser does.
  @spec parse_concat([term()]) :: parsed()
  defp parse_concat(tokens), do: parse_sum(tokens)

  @spec parse_sum([term()]) :: parsed()
  defp parse_sum(tokens) do
    with {:ok, left, rest} <- parse_product(tokens) do
      parse_sum_tail(left, rest)
    end
  end

  defp parse_sum_tail(left, [{:tok, op} | rest]) when op in ["+", "-"] do
    with {:ok, right, rest} <- parse_product(rest) do
      parse_sum_tail({:op, operator(op), left, right}, rest)
    end
  end

  defp parse_sum_tail(left, rest), do: {:ok, left, rest}

  @spec parse_product([term()]) :: parsed()
  defp parse_product(tokens) do
    with {:ok, left, rest} <- parse_factor(tokens) do
      parse_product_tail(left, rest)
    end
  end

  defp parse_product_tail(left, [{:tok, op} | rest]) when op in ["*", "/", "%"] do
    with {:ok, right, rest} <- parse_factor(rest) do
      parse_product_tail({:op, operator(op), left, right}, rest)
    end
  end

  # `||` has the precedence of `*`, `/` and `%`, left to right with them (verified on
  # Core: `'a' || 1 + 2` is `('a' || 1) + 2`, an arithmetic error on text).
  defp parse_product_tail(left, [{:tok, "||"} | rest]) do
    with {:ok, right, rest} <- parse_factor(rest) do
      parse_product_tail({:concat, left, right}, rest)
    end
  end

  defp parse_product_tail(left, rest), do: {:ok, left, rest}

  @spec operator(binary()) :: :+ | :- | :* | :/ | :rem
  defp operator("+"), do: :+
  defp operator("-"), do: :-
  defp operator("*"), do: :*
  defp operator("/"), do: :/
  defp operator("%"), do: :rem

  @spec parse_factor([term()]) :: parsed()
  defp parse_factor(tokens) do
    with {:ok, expr, rest} <- parse_primary(tokens), do: parse_shorthand(expr, rest)
  end

  # `expr::TYPE` is `CAST(expr AS TYPE)`.
  defp parse_shorthand(expr, [{:tok, "::"}, {:word, type} | rest]) do
    with {:ok, target} <- cast_type(type), do: parse_shorthand({:cast, expr, target}, rest)
  end

  defp parse_shorthand(_expr, [{:tok, "::"} | _rest]), do: {:error, :invalid_cast}
  defp parse_shorthand(expr, rest), do: {:ok, expr, rest}

  # A `-` directly before a number is the number's sign, as DataFusion reads
  # it (verified); before anything else, even a parenthesised number, it is a
  # negation.
  defp parse_primary([{:tok, "-"}, {:num, text} | rest]), do: {:ok, number(text, true), rest}

  defp parse_primary([{:tok, "-"} | rest]) do
    with {:ok, inner, rest} <- parse_factor(rest), do: {:ok, {:neg, inner}, rest}
  end

  defp parse_primary([{:num, text} | rest]), do: {:ok, number(text, false), rest}
  defp parse_primary([{:str, text} | rest]), do: {:ok, {:lit, SQLLiteral.unescape(text)}, rest}
  defp parse_primary([{:param, _name} = param | rest]), do: {:ok, param, rest}

  defp parse_primary([{:quoted, name} | rest]),
    do: {:ok, {:field, SQLLiteral.identifier_name(name)}, rest}

  defp parse_primary([{:qualified, qualifier, column} | rest]),
    do: {:ok, {:field, {:qualified, qualifier, column}}, rest}

  defp parse_primary([{:word, word}, {:tok, "("} | args]) do
    case String.upcase(word) do
      "CAST" -> parse_cast(args)
      _call -> parse_named_call(word, args)
    end
  end

  defp parse_primary([{:word, word} | rest] = tokens) do
    if keyword?(word, "CASE"), do: parse_case(rest), else: parse_word(word, rest, tokens)
  end

  defp parse_primary([{:tok, "("} | rest]) do
    case parse_or(rest) do
      {:ok, inner, [{:tok, ")"} | rest]} -> {:ok, inner, rest}
      {:ok, _inner, _rest} -> {:error, :unbalanced_parenthesis}
      {:error, _reason} = error -> error
    end
  end

  defp parse_primary(_tokens), do: {:error, :unexpected_token}

  # A bare `true`, `false` or `null` is a literal; any other word a column.
  defp parse_word(word, rest, _tokens), do: {:ok, word_value(word), rest}

  @spec word_value(binary()) :: t()
  defp word_value(word) do
    case String.downcase(word) do
      "true" -> {:lit, true}
      "false" -> {:lit, false}
      "null" -> {:lit, nil}
      _column -> {:field, word}
    end
  end

  # CAST(expr AS type): the tokens are `(`, the expression, `AS`, the type
  # name and `)`.
  defp parse_cast(tokens) do
    with {:ok, inner, [{:word, as_kw}, {:word, type}, {:tok, ")"} | rest]}
         when as_kw in ["AS", "as", "As"] <- parse_or(tokens),
         {:ok, target} <- cast_type(type) do
      {:ok, {:cast, inner, target}, rest}
    else
      {:error, _reason} = error -> error
      _shape -> {:error, :invalid_cast}
    end
  end

  defp parse_named_call(name, args) do
    case SQLFunctions.lookup(name) do
      nil -> {:error, {:unsupported_function, name}}
      function -> parse_call(function, args)
    end
  end

  # CASE [operand] WHEN condition THEN result ... [ELSE result] END.
  defp parse_case(tokens) do
    with {:ok, operand, rest} <- case_operand(tokens),
         {:ok, whens, rest} <- case_whens(rest, []),
         {:ok, otherwise, rest} <- case_else(rest) do
      case rest do
        [{:word, end_word} | rest] ->
          if keyword?(end_word, "END"),
            do: {:ok, {:case, operand, whens, otherwise}, rest},
            else: {:error, :invalid_case}

        _other ->
          {:error, :invalid_case}
      end
    end
  end

  defp case_operand([{:word, word} | _rest] = tokens) do
    if keyword?(word, "WHEN"), do: {:ok, nil, tokens}, else: parse_or(tokens)
  end

  defp case_operand(tokens), do: parse_or(tokens)

  defp case_whens([{:word, word} | rest], acc) do
    if keyword?(word, "WHEN") do
      with {:ok, condition, [{:word, then_word} | rest]} <- parse_or(rest),
           true <- keyword?(then_word, "THEN"),
           {:ok, result, rest} <- parse_or(rest) do
        case_whens(rest, [{condition, result} | acc])
      else
        {:error, _reason} = error -> error
        _shape -> {:error, :invalid_case}
      end
    else
      case_whens_done([{:word, word} | rest], acc)
    end
  end

  defp case_whens(tokens, acc), do: case_whens_done(tokens, acc)

  defp case_whens_done(_tokens, []), do: {:error, :invalid_case}
  defp case_whens_done(tokens, acc), do: {:ok, Enum.reverse(acc), tokens}

  defp case_else([{:word, word} | rest] = tokens) do
    if keyword?(word, "ELSE") do
      with {:ok, otherwise, rest} <- parse_or(rest), do: {:ok, otherwise, rest}
    else
      {:ok, nil, tokens}
    end
  end

  defp case_else(tokens), do: {:ok, nil, tokens}

  @spec keyword?(binary(), binary()) :: boolean()
  defp keyword?(word, keyword), do: String.upcase(word) == keyword

  # A number as the engine types it: `Int64`, then `UInt64` (never for a
  # negative one), then `Float64`.
  @spec number(binary(), boolean()) :: t()
  defp number(text, negative) do
    if Regex.match?(~r/\A[0-9]+\z/, text) do
      value = String.to_integer(text)
      value = if negative, do: -value, else: value

      cond do
        value >= @int64_min and value <= @int64_max -> {:lit, value}
        value > 0 and value <= @uint64_max -> {:uint, value}
        true -> float_literal(text, negative)
      end
    else
      float_literal(text, negative)
    end
  end

  @spec float_literal(binary(), boolean()) :: t()
  defp float_literal(text, negative) do
    case SQLLiteral.float_value(text) do
      :nonfinite -> {:lit, if(negative, do: :neg_inf, else: :inf)}
      value -> {:lit, if(negative, do: -value, else: value)}
    end
  end

  @spec parse_call(SQLFunctions.name(), [term()]) :: parsed()
  defp parse_call(function, [{:tok, ")"} | rest]), do: {:ok, {:call, function, []}, rest}
  defp parse_call(function, tokens), do: parse_call_args(function, tokens, [])

  defp parse_call_args(function, tokens, args) do
    case parse_or(tokens) do
      {:ok, arg, [{:tok, ","} | rest]} ->
        parse_call_args(function, rest, [arg | args])

      {:ok, arg, [{:tok, ")"} | rest]} ->
        {:ok, {:call, function, Enum.reverse([arg | args])}, rest}

      {:ok, _arg, _rest} ->
        {:error, :unbalanced_parenthesis}

      {:error, _reason} = error ->
        error
    end
  end

  # The SQL type names DataFusion accepts for the casts the double performs
  # (verified: `INT` is `Int32`, `SMALLINT` `Int16`, `TINYINT` `Int8`,
  # `BIGINT` `Int64`, `DOUBLE` `Float64`); anything else is outside the
  # subset, `FLOAT` and `REAL` (`Float32`) and the unsigned and decimal types
  # among it.
  @spec cast_type(binary()) :: {:ok, cast_type()} | {:error, term()}
  defp cast_type(type) do
    case String.upcase(type) do
      t when t in ~w(INTEGER INT INT4) -> {:ok, :int32}
      t when t in ~w(SMALLINT INT2) -> {:ok, :int16}
      "TINYINT" -> {:ok, :int8}
      t when t in ~w(BIGINT INT8) -> {:ok, :int64}
      t when t in ~w(DOUBLE FLOAT8) -> {:ok, :float}
      t when t in ~w(VARCHAR STRING TEXT CHAR) -> {:ok, :string}
      _other -> {:error, {:unsupported_cast_type, type}}
    end
  end

  # ---------------------------------------------------------------------------
  # Walking
  # ---------------------------------------------------------------------------

  @doc "The expressions directly inside an expression, in the order written."
  @spec children(t()) :: [t()]
  def children({:neg, inner}), do: [inner]
  def children({:pos, inner}), do: [inner]
  def children({:not, inner}), do: [inner]
  def children({:cast, inner, _type}), do: [inner]
  def children({:op, _op, left, right}), do: [left, right]
  def children({:cmp, _op, left, right}), do: [left, right]
  def children({:and, left, right}), do: [left, right]
  def children({:or, left, right}), do: [left, right]
  def children({:concat, left, right}), do: [left, right]
  def children({:call, _name, args}), do: args
  def children({:is_null, inner, _negated}), do: [inner]
  def children({:is_bool, inner, _value, _negated}), do: [inner]
  def children({:is_distinct, left, right, _negated}), do: [left, right]
  def children({:in, inner, items, _negated}), do: [inner | items]
  def children({:between, inner, low, high, _negated}), do: [inner, low, high]
  def children({:like, inner, pattern, _negated, _ilike, _regex}), do: [inner, pattern]

  def children({:case, operand, whens, otherwise}) do
    List.wrap(operand) ++
      Enum.flat_map(whens, fn {condition, result} -> [condition, result] end) ++
      List.wrap(otherwise)
  end

  def children(_leaf), do: []

  @doc """
  The expression with `fun` applied to each expression directly inside it
  (a leaf is returned as it is).
  """
  @spec map_children(t(), (t() -> t())) :: t()
  def map_children({:neg, inner}, fun), do: {:neg, fun.(inner)}
  def map_children({:pos, inner}, fun), do: {:pos, fun.(inner)}
  def map_children({:not, inner}, fun), do: {:not, fun.(inner)}
  def map_children({:cast, inner, type}, fun), do: {:cast, fun.(inner), type}
  def map_children({:op, op, left, right}, fun), do: {:op, op, fun.(left), fun.(right)}
  def map_children({:cmp, op, left, right}, fun), do: {:cmp, op, fun.(left), fun.(right)}
  def map_children({:and, left, right}, fun), do: {:and, fun.(left), fun.(right)}
  def map_children({:or, left, right}, fun), do: {:or, fun.(left), fun.(right)}
  def map_children({:concat, left, right}, fun), do: {:concat, fun.(left), fun.(right)}
  def map_children({:call, name, args}, fun), do: {:call, name, Enum.map(args, fun)}
  def map_children({:is_null, inner, negated}, fun), do: {:is_null, fun.(inner), negated}

  def map_children({:is_bool, inner, value, negated}, fun),
    do: {:is_bool, fun.(inner), value, negated}

  def map_children({:is_distinct, left, right, negated}, fun),
    do: {:is_distinct, fun.(left), fun.(right), negated}

  def map_children({:in, inner, items, negated}, fun),
    do: {:in, fun.(inner), Enum.map(items, fun), negated}

  def map_children({:between, inner, low, high, negated}, fun),
    do: {:between, fun.(inner), fun.(low), fun.(high), negated}

  def map_children({:like, inner, pattern, negated, ilike, regex}, fun),
    do: {:like, fun.(inner), fun.(pattern), negated, ilike, regex}

  def map_children({:case, operand, whens, otherwise}, fun) do
    {:case, operand && fun.(operand),
     Enum.map(whens, fn {condition, result} -> {fun.(condition), fun.(result)} end),
     otherwise && fun.(otherwise)}
  end

  def map_children(leaf, _fun), do: leaf

  @doc "Whether `predicate` holds for the expression or for any expression inside it."
  @spec any?(t(), (t() -> boolean())) :: boolean()
  def any?(expr, predicate),
    do: predicate.(expr) or Enum.any?(children(expr), &any?(&1, predicate))

  @doc """
  The first value `fun` finds, other than `nil`: in the expressions inside
  `expr`, the innermost first, and last in `expr` itself.
  """
  @spec find_value(t(), (t() -> term())) :: term()
  def find_value(expr, fun),
    do: Enum.find_value(children(expr), &find_value(&1, fun)) || fun.(expr)

  @doc "The columns an expression reads, in order."
  @spec columns(t()) :: [column_ref()]
  def columns({:field, ref}), do: [ref]
  def columns({:uint_col, name}), do: [name]
  def columns(expr), do: Enum.flat_map(children(expr), &columns/1)

  @doc """
  A column reference as the engine prints it in a message: a name bare when
  it is a lower case word, otherwise quoted; a reference to another relation
  as it was written.
  """
  @spec ref_text(column_ref()) :: binary()
  def ref_text({:qualified, qualifier, column}),
    do: SQLLiteral.render_identifier(SQLLiteral.unquoted(qualifier)) <> "." <> render_part(column)

  def ref_text(name), do: SQLLiteral.render_identifier(name)

  @spec render_part(binary()) :: binary()
  defp render_part(part), do: SQLLiteral.render_identifier(SQLLiteral.unquoted(part))

  @doc """
  An expression as the engine writes it in a column's name: columns
  qualified by `qualifier`, literals with their type, operators infix and
  unparenthesised, a call's arguments joined by a bare comma. A `CAST` is
  written as the expression it casts when `casts` is `:drop` (the engine's
  name for the column) and refused when it is `:refuse` (the planner's
  printing, which keeps the cast under conditions the double does not model).
  `:display` is the planner's text of an expression in its error for a `WHERE` that is
  one (`'main.n * (main.x + Int64(1))'`): the arguments of a call apart by a comma and a
  space, a sum or difference under a product in parentheses, `power` and
  `character_length` with the name the query gave them after `AS`; a cast is refused.

  Throws `:unrenderable` for what the double does not print: a column when
  `qualifier` is `nil` (the side of a join that holds it is not known), a
  refused cast.
  """
  @spec render(t(), binary() | nil, casts()) :: binary()
  def render({kind, _value} = leaf, qualifier, casts)
      when kind in [:field, :uint_col, :lit, :uint, :raw, :param],
      do: render_leaf(leaf, qualifier, casts)

  def render({:op, op, left, right}, qualifier, :display) do
    shown = &operand(&1, op, qualifier)
    "#{shown.(left)} #{symbol(op)} #{shown.(right)}"
  end

  def render({:op, op, left, right}, qualifier, casts),
    do: "#{render(left, qualifier, casts)} #{symbol(op)} #{render(right, qualifier, casts)}"

  def render({:neg, inner}, qualifier, casts), do: "(- #{render(inner, qualifier, casts)})"

  # The engine prints a unary plus as its operand.
  def render({:pos, inner}, qualifier, casts), do: render(inner, qualifier, casts)

  def render({:call, function, args}, qualifier, :display) do
    shown = Enum.map_join(args, ", ", &render(&1, qualifier, :display))
    named = Enum.map_join(args, ",", &render(&1, qualifier, :drop))

    case function do
      :pow -> "power(#{shown}) AS pow(#{named})"
      :length -> "character_length(#{shown}) AS length(#{named})"
      _plain -> "#{function}(#{shown})"
    end
  end

  # The name of a `length` is the text the query gave it, which prints the arguments of the
  # calls under it apart by a comma and a space (verified: `length(coalesce(s, 'a'))` is
  # `length(coalesce(cpu.s, Utf8("a")))`, where `abs(coalesce(s, 'a'))` has no space).
  # A cast under it keeps its text there (`length(CAST(cpu.n AS Utf8))`), which is refused.
  def render({:call, :length, [arg]}, qualifier, :drop),
    do: "length(#{render(arg, qualifier, :display)})"

  def render({:call, function, args}, qualifier, casts),
    do: "#{function}(#{Enum.map_join(args, ",", &render(&1, qualifier, casts))})"

  def render({:cast, inner, _type}, qualifier, :drop), do: render(inner, qualifier, :drop)

  def render({:cast, _inner, _type}, _qualifier, casts) when casts in [:refuse, :display],
    do: throw(:unrenderable)

  def render(node, qualifier, casts), do: render_form(node, qualifier, casts)

  @spec render_leaf(t(), binary() | nil, casts()) :: binary()
  defp render_leaf({:field, ref}, qualifier, _casts), do: qualified(ref, qualifier)
  defp render_leaf({:uint_col, name}, qualifier, _casts), do: qualified(name, qualifier)

  defp render_leaf({:lit, value}, _qualifier, _casts) when is_integer(value),
    do: "Int64(#{value})"

  defp render_leaf({:lit, value}, _qualifier, _casts) when is_float(value),
    do: "Float64(#{Format.render_decimal(value)})"

  defp render_leaf({:lit, value}, _qualifier, _casts) when is_binary(value),
    do: ~s|Utf8("#{value}")|

  defp render_leaf({:lit, value}, _qualifier, _casts) when is_boolean(value),
    do: "Boolean(#{value})"

  defp render_leaf({:lit, nil}, _qualifier, _casts), do: "NULL"
  defp render_leaf({:lit, :inf}, _qualifier, _casts), do: "Float64(inf)"
  defp render_leaf({:lit, :neg_inf}, _qualifier, _casts), do: "Float64(-inf)"
  defp render_leaf({:uint, value}, _qualifier, _casts), do: "UInt64(#{value})"
  defp render_leaf({:raw, text}, _qualifier, _casts), do: text
  defp render_leaf({:param, name}, _qualifier, _casts), do: "$" <> name

  @spec render_form(t(), binary() | nil, casts()) :: binary()
  defp render_form({:cmp, op, left, right}, qualifier, casts),
    do: join([left, symbol(op), right], qualifier, casts)

  defp render_form({:and, left, right}, qualifier, casts),
    do: join([left, "AND", right], qualifier, casts)

  defp render_form({:or, left, right}, qualifier, casts),
    do: join([left, "OR", right], qualifier, casts)

  defp render_form({:concat, left, right}, qualifier, casts),
    do: join([left, "||", right], qualifier, casts)

  defp render_form({:not, inner}, qualifier, casts), do: join(["NOT", inner], qualifier, casts)

  defp render_form({:is_null, inner, negated}, qualifier, casts),
    do: join([inner, if(negated, do: "IS NOT NULL", else: "IS NULL")], qualifier, casts)

  defp render_form({:is_bool, inner, value, negated}, qualifier, casts) do
    word = if value, do: "TRUE", else: "FALSE"
    join([inner, if(negated, do: "IS NOT " <> word, else: "IS " <> word)], qualifier, casts)
  end

  defp render_form({:is_distinct, left, right, negated}, qualifier, casts) do
    word = if negated, do: "IS NOT DISTINCT FROM", else: "IS DISTINCT FROM"
    join([left, word, right], qualifier, casts)
  end

  defp render_form({:in, inner, items, negated}, qualifier, casts) do
    word = if negated, do: "NOT IN", else: "IN"

    list = Enum.map_join(items, ", ", &render(&1, qualifier, casts))
    # The planner's text of a list is in brackets and parentheses (`IN ([a, b])`); the name
    # of a select item is not.
    list = if casts == :display, do: "([#{list}])", else: list
    "#{render(inner, qualifier, casts)} #{word} " <> list
  end

  defp render_form({:between, inner, low, high, negated}, qualifier, casts) do
    word = if negated, do: "NOT BETWEEN", else: "BETWEEN"
    join([inner, word, low, "AND", high], qualifier, casts)
  end

  defp render_form({:like, inner, pattern, negated, ilike, _regex}, qualifier, casts) do
    word = if(negated, do: "NOT ", else: "") <> if(ilike, do: "ILIKE", else: "LIKE")
    join([inner, word, pattern], qualifier, casts)
  end

  defp render_form({:case, operand, whens, otherwise}, qualifier, casts) do
    head = if operand, do: ["CASE", operand], else: ["CASE"]

    branches =
      Enum.flat_map(whens, fn {condition, result} -> ["WHEN", condition, "THEN", result] end)

    tail = if otherwise, do: ["ELSE", otherwise, "END"], else: ["END"]

    join(head ++ branches ++ tail, qualifier, casts)
  end

  # An operand of an arithmetic operator in the planner's text: in parentheses when it is
  # an operator that binds less tightly.
  @spec operand(t(), :+ | :- | :* | :/ | :rem, binary() | nil) :: binary()
  defp operand({:op, inner, _left, _right} = expr, op, qualifier) do
    text = render(expr, qualifier, :display)
    if precedence(inner) < precedence(op), do: "(" <> text <> ")", else: text
  end

  defp operand(expr, _op, qualifier), do: render(expr, qualifier, :display)

  defp precedence(op) when op in [:+, :-], do: 30
  defp precedence(_product), do: 40

  # The words and expressions of a name, one space apart.
  @spec join([binary() | t()], binary() | nil, casts()) :: binary()
  defp join(parts, qualifier, casts) do
    Enum.map_join(parts, " ", fn
      part when is_binary(part) -> part
      expr -> render(expr, qualifier, casts)
    end)
  end

  @spec qualified(column_ref(), binary() | nil) :: binary()
  defp qualified(_ref, nil), do: throw(:unrenderable)
  defp qualified({:qualified, qualifier, column}, _qualifier), do: qualifier <> "." <> column
  defp qualified(name, qualifier), do: qualifier <> "." <> name

  @doc "The SQL symbol of an arithmetic or a comparison operator."
  @spec symbol(:+ | :- | :* | :/ | :rem | comparison()) :: binary()
  def symbol(:rem), do: "%"
  def symbol(:eq), do: "="
  def symbol(:ne), do: "!="
  def symbol(:gt), do: ">"
  def symbol(:lt), do: "<"
  def symbol(:gte), do: ">="
  def symbol(:lte), do: "<="
  def symbol(op), do: Atom.to_string(op)
end
