defmodule InfluxElixir.Client.Local.Retention do
  @moduledoc false
  # A v3 database's retention period, as `Client.Local` keeps and applies it
  # (all verified against InfluxDB 3 Core).
  #
  # `retention_period` is a duration string in the grammar of Rust's
  # `humantime`: one or more `<number><unit>` parts, optionally spaced, a
  # fraction allowed (`1.5h`), units case-sensitive. A month is 30.44 days
  # and a year 365.25. The engine keeps whole seconds: `1500ms` is `1s` and
  # anything under a second is `0`, which is a retention of zero, not none.
  #
  # A write is never refused for being older than the retention: it is
  # accepted (204, whatever `accept_partial` says) and stored. Expiry is a
  # read rule: a query sees only the chunks that still hold a point at or
  # after `now - retention`. A chunk is the points of one table within one
  # 10-minute window (a multiple of 600 s since the epoch), not a point: an
  # expired point shares the fate of the newest point in its chunk, so it is
  # shown for as long as that point is, and a table whose chunks are all
  # expired answers no rows while its schema (columns, `SHOW MEASUREMENTS`,
  # `SHOW TAG KEYS`) stays. A retention of `0` hides every point before now.
  # All of SQL, InfluxQL and `SHOW TAG VALUES` read through this rule.
  #
  # A store keeps a marker for each chunk a database with a retention was
  # written to (`chunks/1`), so a read finds out from the few markers, not from
  # the points, that none reaches back to the cut-off (`oldest_chunk/1`) and
  # shows every point as it is; only when one does are the points sorted out
  # (`visible/3`).
  #
  # The engine's own persisted files follow the same rule, per file: a
  # chunk that the engine has split across files by writes on either side of
  # a snapshot is not modelled.

  @chunk_ns 600 * 1_000_000_000
  @second_ns 1_000_000_000

  # Nanoseconds in each unit the grammar knows, longest spelling first within
  # a unit so that the regex alternation never stops at a shorter prefix.
  @units [
    {~w(nanos nsec ns), 1},
    {~w(usec us µs), 1_000},
    {~w(millis msec ms), 1_000_000},
    {~w(seconds second secs sec s), @second_ns},
    {~w(minutes minute mins min m), 60 * @second_ns},
    {~w(hours hour hrs hr h), 3_600 * @second_ns},
    {~w(days day d), 86_400 * @second_ns},
    {~w(weeks week w), 604_800 * @second_ns},
    {~w(months month M), 2_630_016 * @second_ns},
    {~w(years year y), 31_557_600 * @second_ns}
  ]

  @unit_ns Map.new(for {names, ns} <- @units, name <- names, do: {name, ns})
  @unit_pattern @unit_ns
                |> Map.keys()
                |> Enum.sort_by(&{-String.length(&1), &1})
                |> Enum.join("|")

  @duration Regex.compile!(
              "^\\s*(?:0|(?:\\d+(?:\\.\\d+)?\\s*(?:#{@unit_pattern})\\s*)+)\\s*$",
              "u"
            )
  @part Regex.compile!("(\\d+)(?:\\.(\\d+))?\\s*(#{@unit_pattern})", "u")

  @typedoc "A retention: whole seconds, or `nil` for a database without one."
  @type t :: non_neg_integer() | nil

  @doc "Whether `text` is a duration the engine reads."
  @spec valid?(binary()) :: boolean()
  def valid?(text), do: Regex.match?(@duration, text)

  @doc """
  The retention in whole seconds of a valid duration `text` (see `valid?/1`),
  fractions of a second dropped.
  """
  @spec seconds(binary()) :: non_neg_integer()
  def seconds(text) do
    @part
    |> Regex.scan(text)
    |> Enum.map(fn [_all, whole, fraction, unit] -> part_ns(whole, fraction, unit) end)
    |> Enum.sum()
    |> div(@second_ns)
  end

  @spec part_ns(binary(), binary(), binary()) :: non_neg_integer()
  defp part_ns(whole, fraction, unit) do
    scale = Map.fetch!(@unit_ns, unit)
    digits = byte_size(fraction)
    numerator = String.to_integer(whole <> fraction)
    div(numerator * scale, Integer.pow(10, digits))
  end

  @doc """
  The duration as `SHOW RETENTION POLICIES` prints it, in the whole seconds
  of `retention`: `0s` for none, `30s`, `1m0s`, `1h30m0s`, `168h0m0s`.
  """
  @spec format(t()) :: binary()
  def format(nil), do: "0s"

  def format(seconds) do
    hours = div(seconds, 3_600)
    minutes = seconds |> div(60) |> rem(60)
    rest = rem(seconds, 60)

    cond do
      hours > 0 -> "#{hours}h#{minutes}m#{rest}s"
      minutes > 0 -> "#{minutes}m#{rest}s"
      true -> "#{rest}s"
    end
  end

  @doc """
  The oldest timestamp, in nanoseconds, a point may have and be visible by its
  own age: a retention of `seconds` before `now_ns`.
  """
  @spec cutoff(non_neg_integer(), integer()) :: integer()
  def cutoff(seconds, now_ns), do: now_ns - seconds * @second_ns

  @doc """
  The chunks `points` fall in, each once, as `{measurement, index}`. A store
  keeps one marker per chunk it has written to, so that a table with no chunk
  that reaches back to the cut-off (`oldest_chunk/1`) is known to hold no
  expired point without reading its points.
  """
  @spec chunks([map()]) :: [{binary(), integer()}]
  def chunks(points) do
    points
    |> Enum.reduce(%{}, fn point, seen ->
      chunk = chunk(point)
      if is_map_key(seen, chunk), do: seen, else: Map.put(seen, chunk, true)
    end)
    |> Map.keys()
  end

  @doc """
  The index of the newest chunk that can hold a point older than `cutoff`: the
  one `cutoff` falls in, since every one before it is expired whole.
  """
  @spec oldest_chunk(integer()) :: integer()
  def oldest_chunk(cutoff), do: Integer.floor_div(cutoff, @chunk_ns)

  @doc """
  The points a query sees: all of them without a retention, otherwise those
  in a chunk (one measurement, one 10-minute window) with a point at or after
  `now_ns - retention`.

  A point at or after the cut-off is seen by its own age, and every chunk
  before the one the cut-off falls in is expired whole, so only that one
  chunk of each measurement can be kept alive by a newer point: the
  measurements with a point in it from the cut-off on are found in one pass,
  and a point is kept when it is not older than the cut-off or lies in that
  chunk of such a measurement.
  """
  @spec visible([map()], t(), integer()) :: [map()]
  def visible(points, nil, _now_ns), do: points

  def visible(points, seconds, now_ns) do
    cutoff = cutoff(seconds, now_ns)

    if all_current?(points, cutoff),
      do: points,
      else: kept(points, cutoff, oldest_chunk(cutoff) * @chunk_ns)
  end

  @spec chunk(map()) :: {binary(), integer()}
  defp chunk(point), do: {point.measurement, Integer.floor_div(point.timestamp, @chunk_ns)}

  @spec all_current?([map()], integer()) :: boolean()
  defp all_current?([], _cutoff), do: true

  defp all_current?([%{timestamp: timestamp} | rest], cutoff) when timestamp >= cutoff,
    do: all_current?(rest, cutoff)

  defp all_current?(_expired, _cutoff), do: false

  @spec kept([map()], integer(), integer()) :: [map()]
  defp kept(points, cutoff, window_start) do
    window_end = window_start + @chunk_ns

    alive =
      Enum.reduce(points, %{}, fn
        %{timestamp: timestamp, measurement: measurement}, acc
        when timestamp >= cutoff and timestamp < window_end ->
          Map.put(acc, measurement, true)

        _point, acc ->
          acc
      end)

    Enum.filter(points, fn %{timestamp: timestamp, measurement: measurement} ->
      timestamp >= cutoff or (timestamp >= window_start and is_map_key(alive, measurement))
    end)
  end
end
