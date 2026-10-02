defmodule InfluxElixir.Client.Local.SQLExpr do
  @moduledoc """
  The arithmetic expressions of a SQL text: a column, a literal, a `$name`
  placeholder, an operation, a unary minus, a `CAST` or a call of one of
  `InfluxElixir.Client.Local.SQLFunctions`. They stand in an aggregate's
  argument, a projection, a `WHERE` operand and an `ORDER BY` term.

  A `$name` is kept as `{:param, name}` and replaced by
  `InfluxElixir.Client.Local.SQLBind`; a bound non-negative integer is
  `{:uint, n}`, the engine's `UInt64`.

  A number is typed as the engine types it (verified against InfluxDB 3
  Core): an integer that fits `Int64` is one, a larger one that fits `UInt64`
  is a `{:uint, n}`, anything else is a `Float64`; a `-` written directly
  before a number is part of it (`-9223372036854775808` is an `Int64`, while
  `-(9223372036854775808)` negates a `UInt64`, which the engine refuses). A
  float too large for a double is `{:lit, :inf}` or `{:lit, :neg_inf}`, which the engine
  answers as a JSON `null` and compares as infinity.

  `render/3` writes an expression as the engine names a column: the name
  that stands for a select item without an alias.
  """

  alias InfluxElixir.Client.Local.{Format, SQLFunctions, SQLLimits, SQLLiteral}

  require SQLLimits

  @typedoc """
  A column an expression reads: its name, or a reference to a relation the
  query does not have (`"XQA".v`, `foo.v`), kept as it was written so the
  engine's error can print it.
  """
  @type column_ref :: binary() | {:qualified, binary(), binary()}

  @typedoc """
  An arithmetic expression: a column, a literal, a `$name`
  placeholder (`{:param, name}`, replaced by `InfluxElixir.Client.Local.SQLBind`)
  or a bound non-negative integer parameter (`{:uint, n}`, the engine's
  `UInt64`), or an operation over expressions. The parser reads a column as
  `{:field, name}`; `InfluxElixir.Client.Local.SQLTyping` reads one the store
  holds as `UInt64` as `{:uint_col, name}`.
  """
  @type t ::
          {:field, column_ref()}
          | {:lit, number() | binary() | boolean() | nil | :inf | :neg_inf}
          | {:uint_col, binary()}
          | {:uint, non_neg_integer()}
          | {:param, binary()}
          | {:op, :+ | :- | :* | :/ | :rem, t(), t()}
          | {:neg, t()}
          | {:cast, t(), cast_type()}
          | {:call, SQLFunctions.name(), [t()]}
          | {:unreadable, binary()}

  @typedoc """
  `CAST(expr AS type)` targets (and their synonyms): the integer types by
  width (`INTEGER` is 32 bits), `DOUBLE`, and text.
  """
  @type cast_type :: :int8 | :int16 | :int32 | :int64 | :float | :string

  @typedoc "How `render/3` treats a `CAST`: written as the engine names it (gone), or refused."
  @type casts :: :drop | :refuse

  @int64_min SQLLimits.int64_min()
  @int64_max SQLLimits.int64_max()
  @uint64_max SQLLimits.uint64_max()

  @number "(?:[0-9]+\\.[0-9]*|\\.[0-9]+|[0-9]+)(?:[eE][+-]?[0-9]+)?"
  @quoted ~S{"(?:[^"]|"")*"}
  @expr_token ~r/\s*(?:(#{@number})|\$(\w+)|((?:\w+|#{@quoted})(?:\.(?:\w+|#{@quoted}))?)|([()+\-*\/%,]))/u

  # `col::INTEGER` is DataFusion's shorthand for `CAST(col AS INTEGER)`.
  @shorthand_cast ~r/(\w+)::(\w+)/u

  @doc """
  Parses an expression (recursive descent, standard precedence):

      expr   := term   (('+' | '-') term)*
      term   := factor (('*' | '/' | '%') factor)*
      factor := '-' factor | number | identifier | '(' expr ')'
              | function '(' [expr (',' expr)*] ')'

  `function` is one of `InfluxElixir.Client.Local.SQLFunctions`; any number of
  arguments parses, and the executor answers a wrong count or type as the
  engine's planner does. A call of any other function is
  `{:error, {:unsupported_function, name}}`.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(str) do
    with {:ok, tokens} <- tokenize_expr(str),
         {:ok, ast, []} <- parse_sum(tokens) do
      {:ok, ast}
    else
      {:ok, _ast, _leftover} -> {:error, :trailing_tokens}
      {:error, _reason} = error -> error
    end
  end

  # Every non-blank byte must belong to a token; anything the scanner skipped
  # (a comma, a quote) makes the expression invalid.
  @spec tokenize_expr(binary()) :: {:ok, [term()]} | {:error, term()}
  defp tokenize_expr(str) do
    str = Regex.replace(@shorthand_cast, str, "CAST(\\1 AS \\2)")
    matches = Regex.scan(@expr_token, str)

    if String.trim(Regex.replace(@expr_token, str, "")) == "" do
      {:ok, Enum.map(matches, &expr_token/1)}
    else
      {:error, :unexpected_character}
    end
  end

  # A match's groups are a number, a `$name`, a name or a (possibly
  # qualified) quoted name, or an operator; the groups after the last one
  # that matched are not in the list.
  @spec expr_token([binary()]) :: term()
  defp expr_token([_full | groups]) do
    case groups ++ List.duplicate("", 4 - length(groups)) do
      [num, "", "", ""] when num != "" -> {:num, num}
      ["", name, "", ""] when name != "" -> {:param, name}
      ["", "", ident, ""] when ident != "" -> name_token(ident)
      ["", "", "", op] -> {:tok, op}
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

  @spec parse_sum([term()]) :: {:ok, t(), [term()]} | {:error, term()}
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

  @spec parse_product([term()]) :: {:ok, t(), [term()]} | {:error, term()}
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

  defp parse_product_tail(left, rest), do: {:ok, left, rest}

  @spec operator(binary()) :: :+ | :- | :* | :/ | :rem
  defp operator("+"), do: :+
  defp operator("-"), do: :-
  defp operator("*"), do: :*
  defp operator("/"), do: :/
  defp operator("%"), do: :rem

  @spec parse_factor([term()]) :: {:ok, t(), [term()]} | {:error, term()}
  # A `-` directly before a number is the number's sign, as DataFusion reads
  # it (verified); before anything else, even a parenthesised number, it is a
  # negation.
  defp parse_factor([{:tok, "-"}, {:num, text} | rest]), do: {:ok, number(text, true), rest}

  defp parse_factor([{:tok, "-"} | rest]) do
    with {:ok, inner, rest} <- parse_factor(rest), do: {:ok, {:neg, inner}, rest}
  end

  defp parse_factor([{:num, text} | rest]), do: {:ok, number(text, false), rest}
  defp parse_factor([{:param, _name} = param | rest]), do: {:ok, param, rest}

  defp parse_factor([{:quoted, name} | rest]),
    do: {:ok, {:field, SQLLiteral.identifier_name(name)}, rest}

  defp parse_factor([{:qualified, qualifier, column} | rest]),
    do: {:ok, {:field, {:qualified, qualifier, column}}, rest}

  # CAST(expr AS type): the tokens are `CAST`, `(`, the expression, `AS`,
  # the type name and `)`.
  defp parse_factor([{:word, cast}, {:tok, "("} | rest]) when cast in ["CAST", "cast", "Cast"] do
    with {:ok, inner, [{:word, as_kw}, {:word, type}, {:tok, ")"} | rest]}
         when as_kw in ["AS", "as", "As"] <- parse_sum(rest),
         {:ok, target} <- cast_type(type) do
      {:ok, {:cast, inner, target}, rest}
    else
      {:error, _reason} = error -> error
      _shape -> {:error, :invalid_cast}
    end
  end

  defp parse_factor([{:word, name}, {:tok, "("} | args]) do
    case SQLFunctions.lookup(name) do
      nil -> {:error, {:unsupported_function, name}}
      function -> parse_call(function, args)
    end
  end

  defp parse_factor([{:word, word} | rest]), do: {:ok, word_value(word), rest}

  defp parse_factor([{:tok, "("} | rest]) do
    case parse_sum(rest) do
      {:ok, inner, [{:tok, ")"} | rest]} -> {:ok, inner, rest}
      {:ok, _inner, _rest} -> {:error, :unbalanced_parenthesis}
      {:error, _reason} = error -> error
    end
  end

  defp parse_factor(_tokens), do: {:error, :unexpected_token}

  # A bare `true`, `false` or `null` is a literal; any other word a column.
  @spec word_value(binary()) :: t()
  defp word_value(word) do
    case String.downcase(word) do
      "true" -> {:lit, true}
      "false" -> {:lit, false}
      "null" -> {:lit, nil}
      _column -> {:field, word}
    end
  end

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

  @spec parse_call(SQLFunctions.name(), [term()]) :: {:ok, t(), [term()]} | {:error, term()}
  defp parse_call(function, [{:tok, ")"} | rest]), do: {:ok, {:call, function, []}, rest}
  defp parse_call(function, tokens), do: parse_call_args(function, tokens, [])

  defp parse_call_args(function, tokens, args) do
    case parse_sum(tokens) do
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

  @doc "The columns an expression reads, in order."
  @spec columns(t()) :: [column_ref()]
  def columns({:field, ref}), do: [ref]
  def columns({:uint_col, name}), do: [name]
  def columns({:lit, _value}), do: []
  def columns({:uint, _value}), do: []
  def columns({:param, _name}), do: []
  def columns({:unreadable, _text}), do: []
  def columns({:neg, inner}), do: columns(inner)
  def columns({:cast, inner, _type}), do: columns(inner)
  def columns({:op, _op, left, right}), do: columns(left) ++ columns(right)
  def columns({:call, _name, args}), do: Enum.flat_map(args, &columns/1)

  @doc """
  A column reference as the engine prints it in a message: a name bare when
  it is a lower case word, otherwise quoted; a reference to another relation
  as it was written.
  """
  @spec ref_text(column_ref()) :: binary()
  def ref_text({:qualified, qualifier, column}),
    do: SQLLiteral.render_identifier(bare_name(qualifier)) <> "." <> render_part(column)

  def ref_text(name), do: SQLLiteral.render_identifier(name)

  @spec render_part(binary()) :: binary()
  defp render_part(part), do: SQLLiteral.render_identifier(bare_name(part))

  @spec bare_name(binary()) :: binary()
  defp bare_name(text) do
    if SQLLiteral.identifier?(text), do: SQLLiteral.identifier_name(text), else: text
  end

  @doc """
  An expression as the engine writes it in a column's name: columns
  qualified by `qualifier`, literals with their type, operators infix and
  unparenthesised, a call's arguments joined by a bare comma. A `CAST` is
  written as the expression it casts when `casts` is `:drop` (the engine's
  name for the column) and refused when it is `:refuse` (the planner's
  printing, which keeps the cast under conditions the double does not model).

  Throws `:unrenderable` for what the double does not print: a column when
  `qualifier` is `nil` (the side of a join that holds it is not known), a
  refused cast.
  """
  @spec render(t(), binary() | nil, casts()) :: binary()
  def render({:field, ref}, qualifier, _casts), do: qualified(ref, qualifier)
  def render({:uint_col, name}, qualifier, _casts), do: qualified(name, qualifier)
  def render({:lit, value}, _qualifier, _casts) when is_integer(value), do: "Int64(#{value})"

  def render({:lit, value}, _qualifier, _casts) when is_float(value),
    do: "Float64(#{Format.render_decimal(value)})"

  def render({:lit, value}, _qualifier, _casts) when is_binary(value), do: ~s|Utf8("#{value}")|
  def render({:lit, value}, _qualifier, _casts) when is_boolean(value), do: "Boolean(#{value})"
  def render({:lit, nil}, _qualifier, _casts), do: "NULL"
  def render({:lit, :inf}, _qualifier, _casts), do: "Float64(inf)"
  def render({:lit, :neg_inf}, _qualifier, _casts), do: "Float64(-inf)"
  def render({:uint, value}, _qualifier, _casts), do: "UInt64(#{value})"
  def render({:param, name}, _qualifier, _casts), do: "$" <> name

  def render({:op, op, left, right}, qualifier, casts),
    do: "#{render(left, qualifier, casts)} #{symbol(op)} #{render(right, qualifier, casts)}"

  def render({:neg, inner}, qualifier, casts), do: "(- #{render(inner, qualifier, casts)})"

  def render({:call, function, args}, qualifier, casts),
    do: "#{function}(#{Enum.map_join(args, ",", &render(&1, qualifier, casts))})"

  def render({:cast, inner, _type}, qualifier, :drop), do: render(inner, qualifier, :drop)
  def render({:cast, _inner, _type}, _qualifier, :refuse), do: throw(:unrenderable)

  @spec qualified(column_ref(), binary() | nil) :: binary()
  defp qualified(_ref, nil), do: throw(:unrenderable)
  defp qualified({:qualified, qualifier, column}, _qualifier), do: qualifier <> "." <> column
  defp qualified(name, qualifier), do: qualifier <> "." <> name

  @doc "The SQL symbol of an arithmetic operator."
  @spec symbol(:+ | :- | :* | :/ | :rem) :: binary()
  def symbol(:rem), do: "%"
  def symbol(op), do: Atom.to_string(op)
end
