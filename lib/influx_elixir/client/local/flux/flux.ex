defmodule InfluxElixir.Client.Local.Flux do
  @moduledoc false
  # The Flux subset `InfluxElixir.Client.Local` answers, with InfluxDB 2's
  # semantics (verified against `influxdb:2.7`; see
  # `docs/design/2026-09-24_local-flux-pipeline.md`).
  #
  # A query is a pipeline, `from(bucket: "b") |> range(...) |> ...`, and every
  # stage is applied — or the query is refused by name.
  #
  # Supported stages:
  #
  #   * `from(bucket: "b")` — first; the bucket must exist (404 otherwise)
  #   * `range(start: s[, stop: s])` — required, and the first stage after `from`
  #     (any other stage before it is the engine's "cannot submit unbounded
  #     read"); `s` is Unix seconds, an RFC3339 time, a duration from now (`-1h`,
  #     `-30m`, `-7d`, `-10s`, `-2w`) or `now()`; `stop` defaults to now. Every
  #     row carries `_start` and `_stop`. A range that is empty (`start` not
  #     before `stop`) is the engine's 400 "cannot query an empty range".
  #     Times are 64-bit nanoseconds as on the engine, so a time that does
  #     not fit wraps: `stop: 99999999999999` (seconds) is 1976-05-08 in
  #     `_stop`.
  #   * `filter(fn: (r) => ...)` — `r.key` or `r["key"]` compared with
  #     `== != < <= > >=` against a string (the escapes `\" \\ \n \r \t \$`),
  #     number (no exponent, as in Flux) or boolean, combined with
  #     `and`, `or`, `not` and parentheses. How a key the row lacks answers
  #     depends on storage pushdown, see below.
  #   * `first() last() min() max()` — the selected row per table
  #   * `mean() sum() count()` — one row per table, without `_time`
  #     (`mean` is a float; `count` counts rows); an integer or unsigned sum
  #     wraps in 64 bits as on the engine, and `mean` divides the wrapped sum
  #   * `limit(n: N[, offset: M])` — per table
  #   * `yield(name: "x")` — names a result; every `yield` returns its own
  #     result, tables numbered from 0 in each, and a last stage that is not a
  #     `yield` returns the rest as `_result`. The engine returns the results
  #     in no fixed order; the double returns them in pipeline order.
  #
  # Refused by name (the engine's answer is an error whose text holds a
  # position in the query, or depends on the plan, or is not verified):
  # a column compared with a literal of another type where Flux reads it, a
  # time column compared in Flux, ordering against a boolean, ordering `_value`
  # against a string, a `_value` comparison on an unsigned field, `min()` and
  # `max()` of a string or boolean field, `sum()` and `mean()` of one where
  # Flux reads it or storage may have dropped the series, a `yield` with no
  # name or one named by an expression, an argument a stage does not take.
  # An argument given twice is the engine's own 400, which names it.
  #
  # Pushdown (verified on 2.7, `docs/design/2026-10-10_local-flux-pushdown-and-yields.md`).
  # The `filter`s right after `range` are pushed to storage, one after another,
  # while each one is pushed whole. A filter is split at its top-level `and`s
  # and a conjunct is pushable when it is `key == lit` (not `== ""`), `key != lit`,
  # `_value` against a literal with any comparison, or an `and`/`or` of such
  # (`not`, a comparison of any other key, a negative number and `== ""` are
  # not). The pushable conjuncts run in storage: a key the series lacks, and
  # `_time`, `_start` and `_stop`, which are not there yet, are the empty string
  # for `!=` (`r.nosuch != "a"` keeps every row, `r.nosuch != ""` none) and equal
  # to nothing for `==`; a literal of another type than the key matches nothing;
  # a series every conjunct leaves out is not there for the stages after. The
  # others, and every filter after the first one that was not pushed whole or
  # after any other stage, run as Flux: a key the row lacks is null, only true
  # keeps a row, `and` and `or` let the left side decide (see `matches?/3`) and a
  # column compared with a literal of another type is an error.
  #
  # A selector or an aggregate right after pushed filters is read by storage
  # too, which keeps the series order and decides the errors on a string or
  # boolean field; one that Flux runs emits its tables sorted by group key.
  #
  # Tables are the series — measurement, tag set, field — numbered from `0`
  # in that order, rows in time order, as the engine numbers them. Time order
  # is the stored nanoseconds, finer than the microsecond a row's `_time`
  # carries, so `first()` and `last()` choose between points a microsecond
  # holds as the engine does.

  alias InfluxElixir.Client.Local.Durations
  alias InfluxElixir.Query.ResponseParser

  @typedoc """
  A filter predicate: comparisons of a row key with a literal (`{:cmp, key, op,
  literal}`), joined by `and`, `or` and `not`. `{:unary, cmp}`
  is a comparison against a negative number, which the engine reads as a
  unary expression (`-0` among them).
  """
  @type predicate ::
          {:cmp, binary(), binary(), term()}
          | {:and, predicate(), predicate()}
          | {:or, predicate(), predicate()}
          | {:not, predicate()}
          | {:unary, predicate()}

  @typedoc "One pipeline stage after `from`."
  @type stage ::
          {:range, integer(), integer()}
          | {:filter, predicate()}
          | {:selector, :first | :last | :min | :max}
          | {:aggregate, :mean | :sum | :count}
          | {:limit, non_neg_integer(), non_neg_integer()}
          | {:yield, binary()}

  @typedoc "A parsed query."
  @type query :: %{bucket: binary(), stages: [stage()]}

  @doc """
  Parses a Flux query. `now_ns` is the instant `now()` and a relative
  `range` resolve against. Returns `{:error, message}` for syntax the
  double does not model.
  """
  @spec parse(binary(), integer()) :: {:ok, query()} | {:error, binary()}
  def parse(flux, now_ns) do
    with {:ok, calls} <- split_pipeline(flux),
         {:ok, bucket, rest} <- parse_from(calls),
         {:ok, stages} <- parse_stages(rest, now_ns),
         :ok <- require_range(stages, bucket),
         :ok <- unique_yields(stages) do
      {:ok, %{bucket: bucket, stages: stages}}
    end
  end

  @doc "The `{start, stop}` nanoseconds of a query's `range` stage."
  @spec range(query()) :: {integer(), integer()}
  def range(%{stages: [{:range, start_ns, stop_ns} | _rest]}), do: {start_ns, stop_ns}

  @doc """
  The measurements a query reads: the ones the filters that storage
  evaluates pin with `r._measurement == "m"` (joined by `or`, narrowed by
  `and`), or `:all`. A series of any other one is not there for the stages
  after them; `Client.Local` reads just these from the store.
  """
  @spec measurements(query()) :: :all | [binary()]
  def measurements(%{stages: [_range | rest]}) do
    rest |> pushed_conjuncts() |> Enum.map(&pinned/1) |> Enum.reduce(:all, &intersect/2)
  end

  # The conjuncts storage evaluates: those of the filters right after `range`
  # that it can, up to the first filter it cannot take whole. Nothing else
  # may hide a series from the stages after it.
  @spec pushed_conjuncts([stage()]) :: [predicate()]
  defp pushed_conjuncts([{:filter, predicate} | rest]) do
    case predicate |> conjuncts() |> Enum.split_with(&pushable?/1) do
      {pushed, []} -> pushed ++ pushed_conjuncts(rest)
      {pushed, _remainder} -> pushed
    end
  end

  defp pushed_conjuncts(_stages), do: []

  @spec pinned(predicate()) :: :all | [binary()]
  defp pinned({:cmp, "_measurement", "==", literal}) when is_binary(literal), do: [literal]
  defp pinned({:and, a, b}), do: intersect(pinned(a), pinned(b))

  defp pinned({:or, a, b}) do
    case {pinned(a), pinned(b)} do
      {:all, _b} -> :all
      {_a, :all} -> :all
      {a, b} -> Enum.uniq(a ++ b)
    end
  end

  defp pinned(_predicate), do: :all

  @spec intersect(:all | [binary()], :all | [binary()]) :: :all | [binary()]
  defp intersect(:all, other), do: other
  defp intersect(other, :all), do: other
  defp intersect(a, b), do: Enum.filter(a, &(&1 in b))

  @doc """
  Runs a parsed query over the bucket's points (`%{measurement, tags,
  fields, timestamp}` maps, duplicates already merged). `opts[:uint]` is the
  set of `{measurement, field}` whose column is unsigned.
  """
  @spec run(query(), [map()], keyword()) :: {:ok, [map()]} | {:error, binary()}
  def run(%{stages: [{:range, start_ns, stop_ns} | rest]}, points, opts \\ []) do
    check_results(rest)
    bounds = {datetime(start_ns), datetime(stop_ns)}
    uints = Keyword.get(opts, :uint, MapSet.new())

    tables =
      points
      |> Enum.filter(&(&1.timestamp >= start_ns and &1.timestamp < stop_ns))
      |> Enum.flat_map(&timed_rows(&1, bounds))
      |> Enum.group_by(fn {key, _timed} -> key end, fn {_key, timed} -> timed end)
      |> Enum.sort_by(fn {key, _rows} -> key end)
      |> Enum.map(fn {{measurement, _tags, field}, timed} ->
        timed |> table_rows() |> table(MapSet.member?(uints, {measurement, field}))
      end)

    {:ok, rest |> results(tables) |> result_rows()}
  catch
    {:flux_error, message} -> {:error, message}
  end

  # ---------------------------------------------------------------------------
  # Execution
  # ---------------------------------------------------------------------------

  # A table: the series' rows, the kind of its `_value` (`:number`, `:uint`,
  # `:string` or `:bool`), its column names and one of its rows as it was
  # read. The kind and the columns stay when a filter takes every row out:
  # the engine still knows the table.
  @typep table :: %{
           kind: :number | :uint | :string | :bool,
           keys: MapSet.t(),
           sample: map(),
           rows: [map()]
         }

  # The columns of storage, which hold no `_time`, `_start` or `_stop` yet
  # while a filter is pushed down.
  @time_columns ["_start", "_stop", "_time"]

  @spec table([map()], boolean()) :: table()
  defp table([first | _rest] = rows, uint?) do
    %{
      kind: kind_of(first["_value"], uint?),
      keys: first |> Map.keys() |> MapSet.new(),
      sample: first,
      rows: rows
    }
  end

  @spec kind_of(term(), boolean()) :: :number | :uint | :string | :bool
  defp kind_of(value, _uint?) when is_boolean(value), do: :bool
  defp kind_of(value, _uint?) when is_binary(value), do: :string
  defp kind_of(_value, true), do: :uint
  defp kind_of(_value, false), do: :number

  # The engine builds a result for the plan before it reads anything, and a
  # plan with a last stage that is not a `yield` has a result named `_result`.
  @spec check_results([stage()]) :: :ok
  defp check_results(stages) do
    if not match?({:yield, _name}, List.last(stages)) and {:yield, "_result"} in stages do
      throw(
        {:flux_error,
         "failed to initialize execute state: tried to produce more than one result " <>
           "with the name \"_result\""}
      )
    end

    :ok
  end

  # The results in pipeline order: one per `yield`, then `_result` when the
  # last stage is not one. (The engine returns them in no fixed order.)
  @spec results([stage()], [table()]) :: [{binary(), [table()]}]
  defp results(stages, tables) do
    {tables, rest, direct?} = read_region(tables, stages)
    {tables, yields, _direct?} = Enum.reduce(rest, {tables, [], direct?}, &run_stage/2)

    if match?({:yield, _name}, List.last(stages)),
      do: Enum.reverse(yields),
      else: Enum.reverse([{"_result", tables} | yields])
  end

  # A tag named `table` or `result` is a column of its own after the engine's (verified,
  # 2.7), and a client reading the CSV by name keeps the later one: the tag.
  @spec result_rows([{binary(), [table()]}]) :: [map()]
  defp result_rows(results) do
    Enum.flat_map(results, fn {name, tables} ->
      tables
      |> Enum.reject(&(&1.rows == []))
      |> Enum.with_index()
      |> Enum.flat_map(fn {table, index} ->
        Enum.map(table.rows, &Map.merge(%{"table" => index, "result" => name}, &1))
      end)
    end)
  end

  @spec run_stage(stage(), {[table()], list(), boolean()}) :: {[table()], list(), boolean()}
  defp run_stage({:yield, name}, {tables, yields, _direct?}),
    do: {tables, [{name, tables} | yields], false}

  defp run_stage(stage, {tables, yields, direct?}),
    do: {apply_stage(stage, tables, direct?), yields, false}

  # The filters right after `range` are pushed to storage while each one is
  # pushed whole. Returns the tables, the stages left, and whether the tables
  # are the output of a read that was pushed whole (an aggregate that follows
  # is read by storage too).
  @spec read_region([table()], [stage()]) :: {[table()], [stage()], boolean()}
  defp read_region(tables, [{:filter, predicate} | rest]) do
    {pushed, remainder} = predicate |> conjuncts() |> Enum.split_with(&pushable?/1)
    tables = push_filter(tables, pushed)

    case remainder do
      [] -> read_region(tables, rest)
      _remainder -> {flux_filter(tables, remainder), rest, false}
    end
  end

  defp read_region(tables, rest), do: {tables, rest, true}

  @spec conjuncts(predicate()) :: [predicate()]
  defp conjuncts({:and, a, b}), do: conjuncts(a) ++ conjuncts(b)
  defp conjuncts(other), do: [other]

  # A conjunct storage can evaluate: `key == lit`, `key != lit`, `_value`
  # against a literal with any comparison, and `and`/`or` of such. A negative
  # number is a unary expression to the planner, `== ""` is left to Flux, and
  # so are `not` and a comparison of any other key.
  @spec pushable?(predicate()) :: boolean()
  defp pushable?({:unary, _comparison}), do: false
  defp pushable?({:cmp, _key, "==", ""}), do: false
  defp pushable?({:cmp, _key, op, _literal}) when op in ["==", "!="], do: true
  defp pushable?({:cmp, "_value", _op, _literal}), do: true
  defp pushable?({:cmp, _key, _op, _literal}), do: false
  defp pushable?({kind, a, b}) when kind in [:and, :or], do: pushable?(a) and pushable?(b)
  defp pushable?({:not, _predicate}), do: false

  @spec atoms(predicate()) :: [{binary(), binary(), term()}]
  defp atoms({:cmp, key, op, literal}), do: [{key, op, literal}]
  defp atoms({_wrapper, predicate}), do: atoms(predicate)
  defp atoms({_logic, a, b}), do: atoms(a) ++ atoms(b)

  @spec push_filter([table()], [predicate()]) :: [table()]
  defp push_filter(tables, []), do: tables

  defp push_filter(tables, pushed) do
    tables =
      Enum.filter(tables, fn table -> Enum.all?(pushed, &(series(&1, table.sample) != false)) end)

    # Only a series the filter can reach compares its values: `_field == "n" and
    # r._value > 0` next to an unsigned `u` is answered (verified, 2.7).
    check_unsigned(tables, Enum.flat_map(pushed, &atoms/1))
    keep_rows(tables, fn _table, row -> Enum.all?(pushed, &pushed?(&1, row)) end)
  end

  # What storage can tell of a series before it reads a value: true, false,
  # or `:unknown` when only `_value` decides. A series that is false is not
  # there at all, as far as the stages after the filter can see.
  @spec series(predicate(), map()) :: boolean() | :unknown
  defp series({:and, a, b}, sample) do
    case {series(a, sample), series(b, sample)} do
      {false, _b} -> false
      {_a, false} -> false
      {true, true} -> true
      _unknown -> :unknown
    end
  end

  defp series({:or, a, b}, sample) do
    case {series(a, sample), series(b, sample)} do
      {true, _b} -> true
      {_a, true} -> true
      {false, false} -> false
      _unknown -> :unknown
    end
  end

  defp series({:cmp, "_value", _op, _literal}, _sample), do: :unknown
  defp series(comparison, sample), do: pushed?(comparison, sample)

  @spec flux_filter([table()], [predicate()]) :: [table()]
  defp flux_filter(tables, conjuncts) do
    atoms = Enum.flat_map(conjuncts, &atoms/1)
    # A table with no row is not handed to a Flux stage at all (verified).
    reaching = Enum.reject(tables, &(&1.rows == []))
    check_unsigned(reaching, atoms)
    check_types(reaching, atoms)

    keep_rows(tables, fn table, row ->
      Enum.all?(conjuncts, &(matches?(&1, table, row) == true))
    end)
  end

  @spec keep_rows([table()], (table(), map() -> boolean())) :: [table()]
  defp keep_rows(tables, keep?) do
    Enum.map(tables, fn table -> %{table | rows: Enum.filter(table.rows, &keep?.(table, &1))} end)
  end

  # Storage's answer: two-valued. A key the series lacks, and `_time`,
  # `_start` and `_stop`, are the empty string for `!=` (`!= "a"` keeps the
  # row, `!= ""` drops it) and equal to nothing for `==`; a literal of another
  # type than the key matches nothing.
  @spec pushed?(predicate(), map()) :: boolean()
  defp pushed?({:and, a, b}, row), do: pushed?(a, row) and pushed?(b, row)
  defp pushed?({:or, a, b}, row), do: pushed?(a, row) or pushed?(b, row)
  defp pushed?({:cmp, "_value", op, literal}, row), do: same_type?(row["_value"], op, literal)

  defp pushed?({:cmp, key, op, literal}, row) when is_binary(literal) do
    case Map.fetch(row, key) do
      {:ok, value} when key not in @time_columns -> ordered(op, value, literal)
      _lacking -> op == "!=" and literal != ""
    end
  end

  defp pushed?({:cmp, _key, _op, _literal}, _row), do: false

  @spec same_type?(term(), binary(), term()) :: boolean()
  defp same_type?(value, op, literal) when is_number(value) and is_number(literal),
    do: ordered(op, value, literal)

  defp same_type?(value, op, literal) when is_binary(value) and is_binary(literal),
    do: ordered(op, value, literal)

  defp same_type?(value, op, literal) when is_boolean(value) and is_boolean(literal),
    do: ordered(op, value, literal)

  defp same_type?(_value, _op, _literal), do: false

  @spec apply_stage(stage(), [table()], boolean()) :: [table()]
  defp apply_stage({:filter, predicate}, tables, _direct?), do: flux_filter(tables, [predicate])

  defp apply_stage({:limit, n, offset}, tables, _direct?),
    do: map_rows(tables, &(&1 |> Enum.drop(offset) |> Enum.take(n)))

  defp apply_stage({:selector, kind}, tables, direct?) when kind in [:min, :max] do
    if Enum.any?(tables, &(&1.kind in [:string, :bool] and (direct? or &1.rows != []))) do
      refuse(
        "#{kind}() of a string or boolean field is an engine error whose form depends on " <>
          "the plan (a 500 \"panic: unsupported for aggregate #{kind}\" when storage reads " <>
          "it, a positioned 400 otherwise)"
      )
    end

    tables |> map_rows(&select(kind, &1)) |> in_group_key_order(direct?)
  end

  defp apply_stage({:selector, kind}, tables, direct?),
    do: tables |> map_rows(&select(kind, &1)) |> in_group_key_order(direct?)

  defp apply_stage({:aggregate, kind}, tables, direct?) do
    check_aggregate(kind, tables, direct?)
    tables |> Enum.map(&aggregate(kind, &1)) |> in_group_key_order(direct?)
  end

  # A selector or an aggregate that storage reads leaves the tables in series
  # order; one that Flux runs emits them sorted by group key: the columns in
  # label order (`_field`, `_measurement`, `_start`, `_stop`, then the tags),
  # a key that is a prefix of another before it (verified).
  @spec in_group_key_order([table()], boolean()) :: [table()]
  defp in_group_key_order(tables, true), do: tables

  defp in_group_key_order(tables, false),
    do: Enum.sort_by(tables, &(&1.sample |> Map.drop(["_value", "_time"]) |> Enum.sort()))

  @spec map_rows([table()], ([map()] -> [map()])) :: [table()]
  defp map_rows(tables, fun), do: Enum.map(tables, &%{&1 | rows: fun.(&1.rows)})

  @spec select(:first | :last | :min | :max, [map()]) :: [map()]
  defp select(_kind, []), do: []
  defp select(:first, [row | _rest]), do: [row]
  defp select(:last, rows), do: [List.last(rows)]

  # The first row with the extreme value wins a tie.
  defp select(kind, rows) do
    better? = if kind == :max, do: &Kernel.>/2, else: &Kernel.</2

    [
      Enum.reduce(rows, fn row, best ->
        if better?.(row["_value"], best["_value"]), do: row, else: best
      end)
    ]
  end

  # `sum` and `mean` of a string or boolean field. Storage, when it reads the
  # aggregate, refuses the table even when a filter took its rows out; Flux
  # refuses it with a position, and takes no notice of an empty table.
  @spec check_aggregate(:mean | :sum | :count, [table()], boolean()) :: :ok
  defp check_aggregate(:count, _tables, _direct?), do: :ok

  defp check_aggregate(kind, tables, direct?) do
    offenders = Enum.filter(tables, &(&1.kind in [:string, :bool]))
    kinds = offenders |> Enum.map(& &1.kind) |> Enum.uniq()
    rows? = Enum.any?(offenders, &(&1.rows != []))

    cond do
      offenders == [] ->
        :ok

      direct? and rows? ->
        throw(
          {:flux_error,
           "unsupported input type for #{kind} aggregate: #{type_name(first_error_kind(kinds))}"}
        )

      direct? or rows? ->
        refuse(
          "#{kind}() of a string or boolean field: the engine's error depends on the plan " <>
            "(and on which series storage has dropped)"
        )

      true ->
        :ok
    end
  end

  # Storage names the boolean when a string and a boolean field are both there,
  # whichever series it reads first (verified in three arrangements).
  @spec first_error_kind([:string | :bool]) :: :string | :bool
  defp first_error_kind(kinds), do: if(:bool in kinds, do: :bool, else: :string)

  @spec aggregate(:mean | :sum | :count, table()) :: table()
  defp aggregate(kind, %{rows: rows} = input) do
    table = %{
      input
      | keys: MapSet.delete(input.keys, "_time"),
        kind: aggregate_kind(kind, input.kind)
    }

    case rows do
      [] ->
        table

      [first | _rest] ->
        values = Enum.map(rows, & &1["_value"])

        value =
          case kind do
            :count -> length(values)
            :sum -> total(values, input.kind)
            :mean -> mean(total(values, input.kind), length(values))
          end

        %{table | rows: [first |> Map.delete("_time") |> Map.put("_value", value)]}
    end
  end

  # The sum of a table's values as the engine adds them: integers in 64 bits,
  # so a sum that does not fit wraps, and a mean divides the wrapped sum
  # (verified: two `9223372036854775807i` and a `5i` sum to 3, mean 1).
  @spec total([number()], :number | :uint) :: number() | binary()
  defp total(values, :uint), do: values |> Enum.sum() |> Bitwise.band(0xFFFFFFFFFFFFFFFF)

  defp total([value | _rest] = values, :number) when is_integer(value),
    do: wrap64(Enum.sum(values))

  defp total(values, :number), do: Enum.reduce(values, &add_float/2)

  # Floats are added in order, and a sum past the float range is an infinity for good: the
  # engine answers `+Inf` for two `1.7e308` and for those two and a `-1.7e308` after them,
  # and `-Inf` for two `-1.7e308` (verified, 2.7). A client reads `+Inf` from the CSV as
  # the text `"+Inf"`, which is what this answers; the stored values are finite, so the
  # sum is never NaN.
  @spec add_float(float(), float() | binary()) :: float() | binary()
  defp add_float(_value, infinity) when is_binary(infinity), do: infinity

  defp add_float(value, sum) do
    value + sum
  rescue
    ArithmeticError -> if value > 0, do: "+Inf", else: "-Inf"
  end

  # The engine's mean is the sum over the count, so a sum that overflowed is its mean too.
  @spec mean(number() | binary(), pos_integer()) :: number() | binary()
  defp mean(infinity, _count) when is_binary(infinity), do: infinity
  defp mean(sum, count), do: sum / count

  @spec aggregate_kind(:mean | :sum | :count, atom()) :: atom()
  defp aggregate_kind(:sum, kind), do: kind
  defp aggregate_kind(_count_or_mean, _kind), do: :number

  # Flux logic has a null: a key the table does not have is null, a
  # comparison with null is null, `not null` is null, and filter keeps a
  # row only when the predicate is true. `and` and `or` are not the three
  # valued ones (verified): the left side decides whether the right one is
  # read, and a left side that is not true counts as false. `a and b` is `b`
  # when `a` is true and false otherwise (so null and true is false, true
  # and null is null); `a or b` is true when `a` is true and `b` otherwise
  # (so null or false is false, false or null is null).
  @spec matches?(predicate(), table(), map()) :: boolean() | nil
  defp matches?({:and, a, b}, table, row) do
    if matches?(a, table, row) == true, do: matches?(b, table, row), else: false
  end

  defp matches?({:or, a, b}, table, row) do
    if matches?(a, table, row) == true, do: true, else: matches?(b, table, row)
  end

  defp matches?({:unary, comparison}, table, row), do: matches?(comparison, table, row)

  defp matches?({:not, a}, table, row) do
    case matches?(a, table, row) do
      nil -> nil
      value -> not value
    end
  end

  defp matches?({:cmp, key, op, literal}, table, row) do
    if MapSet.member?(table.keys, key), do: compare(op, Map.fetch!(row, key), literal)
  end

  @spec compare(binary(), term(), term()) :: boolean()
  defp compare(op, a, b) when is_number(a) and is_number(b), do: ordered(op, a, b)
  defp compare(op, a, b) when is_binary(a) and is_binary(b), do: ordered(op, a, b)
  defp compare("==", a, b), do: a === b
  defp compare("!=", a, b), do: a !== b
  defp compare(_op, _a, _b), do: false

  @spec ordered(binary(), term(), term()) :: boolean()
  defp ordered("==", a, b), do: a == b
  defp ordered("!=", a, b), do: a != b
  defp ordered("<", a, b), do: a < b
  defp ordered("<=", a, b), do: a <= b
  defp ordered(">", a, b), do: a > b
  defp ordered(">=", a, b), do: a >= b

  # A column compared with a literal of another type is an error on the
  # engine (with the position in the query), and so is a time column with
  # any literal: the double names it instead. A column the table lacks is
  # null, whatever the literal.
  @spec check_types([table()], [{binary(), binary(), term()}]) :: :ok
  defp check_types(tables, atoms) do
    for table <- tables, {key, op, literal} <- atoms, MapSet.member?(table.keys, key) do
      column = column_type(table, key)

      if key in @time_columns or column != literal_type(literal) do
        refuse(
          "comparing the #{column} column #{key} with a #{literal_type(literal)} (#{op}) is " <>
            "an error on the engine (unsupported binary expression)"
        )
      end
    end

    :ok
  end

  @spec column_type(table(), binary()) :: :number | :string | :bool | :time
  defp column_type(_table, key) when key in @time_columns, do: :time
  defp column_type(%{kind: :bool}, "_value"), do: :bool
  defp column_type(%{kind: :string}, "_value"), do: :string
  defp column_type(_table, "_value"), do: :number
  defp column_type(_table, _key), do: :string

  @spec literal_type(term()) :: :number | :string | :bool
  defp literal_type(literal) when is_number(literal), do: :number
  defp literal_type(literal) when is_binary(literal), do: :string
  defp literal_type(literal) when is_boolean(literal), do: :bool

  # An unsigned column answers `_value` comparisons by rules of its own
  # (none of an integer literal's `==` or ordering in storage), not verified.
  @spec check_unsigned([table()], [{binary(), binary(), term()}]) :: :ok
  defp check_unsigned(tables, atoms) do
    if Enum.any?(tables, &(&1.kind == :uint)) and
         Enum.any?(atoms, fn {key, _op, _literal} -> key == "_value" end) do
      refuse("a comparison of the _value of an unsigned field is not modelled")
    end

    :ok
  end

  @spec refuse(binary()) :: no_return()
  defp refuse(message), do: throw({:flux_error, "Client.Local: " <> message})

  # A table's rows in time order: by the stored nanoseconds, which a row's
  # microsecond `_time` cannot tell apart. The sort is stable, so points at
  # one instant keep their order.
  @spec table_rows([{integer(), map()}]) :: [map()]
  defp table_rows(timed) do
    timed |> Enum.sort_by(fn {ns, _row} -> ns end) |> Enum.map(fn {_ns, row} -> row end)
  end

  # The tag names a row's own columns would shadow; a series is told apart
  # by the tags that are left.
  @reserved_columns ["_measurement", "_field", "_value", "_time", "_start", "_stop"]

  # A point's rows, one per field, each with its series key — the engine's
  # series order: measurement, then the tag set, then field — and the
  # stored nanoseconds it is ordered by. The point's own parts are built
  # once, not once per field.
  @spec timed_rows(map(), {DateTime.t(), DateTime.t()}) ::
          [{{binary(), [{binary(), binary()}], binary()}, {integer(), map()}}]
  defp timed_rows(point, {start, stop}) do
    series = point.tags |> Map.drop(@reserved_columns) |> Enum.sort()

    base =
      Map.merge(point.tags, %{
        "_measurement" => point.measurement,
        "_start" => start,
        "_stop" => stop,
        "_time" => datetime(point.timestamp)
      })

    for {field, value} <- point.fields do
      row = base |> Map.put("_field", field) |> Map.put("_value", value)
      {{point.measurement, series, field}, {point.timestamp, row}}
    end
  end

  @spec type_name(:string | :bool) :: binary()
  defp type_name(:string), do: "string"
  defp type_name(:bool), do: "boolean"

  @spec datetime(integer()) :: DateTime.t()
  defp datetime(ns) do
    ns |> DateTime.from_unix!(:nanosecond) |> ResponseParser.microsecond_precision()
  end

  # ---------------------------------------------------------------------------
  # Parsing — the pipeline
  # ---------------------------------------------------------------------------

  # Splits `a(...) |> b(...)` at top-level pipes into `{name, args}` calls.
  @spec split_pipeline(binary()) :: {:ok, [{binary(), binary()}]} | {:error, binary()}
  defp split_pipeline(flux) do
    flux
    |> split_top_level("|>")
    |> Enum.reduce_while({:ok, []}, fn text, {:ok, acc} ->
      case Regex.run(~r/^\s*([A-Za-z_]\w*)\s*\((.*)\)\s*$/s, text) do
        [_full, name, args] ->
          {:cont, {:ok, [{name, args} | acc]}}

        nil ->
          {:halt, {:error, "Client.Local: unsupported Flux expression: #{String.trim(text)}"}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  @spec parse_from([{binary(), binary()}]) ::
          {:ok, binary(), [{binary(), binary()}]} | {:error, binary()}
  defp parse_from([{"from", args} | rest]) do
    # The bucket is a string literal as any other: `"a\\b"` names `a\b` (verified, 2.7).
    with [_full, quoted] <- Regex.run(~r/^\s*bucket\s*:\s*("(?:[^"\\]|\\.)*")\s*$/s, args),
         {:ok, bucket} <- string_literal(quoted) do
      {:ok, bucket, rest}
    else
      _unsupported -> {:error, "Client.Local: unsupported from(): #{args}"}
    end
  end

  defp parse_from(_calls),
    do: {:error, "Client.Local: a Flux query must start with from(bucket: ...)"}

  @spec parse_stages([{binary(), binary()}], integer()) :: {:ok, [stage()]} | {:error, binary()}
  defp parse_stages(calls, now_ns) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, acc} ->
      case parse_stage(call, now_ns) do
        {:ok, stage} -> {:cont, {:ok, [stage | acc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, stages} -> {:ok, Enum.reverse(stages)}
      error -> error
    end
  end

  @selectors %{"first" => :first, "last" => :last, "min" => :min, "max" => :max}
  @aggregates %{"mean" => :mean, "sum" => :sum, "count" => :count}

  @spec parse_stage({binary(), binary()}, integer()) :: {:ok, stage()} | {:error, binary()}
  defp parse_stage({"range", args}, now_ns) do
    with {:ok, params} <- named_args(args, "range", ["start", "stop"]),
         {:ok, {start, start_order}} <- fetch_time(params, "start", now_ns),
         {:ok, {stop, stop_order}} <- optional_time(params, "stop", now_ns),
         :ok <- non_empty(start_order, stop_order) do
      {:ok, {:range, start, stop}}
    end
  end

  defp parse_stage({"filter", args}, _now_ns) do
    case Regex.run(~r/^\s*fn\s*:\s*\(\s*r\s*\)\s*=>\s*(.+?)\s*$/s, args) do
      [_full, body] ->
        with {:ok, predicate} <- parse_predicate(body), do: {:ok, {:filter, predicate}}

      nil ->
        {:error, "Client.Local: unsupported filter(): #{args}"}
    end
  end

  defp parse_stage({"limit", args}, _now_ns) do
    with {:ok, params} <- named_args(args, "limit", ["n", "offset"]),
         {:ok, n} <- fetch_int(params, "n"),
         {:ok, offset} <- optional_int(params, "offset") do
      {:ok, {:limit, n, offset}}
    end
  end

  defp parse_stage({"yield", args}, _now_ns) do
    with {:ok, params} <- named_args(args, "yield", ["name"]) do
      case Map.fetch(params, "name") do
        {:ok, quoted} -> yield_name(quoted, args)
        :error -> {:ok, {:yield, "_result"}}
      end
    end
  end

  defp parse_stage({name, args}, _now_ns) do
    cond do
      String.trim(args) != "" and Map.has_key?(Map.merge(@selectors, @aggregates), name) ->
        {:error, "Client.Local: unsupported Flux arguments: #{name}(#{args})"}

      kind = @selectors[name] ->
        {:ok, {:selector, kind}}

      kind = @aggregates[name] ->
        {:ok, {:aggregate, kind}}

      true ->
        {:error, "Client.Local: unsupported Flux function: #{name}()"}
    end
  end

  @spec require_range([stage()], binary()) :: :ok | {:error, binary()}
  defp require_range(stages, bucket) do
    cond do
      not match?([{:range, _start, _stop} | _rest], stages) ->
        {:error,
         "error in building plan while starting program: cannot submit unbounded read to " <>
           "\"#{bucket}\"; try bounding 'from' with a call to 'range'"}

      Enum.count(stages, &match?({:range, _start, _stop}, &1)) > 1 ->
        {:error, "Client.Local: unsupported Flux: more than one range()"}

      true ->
        :ok
    end
  end

  # Two `yield`s of one name are a plan error on the engine.
  @spec unique_yields([stage()]) :: :ok | {:error, binary()}
  defp unique_yields(stages) do
    names = for {:yield, name} <- stages, do: name

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      [name | _rest] ->
        {:error,
         "error in building plan while starting program: found more than one call to " <>
           "yield() with the name \"#{name}\""}
    end
  end

  # A result's name is one string literal. The engine also takes an
  # expression (`"a" + "b"` names `ab`), which is not modelled.
  @spec yield_name(binary(), binary()) :: {:ok, stage()} | {:error, binary()}
  defp yield_name(quoted, args) do
    with true <- Regex.match?(~r/^"(?:[^"\\]|\\.)*"$/s, quoted),
         {:ok, name} when name != "" <- string_literal(quoted) do
      {:ok, {:yield, name}}
    else
      {:ok, ""} -> {:error, "Client.Local: unsupported yield(): a result with no name"}
      _other -> {:error, "Client.Local: unsupported yield(): #{args}"}
    end
  end

  # `key: value, key: value` at top level (values may hold commas in quotes
  # or parentheses). A key given twice is the engine's error, which names it
  # with no position; a key the function does not take is an error with one.
  @spec named_args(binary(), binary(), [binary()]) ::
          {:ok, %{binary() => binary()}} | {:error, binary()}
  defp named_args(args, function, allowed) do
    pairs =
      args
      |> split_top_level(",")
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(fn pair ->
        case String.split(pair, ":", parts: 2) do
          [key, value] -> {String.trim(key), String.trim(value)}
          [bare] -> {String.trim(bare), ""}
        end
      end)

    keys = Enum.map(pairs, &elem(&1, 0))

    cond do
      repeated = List.first(keys -- Enum.uniq(keys)) ->
        {:error, "duplicate keyword parameter specified: \"#{repeated}\""}

      unexpected = Enum.find(keys, &(&1 not in allowed)) ->
        {:error, "Client.Local: unsupported #{function}(): unexpected argument #{unexpected}"}

      true ->
        {:ok, Map.new(pairs)}
    end
  end

  # The plan is refused when the range has no time in it. The engine
  # compares seconds given as integers as Go times, which count seconds
  # since the year 1 in 64 bits, before they become nanoseconds: a wrapped
  # stop is not "empty" (`range(start: 0, stop: 18446744073)` reads
  # nothing without an error), only one that overflows that count is. Every
  # other form is compared as the nanoseconds it wraps to.
  @spec non_empty(integer(), integer()) :: :ok | {:error, binary()}
  defp non_empty(start, stop) when start < stop, do: :ok

  defp non_empty(_start, _stop),
    do: {:error, "error in building plan while starting program: cannot query an empty range"}

  @spec fetch_time(map(), binary(), integer()) ::
          {:ok, {integer(), integer()}} | {:error, binary()}
  defp fetch_time(params, key, now_ns) do
    case Map.fetch(params, key) do
      {:ok, text} -> parse_time(text, now_ns)
      :error -> {:error, "Client.Local: range() needs #{key}"}
    end
  end

  @spec optional_time(map(), binary(), integer()) ::
          {:ok, {integer(), integer()}} | {:error, binary()}
  defp optional_time(params, key, now_ns) do
    if Map.has_key?(params, key),
      do: fetch_time(params, key, now_ns),
      else: {:ok, {now_ns, now_ns}}
  end

  # Seconds from the year 1 to the epoch, the offset of Go's time count.
  @year_one 62_135_596_800

  # `{nanoseconds, ordering key}`: the time as the engine holds it (a
  # signed 64-bit count, so one that does not fit wraps) and the value an
  # empty range is judged on, see `non_empty/2`.
  @spec parse_time(binary(), integer()) ::
          {:ok, {integer(), integer()}} | {:error, binary()}
  defp parse_time("now()", now_ns), do: {:ok, {now_ns, now_ns}}

  defp parse_time(text, now_ns) do
    cond do
      match = Regex.run(~r/^(-?)(\d+)(s|m|h|d|w)$/, text) ->
        [_full, sign, amount, unit] = match
        offset = String.to_integer(amount) * Durations.ns(unit)
        wrapped = wrap64(now_ns + if(sign == "-", do: -offset, else: offset))
        {:ok, {wrapped, wrapped}}

      Regex.match?(~r/^-?\d+$/, text) ->
        seconds = String.to_integer(text)

        {:ok,
         {wrap64(seconds * 1_000_000_000),
          (wrap64(seconds + @year_one) - @year_one) * 1_000_000_000}}

      true ->
        rfc3339(text)
    end
  end

  # An RFC3339 time with its `T`, a `.` before any fraction and an offset of `Z` or
  # `+hh:mm`: the engine reads `2026-10-10 00:00:00Z` as a date and then a syntax error, and
  # refuses `+0200`, `+02` and `00:00:00,5Z` (verified, 2.7), all of which
  # `DateTime.from_iso8601/1` would take.
  @spec rfc3339(binary()) :: {:ok, {integer(), integer()}} | {:error, binary()}
  defp rfc3339(text) do
    with [_all | fraction] <-
           Regex.run(
             ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.(\d+))?(?:Z|[+-]\d{2}:\d{2})$/,
             text
           ),
         {:ok, dt, _offset} <- DateTime.from_iso8601(text) do
      wrapped = wrap64(DateTime.to_unix(dt, :second) * 1_000_000_000 + fraction_ns(fraction))
      {:ok, {wrapped, wrapped}}
    else
      _unsupported -> {:error, "Client.Local: unsupported range() time: #{text}"}
    end
  end

  @spec fraction_ns([binary()]) :: non_neg_integer()
  defp fraction_ns([]), do: 0

  defp fraction_ns([digits]),
    do: digits |> String.slice(0, 9) |> String.pad_trailing(9, "0") |> String.to_integer()

  # Two's-complement 64-bit wrap, which is what multiplying seconds by 1e9
  # does on the engine.
  @spec wrap64(integer()) :: integer()
  defp wrap64(value) do
    wrapped = Bitwise.band(value, 0xFFFFFFFFFFFFFFFF)
    if wrapped >= 0x8000000000000000, do: wrapped - 0x10000000000000000, else: wrapped
  end

  @spec fetch_int(map(), binary()) :: {:ok, non_neg_integer()} | {:error, binary()}
  defp fetch_int(params, key) do
    with {:ok, text} <- Map.fetch(params, key),
         {n, ""} when n >= 0 <- Integer.parse(text) do
      {:ok, n}
    else
      _missing -> {:error, "Client.Local: limit() needs a non-negative integer #{key}"}
    end
  end

  @spec optional_int(map(), binary()) :: {:ok, non_neg_integer()} | {:error, binary()}
  defp optional_int(params, key),
    do: if(Map.has_key?(params, key), do: fetch_int(params, key), else: {:ok, 0})

  # ---------------------------------------------------------------------------
  # Parsing — filter predicates: or > and > not > comparison | ( ... )
  # ---------------------------------------------------------------------------

  # A number has no exponent in Flux: `1e5` is `1` and the identifier `e5`,
  # an error on the engine.
  @token ~r/^(?<all>\s*(?:(?<str>"(?:[^"\\]|\\.)*")|(?<num>-?\d+(?:\.\d+)?)|(?<key>r\.[A-Za-z_]\w*|r\s*\[\s*"(?:[^"\\]|\\.)*"\s*\])|(?<op>==|!=|<=|>=|<|>)|(?<paren>[()])|(?<word>[A-Za-z_]\w*)))/

  @spec parse_predicate(binary()) :: {:ok, predicate()} | {:error, binary()}
  defp parse_predicate(text) do
    with {:ok, tokens} <- tokenize(text, []),
         {:ok, predicate, []} <- parse_or(tokens),
         :ok <- check_comparisons(predicate) do
      {:ok, predicate}
    else
      {:refused, message} ->
        {:error, "Client.Local: " <> message}

      _error ->
        {:error, "Client.Local: unsupported filter predicate: #{text}"}
    end
  end

  # Ordering a boolean is an error on the engine (`bool is not Comparable`),
  # and ordering `_value` against a string is answered by storage with no
  # row and by Flux with the strings' order: neither is modelled.
  @spec check_comparisons(predicate()) :: :ok | {:refused, binary()}
  defp check_comparisons({:cmp, key, op, literal}) when op not in ["==", "!="] do
    cond do
      is_boolean(literal) ->
        {:refused,
         "ordering against a boolean is an error on the engine (bool is not Comparable)"}

      key == "_value" and is_binary(literal) ->
        {:refused, "ordering _value against a string is not modelled"}

      true ->
        :ok
    end
  end

  defp check_comparisons({:cmp, _key, _op, _literal}), do: :ok
  defp check_comparisons({_wrapper, predicate}), do: check_comparisons(predicate)

  defp check_comparisons({_logic, a, b}) do
    with :ok <- check_comparisons(a), do: check_comparisons(b)
  end

  @spec tokenize(binary(), list()) :: {:ok, list()} | :error
  # One match per token; the blank check reads only up to the next token's first character.
  defp tokenize(text, acc) do
    with false <- Regex.match?(~r/^\s*$/, text),
         %{"all" => full} = captures <- Regex.named_captures(@token, text),
         {:ok, token} <- token(captures) do
      rest = binary_part(text, byte_size(full), byte_size(text) - byte_size(full))
      tokenize(rest, [token | acc])
    else
      true -> {:ok, Enum.reverse(acc)}
      _unknown -> :error
    end
  end

  @spec token(map()) :: {:ok, tuple()} | :error
  defp token(%{"str" => "\"" <> _rest = str}) do
    with {:ok, text} <- string_literal(str), do: {:ok, {:lit, text}}
  end

  defp token(%{"num" => "-" <> _digits = num}) do
    with {:ok, n} <- number(num), do: {:ok, {:negative, n}}
  end

  defp token(%{"num" => num}) when num != "" do
    with {:ok, n} <- number(num), do: {:ok, {:lit, n}}
  end

  defp token(%{"key" => key}) when key != "" do
    with {:ok, name} <- key_name(key), do: {:ok, {:key, name}}
  end

  defp token(%{"op" => op}) when op != "", do: {:ok, {:op, op}}
  defp token(%{"paren" => paren}) when paren != "", do: {:ok, {:paren, paren}}
  defp token(%{"word" => word}) when word in ["true", "false"], do: {:ok, {:lit, word == "true"}}
  defp token(%{"word" => "and"}), do: {:ok, {:and}}
  defp token(%{"word" => "or"}), do: {:ok, {:or}}
  defp token(%{"word" => "not"}), do: {:ok, {:not}}
  defp token(_other), do: :error

  @spec key_name(binary()) :: {:ok, binary()} | :error
  defp key_name("r." <> name), do: {:ok, name}

  defp key_name(bracket) do
    [quoted] = Regex.run(~r/"(?:[^"\\]|\\.)*"/, bracket)
    string_literal(quoted)
  end

  # The text of a Flux string literal, quotes included. `\"`, `\\`, `\n`,
  # `\r`, `\t` and `\$` are escapes; any other escape is an error on the
  # engine, and `${` an interpolation: neither is modelled.
  @spec string_literal(binary()) :: {:ok, binary()} | :error
  defp string_literal(quoted) do
    quoted |> binary_part(1, byte_size(quoted) - 2) |> unescape("")
  end

  @escapes %{?" => ?", ?\\ => ?\\, ?n => ?\n, ?r => ?\r, ?t => ?\t, ?$ => ?$}

  @spec unescape(binary(), binary()) :: {:ok, binary()} | :error
  defp unescape("", acc), do: {:ok, acc}

  defp unescape(<<?\\, c, rest::binary>>, acc) when is_map_key(@escapes, c),
    do: unescape(rest, <<acc::binary, Map.fetch!(@escapes, c)>>)

  defp unescape(<<?\\, _rest::binary>>, _acc), do: :error
  defp unescape(<<"${", _rest::binary>>, _acc), do: :error
  defp unescape(<<c, rest::binary>>, acc), do: unescape(rest, <<acc::binary, c>>)

  # A float literal past the float range is an infinity on the engine (2.7 answers
  # `r._value > 1<400 digits>.5` with no rows), which the BEAM has no float for: it is
  # refused as an unsupported predicate. It raised.
  @spec number(binary()) :: {:ok, number()} | :error
  defp number(text) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _float -> {:ok, String.to_float(text)}
    end
  rescue
    ArgumentError -> :error
  end

  @spec parse_or(list()) :: {:ok, predicate(), list()} | :error
  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens), do: or_tail(left, rest)
  end

  defp or_tail(left, [{:or} | rest]) do
    with {:ok, right, rest} <- parse_and(rest), do: or_tail({:or, left, right}, rest)
  end

  defp or_tail(left, rest), do: {:ok, left, rest}

  @spec parse_and(list()) :: {:ok, predicate(), list()} | :error
  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_not(tokens), do: and_tail(left, rest)
  end

  defp and_tail(left, [{:and} | rest]) do
    with {:ok, right, rest} <- parse_not(rest), do: and_tail({:and, left, right}, rest)
  end

  defp and_tail(left, rest), do: {:ok, left, rest}

  @spec parse_not(list()) :: {:ok, predicate(), list()} | :error
  defp parse_not([{:not} | rest]) do
    with {:ok, inner, rest} <- parse_not(rest), do: {:ok, {:not, inner}, rest}
  end

  defp parse_not([{:paren, "("} | rest]) do
    case parse_or(rest) do
      {:ok, inner, [{:paren, ")"} | rest]} -> {:ok, inner, rest}
      _error -> :error
    end
  end

  defp parse_not([{:key, key}, {:op, op}, {:lit, literal} | rest]),
    do: {:ok, {:cmp, key, op, literal}, rest}

  defp parse_not([{:key, key}, {:op, op}, {:negative, literal} | rest]),
    do: {:ok, {:unary, {:cmp, key, op, literal}}, rest}

  defp parse_not(_tokens), do: :error

  # ---------------------------------------------------------------------------
  # Splitting outside strings and parentheses
  # ---------------------------------------------------------------------------

  @spec split_top_level(binary(), binary()) :: [binary()]
  defp split_top_level(text, separator), do: do_split(text, separator, 0, false, "", [])

  defp do_split("", _sep, _depth, _quoted, current, acc), do: Enum.reverse([current | acc])

  defp do_split(<<"\\", c::utf8, rest::binary>>, sep, depth, true, current, acc),
    do: do_split(rest, sep, depth, true, current <> "\\" <> <<c::utf8>>, acc)

  defp do_split(<<"\"", rest::binary>>, sep, depth, quoted, current, acc),
    do: do_split(rest, sep, depth, not quoted, current <> "\"", acc)

  defp do_split(<<c::utf8, rest::binary>>, sep, depth, true, current, acc),
    do: do_split(rest, sep, depth, true, current <> <<c::utf8>>, acc)

  defp do_split(<<c, rest::binary>>, sep, depth, false, current, acc) when c in [?(, ?[],
    do: do_split(rest, sep, depth + 1, false, current <> <<c>>, acc)

  defp do_split(<<c, rest::binary>>, sep, depth, false, current, acc) when c in [?), ?]],
    do: do_split(rest, sep, depth - 1, false, current <> <<c>>, acc)

  defp do_split(text, sep, 0, false, current, acc) do
    if String.starts_with?(text, sep) do
      rest = binary_part(text, byte_size(sep), byte_size(text) - byte_size(sep))
      do_split(rest, sep, 0, false, "", [current | acc])
    else
      <<c::utf8, rest::binary>> = text
      do_split(rest, sep, 0, false, current <> <<c::utf8>>, acc)
    end
  end

  defp do_split(<<c::utf8, rest::binary>>, sep, depth, false, current, acc),
    do: do_split(rest, sep, depth, false, current <> <<c::utf8>>, acc)
end
