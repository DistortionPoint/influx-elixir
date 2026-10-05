defmodule InfluxElixir.Client.Local.SQLInterval do
  @moduledoc false
  # The error the engine's interval parser gives a literal that does not fit an interval
  # (verified against InfluxDB 3 Core, each unit; the error is the same wherever the literal
  # stands, in a select list or a `WHERE`, beside `now()` or alone):
  #
  #     SELECT INTERVAL '99999999999 days'
  #     Arrow error: Invalid argument error: Unable to represent 99999999999 days in a
  #     signed 32-bit integer
  #
  # Days, weeks, months and years are counted in a 32-bit integer (a week as seven days, a year
  # as twelve months), hours, minutes and seconds in nanoseconds in a 64-bit one. The words of
  # the error differ by unit. Only whole numbers of these units are read; a fraction, an
  # abbreviated unit or a clock time (`'1:30:00'`) is left to the rest of the double.

  @i32_min -2_147_483_648
  @i32_max 2_147_483_647
  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807

  @nanoseconds %{
    "hour" => 3_600_000_000_000,
    "minute" => 60_000_000_000,
    "second" => 1_000_000_000
  }

  @doc """
  The engine's error (after `Arrow error: `) for an interval literal, or `nil` for one that fits
  or that is not read here. `text` is the literal's content, `unit` the word after it
  (`INTERVAL '99999999999' day`), or `nil`.
  """
  @spec overflow(binary(), binary() | nil) :: binary() | nil
  def overflow(text, unit) do
    words = String.split(text)

    case pairs(words, unit) do
      {:ok, pairs} when unit == nil ->
        if exact?(text, words), do: first_error(pairs, text), else: invalid(text)

      {:ok, pairs} ->
        first_error(pairs, text)

      :error ->
        nil
    end
  end

  # The literal as the engine's parser reads it: no space around it, the numbers and units set
  # apart by one space, and no `+` before a number (verified: `' 1 day'`, `'1  day'`, `'1 day\t'`
  # and `'+1 day'` are the parser's error, not an interval, where `'1\tday'` is one day). Only
  # ASCII text is judged, since the error names the text as Rust escapes it.
  @spec exact?(binary(), [binary()]) :: boolean()
  defp exact?(text, words),
    do: not (String.printable?(text) and ascii?(text)) or exact_words?(text, words)

  @spec exact_words?(binary(), [binary()]) :: boolean()
  defp exact_words?(text, words),
    do:
      text == String.trim(text) and not String.contains?(text, "  ") and
        not Enum.any?(words, &String.starts_with?(&1, "+"))

  @spec ascii?(binary()) :: boolean()
  defp ascii?(text), do: byte_size(text) == String.length(text)

  @spec invalid(binary()) :: binary()
  defp invalid(text), do: "Parser error: Invalid input syntax for type interval: #{inspect(text)}"

  # `[{number, unit}]` of `1 year 2 days`, or of `5` with the unit written after the literal.
  @spec pairs([binary()], binary() | nil) :: {:ok, [{binary(), binary()}]} | :error
  defp pairs([number], unit) when is_binary(unit), do: {:ok, [{number, singular(unit)}]}

  defp pairs(words, nil) do
    if rem(length(words), 2) == 0 and words != [],
      do: {:ok, words |> Enum.chunk_every(2) |> Enum.map(fn [n, u] -> {n, singular(u)} end)},
      else: :error
  end

  defp pairs(_words, _unit), do: :error

  @spec singular(binary()) :: binary()
  defp singular(unit), do: unit |> String.downcase() |> String.replace_suffix("s", "")

  @spec first_error([{binary(), binary()}], binary()) :: binary() | nil
  defp first_error(pairs, text), do: Enum.find_value(pairs, &error(&1, text))

  @spec error({binary(), binary()}, binary()) :: binary() | nil
  defp error({number, unit}, text) do
    case Integer.parse(number) do
      {value, ""} when value >= @i64_min and value <= @i64_max -> unit_error(value, unit)
      {_value, ""} -> "Parser error: Invalid input syntax for type interval: \"#{text}\""
      _fraction -> nil
    end
  end

  @spec unit_error(integer(), binary()) :: binary() | nil
  defp unit_error(value, "day") do
    if fits_32?(value),
      do: nil,
      else: "Invalid argument error: " <> unrepresentable(value, "days")
  end

  defp unit_error(value, "week") do
    if fits_32?(value * 7),
      do: nil,
      else: "Parser error: Unable to represent #{value} weeks as days in a signed 32-bit integer"
  end

  defp unit_error(value, "month") do
    if fits_32?(value),
      do: nil,
      else: "Parser error: " <> unrepresentable(value, "months")
  end

  defp unit_error(value, "year") do
    if fits_32?(value * 12),
      do: nil,
      else:
        "Parser error: Unable to represent #{value} years as months in a signed 32-bit integer"
  end

  defp unit_error(value, unit) when is_map_key(@nanoseconds, unit) do
    scale = Map.fetch!(@nanoseconds, unit)
    product = value * scale

    if product >= @i64_min and product <= @i64_max,
      do: nil,
      else: "Arithmetic overflow: Overflow happened on: #{value} * #{scale}"
  end

  defp unit_error(_value, _unit), do: nil

  @spec fits_32?(integer()) :: boolean()
  defp fits_32?(value), do: value >= @i32_min and value <= @i32_max

  @spec unrepresentable(integer(), binary()) :: binary()
  defp unrepresentable(value, unit),
    do: "Unable to represent #{value} #{unit} in a signed 32-bit integer"
end
