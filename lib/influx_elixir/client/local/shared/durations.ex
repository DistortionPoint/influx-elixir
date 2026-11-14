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
end
