defmodule InfluxElixir.Client.Local.LineProtocolNumber do
  @moduledoc false
  # The numbers of an InfluxDB 3 field value and timestamp, scanned as the engine
  # scans them: `-?digits[.digits][e[+-]digits]`, `i` and `u` suffixes for the
  # integers, and what follows the longest match left as trailing content; and
  # the engines' names for the columns a field value makes.
  alias InfluxElixir.Client.Local.SQLLimits

  require SQLLimits

  @spec scan(binary()) :: {:ok, term(), binary()} | :fail | {:error, binary()}
  def scan(text) do
    sign = sign_size(text)
    <<_sign::binary-size(sign), unsigned::binary>> = text

    case digit_count(unsigned, 0) do
      0 ->
        :fail

      digits ->
        int_end = sign + digits
        <<whole::binary-size(int_end), tail::binary>> = text
        v3_number_tail(whole, tail, text, sign == 0)
    end
  end

  # `whole` is the sign and digits, `tail` what follows them and `text` all
  # of it; `unsigned?` is whether there is no sign.
  @spec v3_number_tail(binary(), binary(), binary(), boolean()) ::
          {:ok, term(), binary()} | :fail | {:error, binary()}
  defp v3_number_tail(whole, <<?i, rest::binary>>, _text, _unsigned?),
    do: integer_value(whole, rest, "integer", SQLLimits.int64_min(), SQLLimits.int64_max(), & &1)

  defp v3_number_tail(whole, <<?u, rest::binary>>, _text, true),
    do: integer_value(whole, rest, "unsigned integer", 0, SQLLimits.uint64_max(), &{:uint, &1})

  defp v3_number_tail(whole, tail, text, _unsigned?), do: v3_float(whole, tail, text)

  @spec integer_value(binary(), binary(), binary(), integer(), integer(), fun()) ::
          {:ok, term(), binary()} | {:error, binary()}
  defp integer_value(digits, rest, what, min, max, wrap) do
    case :erlang.binary_to_integer(digits) do
      n when n >= min and n <= max -> {:ok, wrap.(n), rest}
      _out_of_range -> {:error, "Unable to parse #{what} value `#{digits}`"}
    end
  end

  # The fraction needs a digit after its point and the exponent a digit
  # after its sign, or they are left as trailing content.
  @spec v3_float(binary(), binary(), binary()) :: {:ok, float(), binary()} | {:error, binary()}
  defp v3_float(whole, tail, text) do
    fraction = fraction_size(tail)
    <<_fraction::binary-size(fraction), after_fraction::binary>> = tail
    exponent = exponent_size(after_fraction)
    size = byte_size(whole) + fraction + exponent
    <<number::binary-size(size), rest::binary>> = text

    case float_value(number, fraction, exponent) do
      {:ok, float} ->
        {:ok, float, rest}

      :error ->
        {:error,
         "Client.Local: the float #{number} is infinity on InfluxDB 3 Core, " <>
           "which the double cannot hold"}
    end
  end

  # The size of `.digits` at the start of `text`, 0 when there is none.
  @spec fraction_size(binary()) :: non_neg_integer()
  defp fraction_size(<<?., rest::binary>>) do
    case digit_count(rest, 0) do
      0 -> 0
      digits -> digits + 1
    end
  end

  defp fraction_size(_text), do: 0

  # The size of `e[+-]digits` at the start of `text`, 0 when there is none.
  @spec exponent_size(binary()) :: non_neg_integer()
  defp exponent_size(<<e, rest::binary>>) when e in [?e, ?E] do
    {signed, digits_from} =
      case rest do
        <<s, more::binary>> when s in [?+, ?-] -> {1, more}
        _unsigned -> {0, rest}
      end

    case digit_count(digits_from, 0) do
      0 -> 0
      digits -> 1 + signed + digits
    end
  end

  defp exponent_size(_text), do: 0

  # The float a number's text means. With a fraction Erlang reads it as it
  # is; an integer-valued one is converted; only an exponent without a
  # fraction needs `parse_float/1`. `:error` when it does not fit a float.
  @spec float_value(binary(), non_neg_integer(), non_neg_integer()) :: {:ok, float()} | :error
  defp float_value(number, fraction, exponent) do
    cond do
      fraction > 0 -> {:ok, :erlang.binary_to_float(number)}
      exponent > 0 -> parse_float(number)
      true -> {:ok, integer_float(number)}
    end
  rescue
    ArgumentError -> :error
  end

  # `-0` is the float -0.0, and a number of more digits than a float holds
  # raises `ArgumentError`.
  @spec integer_float(binary()) :: float()
  defp integer_float("-" <> digits = number) do
    case :erlang.binary_to_integer(digits) do
      0 -> -0.0
      _nonzero -> :erlang.float(:erlang.binary_to_integer(number))
    end
  end

  defp integer_float(digits), do: :erlang.float(:erlang.binary_to_integer(digits))

  # The size of the minus sign at the start of `text`: 1 or 0.
  @spec sign_size(binary()) :: 0 | 1
  @doc false
  def sign_size(<<?-, _rest::binary>>), do: 1
  def sign_size(_text), do: 0

  # The number of ASCII digits at the start of `text`.
  @spec digit_count(binary(), non_neg_integer()) :: non_neg_integer()
  @doc false
  def digit_count(<<c, rest::binary>>, count) when c in ?0..?9, do: digit_count(rest, count + 1)
  def digit_count(_text, count), do: count

  # The float a number's text means; `:error` when it does not fit a float.
  # Elixir reads most spellings as they are; `5.` and `.5` (which InfluxDB 2
  # reads too) it does not, so they are written the way it does (`5.0` and
  # `0.5`) and tried again.
  @spec parse_float(binary()) :: {:ok, float()} | :error
  @doc false
  def parse_float(text) do
    case Float.parse(text) do
      {float, ""} -> {:ok, float}
      _unread -> parse_float_normalised(text)
    end
  end

  defp parse_float_normalised(text) do
    {mantissa, exponent} = split_exponent(text)
    {sign, unsigned} = split_sign(mantissa)
    {whole, fraction} = split_point(unsigned)

    if whole == "" and fraction == "" do
      :error
    else
      normal =
        sign <>
          if(whole == "", do: "0", else: whole) <>
          "." <> if(fraction == "", do: "0", else: fraction) <> exponent

      case Float.parse(normal) do
        {float, ""} -> {:ok, float}
        _unread -> :error
      end
    end
  end

  @spec split_exponent(binary()) :: {binary(), binary()}
  defp split_exponent(text) do
    case :binary.split(text, ["e", "E"]) do
      [mantissa, exponent] -> {mantissa, "e" <> exponent}
      [mantissa] -> {mantissa, ""}
    end
  end

  @spec split_sign(binary()) :: {binary(), binary()}
  defp split_sign("-" <> unsigned), do: {"-", unsigned}
  defp split_sign(unsigned), do: {"", unsigned}

  @spec split_point(binary()) :: {binary(), binary()}
  defp split_point(unsigned) do
    case :binary.split(unsigned, ".") do
      [whole, fraction] -> {whole, fraction}
      [whole] -> {whole, ""}
    end
  end

  @doc """
  The engine's name for a column kind: `iox::column_type::tag` or
  `iox::column_type::field::<integer | uinteger | float | string | boolean>`.
  """
  @spec column_type(:tag | :field, term()) :: binary()
  def column_type(:tag, _value), do: "iox::column_type::tag"

  def column_type(:field, {:uint, _n}), do: "iox::column_type::field::uinteger"
  def column_type(:field, value) when is_integer(value), do: "iox::column_type::field::integer"
  def column_type(:field, value) when is_float(value), do: "iox::column_type::field::float"
  def column_type(:field, value) when is_binary(value), do: "iox::column_type::field::string"
  def column_type(:field, value) when is_boolean(value), do: "iox::column_type::field::boolean"

  @doc "InfluxDB 2's name for a field type (`integer`, `unsigned`, `float`, `string`, `boolean`)."
  @spec v2_field_type(binary()) :: binary()
  def v2_field_type("iox::column_type::field::uinteger"), do: "unsigned"
  def v2_field_type("iox::column_type::field::" <> type), do: type
end
