defmodule InfluxElixir.Client.Local.SQLExpr do
  @moduledoc """
  The arithmetic expressions of a SQL text: a field reference, a literal, a
  `$name` placeholder, an operation, a unary minus, a `CAST` or a call of one
  of `InfluxElixir.Client.Local.SQLFunctions`. They stand in an aggregate's
  argument, a projection, a `WHERE` operand and an `ORDER BY` term.

  A `$name` is kept as `{:param, name}` and replaced by
  `InfluxElixir.Client.Local.SQLBind`; a bound non-negative integer is
  `{:uint, n}`, the engine's `UInt64`.
  """

  alias InfluxElixir.Client.Local.{SQLFunctions, SQLLiteral}

  @typedoc """
  An arithmetic expression: a field reference, a literal, a `$name`
  placeholder (`{:param, name}`, replaced by `InfluxElixir.Client.Local.SQLBind`)
  or a bound non-negative integer parameter (`{:uint, n}`, the engine's
  `UInt64`), or an operation over expressions.
  """
  @type t ::
          {:field, binary()}
          | {:lit, number() | binary() | boolean()}
          | {:uint, non_neg_integer()}
          | {:param, binary()}
          | {:op, :+ | :- | :* | :/ | :rem, t(), t()}
          | {:neg, t()}
          | {:cast, t(), cast_type()}
          | {:call, SQLFunctions.name(), [t()]}

  @typedoc "`CAST(expr AS INTEGER | DOUBLE | VARCHAR)` targets (and their synonyms)."
  @type cast_type :: :integer | :float | :string

  @expr_token ~r/\s*(?:([0-9]+\.[0-9]+|[0-9]+)|\$(\w+)|(\w+)|([()+\-*\/%,]))/u

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
  engine's planner does.
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

    consumed =
      matches |> Enum.map(fn [full | _groups] -> byte_size(String.trim(full)) end) |> Enum.sum()

    if consumed == byte_size(String.replace(str, ~r/\s/u, "")) do
      {:ok, Enum.map(matches, &expr_token/1)}
    else
      {:error, :unexpected_character}
    end
  end

  # A match's groups are a number, a `$name`, an identifier or an operator;
  # the groups after the last one that matched are not in the list.
  @spec expr_token([binary()]) :: term()
  defp expr_token([_full | groups]) do
    case groups ++ List.duplicate("", 4 - length(groups)) do
      [num, "", "", ""] when num != "" -> {:lit, SQLLiteral.coerce(num)}
      ["", name, "", ""] when name != "" -> {:param, name}
      ["", "", ident, ""] when ident != "" -> {:field, ident}
      ["", "", "", op] -> {:tok, op}
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
  # Unary minus (`-n`, `-(a + b)`), as DataFusion reads it (verified).
  defp parse_factor([{:tok, "-"} | rest]) do
    with {:ok, inner, rest} <- parse_factor(rest), do: {:ok, {:neg, inner}, rest}
  end

  defp parse_factor([{:lit, _value} = lit | rest]), do: {:ok, lit, rest}
  defp parse_factor([{:param, _name} = param | rest]), do: {:ok, param, rest}

  # CAST(expr AS type): the tokens are `CAST`, `(`, the expression, `AS`,
  # the type name and `)`.
  defp parse_factor([{:field, cast}, {:tok, "("} | rest]) when cast in ["CAST", "cast", "Cast"] do
    with {:ok, inner, [{:field, as_kw}, {:field, type}, {:tok, ")"} | rest]}
         when as_kw in ["AS", "as", "As"] <- parse_sum(rest),
         {:ok, target} <- cast_type(type) do
      {:ok, {:cast, inner, target}, rest}
    else
      {:error, _reason} = error -> error
      _shape -> {:error, :invalid_cast}
    end
  end

  defp parse_factor([{:field, name} = field, {:tok, "("} | args] = tokens) do
    case SQLFunctions.lookup(name) do
      nil -> {:ok, field, tl(tokens)}
      function -> parse_call(function, args)
    end
  end

  defp parse_factor([{:field, _name} = field | rest]), do: {:ok, field, rest}

  defp parse_factor([{:tok, "("} | rest]) do
    case parse_sum(rest) do
      {:ok, inner, [{:tok, ")"} | rest]} -> {:ok, inner, rest}
      {:ok, _inner, _rest} -> {:error, :unbalanced_parenthesis}
      {:error, _reason} = error -> error
    end
  end

  defp parse_factor(_tokens), do: {:error, :unexpected_token}

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

  # The SQL type names DataFusion accepts for the three casts the double
  # performs; anything else (BOOLEAN, TIMESTAMP, ...) is outside the subset.
  @spec cast_type(binary()) :: {:ok, cast_type()} | {:error, term()}
  defp cast_type(type) do
    case String.upcase(type) do
      t when t in ~w(INTEGER INT BIGINT SMALLINT TINYINT) -> {:ok, :integer}
      t when t in ~w(DOUBLE FLOAT REAL) -> {:ok, :float}
      t when t in ~w(VARCHAR STRING TEXT CHAR) -> {:ok, :string}
      _other -> {:error, {:unsupported_cast_type, type}}
    end
  end

  @doc "The columns an expression reads, in order."
  @spec columns(t()) :: [binary()]
  def columns({:field, name}), do: [name]
  def columns({:lit, _value}), do: []
  def columns({:uint, _value}), do: []
  def columns({:param, _name}), do: []
  def columns({:neg, inner}), do: columns(inner)
  def columns({:cast, inner, _type}), do: columns(inner)
  def columns({:op, _op, left, right}), do: columns(left) ++ columns(right)
  def columns({:call, _name, args}), do: Enum.flat_map(args, &columns/1)
end
