defmodule InfluxElixir.Client.Local.LineProtocolTime do
  @moduledoc false
  # A line's timestamp: the precision it is written in and the range of
  # nanoseconds each engine accepts.

  alias InfluxElixir.Client.Local.{LineProtocolParser, SQLLimits}

  require SQLLimits

  @typep precision :: LineProtocolParser.precision()
  @typep dialect :: LineProtocolParser.dialect()

  # Parses a raw timestamp (`-?digits`, as both grammars have checked it),
  # normalising to nanoseconds.
  @spec parse_timestamp(binary() | nil, precision(), dialect()) ::
          {:ok, integer() | nil} | {:error, binary()}
  @doc false
  def parse_timestamp(nil, _prec, _dialect), do: {:ok, nil}
  def parse_timestamp("", _prec, _dialect), do: {:ok, nil}

  # The stored time is nanoseconds in a signed 64-bit integer. A timestamp
  # that does not fit once scaled to nanoseconds is refused, in each
  # version's words (verified): InfluxDB 3 takes the whole int64 range,
  # InfluxDB 2 all but its two ends.
  def parse_timestamp(ts_str, precision, dialect) do
    ts = :erlang.binary_to_integer(ts_str)

    if ts in SQLLimits.int64_min()..SQLLimits.int64_max() do
      ns = to_nanoseconds(ts, precision)

      if in_range?(ns, dialect),
        do: {:ok, ns},
        else: {:error, out_of_range(ts, precision, dialect)}
    else
      {:error, int64_overflow(ts_str, dialect)}
    end
  end

  @spec in_range?(integer(), dialect()) :: boolean()
  defp in_range?(ns, :v3), do: ns in SQLLimits.int64_min()..SQLLimits.int64_max()
  defp in_range?(ns, :v2), do: ns in (SQLLimits.int64_min() + 2)..(SQLLimits.int64_max() - 1)

  @spec out_of_range(integer(), precision(), dialect()) :: binary()
  defp out_of_range(ts, precision, :v3),
    do: "timestamp, #{ts}, out of range for precision: #{precision_name(precision)}"

  defp out_of_range(_ts, _precision, :v2),
    do: "time outside range #{SQLLimits.int64_min() + 2} - #{SQLLimits.int64_max() - 1}"

  @spec int64_overflow(binary(), dialect()) :: binary()
  defp int64_overflow(ts_str, :v3), do: "Unable to parse timestamp value `#{ts_str}`"

  defp int64_overflow(ts_str, :v2),
    do: ~s|strconv.ParseInt: parsing "#{ts_str}": value out of range|

  @spec precision_name(precision()) :: binary()
  defp precision_name(:second), do: "Second"
  defp precision_name(:millisecond), do: "Millisecond"
  defp precision_name(:microsecond), do: "Microsecond"
  defp precision_name(_nanosecond_or_auto), do: "Nanosecond"

  # `:auto` is InfluxDB 3's guess from the magnitude, verified against the
  # engine: |ts| below 5e9 is seconds, below 5e12 milliseconds, below 5e15
  # microseconds, otherwise nanoseconds.
  @spec to_nanoseconds(integer(), precision()) :: integer()
  defp to_nanoseconds(ts, :auto) when abs(ts) < 5_000_000_000, do: to_nanoseconds(ts, :second)

  defp to_nanoseconds(ts, :auto) when abs(ts) < 5_000_000_000_000,
    do: to_nanoseconds(ts, :millisecond)

  defp to_nanoseconds(ts, :auto) when abs(ts) < 5_000_000_000_000_000,
    do: to_nanoseconds(ts, :microsecond)

  defp to_nanoseconds(ts, :auto), do: ts
  defp to_nanoseconds(ts, :nanosecond), do: ts
  defp to_nanoseconds(ts, :microsecond), do: ts * 1_000
  defp to_nanoseconds(ts, :millisecond), do: ts * 1_000_000
  defp to_nanoseconds(ts, :second), do: ts * 1_000_000_000
end
