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
  after the type, or why the double does not compute the cast.
  """
  @spec read([expr_token()]) ::
          {:ok, SQLExpr.cast_type(), [expr_token()]} | {:error, {:cast_type, binary()}}
  def read(tokens) do
    window = tokens |> Enum.take(@window) |> Enum.take_while(&typed?/1)

    case window |> Enum.map(&grammar_token/1) |> SQLDmlType.parse() do
      {:ok, type, rest} -> target(type, Enum.drop(tokens, length(window) - length(rest)))
      _unread -> {:error, {:cast_type, "a type the double does not read"}}
    end
  end

  @doc """
  Whether a text is a whole type (`BIGINT UNSIGNED`, `TIMESTAMP WITH TIME ZONE`): a select item
  that ends in the cast `n::BIGINT` and a word `UNSIGNED` has no alias.
  """
  @spec type?(binary()) :: boolean()
  def type?(text) do
    {:ok, tokens} = SQLTokenizer.tokenize(text)
    match?({:ok, _type, [{:eof, _printed, _upper, _line, _col}]}, SQLDmlType.parse(tokens))
  end

  @spec target(SQLDmlType.t(), [expr_token()]) ::
          {:ok, SQLExpr.cast_type(), [expr_token()]} | {:error, {:cast_type, binary()}}
  defp target(%{family: :int, bits: 8}, rest), do: {:ok, :int8, rest}
  defp target(%{family: :int, bits: 16}, rest), do: {:ok, :int16, rest}
  defp target(%{family: :int, bits: 32}, rest), do: {:ok, :int32, rest}
  defp target(%{family: :int, bits: 64}, rest), do: {:ok, :int64, rest}
  defp target(%{family: :float, arrow: "Float64"}, rest), do: {:ok, :float, rest}
  defp target(%{family: :str}, rest), do: {:ok, :string, rest}

  defp target({:unsupported, printed}, _rest) do
    {:error,
     {:cast_type,
      "a cast to a type the engine cannot plan (#{printed}): its error (405) stands among " <>
        "the schema errors of the query in an order that is not modelled"}}
  end

  defp target(%{family: :uint, arrow: arrow}, _rest), do: unmodelled(arrow)
  defp target(%{arrow: arrow}, _rest), do: unmodelled(arrow)

  @spec unmodelled(binary()) :: {:error, {:cast_type, binary()}}
  defp unmodelled(arrow),
    do: {:error, {:cast_type, "a cast to #{arrow}: the double does not model that type"}}

  # The tokens a type is made of: its words, a size and the punctuation of one.
  @spec typed?(expr_token()) :: boolean()
  defp typed?({:word, _word}), do: true
  defp typed?({:num, _text}), do: true
  defp typed?({:tok, symbol}), do: symbol in ["(", ")", ",", "<", ">"]
  defp typed?(_token), do: false

  # An expression token as the type grammar reads it (the lines and columns it names in a
  # parser error are not used: the syntax check has judged the text before).
  @spec grammar_token(expr_token()) :: SQLTokenizer.token()
  defp grammar_token({:word, word}), do: {:word, word, String.upcase(word), 1, 1}
  defp grammar_token({:num, text}), do: {:number, text, text, 1, 1}
  defp grammar_token({:tok, symbol}), do: {:symbol, symbol, symbol, 1, 1}
end
