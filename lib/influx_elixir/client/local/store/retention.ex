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
  The points a query sees: all of them without a retention, otherwise those
  in a chunk (one measurement, one 10-minute window) with a point at or after
  `now_ns - retention`.
  """
  @spec visible([map()], t(), integer()) :: [map()]
  def visible(points, nil, _now_ns), do: points

  def visible(points, seconds, now_ns) do
    cutoff = now_ns - seconds * @second_ns

    newest =
      Enum.reduce(points, %{}, fn point, acc ->
        Map.update(acc, chunk(point), point.timestamp, &max(&1, point.timestamp))
      end)

    Enum.filter(points, &(Map.fetch!(newest, chunk(&1)) >= cutoff))
  end

  @spec chunk(map()) :: {binary(), integer()}
  defp chunk(point), do: {point.measurement, Integer.floor_div(point.timestamp, @chunk_ns)}
end
