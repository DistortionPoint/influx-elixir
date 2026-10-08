defmodule InfluxElixir.Client.Local.InfluxQLLiteral do
  @moduledoc false
  # A constant in the select list of an InfluxQL statement. The engine reads
  # the statement and then refuses it while it plans (verified): a select item
  # that is a constant has "no variable" in it, and a function given a constant
  # expects "a field argument", naming the constant the way the engine's parser
  # holds it (`Literal(Boolean(true))`, `Literal(Integer(1))`,
  # `Literal(Float(1.5))`, `Literal(String("a"))`,
  # `Literal(Duration(Duration(5000000000)))`).

  alias InfluxElixir.Client.Local.{Durations, InfluxQLError, InfluxQLText, SQLLimits}

  require SQLLimits

  @functions ~w(mean sum count min max first last median spread stddev)

  @doc """
  The engine's name for a constant written as `text`: `{:ok, "Boolean(true)"}`,
  `:none` when the text is no constant, `{:error, message}` for a constant
  the double cannot name as the engine does.
  """
  @spec debug(binary()) :: {:ok, binary()} | :none | {:error, binary()}
  def debug(text) do
    cond do
      String.downcase(text) in ["true", "false"] ->
        {:ok, "Boolean(#{String.downcase(text)})"}

      Regex.match?(~r/^[+-]?\d+$/, text) ->
        integer(text)

      Regex.match?(~r/^[+-]?(?:\d+\.\d+|\.\d+)$/, text) ->
        float(text)

      Regex.match?(~r/^\d+(?:ns|ms|u|µ|s|m|h|d|w)$/, text) ->
        duration(text)

      String.starts_with?(text, "'") and String.ends_with?(text, "'") and byte_size(text) > 1 ->
        string(binary_part(text, 1, byte_size(text) - 2))

      true ->
        :none
    end
  end

  @spec integer(binary()) :: {:ok, binary()} | {:error, binary()}
  defp integer(text) do
    case String.to_integer(text) do
      n when abs(n) <= SQLLimits.int64_max() -> {:ok, "Integer(#{n})"}
      _beyond -> {:error, "an integer constant beyond 64 bits"}
    end
  end

  # A float prints as the engine's Rust `Debug` does: the shortest digits
  # that read back, in plain notation from 1e-4 up to 1e16. One outside that
  # is out of reach.
  @spec float(binary()) :: {:ok, binary()} | {:error, binary()}
  defp float(text) do
    value = text |> String.trim_leading("+") |> InfluxQLText.leading_zero() |> String.to_float()

    if value == 0.0 or (abs(value) >= 1.0e-4 and abs(value) < 1.0e16),
      do: {:ok, "Float(#{value |> Float.to_string() |> plain()})"},
      else: {:error, "a float constant of that size"}
  end

  @doc """
  A float as Rust's `Display` writes it (`2.0` is `2`, `0.5` is `0.5`, never an
  exponent), the way the engine words a number in its errors.
  """
  @spec display(float()) :: binary()
  def display(value) when is_float(value),
    do: value |> Float.to_string() |> plain() |> String.replace_suffix(".0", "")

  # Elixir prints the shortest digits with an exponent where Rust prints the
  # digits in full (`1.0e14` is `100000000000000.0`).
  @spec plain(binary()) :: binary()
  defp plain(text) do
    case String.split(text, "e") do
      [plain] -> plain
      [mantissa, exponent] -> shift(mantissa, String.to_integer(exponent))
    end
  end

  @spec shift(binary(), integer()) :: binary()
  defp shift(mantissa, exponent) do
    {sign, unsigned} = split_sign(mantissa)
    [whole, fraction] = String.split(unsigned, ".")
    digits = whole <> String.trim_trailing(fraction, "0")
    point = byte_size(whole) + exponent
    size = byte_size(digits)

    cond do
      point >= size ->
        sign <> digits <> String.duplicate("0", point - size) <> ".0"

      point <= 0 ->
        sign <> "0." <> String.duplicate("0", -point) <> digits

      true ->
        sign <> binary_part(digits, 0, point) <> "." <> binary_part(digits, point, size - point)
    end
  end

  @spec split_sign(binary()) :: {binary(), binary()}
  defp split_sign("-" <> unsigned), do: {"-", unsigned}
  defp split_sign(unsigned), do: {"", unsigned}

  @display_units [
    {"w", 604_800_000_000_000},
    {"d", 86_400_000_000_000},
    {"h", 3_600_000_000_000},
    {"m", 60_000_000_000},
    {"s", 1_000_000_000},
    {"ms", 1_000_000},
    {"u", 1_000},
    {"ns", 1}
  ]

  @doc """
  A duration in nanoseconds as the engine words it in an error: `0s` for none,
  otherwise the units it holds from the weeks down (`1s500ms`), a unit only
  where the duration is more than that unit (a lone minute is `60s`, a lone
  nanosecond nothing at all), and a negative one after a `-`.
  """
  @spec display_duration(integer()) :: binary()
  def display_duration(0), do: "0s"
  def display_duration(ns) when ns < 0, do: "-" <> display_duration(-ns)

  def display_duration(ns) do
    {text, _rest} =
      Enum.reduce(@display_units, {"", ns}, fn {unit, size}, {text, rest} ->
        if ns > size and rest >= size,
          do: {text <> "#{div(rest, size)}#{unit}", rem(rest, size)},
          else: {text, rest}
      end)

    text
  end

  @spec duration(binary()) :: {:ok, binary()}
  defp duration(text) do
    [count, unit] = Regex.run(~r/^(\d+)(ns|ms|u|µ|s|m|h|d|w)$/, text, capture: :all_but_first)
    ns = String.to_integer(count) * Durations.ns(unit)
    {:ok, "Duration(Duration(#{ns}))"}
  end

  # A string constant, its `\'` undone; one with any other backslash, or with
  # a character Rust escapes in `Debug` beyond the quote and the backslash, is
  # out of reach.
  @spec string(binary()) :: {:ok, binary()} | {:error, binary()}
  defp string(inner) do
    text = String.replace(inner, "\\'", "'")

    if String.contains?(text, "\\") or not String.printable?(text) or
         Regex.match?(~r/[\x00-\x1f\x7f]/, text),
       do: {:error, "a string constant with escapes"},
       else: {:ok, ~s|String("#{String.replace(text, "\"", "\\\"")}")|}
  end

  @doc """
  The engine's planning error for the first item of a select list that is a
  constant, or a function of one, `:ok` when there is none.
  """
  @spec constant_error([term()]) :: :ok | {:error, {:engine, binary()}}
  def constant_error(items) do
    Enum.find_value(items, :ok, fn
      {:aggregate, "distinct", {:literal, _debug}, _alias} ->
        {:error, {:engine, InfluxQLError.select_error("expected field argument in distinct()")}}

      {:literal, _text} ->
        {:error,
         {:engine, InfluxQLError.select_error("field must contain at least one variable")}}

      {:aggregate, fun, {:literal, debug}, _alias} when fun in @functions ->
        message = "expected field argument in #{fun}(), got Literal(#{debug})"
        {:error, {:engine, InfluxQLError.select_error(message)}}

      _item ->
        nil
    end)
  end

  @doc "Whether an item is a constant or a function of one."
  @spec literal_item?(term()) :: boolean()
  def literal_item?({:literal, _text}), do: true
  def literal_item?({:aggregate, _fun, {:literal, _debug}, _alias}), do: true
  def literal_item?(_item), do: false
end
