defmodule InfluxElixir.Client.Local.SQLCastType do
  @moduledoc false
  # The type of a `CAST(x AS type)` and an `x::type` in a select list, `WHERE`, `ORDER BY` and
  # `GROUP BY`, for `InfluxElixir.Client.Local` (verified against InfluxDB 3 Core).
  #
  # The grammar of a type is the engine parser's, and the DML statements read it already
  # (`InfluxElixir.Client.Local.SQLDmlType.parse/1`): a name, a size for the names that take
  # one, `UNSIGNED` and `SIGNED` after an integer, the words of `DOUBLE PRECISION` and
  # `TIMESTAMP WITH TIME ZONE`, array suffixes. The syntax check, the splitting of an implicit
  # alias off an item (`n::BIGINT UNSIGNED` has none, `n::INT ARRAY` has `ARRAY`) and the
  # expression parser all read it there, so there is one grammar, and this module only says
  # which of its types the double computes:
  #
  #   * the signed integers of 8 to 64 bits, with or without a size or `SIGNED`
  #   * `DOUBLE`, `DOUBLE PRECISION` and `FLOAT8`
  #   * text: `VARCHAR`, `CHAR`, `STRING` and `TEXT`, with or without a size
  #
  # Every other type the grammar reads is refused by name, each for its own reason, since the
  # double does not model its values (an unsigned integer, `Float32`, a decimal, a date, a
  # timestamp, a boolean, an array), or the engine's error for it (405) stands among the schema
  # errors of the query in an order that is not modelled (a word the planner cannot plan).

  alias InfluxElixir.Client.Local.{SQLDmlType, SQLExpr, SQLTokenizer}

  @typep expr_token :: term()

  # The most tokens a type takes (`DOUBLE PRECISION UNSIGNED`, `TIMESTAMP WITH TIME ZONE`,
  # `DECIMAL ( 10 , 2 )`, with room to spare).
  @window 24

  @doc """
  Reads the type at the front of an expression parser's tokens: the cast target and the tokens
  after the type, or why the double does not compute the cast. `operand` is the expression
  cast, which a refusal of an unsigned integer names the kind of (a `NULL`, a literal, a
  column or another expression: the engine's answers for them differ).
  """
  @spec read([expr_token()], SQLExpr.t()) ::
          {:ok, SQLExpr.cast_type(), [expr_token()]} | {:error, {:cast_type, binary()}}
  def read(tokens, operand) do
    window = tokens |> Enum.take(@window) |> Enum.take_while(&typed?/1)

    case window |> Enum.map(&grammar_token/1) |> SQLDmlType.parse() do
      {:ok, type, rest} -> target(type, Enum.drop(tokens, length(window) - length(rest)), operand)
      _unread -> {:error, {:cast_type, "a type the double does not read"}}
    end
  end

  @doc """
  Whether a text is a whole type (`BIGINT UNSIGNED`, `TIMESTAMP WITH TIME ZONE`): a select item
  that ends in the cast `n::BIGINT` and a word `UNSIGNED` has no alias.
  """
  @spec type?(binary()) :: boolean()
  def type?(text) do
    case SQLTokenizer.tokenize(text) do
      {:ok, tokens} ->
        match?({:ok, _type, [{:eof, _printed, _upper, _line, _col}]}, SQLDmlType.parse(tokens))

      :bail ->
        false
    end
  end

  @spec target(SQLDmlType.t(), [expr_token()], SQLExpr.t()) ::
          {:ok, SQLExpr.cast_type(), [expr_token()]} | {:error, {:cast_type, binary()}}
  defp target(%{family: :int, bits: 8}, rest, _operand), do: {:ok, :int8, rest}
  defp target(%{family: :int, bits: 16}, rest, _operand), do: {:ok, :int16, rest}
  defp target(%{family: :int, bits: 32}, rest, _operand), do: {:ok, :int32, rest}
  defp target(%{family: :int, bits: 64}, rest, _operand), do: {:ok, :int64, rest}
  defp target(%{family: :float, arrow: "Float64"}, rest, _operand), do: {:ok, :float, rest}
  defp target(%{family: :str}, rest, _operand), do: {:ok, :string, rest}

  defp target({:unsupported, printed}, _rest, _operand) do
    {:error,
     {:cast_type,
      "a cast to a type the engine cannot plan (#{printed}): its error (405) stands among " <>
        "the schema errors of the query in an order that is not modelled"}}
  end

  defp target(%{family: :uint, arrow: arrow}, _rest, operand),
    do: unmodelled("of #{operand_kind(operand)} to #{arrow}")

  defp target(%{arrow: arrow}, _rest, _operand), do: unmodelled("to #{arrow}")

  @spec unmodelled(binary()) :: {:error, {:cast_type, binary()}}
  defp unmodelled(cast),
    do: {:error, {:cast_type, "a cast #{cast}: the double does not model that type"}}

  # What is cast, for the refusal of an unsigned integer: the engine's answer for it depends on
  # whether it is a `NULL`, a literal, a column or something computed.
  @spec operand_kind(SQLExpr.t()) :: binary()
  defp operand_kind({:lit, nil}), do: "NULL"
  defp operand_kind({:lit, _value}), do: "a literal"
  defp operand_kind({:field, _column}), do: "a column"
  defp operand_kind(_expression), do: "an expression"

  # The tokens a type is made of: its words, a size and the punctuation of one.
  @spec typed?(expr_token()) :: boolean()
  defp typed?({:word, _word}), do: true
  defp typed?({:num, _text}), do: true
  defp typed?({:tok, symbol}), do: symbol in ["(", ")", ",", "<", ">"]
  defp typed?(_token), do: false

  # An expression token as the type grammar reads it (the lines and columns it names in a
  # parser error are not used: the expression parser's tokens come from a text the tokenizer
  # read, and a text it did not read never gets here, `type?/1` being false for it).
  @spec grammar_token(expr_token()) :: SQLTokenizer.token()
  defp grammar_token({:word, word}), do: {:word, word, String.upcase(word), 1, 1}
  defp grammar_token({:num, text}), do: {:number, text, text, 1, 1}
  defp grammar_token({:tok, symbol}), do: {:symbol, symbol, symbol, 1, 1}
end
