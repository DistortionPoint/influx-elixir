defmodule InfluxElixir.Client.Local.Durations do
  @moduledoc false
  # The nanoseconds in each unit of the engines' duration literals (`ns u µ ms s
  # m h d w`), in one place for InfluxQL, its select list and Flux.

  @units %{
    "ns" => 1,
    "u" => 1_000,
    "µ" => 1_000,
    "ms" => 1_000_000,
    "s" => 1_000_000_000,
    "m" => 60_000_000_000,
    "h" => 3_600_000_000_000,
    "d" => 86_400_000_000_000,
    "w" => 604_800_000_000_000
  }

  @doc "The nanoseconds in one unit, given as text (`ms`, `h`, ...); raises for a unit that is none."
  @spec ns(binary()) :: pos_integer()
  def ns(unit), do: Map.fetch!(@units, unit)

  @doc "The total nanoseconds in a compound duration literal (`1h30m`, `500ms`, ...)."
  @spec total_ns(binary()) :: non_neg_integer()
  def total_ns(text) do
    ~r/(\d+)(ns|ms|u|µ|s|m|h|d|w)/
    |> Regex.scan(text)
    |> Enum.reduce(0, fn [_all, count, unit], total ->
      total + String.to_integer(count) * ns(unit)
    end)
  end

  @doc "Converts a fractional-second digit string (or capture list) into nanoseconds (0..999_999_999)."
  @spec fraction_ns(binary() | [binary()] | nil) :: non_neg_integer()
  def fraction_ns(empty) when empty in ["", nil, []], do: 0
  def fraction_ns([digits]), do: fraction_ns(digits)

  def fraction_ns(digits) when is_binary(digits),
    do: digits |> String.slice(0, 9) |> String.pad_trailing(9, "0") |> String.to_integer()

  @doc "Zero-pads `number` on the left to at least `width` decimal digits."
  @spec pad(non_neg_integer(), pos_integer()) :: binary()
  def pad(number, width), do: number |> Integer.to_string() |> String.pad_leading(width, "0")

  @doc "Formats a nanosecond remainder (`0..999_999_999`) as `\"\"` (for `0`) or 3, 6, or 9 digits."
  @spec fraction_digits(non_neg_integer()) :: binary()
  def fraction_digits(0), do: ""
  def fraction_digits(nanos) when rem(nanos, 1_000_000) == 0, do: pad(div(nanos, 1_000_000), 3)
  def fraction_digits(nanos) when rem(nanos, 1_000) == 0, do: pad(div(nanos, 1_000), 6)
  def fraction_digits(nanos), do: pad(nanos, 9)

  @doc "Formats `ns` nanoseconds since the Unix epoch as a 9-digit ISO-8601 UTC timestamp."
  @spec iso_ns(integer()) :: binary()
  def iso_ns(ns) do
    seconds = Integer.floor_div(ns, 1_000_000_000)
    nanos = Integer.mod(ns, 1_000_000_000)
    stamp = seconds |> DateTime.from_unix!() |> DateTime.to_iso8601() |> String.trim_trailing("Z")
    "#{stamp}.#{pad(nanos, 9)}Z"
  end
end
