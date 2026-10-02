path = "sql_cast.ex"
src = File.read!(path)
[head, rest] = String.split(src, "  @float_text ~r", parts: 2)
[_old, tail] = String.split(rest, "  @spec special([binary()])", parts: 2)

new = ~S'''
  @float_text ~r/\A([+-]?)([0-9]*)\.?([0-9]*)(?:[eE]([+-]?[0-9]+))?\z/
  @special_text ~r/\A([+-]?)(inf|infinity|nan)\z/i

  @spec to_float(term()) :: {:ok, term()} | :error
  defp to_float(value) when is_boolean(value), do: {:ok, if(value, do: 1.0, else: 0.0)}

  defp to_float(value) when is_binary(value) do
    case {Regex.run(@float_text, value), Regex.run(@special_text, value)} do
      {[_text, _sign, "", "" | _exponent], nil} -> :error
      {[_text, sign, whole, fraction | exponent], _special} -> {:ok, decimal(sign, whole, fraction, exponent)}
      {nil, [_text, _sign, _word] = special} -> {:ok, special(special)}
      {nil, nil} -> :error
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

'''

File.write!(path, head <> new <> "  @spec special([binary()])" <> tail)
