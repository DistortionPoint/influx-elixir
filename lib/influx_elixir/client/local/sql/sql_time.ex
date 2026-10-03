defmodule InfluxElixir.Client.Local.SQLTime do
  @moduledoc false
  # What a `time` comparand is, as InfluxDB 3 reads it (verified against Core):
  #
  #   * a quoted string is read as Arrow reads a timestamp: `YYYY-MM-DD`, then
  #     optionally `T`, `t` or a space, `HH:MM:SS` (`:60` is the next minute), a
  #     fraction (digits past the ninth are dropped) and a zone — `Z`, `z`, a
  #     fixed offset (`+01:00`, `+0100`, `+01`, after any blanks) or a name of
  #     the time zone database, which is case sensitive: the ones that are UTC
  #     (`UTC`, `GMT`, `Zulu`, `UCT`, `Universal`, `Greenwich`, `GMT0`, `GMT+0`,
  #     `GMT-0` and the same under `Etc/`), `Etc/GMT+1` to `Etc/GMT+12` (the
  #     sign is inverted: UTC minus that many hours) and `Etc/GMT-1` to
  #     `Etc/GMT-14`, and the fixed offsets `EST`, `MST` and `HST`. A string it cannot
  #     read is the optimizer's 500 naming why (`timestamp must contain at
  #     least 10 characters`, `error parsing date`, `invalid timestamp
  #     separator`, `error parsing time`, `Invalid timezone "..."`), and an
  #     instant outside the `Int64` nanoseconds is its overflow error
  #   * `now()`, offset by `+`/`-` `INTERVAL 'N unit'` terms
  #   * a `$name`, bound by `InfluxElixir.Client.Local.SQLBind`: a string is
  #     read as above, a null is unknown, a number or boolean is the planner's
  #     type error
  #   * `NULL`, which compares as unknown
  #   * a bare number is the planner's type error, worded by the caller
  #
  # The optimizer folds a constant after the planner has typed the whole
  # query, so an unreadable string is kept in the parsed query as
  # `{:invalid_time, error}` and raised by `first_invalid/1` once the type
  # checks have passed. What the double cannot model — a time zone whose offset
  # changes with the date — is the same marker carrying a `Client.Local:`
  # refusal.

  alias InfluxElixir.Client.Local.{SQLError, SQLLimits, SQLLiteral}

  require SQLLimits

  @typedoc """
  A `time` comparand: nanoseconds since the epoch, `now()` plus an offset,
  null, a `$name` still to bind, a bare number of the given type (an error
  once the clause is known) or an unreadable string.
  """
  @type bound ::
          integer()
          | {:now, integer()}
          | nil
          | {:param, binary()}
          | {:param, binary(), :left}
          | {:number, binary()}
          | {:invalid_time, SQLError.t()}

  @typedoc "What `comparand/1` returns."
  @type comparand ::
          {:ok, bound()} | {:error, {:number, binary()} | SQLError.t()}

  @now_pattern ~r/^now\(\)((?:\s*[+-]\s*INTERVAL\s*'[^']*')*)$/iu
  @interval_term ~r/([+-])\s*INTERVAL\s*'([^']*)'/iu

  @int64_max SQLLimits.int64_max()
  @first_second -9_223_372_036

  # The names of the time zone database that are UTC all year (verified).
  @utc_zones ~w(UTC GMT Zulu UCT Universal Greenwich GMT0 GMT+0 GMT-0 Etc/UTC Etc/GMT Etc/UCT
                Etc/Zulu Etc/Universal Etc/Greenwich Etc/GMT0 Etc/GMT+0 Etc/GMT-0)

  # Names whose offset never changes (verified: the offset holds in July).
  @fixed_zones %{"EST" => -5 * 3600, "MST" => -7 * 3600, "HST" => -10 * 3600}

  # Zone names of the tz database with no fixed offset; the double holds no
  # tz database and refuses these, and any name with a `/`, by name.
  @zone_names ~w(EST5EDT CST6CDT MST7MDT PST8PDT CET MET EET WET Cuba Egypt Eire Hongkong
                 Iceland Iran Israel Jamaica Japan Kwajalein Libya Navajo NZ PRC Poland
                 Portugal ROC ROK Singapore Turkey)

  @doc """
  Reads the text of a `time` comparand. `{:error, {:number, type}}` is a bare
  number of that type, for the caller to word as its clause does.
  """
  @spec comparand(binary()) :: comparand()
  def comparand(text) do
    cond do
      SQLLiteral.string?(text) -> string_bound(SQLLiteral.body(text))
      String.upcase(text) == "NULL" -> {:ok, nil}
      match = Regex.run(@now_pattern, text) -> now_offset(match)
      SQLLiteral.param?(text) -> {:ok, {:param, SQLLiteral.param_name(text)}}
      SQLLiteral.identifier?(text) -> {:error, unsupported(text)}
      type = number_type(text) -> {:error, {:number, type}}
      true -> {:error, unsupported(text)}
    end
  end

  @doc """
  A comparand as a bound: a bare number stays `{:number, type}` and an
  unreadable one becomes `{:invalid_time, error}`, for the clause to settle.
  """
  @spec bound(comparand()) :: bound()
  def bound({:ok, value}), do: value
  def bound({:error, {:number, type}}), do: {:number, type}
  def bound({:error, error}), do: {:invalid_time, error}

  @spec string_bound(binary()) :: {:ok, bound()}
  defp string_bound(text) do
    case literal(text) do
      {:ok, ns} -> {:ok, ns}
      {:error, error} -> {:ok, {:invalid_time, error}}
    end
  end

  @spec number_type(binary()) :: binary() | nil
  defp number_type(text) do
    cond do
      SQLLiteral.integer?(text) -> "Int64"
      SQLLiteral.float?(text) -> "Float64"
      true -> nil
    end
  end

  @spec unsupported(binary()) :: SQLError.t()
  defp unsupported(text) do
    SQLError.refusal(
      "a `time` comparand must be a quoted ISO-8601 string, now() +/- INTERVAL 'N unit', " <>
        "NULL or a $parameter: " <> text
    )
  end

  @doc """
  The engine's type error for `time` compared with something that is not a
  timestamp.
  """
  @spec comparison_type_error(binary(), binary(), binary()) :: SQLError.t()
  def comparison_type_error(left, operator, right) do
    operator = if operator == "<>", do: "!=", else: operator

    SQLError.coercion(
      "Cannot infer common argument type for comparison operation #{left} #{operator} #{right}"
    )
  end

  @doc "What a bound parameter is as a `time` comparand."
  @spec param(term()) :: bound()
  def param(value) when is_binary(value) do
    case literal(value) do
      {:ok, ns} -> ns
      {:error, error} -> {:invalid_time, error}
    end
  end

  def param(nil), do: nil
  def param(value) when is_integer(value) and value >= 0, do: {:number, "UInt64"}
  def param(value) when is_integer(value), do: {:number, "Int64"}
  def param(value) when is_float(value), do: {:number, "Float64"}
  def param(value) when is_boolean(value), do: {:number, "Boolean"}

  @doc "Whether the bound is a `$name` still to bind."
  @spec param_bound?(term()) :: boolean()
  def param_bound?({:param, _name}), do: true
  def param_bound?({:param, _name, :left}), do: true
  def param_bound?(_bound), do: false

  @doc """
  A `time` BETWEEN once its bounds are known: a bare number fails it, naming
  the first bound that has one.
  """
  @spec between(:between | :not_between, bound(), bound()) ::
          {:ok, {atom(), binary(), {bound(), bound()}}} | {:error, SQLError.t()}
  def between(op, low, high) do
    case {low, high} do
      {{:number, type}, _high} -> {:error, SQLError.between_coercion("Timestamp(ns)", type)}
      {_low, {:number, type}} -> {:error, SQLError.between_coercion("Timestamp(ns)", type)}
      {low, high} -> {:ok, {op, "time", {low, high}}}
    end
  end

  @doc """
  A `time` IN list once its items are known: a bare number fails the whole
  list, which the engine words with every item's type, a string being `Utf8`.
  """
  @spec in_list([bound()]) :: {:ok, [bound()]} | {:error, SQLError.t()}
  def in_list(bounds) do
    if Enum.any?(bounds, &match?({:number, _type}, &1)) do
      types =
        Enum.map_join(bounds, ", ", fn
          {:number, type} -> type
          nil -> "Null"
          _other -> "Utf8"
        end)

      {:error,
       SQLError.coercion("Can not find compatible types to compare Timestamp(ns) with [#{types}]")}
    else
      {:ok, bounds}
    end
  end

  @doc """
  The first unreadable string among the `time` comparands of a `WHERE`, in
  the order written, as the optimizer's error; `:ok` when there is none.
  """
  @spec first_invalid([term()]) :: :ok | {:error, SQLError.t()}
  def first_invalid(nodes), do: nodes |> invalid_in() |> List.first() |> invalid_result()

  @doc """
  The first type error kept in a `WHERE` (a `time` compared with a number,
  see `InfluxElixir.Client.Local.SQLPredicate.deferred_clause/1`), in the order
  written; `:ok` when there is none. A statement that is not planned
  against a schema raises it as soon as it is parsed.
  """
  @spec first_type_error([term()]) :: :ok | {:error, SQLError.t()}
  def first_type_error(nodes), do: nodes |> type_errors_in() |> List.first() |> invalid_result()

  @spec type_errors_in(term()) :: [SQLError.t()]
  defp type_errors_in(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &type_errors_in/1)
  defp type_errors_in({:or, branches}), do: Enum.flat_map(branches, &type_errors_in/1)
  defp type_errors_in({:not, conjunction}), do: type_errors_in(conjunction)
  defp type_errors_in({:time_type_error, "time", error}), do: [error]
  defp type_errors_in(_other), do: []

  @spec invalid_result(SQLError.t() | nil) :: :ok | {:error, SQLError.t()}
  defp invalid_result(nil), do: :ok
  defp invalid_result(error), do: {:error, error}

  @spec invalid_in(term()) :: [SQLError.t()]
  defp invalid_in(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &invalid_in/1)
  defp invalid_in({:or, branches}), do: Enum.flat_map(branches, &invalid_in/1)
  defp invalid_in({:not, conjunction}), do: invalid_in(conjunction)
  defp invalid_in({:invalid_time, error}), do: [error]

  defp invalid_in({op, "time", {low, high}}) when op in [:between, :not_between],
    do: invalid_in([low, high])

  defp invalid_in({op, "time", values}) when op in [:in, :not_in] and is_list(values),
    do: invalid_in(values)

  defp invalid_in({_op, "time", value}), do: invalid_in(value)
  defp invalid_in(_other), do: []

  # ---------------------------------------------------------------------------
  # now() and intervals
  # ---------------------------------------------------------------------------

  @spec now_offset([binary()]) :: {:ok, {:now, integer()}} | {:error, SQLError.t()}
  defp now_offset([_full, terms]) do
    @interval_term
    |> Regex.scan(terms)
    |> Enum.reduce_while({:ok, {:now, 0}}, fn [_term, sign, interval], {:ok, {:now, acc}} ->
      case interval(interval) do
        {:ok, ns} when sign == "-" -> {:cont, {:ok, {:now, acc - ns}}}
        {:ok, ns} -> {:cont, {:ok, {:now, acc + ns}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  An interval as nanoseconds: `"N unit"` with the unit one of second,
  minute, hour or day (plural or not).
  """
  @spec interval(binary()) :: {:ok, pos_integer()} | {:error, SQLError.t()}
  def interval(text) do
    case Regex.run(~r/^\s*([0-9]+)\s+(\w+)\s*$/u, text) do
      [_full, count, unit] ->
        case unit_ns(String.downcase(unit)) do
          nil -> {:error, SQLError.refusal("unknown interval unit: #{unit}")}
          ns -> {:ok, String.to_integer(count) * ns}
        end

      _no_match ->
        {:error, SQLError.refusal("invalid interval: #{text}")}
    end
  end

  @spec unit_ns(binary()) :: pos_integer() | nil
  defp unit_ns(unit) when unit in ["second", "seconds"], do: 1_000_000_000
  defp unit_ns(unit) when unit in ["minute", "minutes"], do: 60_000_000_000
  defp unit_ns(unit) when unit in ["hour", "hours"], do: 3_600_000_000_000
  defp unit_ns(unit) when unit in ["day", "days"], do: 86_400_000_000_000
  defp unit_ns(_unknown), do: nil

  # ---------------------------------------------------------------------------
  # A timestamp string, as Arrow reads it
  # ---------------------------------------------------------------------------

  # A quoted timestamp's text as nanoseconds since the epoch, or the
  # optimizer's error for it.
  @spec literal(binary()) :: {:ok, integer()} | {:error, SQLError.t()}
  defp literal(text) do
    with {:ok, instant, leap} <- timestamp(text),
         :ok <- in_range(instant, leap) do
      {:ok, instant}
    else
      {:error, detail} -> {:error, SQLError.simplify(detail)}
      {:refusal, message} -> {:error, SQLError.refusal(message)}
    end
  end

  # Arrow counts bytes, so a short string of wide characters is long enough.
  @spec timestamp(binary()) ::
          {:ok, integer(), boolean()} | {:error, binary()} | {:refusal, binary()}
  defp timestamp(text) when byte_size(text) < 10,
    do: failed(text, "timestamp must contain at least 10 characters")

  defp timestamp(text) do
    with {:ok, date, rest} <- date(text),
         {:ok, clock, offset} <- time_and_zone(rest) do
      {_seconds, _nanos, leap} = clock
      {:ok, instant(date, clock, offset), leap}
    else
      {:error, reason} when is_binary(reason) ->
        failed(text, reason)

      {:zone, zone} ->
        {:error,
         ~s|Arrow error: Parser error: Invalid timezone "#{zone}": failed to parse timezone|}

      {:refusal, _message} = refusal ->
        refusal
    end
  end

  @spec failed(binary(), binary()) :: {:error, binary()}
  defp failed(text, reason),
    do: {:error, "Arrow error: Parser error: Error parsing timestamp from '#{text}': #{reason}"}

  @spec date(binary()) :: {:ok, Date.t(), binary()} | {:error, binary()}
  defp date(<<y::binary-size(4), ?-, m::binary-size(2), ?-, d::binary-size(2), rest::binary>>) do
    with true <- digits?(y <> m <> d),
         {:ok, date} <- Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
      {:ok, date, rest}
    else
      _invalid -> {:error, "error parsing date"}
    end
  end

  defp date(_text), do: {:error, "error parsing date"}

  @spec time_and_zone(binary()) ::
          {:ok, {integer(), non_neg_integer(), boolean()}, integer()}
          | {:error, binary()}
          | {:zone, binary()}
          | {:refusal, binary()}
  defp time_and_zone(""), do: {:ok, {0, 0, false}, 0}

  defp time_and_zone(<<separator, rest::binary>>) when separator in [?T, ?t, ?\s] do
    with {:ok, seconds, leap, tail} <- clock(rest),
         {:ok, nanos, tail} <- fraction(tail),
         {:ok, offset} <- zone(tail) do
      {:ok, {seconds, nanos, leap}, offset}
    end
  end

  defp time_and_zone(_text), do: {:error, "invalid timestamp separator"}

  @spec clock(binary()) ::
          {:ok, non_neg_integer(), boolean(), binary()} | {:error, binary()}
  defp clock(<<h::binary-size(2), ?:, m::binary-size(2), ?:, s::binary-size(2), tail::binary>>) do
    if digits?(h <> m <> s), do: clock_value(h, m, s, tail), else: {:error, "error parsing time"}
  end

  defp clock(_text), do: {:error, "error parsing time"}

  defp clock_value(h, m, s, tail) do
    {hour, minute, second} = {String.to_integer(h), String.to_integer(m), String.to_integer(s)}

    if hour > 23 or minute > 59 or second > 60,
      do: {:error, "error parsing time"},
      else: {:ok, hour * 3600 + minute * 60 + second, second == 60, tail}
  end

  # Digits past the ninth are read and dropped.
  @spec fraction(binary()) :: {:ok, non_neg_integer(), binary()} | {:error, binary()}
  defp fraction(<<?., rest::binary>>) do
    {digits, tail} = take_digits(rest, [])

    case digits do
      [] ->
        {:error, "error parsing time"}

      _digits ->
        nanos = digits |> Enum.take(9) |> to_string() |> String.pad_trailing(9, "0")
        {:ok, String.to_integer(nanos), tail}
    end
  end

  defp fraction(tail), do: {:ok, 0, tail}

  @spec take_digits(binary(), [byte()]) :: {[byte()], binary()}
  defp take_digits(<<d, rest::binary>>, acc) when d in ?0..?9, do: take_digits(rest, [d | acc])
  defp take_digits(rest, acc), do: {Enum.reverse(acc), rest}

  @spec zone(binary()) :: {:ok, integer()} | {:zone, binary()} | {:refusal, binary()}
  defp zone(""), do: {:ok, 0}
  defp zone(zone) when zone in ["Z", "z"], do: {:ok, 0}

  defp zone(text) do
    zone = String.trim_leading(text)

    case fixed_offset(zone) do
      {:ok, offset} -> {:ok, offset}
      :error -> named_zone(zone)
    end
  end

  # `[+-]HH:MM`, `[+-]HHMM` and `[+-]HH`; a day or more is no offset.
  @spec fixed_offset(binary()) :: {:ok, integer()} | :error
  defp fixed_offset(<<sign, h::binary-size(2), ?:, m::binary-size(2)>>), do: offset(sign, h, m)
  defp fixed_offset(<<sign, h::binary-size(2), m::binary-size(2)>>), do: offset(sign, h, m)
  defp fixed_offset(<<sign, h::binary-size(2)>>), do: offset(sign, h, "00")
  defp fixed_offset(_zone), do: :error

  @spec offset(byte(), binary(), binary()) :: {:ok, integer()} | :error
  defp offset(sign, h, m) when sign in [?+, ?-] do
    seconds = if digits?(h <> m), do: String.to_integer(h) * 3600 + String.to_integer(m) * 60

    cond do
      seconds == nil or seconds >= 86_400 -> :error
      sign == ?+ -> {:ok, seconds}
      true -> {:ok, -seconds}
    end
  end

  defp offset(_sign, _h, _m), do: :error

  @spec named_zone(binary()) :: {:ok, integer()} | {:zone, binary()} | {:refusal, binary()}
  defp named_zone(zone) when zone in @utc_zones, do: {:ok, 0}

  defp named_zone(zone) do
    cond do
      Map.has_key?(@fixed_zones, zone) -> {:ok, Map.fetch!(@fixed_zones, zone)}
      match = Regex.run(~r/\AEtc\/GMT([+-])([0-9]+)\z/, zone) -> etc_zone(zone, match)
      String.contains?(zone, "/") or zone in @zone_names -> unmodelled_zone(zone)
      true -> {:zone, zone}
    end
  end

  # `Etc/GMT+N` is N hours *behind* UTC, `Etc/GMT-N` ahead; the database has
  # +1 to +12 and -1 to -14, written without a leading zero (verified).
  @spec etc_zone(binary(), [binary()]) :: {:ok, integer()} | {:zone, binary()}
  defp etc_zone(zone, [_full, sign, digits]) do
    hours = String.to_integer(digits)
    plain? = not String.starts_with?(digits, "0")

    cond do
      plain? and sign == "+" and hours in 1..12 -> {:ok, -hours * 3600}
      plain? and sign == "-" and hours in 1..14 -> {:ok, hours * 3600}
      true -> {:zone, zone}
    end
  end

  @spec unmodelled_zone(binary()) :: {:refusal, binary()}
  defp unmodelled_zone(zone),
    do: {:refusal, "the double holds no time zone database, so it cannot read the zone #{zone}"}

  @spec digits?(binary()) :: boolean()
  defp digits?(text), do: Regex.match?(~r/\A[0-9]+\z/, text)

  @spec instant(Date.t(), {integer(), non_neg_integer(), boolean()}, integer()) :: integer()
  defp instant(date, {seconds, nanos, _leap}, offset) do
    midnight = date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
    (midnight + seconds - offset) * 1_000_000_000 + nanos
  end

  # Arrow reads the seconds and the nanoseconds apart, and the seconds
  # before 1677-09-21T00:12:44 overflow the nanosecond count even when the
  # sum would fit.
  @spec in_range(integer(), boolean()) :: :ok | {:error, binary()}
  defp in_range(ns, leap) do
    if Integer.floor_div(ns, 1_000_000_000) >= @first_second and ns <= @int64_max,
      do: :ok,
      else:
        {:error,
         "Arrow error: Cast error: Overflow converting #{display(ns, leap)} to Nanosecond. The " <>
           "dates that can be represented as nanoseconds have to be between " <>
           "1677-09-21T00:12:44.0 and 2262-04-11T23:47:16.854775804"}
  end

  # chrono's rendering of a naive datetime; a leap second (`:60`) is the
  # second after `:59`, which chrono writes as `:60`.
  @spec display(integer(), boolean()) :: binary()
  defp display(ns, leap) do
    shown = if leap, do: ns - 1_000_000_000, else: ns
    nanos = Integer.mod(shown, 1_000_000_000)
    datetime = shown |> Integer.floor_div(1_000_000_000) |> DateTime.from_unix!()
    year = datetime.year
    second = if leap, do: datetime.second + 1, else: datetime.second

    sign = if year < 0, do: "-", else: ""
    date = "#{sign}#{pad(abs(year), 4)}-#{pad(datetime.month, 2)}-#{pad(datetime.day, 2)}"
    time = "#{pad(datetime.hour, 2)}:#{pad(datetime.minute, 2)}:#{pad(second, 2)}"
    date <> " " <> time <> fraction_text(nanos)
  end

  @spec fraction_text(non_neg_integer()) :: binary()
  defp fraction_text(0), do: ""

  defp fraction_text(nanos) when rem(nanos, 1_000_000) == 0,
    do: "." <> pad(div(nanos, 1_000_000), 3)

  defp fraction_text(nanos) when rem(nanos, 1000) == 0, do: "." <> pad(div(nanos, 1000), 6)
  defp fraction_text(nanos), do: "." <> pad(nanos, 9)

  @spec pad(non_neg_integer(), pos_integer()) :: binary()
  defp pad(number, width), do: number |> Integer.to_string() |> String.pad_leading(width, "0")
end
