defmodule InfluxElixir.Client.Local.SQLCast do
  @moduledoc false
  # `CAST(expr AS type)` as DataFusion performs it (verified against InfluxDB 3
  # Core).
  #
  # `INTEGER` and `INT` are `Int32`, `SMALLINT` is `Int16`, `TINYINT` is `Int8`
  # and `BIGINT` is `Int64`; a value outside the target's range cannot be
  # cast. Text becomes a number only when the whole string is one (`"2.5"` is
  # not an integer, and a space around a number spoils it; `+7`, `007`, `.5`,
  # `5.` and `1E3` are numbers, and `inf`, `infinity` and `nan` in any case are
  # the float's specials). A float or a decimal becomes an integer by truncation
  # toward zero, a number or boolean becomes text by rendering (a float as the
  # engine writes it, `5000.0` and never `5.0e3`; a decimal with its scale,
  # `2.5000`; an infinity `inf` or `-inf`, a NaN `NaN`) and a boolean becomes 0
  # or 1. Null stays null.
  #
  # A cast that cannot be performed — text that is not a number, an infinity or
  # a NaN as an integer, a number outside the target's range — fails the query
  # on the engine in one of two ways. Over a column, mid-response: InfluxDB 3
  # Core closes the connection, which `Client.HTTP` reports as a transport
  # error, so the double reports the same shape. Over a constant, the
  # optimizer folds it first and fails the query before any row is read, with a
  # 500 whose body names the value (see `fold/2`).
  #
  # `FLOAT` and `REAL` are `Float32`, which the double does not model: refused
  # by name. A cast of a timestamp is its nanoseconds, which the double keeps
  # only to the microsecond: refused by name, except into a type too narrow for
  # any recent time, which fails as the engine's cast does.

  alias InfluxElixir.Client.Local.{Format, SQLError, SQLExpr, SQLLimits, SQLNumber}

  require SQLLimits

  @integer_types [:int8, :int16, :int32, :int64]

  @doc "The value cast to `type`, or the throw of the query's failure."
  @spec cast(term(), SQLExpr.cast_type()) :: term()
  def cast(value, type) do
    case convert(value, type) do
      {:ok, result} -> result
      :error -> closed()
    end
  end

  @doc """
  Whether the optimizer can fold the cast of a constant `value`: `:ok`, or the
  message it fails the query with, as the planner words it
  (`Can't cast value 3000000000 to type Int32`, or for text `Cannot cast
  string 'x' to value of Int32 type`).
  """
  @spec fold(term(), SQLExpr.cast_type()) :: :ok | {:error, binary()}
  def fold(value, type) do
    case convert(value, type) do
      {:ok, _result} -> :ok
      :error -> {:error, failure(value, type)}
    end
  end

  @doc "The width in bits of an integer cast type, or `nil` for any other."
  @spec bits(SQLExpr.cast_type()) :: 8 | 16 | 32 | 64 | nil
  def bits(:int8), do: 8
  def bits(:int16), do: 16
  def bits(:int32), do: 32
  def bits(:int64), do: 64
  def bits(_other), do: nil

  @doc "The Arrow type name of a cast type."
  @spec arrow_type(SQLExpr.cast_type()) :: binary()
  def arrow_type(:int8), do: "Int8"
  def arrow_type(:int16), do: "Int16"
  def arrow_type(:int32), do: "Int32"
  def arrow_type(:int64), do: "Int64"
  def arrow_type(:float), do: "Float64"
  def arrow_type(:string), do: "Utf8"
  def arrow_type(:decimal), do: "Decimal128(?)"

  @doc "Whether the integer is in the range of the integer type with `bits` bits."
  @spec fits?(integer(), 8 | 16 | 32 | 64) :: boolean()
  def fits?(value, bits) do
    half = Bitwise.bsl(1, bits - 1)
    value >= -half and value < half
  end

  @spec convert(term(), SQLExpr.cast_type()) :: {:ok, term()} | :error
  defp convert(nil, _type), do: {:ok, nil}
  defp convert(%DateTime{} = time, type), do: timestamp(time, type)
  defp convert(value, type) when type in @integer_types, do: to_integer(value, bits(type))
  defp convert(value, :float), do: to_float(value)
  defp convert(value, :string), do: to_string_value(value)
  defp convert(value, :decimal), do: to_decimal(value)

  # An integer of either sign as the decimal the engine makes of it beside the other (`Int64`
  # with `UInt64`); only the coalescing functions make one, not a cast written in a query.
  @spec to_decimal(term()) :: {:ok, SQLNumber.decimal()} | :error
  defp to_decimal({:dec, _coefficient, _scale} = decimal), do: {:ok, decimal}
  defp to_decimal({:u, value}), do: {:ok, {:dec, value, 0}}
  defp to_decimal(value) when is_integer(value), do: {:ok, {:dec, value, 0}}
  defp to_decimal(_value), do: :error

  @spec to_integer(term(), 8 | 16 | 32 | 64) :: {:ok, term()} | :error
  defp to_integer(value, bits) when is_boolean(value),
    do: in_range(if(value, do: 1, else: 0), bits)

  defp to_integer(value, bits) when is_integer(value), do: in_range(value, bits)
  defp to_integer({:u, value}, bits), do: in_range(value, bits)
  defp to_integer({:int, _width, value}, bits), do: in_range(value, bits)

  defp to_integer({:dec, coefficient, scale}, bits),
    do: in_range(div(coefficient, Integer.pow(10, scale)), bits)

  defp to_integer(value, bits) when is_float(value), do: in_range(trunc(value), bits)

  defp to_integer(value, bits) when is_binary(value) do
    if Regex.match?(~r/\A[+-]?[0-9]+\z/, value),
      do: value |> String.to_integer() |> in_range(bits),
      else: :error
  end

  defp to_integer(_special_or_other, _bits), do: :error

  @spec in_range(integer(), 8 | 16 | 32 | 64) :: {:ok, term()} | :error
  defp in_range(value, 64) when SQLLimits.is_int64(value), do: {:ok, value}
  defp in_range(_value, 64), do: :error

  defp in_range(value, bits) do
    if fits?(value, bits), do: {:ok, {:int, bits, value}}, else: :error
  end

  @float_text ~r/\A([+-]?)([0-9]*)\.?([0-9]*)(?:[eE]([+-]?[0-9]+))?\z/
  @special_text ~r/\A([+-]?)(inf|infinity|nan)\z/i

  @spec to_float(term()) :: {:ok, term()} | :error
  defp to_float(value) when is_boolean(value), do: {:ok, if(value, do: 1.0, else: 0.0)}

  defp to_float(value) when is_binary(value) do
    case {Regex.run(@float_text, value), Regex.run(@special_text, value)} do
      {[_text, _sign, "", "" | _exponent], nil} ->
        :error

      {[_text, sign, whole, fraction | exponent], _special} ->
        {:ok, decimal(sign, whole, fraction, exponent)}

      {nil, special} when is_list(special) ->
        {:ok, special(special)}

      {nil, nil} ->
        :error
    end
  end

  defp to_float(value) do
    if SQLNumber.numeric?(value), do: {:ok, SQLNumber.to_float(value)}, else: :error
  end

  # `.5` and `5.` are numbers to the engine; Erlang wants a digit on each
  # side of the point. A magnitude too large for a double is an infinity and
  # one too small is zero.
  @spec decimal(binary(), binary(), binary(), [binary()]) :: float() | SQLNumber.special()
  defp decimal(sign, whole, fraction, exponent) do
    text = "#{zero(whole)}.#{zero(fraction)}e#{zero(List.first(exponent, ""))}"

    value =
      case Float.parse(text) do
        {float, ""} -> float
        _overflow -> if String.trim(whole <> fraction, "0") == "", do: 0.0, else: :inf
      end

    if sign == "-", do: SQLNumber.negate_float(value), else: value
  end

  @spec zero(binary()) :: binary()
  defp zero(""), do: "0"
  defp zero(digits), do: digits

  @spec special([binary()]) :: SQLNumber.special()
  defp special([_text, sign, word]) do
    cond do
      String.downcase(word) == "nan" -> :nan
      sign == "-" -> :neg_inf
      true -> :inf
    end
  end

  @spec to_string_value(term()) :: {:ok, binary()} | :error
  defp to_string_value(value) when is_binary(value), do: {:ok, value}
  defp to_string_value(value) when is_float(value), do: {:ok, Format.render_float(value)}
  defp to_string_value(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp to_string_value(value) when is_boolean(value), do: {:ok, Atom.to_string(value)}
  defp to_string_value({:u, value}), do: {:ok, Integer.to_string(value)}
  defp to_string_value({:int, _bits, value}), do: {:ok, Integer.to_string(value)}

  defp to_string_value({:dec, coefficient, scale}),
    do: {:ok, decimal_text(coefficient, scale)}

  defp to_string_value(:inf), do: {:ok, "inf"}
  defp to_string_value(:neg_inf), do: {:ok, "-inf"}
  defp to_string_value(:nan), do: {:ok, "NaN"}
  defp to_string_value(_other), do: :error

  # `{:dec, 25000, 4}` is "2.5000"; `{:dec, -5, 4}` is "-0.0005".
  @spec decimal_text(integer(), non_neg_integer()) :: binary()
  defp decimal_text(coefficient, 0), do: Integer.to_string(coefficient)

  defp decimal_text(coefficient, scale) do
    digits = coefficient |> abs() |> Integer.to_string() |> String.pad_leading(scale + 1, "0")
    {whole, fraction} = String.split_at(digits, -scale)
    sign = if coefficient < 0, do: "-", else: ""
    sign <> whole <> "." <> fraction
  end

  # The words of the optimizer's cast error: text names the string and the
  # target, a number names its value (a float as Rust prints it) and the
  # target.
  @spec failure(term(), SQLExpr.cast_type()) :: binary()
  defp failure(value, type) when is_binary(value),
    do: "Cannot cast string '#{value}' to value of #{arrow_type(type)} type"

  defp failure(value, type), do: "Can't cast value #{shown(value)} to type #{arrow_type(type)}"

  @spec shown(term()) :: binary()
  defp shown(value) when is_float(value), do: Format.render_float(value)
  defp shown({:u, value}), do: Integer.to_string(value)
  defp shown({:int, _bits, value}), do: Integer.to_string(value)
  defp shown(:inf), do: "inf"
  defp shown(:neg_inf), do: "-inf"
  defp shown(:nan), do: "NaN"
  defp shown(value) when is_integer(value), do: Integer.to_string(value)
  defp shown({:dec, coefficient, scale}), do: decimal_text(coefficient, scale)

  # A timestamp is cast as its nanoseconds, which a `DateTime` keeps only to
  # the microsecond. Into a type too narrow for them (every time after the
  # first two seconds of 1970, to `INT`, `SMALLINT` or `TINYINT`) it cannot
  # be cast whatever the nanoseconds are; any other cast is refused.
  @spec timestamp(DateTime.t(), SQLExpr.cast_type()) :: :error | no_return()
  defp timestamp(time, type) do
    bits = bits(type)
    nanoseconds = DateTime.to_unix(time, :microsecond) * 1000

    if bits in [8, 16, 32] and
         (nanoseconds >= Bitwise.bsl(1, bits - 1) + 1000 or
            nanoseconds < -Bitwise.bsl(1, bits - 1) - 1000),
       do: :error,
       else: refuse_timestamp()
  end

  @spec refuse_timestamp() :: no_return()
  defp refuse_timestamp do
    throw(
      {:query_error,
       SQLError.refusal(
         "a CAST of a timestamp: the engine casts its nanoseconds, which the double keeps " <>
           "only to the microsecond"
       )}
    )
  end

  # The shape Client.HTTP gives a query the engine fails mid-response (and
  # Format gives a nested value in CSV), so code matching on it holds
  # against both clients.
  @spec closed() :: no_return()
  defp closed, do: throw({:query_error, SQLError.closed()})
end
