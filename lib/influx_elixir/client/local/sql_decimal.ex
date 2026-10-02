defmodule InfluxElixir.Client.Local.SQLDecimal do
  @moduledoc """
  A decimal expression compared with a float literal too large for it
  (verified against InfluxDB 3 Core).

  An expression over an `Int64` and a `UInt64` is a `Decimal128` to the
  engine, and a comparison of it with a `Float64` casts the float to a
  decimal with 15 decimals. The optimizer does that to a literal before any
  row is read, wherever the comparison stands (`AND false` and `LIMIT 0`
  included), and a float whose decimal does not fit is its error, status
  500:

    * `Invalid argument error: <N> is too large to store in a Decimal128 of
      precision <P>. Max is <M>` (`too small ... Min is` below), where `N` is
      the float times `1e15` as the engine computes it, written with 15
      decimals, and `M` is the largest value of precision `P`
    * `Cast error: Cannot cast to Decimal128(<P>, 15). Overflowing on <X>`
      once that product no longer fits 127 bits, with `X` the float as Rust
      prints it (`1.8e23`, `inf`)

  The precision is that of the expression: for an `Int64` and a `UInt64` it
  is 35 for `/` and `%`, 36 for `+` and `-`, and 38 for `*`. The precision of
  any other shape of expression is not modelled and is refused by name.
  """

  alias InfluxElixir.Client.Local.{SQLError, SQLExpr, SQLFunctions}

  @decimal "Decimal128(?)"
  @precisions %{:/ => 35, :rem => 35, :+ => 36, :- => 36, :* => 38}
  @two_127 170_141_183_460_469_231_731_687_303_715_884_105_728.0
  @scale 1.0e15

  @doc """
  The engine's error for `values` compared with `left`, or `:ok`. `columns`
  maps a column to its Arrow type.
  """
  @spec check(SQLExpr.t(), [term()], %{binary() => binary()}) :: :ok | {:error, SQLError.t()}
  def check(left, values, columns) do
    with @decimal <- SQLFunctions.type_of(left, columns),
         literal when literal != nil <- Enum.find_value(values, &too_large/1) do
      error(left, literal, columns)
    else
      _fits_or_not_decimal -> :ok
    end
  end

  # The float a value is, when it is past what any decimal of the engine's
  # takes (a larger one would fit none of them).
  @spec too_large(term()) :: float() | :inf | :neg_inf | nil
  defp too_large({:expr, {:lit, value}}) when value in [:inf, :neg_inf], do: value
  defp too_large(value) when is_float(value) and abs(value) > 1.0e20, do: value
  defp too_large(_other), do: nil

  @spec error(SQLExpr.t(), float() | :inf | :neg_inf, %{binary() => binary()}) ::
          :ok | {:error, SQLError.t()}
  defp error(left, literal, columns) do
    case precision(left, columns) do
      nil -> {:error, SQLError.refusal(refusal())}
      precision -> body(literal, precision)
    end
  end

  @spec refusal() :: binary()
  defp refusal do
    "a decimal expression compared with a float past 1e20: the engine fails its cast of the " <>
      "float to the expression's decimal type, whose precision is modelled only for a " <>
      "plain `+`, `-`, `*`, `/` or `%` of two columns or integers"
  end

  # The precision of a decimal made of two integer columns or literals.
  @spec precision(SQLExpr.t(), %{binary() => binary()}) :: pos_integer() | nil
  defp precision({:op, op, left, right}, columns) do
    if integer?(left, columns) and integer?(right, columns), do: @precisions[op]
  end

  defp precision(_other, _columns), do: nil

  @spec integer?(SQLExpr.t(), %{binary() => binary()}) :: boolean()
  defp integer?(expr, columns), do: SQLFunctions.type_of(expr, columns) in ["Int64", "UInt64"]

  @spec body(float() | :inf | :neg_inf, pos_integer()) :: :ok | {:error, SQLError.t()}
  defp body(literal, precision) do
    case unscaled(literal) do
      :overflow -> {:error, overflow(literal, precision)}
      value -> fits(value, precision)
    end
  end

  @spec fits(integer(), pos_integer()) :: :ok | {:error, SQLError.t()}
  defp fits(value, precision) do
    max = Integer.pow(10, precision) - 1

    cond do
      value > max -> {:error, range("#{decimal(value)} is too large", precision, "Max is", max)}
      value < -max -> {:error, range("#{decimal(value)} is too small", precision, "Min is", -max)}
      true -> :ok
    end
  end

  # The float times 1e15, as the engine computes it, or `:overflow` once it
  # no longer fits 127 bits.
  @spec unscaled(float() | :inf | :neg_inf) :: integer() | :overflow
  defp unscaled(literal) when literal in [:inf, :neg_inf], do: :overflow
  defp unscaled(literal) when abs(literal) >= 1.0e290, do: :overflow

  defp unscaled(literal) do
    product = literal * @scale
    if abs(product) >= @two_127, do: :overflow, else: trunc(product)
  end

  @spec range(binary(), pos_integer(), binary(), integer()) :: SQLError.t()
  defp range(what, precision, bound, limit) do
    SQLError.simplify(
      "Arrow error: Invalid argument error: #{what} to store in a Decimal128 of precision " <>
        "#{precision}. #{bound} #{decimal(limit)}"
    )
  end

  @spec overflow(float() | :inf | :neg_inf, pos_integer()) :: SQLError.t()
  defp overflow(literal, precision) do
    SQLError.simplify(
      "Arrow error: Cast error: Cannot cast to Decimal128(#{precision}, 15). " <>
        "Overflowing on #{rust(literal)}"
    )
  end

  # An unscaled integer with 15 decimals.
  @spec decimal(integer()) :: binary()
  defp decimal(value) do
    digits = value |> abs() |> Integer.to_string() |> String.pad_leading(16, "0")
    {whole, fraction} = String.split_at(digits, -15)
    sign = if value < 0, do: "-", else: ""
    sign <> whole <> "." <> fraction
  end

  # A float as Rust prints it with `{:?}`: the shortest digits that read back,
  # in exponent form at this size.
  @spec rust(float() | :inf | :neg_inf) :: binary()
  defp rust(:inf), do: "inf"
  defp rust(:neg_inf), do: "-inf"
  defp rust(value), do: value |> Float.to_string() |> String.replace(".0e", "e")
end
