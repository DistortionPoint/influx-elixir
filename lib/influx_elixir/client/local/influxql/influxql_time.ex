defmodule InfluxElixir.Client.Local.InfluxQLTime do
  @moduledoc false
  # What the engine's planner does with `time` in a `WHERE`, before the SQL
  # engine ever sees it (verified):
  #
  #   * a quoted time is read by the planner, not by the SQL engine: a string
  #     it cannot read is `'a' is not a valid timestamp`, one in a form it
  #     reads that does not fit 64-bit nanoseconds is `timestamp out of range`
  #     (`classify/1`)
  #   * `time` standing alone as a condition breaks the planner's stack: as the
  #     whole `WHERE` it is a 500 "expected an element on stack", beside an
  #     `AND` or `OR` a 500 "invalid expr stack", and in parentheses a plain
  #     type error (`check_bare/1`)

  # The patterns here read the CONTENT of a quoted time literal, not statement text, so they
  # are `~r` and keep PCRE's own `\s`, not `~q` (see `InfluxQLBlankRegex`): a vertical tab or a
  # form feed in a time is not a form the double has verified, and `\s` taking it makes the
  # time `:unknown`, which is refused by name, rather than a claim that Core refuses it. Only
  # `trailing_blank?/1`, which claims a refusal, reads the blank as the language does (`~q`).
  import InfluxElixir.Client.Local.InfluxQLBlankRegex, only: [sigil_q: 2]

  alias InfluxElixir.Client.Local.{InfluxQLError, InfluxQLTokens, SQLLimits}

  require SQLLimits

  @day_seconds 86_400

  @date ~r/^(\d{4})-(\d{2})-(\d{2})$/
  @zone "([Zz]|[Uu][Tt][Cc]|[+-]\\d{2}:?\\d{2})"

  # A time with a zone is read leniently (verified): blanks before it, a
  # `+` before the year, one or two digits for every part but the year, any
  # blanks after the `T` or in place of it.
  @zoned Regex.compile!(
           "^\\s*\\+?(\\d{4})-(\\d{1,2})-(\\d{1,2})(?:[Tt]\\s*|\\s+)(\\d{1,2}):(\\d{1,2}):(\\d{1,2})" <>
             "(?:\\.(\\d+))?[ \\t]*" <> @zone <> "$"
         )

  # What follows a whole clock and is not a zone the engine reads.
  @bad_zone ~r/^\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?[\w.,:+\- ]*$/
  @date_zone Regex.compile!("^\\d{4}-\\d{2}-\\d{2}[ \\t]*" <> @zone <> "$")
  @short_clock Regex.compile!(
                 "^\\d{4}-\\d{2}-\\d{2}[Tt ]\\d{2}(?::\\d{2})?[ \\t]*" <> @zone <> "$"
               )
  @naive_space ~r/^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?$/

  # ---------------------------------------------------------------------------
  # A quoted time
  # ---------------------------------------------------------------------------

  @doc """
  How the planner reads the content of a quoted time: `{:ok, nanoseconds}`, `:invalid`,
  `{:out_of_range, shown}` (with the time as the engine prints it), or
  `:unknown` for a form the double does not tell from the engine's.
  """
  @spec classify(binary()) :: {:ok, integer()} | :invalid | {:out_of_range, binary()} | :unknown
  def classify(content) do
    cond do
      not printable?(content) -> :unknown
      not Regex.match?(~r/^\s*[+-]?\d+-\d+-\d+/, content) -> :invalid
      Regex.match?(~r/^\d{5,}-\d+-\d+/, content) -> :invalid
      match = Regex.run(@date, content) -> read(match, "00", "00", "00", nil, "Z")
      match = Regex.run(@zoned, content) -> read_zoned(match)
      match = Regex.run(@naive_space, content) -> read_naive(match)
      naive_clock?(content) or trailing_blank?(content) -> :invalid
      Enum.any?([@date_zone, @short_clock, @bad_zone], &Regex.match?(&1, content)) -> :invalid
      true -> :unknown
    end
  end

  @spec printable?(binary()) :: boolean()
  defp printable?(content),
    do: String.printable?(content) and not String.contains?(content, ["\"", "\\", "'"])

  # A form with a clock that the engine refuses: `T` with no zone, a space
  # form without seconds.
  @spec naive_clock?(binary()) :: boolean()
  defp naive_clock?(content),
    do:
      Regex.match?(
        ~r/^\d{4}-\d{2}-\d{2}(?:[Tt]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?| \d{2}:\d{2})$/,
        content
      )

  @spec trailing_blank?(binary()) :: boolean()
  defp trailing_blank?(content), do: Regex.match?(~q/^\d{4}-\d{2}-\d{2}[Tt ]\S+\s+$/, content)

  @spec read_zoned([binary()]) ::
          {:ok, integer()} | :invalid | {:out_of_range, binary()} | :unknown
  defp read_zoned([_all, y, mo, d, h, mi, s, fraction, zone]),
    do: read([nil, y, mo, d], h, mi, s, fraction, zone)

  @spec read_naive([binary()]) ::
          {:ok, integer()} | :invalid | {:out_of_range, binary()} | :unknown
  defp read_naive([_all, y, mo, d, h, mi, s, fraction]),
    do: read([nil, y, mo, d], h, mi, s, fraction, "Z")

  defp read_naive([_all, y, mo, d, h, mi, s]), do: read([nil, y, mo, d], h, mi, s, nil, "Z")

  @spec read([binary() | nil], binary(), binary(), binary(), binary() | nil, binary()) ::
          {:ok, integer()} | :invalid | {:out_of_range, binary()} | :unknown
  defp read([_all, y, mo, d], h, mi, s, fraction, zone) do
    [year, month, day, hour, minute, second] =
      Enum.map([y, mo, d, h, mi, s], &String.to_integer/1)

    if valid_date?(year, month, day) and hour <= 23 and minute <= 59 and second <= 60 and
         zone_valid?(zone) do
      in_range(year, month, day, {hour, minute, second}, fraction || "", zone)
    else
      :invalid
    end
  end

  @spec valid_date?(integer(), integer(), integer()) :: boolean()
  defp valid_date?(year, month, day),
    do: month in 1..12 and day >= 1 and day <= :calendar.last_day_of_the_month(year, month)

  @spec in_range(integer(), integer(), integer(), tuple(), binary(), binary()) ::
          {:ok, integer()} | {:out_of_range, binary()} | :unknown
  defp in_range(year, month, day, {hour, minute, second}, fraction, zone) do
    days =
      :calendar.date_to_gregorian_days(year, month, day) -
        :calendar.date_to_gregorian_days(1970, 1, 1)

    seconds = days * @day_seconds + hour * 3600 + minute * 60 + second - offset(zone)
    ns = seconds * 1_000_000_000 + fraction_ns(fraction)

    cond do
      SQLLimits.is_int64(ns) -> {:ok, ns}
      zone not in ["Z", "z"] or byte_size(fraction) not in [0, 3, 6, 9] -> :unknown
      true -> {:out_of_range, shown(year, month, day, {hour, minute, second}, fraction)}
    end
  end

  @spec offset(binary()) :: integer()
  defp offset(<<sign, h::binary-size(2), ":", m::binary-size(2)>>), do: offset(sign, h, m)
  defp offset(<<sign, h::binary-size(2), m::binary-size(2)>>), do: offset(sign, h, m)
  defp offset(_utc), do: 0

  defp offset(sign, h, m) do
    seconds = String.to_integer(h) * 3600 + String.to_integer(m) * 60
    if sign == ?-, do: -seconds, else: seconds
  end

  # An offset of 24 hours or more, or of 60 minutes, is no time zone.
  @spec zone_valid?(binary()) :: boolean()
  defp zone_valid?(<<sign, h::binary-size(2), rest::binary>>) when sign in [?+, ?-] do
    minutes = rest |> String.trim_leading(":") |> String.to_integer()
    String.to_integer(h) <= 23 and minutes <= 59
  end

  defp zone_valid?(_z_or_utc), do: true

  @spec fraction_ns(binary()) :: non_neg_integer()
  defp fraction_ns(""), do: 0

  defp fraction_ns(digits),
    do: digits |> String.slice(0, 9) |> String.pad_trailing(9, "0") |> String.to_integer()

  @spec shown(integer(), integer(), integer(), tuple(), binary()) :: binary()
  defp shown(year, month, day, {hour, minute, second}, fraction) do
    date = "#{pad(year, 4)}-#{pad(month, 2)}-#{pad(day, 2)}"
    clock = "#{pad(hour, 2)}:#{pad(minute, 2)}:#{pad(second, 2)}"
    "#{date} #{clock}#{if fraction == "", do: "", else: "." <> fraction} +00:00"
  end

  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")

  @doc """
  The planner's error for an instant that does not fit 64-bit nanoseconds,
  as it names it (`2297-10-16 00:00:00.500 +00:00`: the fraction in groups of
  three digits, as needed). Throws `{:refused, ...}`; an instant beyond the
  years 1 to 9999 is refused by name.
  """
  @spec out_of_range(integer()) :: no_return()
  def out_of_range(ns) do
    seconds = Integer.floor_div(ns, 1_000_000_000)

    if seconds < -62_135_596_800 or seconds > 253_402_300_799,
      do: throw({:refused, "unsupported InfluxQL (a time beyond the year 9999)"})

    %DateTime{year: y, month: mo, day: d, hour: h, minute: mi, second: s} =
      DateTime.from_unix!(seconds)

    fraction = ns |> Integer.mod(1_000_000_000) |> fraction_digits()
    shown = shown(y, mo, d, {h, mi, s}, fraction)
    message = "Error during planning: timestamp out of range: #{shown}"
    throw({:refused, {:engine, 400, InfluxQLError.split_error(message)}})
  end

  @spec fraction_digits(non_neg_integer()) :: binary()
  defp fraction_digits(0), do: ""
  defp fraction_digits(nanos) when rem(nanos, 1_000_000) == 0, do: pad(div(nanos, 1_000_000), 3)
  defp fraction_digits(nanos) when rem(nanos, 1_000) == 0, do: pad(div(nanos, 1_000), 6)
  defp fraction_digits(nanos), do: pad(nanos, 9)

  # ---------------------------------------------------------------------------
  # `time` as a condition
  # ---------------------------------------------------------------------------

  @doc """
  Throws `{:refused, {:engine, status, body}}` when the condition tree has a
  bare `time` in it; returns `:ok` otherwise.
  """
  @spec check_bare(tuple()) :: :ok
  def check_bare(tree) do
    cond do
      bare?(tree) -> refuse(500, "expected an element on stack")
      grouped_bare?(tree) -> refuse(400, type_coercion())
      true -> check_operands(tree)
    end
  end

  @spec check_operands(tuple()) :: :ok
  defp check_operands(tree) do
    cond do
      stacked?(tree) ->
        refuse(500, "invalid expr stack")

      not grouped_in_connective?(tree) ->
        :ok

      mentions_time_comparison?(tree) ->
        refuse(500, "invalid expr stack")

      true ->
        grouped_error(tree)
    end
  end

  # What a node is: a bare `time` (the whole condition or the operand of a
  # connective), a `time` in parentheses, or something else.
  @spec kind(tuple()) :: :bare | :grouped | :other
  defp kind({:cmp, tokens}) do
    case unwrap(tokens, 0) do
      {[token], depth} -> if InfluxQLTokens.time?(token), do: depth_kind(depth), else: :other
      _other -> :other
    end
  end

  defp kind({:group, node}), do: if(kind(node) == :other, do: :other, else: :grouped)
  defp kind(_node), do: :other

  defp depth_kind(0), do: :bare
  defp depth_kind(_depth), do: :grouped

  defp unwrap([{:raw, "("} | rest] = tokens, depth) do
    case Enum.split(rest, -1) do
      {inside, [{:raw, ")"}]} -> unwrap(inside, depth + 1)
      _unbalanced -> {tokens, depth}
    end
  end

  defp unwrap(tokens, depth), do: {tokens, depth}

  @spec bare?(tuple()) :: boolean()
  defp bare?(node), do: kind(node) == :bare

  @spec grouped_bare?(tuple()) :: boolean()
  defp grouped_bare?(node), do: kind(node) == :grouped

  @spec stacked?(tuple()) :: boolean()
  defp stacked?({kind, nodes}) when kind in [:and, :or],
    do: Enum.any?(nodes, &(bare?(&1) or stacked?(&1)))

  defp stacked?({:group, node}), do: stacked?(node)
  defp stacked?(_node), do: false

  @spec grouped_in_connective?(tuple()) :: boolean()
  defp grouped_in_connective?({kind, nodes}) when kind in [:and, :or],
    do: Enum.any?(nodes, &(grouped_bare?(&1) or grouped_in_connective?(&1)))

  defp grouped_in_connective?({:group, node}), do: grouped_in_connective?(node)
  defp grouped_in_connective?(_node), do: false

  @doc "Whether a comparison of the `time` stands anywhere in the condition tree."
  @spec mentions_time_comparison?(tuple()) :: boolean()
  def mentions_time_comparison?({:cmp, tokens}),
    do: Enum.any?(tokens, &match?({:op, _op}, &1)) and Enum.any?(tokens, &InfluxQLTokens.time?/1)

  def mentions_time_comparison?({:group, node}), do: mentions_time_comparison?(node)

  def mentions_time_comparison?({_kind, nodes}),
    do: Enum.any?(nodes, &mentions_time_comparison?/1)

  # `(time) AND i > 1`: the engine types the two sides and refuses; the
  # double has seen that and only that.
  @spec grouped_error(tuple()) :: :ok
  defp grouped_error({:group, node}), do: grouped_error(node)

  defp grouped_error({kind, [left, right]}) when kind in [:and, :or] do
    connective = if kind == :and, do: "AND", else: "OR"

    case {grouped_bare?(left), grouped_bare?(right), boolean?(left), boolean?(right)} do
      {true, false, _left, true} -> refuse_types("Timestamp(ns)", connective, "Boolean")
      {false, true, true, _right} -> refuse_types("Boolean", connective, "Timestamp(ns)")
      _other -> refuse_by_name()
    end
  end

  defp grouped_error({kind, nodes}) when kind in [:and, :or] do
    Enum.each(nodes, &grouped_error_inner/1)
    refuse_by_name()
  end

  defp grouped_error(_node), do: :ok

  defp grouped_error_inner(node), do: if(grouped_in_connective?(node), do: grouped_error(node))

  @spec boolean?(tuple()) :: boolean()
  defp boolean?({:cmp, tokens}), do: Enum.any?(tokens, &match?({:op, _op}, &1))
  defp boolean?({:group, node}), do: boolean?(node)
  defp boolean?(_node), do: false

  @spec refuse_types(binary(), binary(), binary()) :: no_return()
  defp refuse_types(left, connective, right) do
    message =
      "Error during planning: Cannot infer common argument type for logical boolean " <>
        "operation #{left} #{connective} #{right}"

    throw({:refused, {:engine, 400, message}})
  end

  @spec refuse_by_name() :: no_return()
  defp refuse_by_name,
    do: throw({:refused, "unsupported InfluxQL (a bare time inside a condition of that shape)"})

  @spec type_coercion() :: binary()
  defp type_coercion do
    "type_coercion\ncaused by\nError during planning: Cannot infer common argument type " <>
      "for logical boolean operation Boolean AND Timestamp(ns)"
  end

  @doc "The engine's error for a condition that splits its `time` from an operand that is no boolean."
  @spec refuse_stack() :: no_return()
  def refuse_stack, do: refuse(500, "invalid expr stack")

  @spec refuse(pos_integer(), binary()) :: no_return()
  defp refuse(400, body), do: throw({:refused, {:engine, 400, body}})

  defp refuse(500, message) do
    throw(
      {:refused,
       {:engine, 500,
        InfluxQLError.split_error("External error: InfluxQL internal error: " <> message)}}
    )
  end
end
