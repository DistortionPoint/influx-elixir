defmodule InfluxElixir.Client.Local.InfluxQLBuckets do
  @moduledoc false
  # `GROUP BY time(every[, offset])` and `fill()` over the rows of one series,
  # as the engine answers them (verified):
  #
  #   * buckets are `every` long and start at `offset` plus a multiple of `every`
  #     from the epoch (`time(7s)` starts at multiples of 7 seconds, `time(1m,
  #     30s)` at :30), and a row is stamped with the start of its bucket
  #   * the buckets run from the one the `WHERE` lower bound falls in (the
  #     series' first row's, without one) to the one its upper bound falls in
  #     (`now()` without one): `time < x` ends with the bucket of `x - 1ns`,
  #     `time <= x` with that of `x`
  #   * every bucket of that range is answered, whatever the data: a series
  #     with no value in the whole range is not answered at all
  #   * a bucket is *present* when any aggregate had values to work on in it
  #     (`count` is zero there, not null); every other bucket is empty
  #   * `fill(null)` (the default) leaves an empty bucket null, `count` zero;
  #     `fill(none)` drops it; `fill(previous)` repeats the last value of the
  #     column (a `count` too), `fill(linear)` interpolates between the values
  #     either side of it (an integer one truncated toward zero; with a `count`
  #     in the list the engine breaks the connection, the double refuses);
  #     `fill(n)` is the number cast to the column's type (an unsigned one
  #     wraps)
  #   * `fill` applies to a null column of a present bucket as it does to an
  #     empty one, except that a `count` there keeps its value
  #
  # The answer is a stream: only the buckets that hold rows are computed, an
  # empty one is the same row every time, so a `LIMIT` over a range of millions
  # of buckets reads only the buckets it keeps.

  alias InfluxElixir.Client.Local.{InfluxQLAggregate, SQLLimits}

  require SQLLimits

  @default_max_rows 2_000_000
  @max_scan 500_000

  @doc """
  The most rows a series may answer, which is what the double holds in memory (a
  row is about 300 bytes; the engine streams, and answers 1.2 million rows for a
  fortnight in seconds). Configurable with `config :influx_elixir,
  :local_influxql_max_rows, n`.
  """
  @spec max_rows() :: pos_integer()
  def max_rows,
    do: Application.get_env(:influx_elixir, :local_influxql_max_rows, @default_max_rows)

  @typedoc "How empty buckets are filled."
  @type fill :: :null | :none | :previous | :linear | {:number, integer() | float()}

  # A cell of the answer: `:null` is no value (the column is left out).
  @typep cell :: :null | {:v, term()}
  @typep row :: {boolean(), [cell()]}
  @typep specs :: [{binary(), InfluxQLAggregate.spec()}]
  @typep indexed :: Enumerable.t({non_neg_integer(), row()})

  @doc """
  The rows of a series as buckets: `{start_ns, %{name => value}}` in time
  order. `compute` gives the named results of the aggregates over the rows of
  a bucket. Options: `:lower` and `:upper` (inclusive bounds in nanoseconds
  or `nil`), `:now` and `:descending` (the buckets come latest first; a
  fill that looks back or ahead reads them all). Throws `{:refused, message}` for what the double does
  not read as the engine.
  """
  @spec series(
          [map()],
          {integer(), integer()},
          fill(),
          keyword(),
          ([map()] -> [{binary(), InfluxQLAggregate.result(), InfluxQLAggregate.spec()}])
        ) :: Enumerable.t({integer(), %{binary() => term()}})
  def series([], _group, _fill, _opts, _compute), do: []

  def series(rows, {every, offset}, fill, opts, compute) do
    check_resolution(every, offset)
    timed = Enum.map(rows, &{time_ns(&1), &1})
    lower = Keyword.get(opts, :lower) || timed |> hd() |> elem(0)
    upper = Keyword.get(opts, :upper) || Keyword.fetch!(opts, :now)
    first = bucket_start(lower, every, offset)
    last = bucket_start(upper, every, offset)

    if first > last,
      do: [],
      else:
        filled(
          timed,
          {every, offset},
          {first, last},
          fill,
          {compute, Keyword.get(opts, :descending, false), Keyword.get(opts, :window)}
        )
  end

  # The rows carry whole microseconds: a bucket of a length or an offset that
  # is not, or a length that is not positive, is not answered once there are
  # points to put in it.
  @spec check_resolution(integer(), integer()) :: :ok
  defp check_resolution(every, offset)
       when every > 0 and rem(every, 1000) == 0 and rem(offset, 1000) == 0,
       do: :ok

  defp check_resolution(_every, _offset),
    do: refuse("GROUP BY time() of zero, negative or under a microsecond")

  @spec filled(
          [{integer(), map()}],
          {integer(), integer()},
          {integer(), integer()},
          fill(),
          {function(), boolean(), non_neg_integer() | nil}
        ) :: Enumerable.t({integer(), map()})
  defp filled(timed, {every, offset}, {first, last}, fill, {compute, descending?, window}) do
    count = div(last - first, every) + 1
    check_rows(fill, count, window)

    groups =
      Enum.group_by(
        timed,
        fn {ns, _row} -> div(bucket_start(ns, every, offset) - first, every) end,
        &elem(&1, 1)
      )

    if Enum.any?(Map.keys(groups), &(&1 < 0 or &1 >= count)),
      do: refuse("a point beyond the end of the GROUP BY time range")

    results = Map.new(groups, fn {index, bucket_rows} -> {index, compute.(bucket_rows)} end)
    empty_results = compute.([])
    specs = Enum.map(empty_results, fn {name, _result, spec} -> {name, spec} end)
    present = Map.new(results, fn {index, named} -> {index, row(named)} end)

    if Enum.any?(present, fn {_index, {present?, _cells}} -> present? end) do
      empty = row(empty_results)
      lazy_back? = fill in [:null, :none] or match?({:number, _number}, fill)
      indexes = bucket_indexes(fill, present, count, descending? and lazy_back?)

      buckets =
        indexes
        |> Stream.map(&{&1, Map.get(present, &1, empty)})
        |> fill_rows(specs, fill)
        |> Stream.map(fn {index, {_present?, cells}} ->
          {first + index * every, values(cells, specs)}
        end)

      if descending? and not lazy_back?,
        do: buckets |> read_all(count) |> Enum.reverse(),
        else: buckets
    else
      []
    end
  end

  # The buckets to walk. `fill(none)` drops the empty ones, so it walks only the
  # present ones: a range of billions of buckets is no more work than its points.
  @spec bucket_indexes(fill(), %{integer() => row()}, pos_integer(), boolean()) ::
          Enumerable.t(integer())
  defp bucket_indexes(:none, present, _count, descending?) do
    kept = for {index, {true, _cells}} <- present, do: index
    Enum.sort(kept, if(descending?, do: :desc, else: :asc))
  end

  defp bucket_indexes(_fill, _present, count, true), do: (count - 1)..0//-1
  defp bucket_indexes(_fill, _present, count, false), do: 0..(count - 1)//1

  # Every bucket but the dropped ones is a row: more than the double holds is
  # refused before any is made, unless a `LIMIT` stops short of that.
  @spec check_rows(fill(), pos_integer(), non_neg_integer() | nil) :: :ok
  defp check_rows(fill, count, nil) when fill != :none do
    if count > max_rows(),
      do: refuse("more than #{max_rows()} rows in a series"),
      else: :ok
  end

  defp check_rows(_fill, _count, _window), do: :ok

  # Every bucket, for a fill that cannot give the latest first without them.
  @spec read_all(Enumerable.t(), pos_integer()) :: list()
  defp read_all(buckets, count) do
    if count > max_rows(),
      do: refuse("a fill that reads more than #{max_rows()} buckets"),
      else: Enum.to_list(buckets)
  end

  # The cells of a bucket, and whether it is present.
  @spec row([{binary(), InfluxQLAggregate.result(), InfluxQLAggregate.spec()}]) :: row()
  defp row(results) do
    present? = Enum.any?(results, fn {_name, result, _spec} -> result != :none end)

    cells =
      for {_name, result, {kind, _type}} <- results do
        case {result, kind, present?} do
          {{:value, value, _point}, _kind, _present} -> {:v, value}
          {:none, :count, true} -> {:v, 0}
          {_none_or_null, _kind, _present} -> :null
        end
      end

    {present?, cells}
  end

  @spec values([cell()], specs()) :: %{binary() => term()}
  defp values(cells, specs) do
    for {{name, _spec}, {:v, value}} <- Enum.zip(specs, cells), into: %{}, do: {name, value}
  end

  # What an empty bucket becomes: every cell null, a `count` too, and then
  # whatever `fill` says.
  @spec fill_rows(indexed(), specs(), fill()) :: indexed()
  defp fill_rows(rows, specs, fill) do
    rows = Stream.map(rows, fn {index, row} -> {index, blank_empty(row)} end)

    case fill do
      :null ->
        Stream.map(rows, fn {index, row} -> {index, null_counts(row, specs)} end)

      :none ->
        Stream.filter(rows, fn {_index, {present?, _cells}} -> present? end)

      :previous ->
        carry_previous(rows, specs)

      :linear ->
        linear(rows, specs)

      {:number, number} ->
        Stream.map(rows, fn {index, row} -> {index, number_cells(row, specs, number)} end)
    end
  end

  @spec blank_empty(row()) :: row()
  defp blank_empty({true, _cells} = row), do: row
  defp blank_empty({false, cells}), do: {false, Enum.map(cells, fn _cell -> :null end)}

  @spec null_counts(row(), specs()) :: row()
  defp null_counts({true, _cells} = row, _specs), do: row

  defp null_counts({false, cells}, specs) do
    {false,
     Enum.zip_with(cells, specs, fn
       :null, {_name, {:count, _type}} -> {:v, 0}
       cell, _spec -> cell
     end)}
  end

  @spec number_cells(row(), specs(), integer() | float()) :: row()
  defp number_cells({present?, cells}, specs, number) do
    {present?,
     Enum.zip_with(cells, specs, fn
       :null, {_name, {_kind, type}} -> {:v, cast(number, type)}
       cell, _spec -> cell
     end)}
  end

  # A number given to `fill()` as the column's type reads it.
  @spec cast(integer() | float(), InfluxQLAggregate.column_type()) :: term()
  defp cast(number, :float), do: number * 1.0
  defp cast(number, :time), do: number |> trunc() |> epoch_time()
  defp cast(number, :integer) when is_integer(number), do: number
  defp cast(number, :integer), do: trunc(number)
  defp cast(number, :unsigned) when is_integer(number), do: SQLLimits.wrap_uint64(number)
  defp cast(number, :unsigned) when number >= 0, do: trunc(number)
  defp cast(_number, type), do: refuse("fill() with a number on a #{type} column")

  # A number given to `fill()` is nanoseconds from the epoch in a column of times (verified:
  # `fill(0)` is 1970-01-01T00:00:00). `Client.HTTP` reads the engine's time to the
  # microsecond (its floor), so the double answers the same.
  @spec epoch_time(integer()) :: DateTime.t()
  defp epoch_time(ns) do
    if SQLLimits.is_int64(ns),
      do: DateTime.from_unix!(Integer.floor_div(ns, 1000), :microsecond),
      else: refuse("fill() with a number outside the times the double holds")
  rescue
    ArgumentError -> refuse("fill() with a number outside the times the double holds")
  end

  # Each column takes the last value it had.
  # With a `count()` among the columns the engine breaks the connection when the
  # first bucket is empty (verified), as it does for a linear fill of one; the
  # double refuses.
  @spec carry_previous(indexed(), specs()) :: indexed()
  defp carry_previous(rows, specs) do
    counts? = Enum.any?(specs, &match?({_name, {:count, _type}}, &1))

    Stream.transform(rows, nil, fn {index, {present?, cells}}, last ->
      if last == nil and not present? and counts?,
        do: refuse("fill(previous) with count() when the first bucket is empty")

      last = last || Enum.map(cells, fn _cell -> :null end)

      filled =
        cells
        |> Enum.zip(last)
        |> Enum.map(fn
          {:null, previous} -> previous
          {cell, _previous} -> cell
        end)

      {[{index, {present?, filled}}], filled}
    end)
  end

  # The engine breaks the connection of a `count` filled linearly when a bucket
  # is empty, and of a text or boolean column whatever the buckets: refused.
  @spec linear(indexed(), specs()) :: indexed()
  defp linear(rows, specs) do
    if Enum.any?(specs, fn {_name, {_kind, type}} -> type in [:string, :boolean, :time] end),
      do: refuse("fill(linear) on a string, boolean or time column"),
      else: linear_rows(rows, specs)
  end

  @spec linear_rows(indexed(), specs()) :: indexed()
  defp linear_rows(rows, specs) do
    types = Enum.map(specs, fn {_name, {_kind, type}} -> type end)
    rows = rows |> Enum.take(@max_scan + 1) |> bounded_scan()

    if Enum.any?(specs, &match?({_name, {:count, _type}}, &1)) and
         Enum.any?(rows, fn {_index, {present?, _cells}} -> not present? end),
       do: refuse("fill(linear) with count() over an empty bucket")

    indexes = Enum.map(rows, &elem(&1, 0))
    present = Enum.map(rows, fn {_index, {present?, _cells}} -> present? end)

    rows
    |> Enum.map(fn {_index, {_present?, cells}} -> cells end)
    |> transpose()
    |> Enum.zip_with(types, &interpolate/2)
    |> transpose()
    |> Enum.zip_with(Enum.zip(indexes, present), fn cells, {index, present?} ->
      {index, {present?, cells}}
    end)
  end

  # A null cell between two values is on the line through them, by the
  # position of its bucket: `y0 + (y1 - y0) * ((i - p) / (q - p))`, an
  # integer one truncated toward zero.
  @spec interpolate([cell()], InfluxQLAggregate.column_type()) :: [cell()]
  defp interpolate(cells, type) do
    indexed = Enum.with_index(cells)
    before = scan_known(indexed)
    after_ = indexed |> Enum.reverse() |> scan_known() |> Enum.reverse()

    [indexed, before, after_]
    |> Enum.zip()
    |> Enum.map(fn
      {{:null, index}, {:ok, p, y0}, {:ok, q, y1}} ->
        {:v, line(y0, y1, (index - p) / (q - p), type)}

      {{cell, _index}, _before, _after} ->
        cell
    end)
  end

  # For every cell, the nearest cell with a value at or before it in the
  # order given.
  @spec scan_known([{cell(), integer()}]) :: [{:ok, integer(), term()} | :none]
  defp scan_known(indexed) do
    indexed
    |> Enum.map_reduce(:none, fn
      {{:v, value}, index}, _last -> {{:ok, index, value}, {:ok, index, value}}
      {:null, _index}, last -> {last, last}
    end)
    |> elem(0)
  end

  @spec line(number() | nil, number() | nil, float(), InfluxQLAggregate.column_type()) :: term()
  defp line(y0, y1, ratio, :float) when is_number(y0) and is_number(y1),
    do: y0 + (y1 - y0) * ratio

  defp line(y0, y1, ratio, type)
       when type in [:integer, :unsigned] and is_number(y0) and is_number(y1),
       do: trunc(y0 + (y1 - y0) * ratio)

  defp line(_y0, _y1, _ratio, type), do: refuse("fill(linear) on a #{type} column")

  @spec bounded_scan(list()) :: list()
  defp bounded_scan(rows) when length(rows) > @max_scan,
    do: refuse("fill(linear) over more than 500000 buckets")

  defp bounded_scan(rows), do: rows

  @spec transpose([[term()]]) :: [[term()]]
  defp transpose([]), do: []
  defp transpose(rows), do: rows |> Enum.zip() |> Enum.map(&Tuple.to_list/1)

  @spec time_ns(map()) :: integer()
  defp time_ns(%{"time" => time}), do: DateTime.to_unix(time, :microsecond) * 1000

  @doc false
  @spec bucket_start(integer(), pos_integer(), integer()) :: integer()
  def bucket_start(ns, every, offset), do: Integer.floor_div(ns - offset, every) * every + offset

  @spec refuse(binary()) :: no_return()
  defp refuse(what), do: throw({:refused, "unsupported InfluxQL (#{what})"})
end
