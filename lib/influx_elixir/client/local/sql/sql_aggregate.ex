defmodule InfluxElixir.Client.Local.SQLAggregate do
  @moduledoc false
  # The aggregates of a SQL select list for `InfluxElixir.Client.Local`, over
  # the points of one group, as InfluxDB 3 computes them (verified against
  # Core).
  #
  # A null result (an aggregate over no values, a sample statistic of one
  # value, a missing grouping value) is left out of the row, as the real
  # engine does; `COUNT` is 0, never null. A result that is an infinity or a
  # NaN is a `null` that is there (see `InfluxElixir.Client.Local.SQLNumber`).
  #
  #   * `SUM` of an `Int64` or a `UInt64` wraps; `MEDIAN` of two of them wraps
  #     their sum before halving (the median of `[9223372036854775807,
  #     9223372036854775807]` is -1)
  #   * `AVG` and the statistics are `Float64`; over a decimal `AVG` is refused
  #     by name (the engine gives it four more places)
  #   * the sample statistics need at least two values; the population forms
  #     are defined for one

  alias InfluxElixir.Client.Local.{
    SQLAggExpr,
    SQLCondition,
    SQLError,
    SQLEval,
    SQLExpr,
    SQLNumber,
    SQLParser,
    SQLRow,
    SQLSelect,
    SQLSort,
    SQLWhere
  }

  @typedoc "A group's points."
  @type points :: [SQLRow.point()]

  # The aggregates of a spread: over one accumulator (the engine merges one for each of its
  # partitions, which the double cannot know: merged series of equal values would not have a
  # variance of exactly zero, as the engine has it).
  @spread [:var, :stddev, :var_pop, :stddev_pop]

  # The order an ascending sort (and `first_value`/`last_value`) puts nulls in.
  @ascending {:asc, :nulls_last}

  @distinct_literal "a DISTINCT aggregate of a literal beside another aggregate over no row: " <>
                      "the engine's answer for it is not modelled"

  @doc """
  One output row of an aggregate or grouped select list: each column over the
  group's `points`; `bucket_ts` is the group's `DATE_BIN` bucket start.
  """
  @spec reduce_columns([SQLSelect.column()], points(), integer() | nil | :scalar) :: map()
  def reduce_columns(columns, points, bucket_ts) do
    if points == [] and distinct_literal_quirk?(columns) do
      throw({:query_error, SQLError.refusal(@distinct_literal)})
    end

    Enum.reduce(columns, %{}, fn column, row ->
      put(row, elem(column, tuple_size(column) - 1), column_result(column, points, bucket_ts))
    end)
  end

  # Over no row the engine answers `count(DISTINCT 'a')` and `sum(DISTINCT 1)` of a literal as
  # 1 beside a `min`, `max` or `sum` (verified: `SELECT max(i), count(distinct 'x y') FROM t
  # WHERE i > 100` is 1; beside `count`, `avg`, `median` or alone it is 0), a rewrite of the
  # engine's that the double does not model. An aggregate not verified either way is refused too.
  @spec distinct_literal_quirk?([SQLSelect.column()]) :: boolean()
  defp distinct_literal_quirk?(columns) do
    aggregates =
      Enum.flat_map(columns, fn
        {:expression, _expr, aggs, _alias} -> Enum.map(aggs, &elem(&1, 1))
        column -> [column]
      end)

    {literals, others} = Enum.split_with(aggregates, &distinct_literal?/1)

    literals != [] and Enum.any?(others, &(aggregate?(&1) and not safe_beside_literal?(&1)))
  end

  @spec distinct_literal?(SQLSelect.column()) :: boolean()
  defp distinct_literal?({:aggregate, agg, {kind, value}, _alias})
       when agg in [:count_distinct, :sum_distinct] and kind in [:lit, :uint],
       do: not is_nil(value)

  defp distinct_literal?(_column), do: false

  @spec aggregate?(SQLSelect.column()) :: boolean()
  defp aggregate?(column), do: elem(column, 0) not in [:grouping_column, :constant, :time_bucket]

  @spec safe_beside_literal?(SQLSelect.column()) :: boolean()
  defp safe_beside_literal?({:count_star, _alias}), do: true
  defp safe_beside_literal?({:count_distinct, _column, _alias}), do: true

  defp safe_beside_literal?({:aggregate, agg, _expr, _alias}),
    do: agg in [:count, :count_distinct, :avg, :median]

  defp safe_beside_literal?(_column), do: false

  @typedoc "A `HAVING` with whether it reads the names of the select list (see `prepare/2`)."
  @type prepared :: nil | {SQLAggExpr.having_t(), boolean()}

  @doc """
  The `HAVING` of a query read once for all its groups: whether it names an item of the select
  list decides whether the condition needs the group's row.
  """
  @spec prepare(SQLAggExpr.having_t() | nil, [SQLSelect.column()]) :: prepared()
  def prepare(nil, _columns), do: nil
  def prepare(having, columns), do: {having, names_outputs?(having, columns)}

  @doc """
  The output rows of one group: its row, unless a `HAVING` (as `prepare/2` read it, `nil` for
  none) leaves it out. The condition reads the group's first row, the aggregates it names and
  the names of the select list.
  """
  @spec reduce_group([SQLSelect.column()], prepared(), points(), integer() | nil | :scalar) ::
          [map()]
  def reduce_group(columns, prepared, points, bucket_ts) do
    case prepared do
      nil ->
        [reduce_columns(columns, points, bucket_ts)]

      # The select list is computed for the groups the `HAVING` keeps (verified: the
      # negation of an unsigned sum, which fails, is never met when the `HAVING` is false).
      {having, false} ->
        if having_holds?(having, points, bucket_ts, %{}),
          do: [reduce_columns(columns, points, bucket_ts)],
          else: []

      {having, true} ->
        row = reduce_columns(columns, points, bucket_ts)
        if having_holds?(having, points, bucket_ts, row), do: [row], else: []
    end
  end

  # Whether a `HAVING` reads the name of a select item (and so needs the row).
  @spec names_outputs?(SQLAggExpr.having_t(), [SQLSelect.column()]) :: boolean()
  defp names_outputs?(%{nodes: nodes}, columns) do
    outputs = Enum.map(columns, &elem(&1, tuple_size(&1) - 1))
    Enum.any?(SQLWhere.conjunction_columns(nodes), &(&1 in outputs))
  end

  @spec having_holds?(SQLAggExpr.having_t(), points(), integer() | nil | :scalar, map()) ::
          boolean()
  defp having_holds?(%{nodes: nodes, aggs: aggs}, points, bucket_ts, row) do
    SQLCondition.matches_all?(group_row(points, aggs, bucket_ts, row), nodes)
  end

  # The row an expression of a group is evaluated over: the group's first
  # row, the select list's outputs and the values of the aggregates the
  # expression names.
  @spec group_row(points(), [{binary(), SQLSelect.column()}], integer() | nil | :scalar, map()) ::
          SQLRow.point()
  defp group_row(points, aggs, bucket_ts, outputs \\ %{}) do
    base = List.first(points) || %{measurement: "", tags: %{}, fields: %{}, timestamp: nil}

    values =
      Map.new(aggs, fn {name, column} -> {name, column_result(column, points, bucket_ts)} end)

    # A name the table has is its column, not the item of that name.
    items = Map.drop(outputs, Map.keys(base.tags) ++ Map.keys(base.fields))
    %{base | fields: base.fields |> Map.merge(items) |> Map.merge(values)}
  end

  # A null result is no key.
  @spec put(map(), binary(), term()) :: map()
  defp put(row, _key, nil), do: row
  defp put(row, key, value), do: Map.put(row, key, value)

  @spec column_result(SQLSelect.column(), points(), integer() | nil | :scalar) :: term()
  defp column_result({:time_bucket, _alias}, _points, bucket_ts),
    do: SQLRow.nanoseconds_to_datetime(bucket_ts)

  # All points in a column-grouped bucket share the same value for this
  # column; sample from the first point.
  defp column_result({:grouping_column, source, _alias}, points, _bucket_ts) do
    case points do
      [first | _rest] -> SQLRow.column_value(first, source)
      [] -> nil
    end
  end

  defp column_result({:aggregate, agg, expr, _alias}, points, bucket_ts)
       when agg in @spread do
    spread(values(expr, points), agg, bucket_ts === :scalar)
  end

  defp column_result({:aggregate, agg, expr, _alias}, points, _bucket_ts),
    do: compute(agg, values(expr, points))

  defp column_result({:expression, expr, aggs, _alias}, points, bucket_ts),
    do: SQLEval.eval(expr, group_row(points, aggs, bucket_ts))

  # COUNT(*) — every matching row counts, regardless of field nullity.
  defp column_result({:count_star, _alias}, points, _bucket_ts), do: length(points)
  defp column_result({:constant, value, _alias}, _points, _bucket_ts), do: value

  defp column_result({:count_distinct, column, _alias}, points, _bucket_ts) do
    points
    |> Enum.map(&SQLRow.column_value(&1, column))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  end

  defp column_result({:ordered_aggregate, agg, field, ordering, _alias}, points, _bucket_ts),
    do: ordered(agg, field, ordering, points)

  defp column_result({:selector, kind, field, ordering, access, _alias}, points, _bucket_ts),
    do: selector(kind, field, ordering, access, points)

  # The non-null values of an aggregate's argument, in the order the group's points are stored.
  # That is not the order the engine adds them in, and no order is: the engine's float sum is
  # not deterministic (twelve runs of the same `SELECT sum(f)` on Core gave four different last
  # digits, the partitions of a scan being merged in the order they finish), so the last digits
  # of the sum, the mean and the variance of floats are not reproducible, even from one run of
  # the engine to the next.
  @spec values(SQLExpr.t(), points()) :: [term()]
  defp values(expr, points) do
    points |> Enum.map(&SQLEval.eval(expr, &1)) |> Enum.reject(&is_nil/1)
  end

  # An aggregate over the non-null values of one group.
  @spec compute(SQLParser.aggregate(), [term()]) :: term()
  defp compute(:count, values), do: length(values)
  defp compute(:count_distinct, values), do: values |> Enum.uniq() |> length()
  defp compute(_agg, []), do: nil
  defp compute(:sum_distinct, values), do: compute(:sum, Enum.uniq(values))
  defp compute(:avg, values), do: average(values)

  defp compute(:sum, [first | _rest] = values),
    do: Enum.reduce(values, zero(first), &add(&2, &1))

  # MIN/MAX also run over `time`, so the comparison is the sort's.
  defp compute(:min, values), do: Enum.min(values, &SQLSort.value_order/2)

  defp compute(:max, values),
    do: Enum.max(values, fn a, b -> SQLSort.value_order(b, a) end)

  defp compute(:median, values), do: median(values)

  # The sum starts from the type's zero, so the sum of `-0.0` is `0.0`
  # (verified).
  @spec zero(SQLNumber.t()) :: SQLNumber.t()
  defp zero(value) when is_integer(value), do: 0
  defp zero({:int, _bits, _value}), do: 0
  defp zero({:u, _value}), do: {:u, 0}
  defp zero({:dec, _coefficient, scale}), do: {:dec, 0, scale}
  defp zero(_float), do: 0.0

  @spec divide(SQLNumber.t(), SQLNumber.t()) :: SQLNumber.t()
  defp divide(value, divisor), do: SQLNumber.arithmetic(:/, value, divisor)

  @spec add(SQLNumber.t(), SQLNumber.t()) :: SQLNumber.t()
  defp add(left, right) when is_float(left) and is_float(right) do
    left + right
  rescue
    ArithmeticError -> SQLNumber.arithmetic(:+, left, right)
  end

  defp add(left, right), do: SQLNumber.arithmetic(:+, left, right)

  # The mean of integers is their exact sum over their count; of floats, the
  # sum the engine's `f64` accumulator makes. A decimal's mean has four more
  # places than the double models.
  @spec average([SQLNumber.t()]) :: float() | SQLNumber.special()
  defp average([first | _rest] = values) do
    cond do
      match?({:dec, _coefficient, _scale}, first) ->
        throw(
          {:query_error,
           SQLError.refusal(
             "AVG of a decimal (an Int64 with a UInt64, or a division of one): the engine " <>
               "gives it four more places than the double models"
           )}
        )

      integer_values?(values) ->
        values |> Enum.map(&integer_of/1) |> Enum.sum() |> Kernel./(length(values))

      true ->
        values |> sum_floats() |> divide(length(values) * 1.0)
    end
  end

  @spec integer_values?([SQLNumber.t()]) :: boolean()
  defp integer_values?(values),
    do: Enum.all?(values, &(is_integer(&1) or match?({:u, _}, &1) or match?({:int, _, _}, &1)))

  @spec integer_of(integer() | {:u, non_neg_integer()} | SQLNumber.narrow()) :: integer()
  defp integer_of({:u, value}), do: value
  defp integer_of({:int, _bits, value}), do: value
  defp integer_of(value), do: value

  @spec sum_floats([SQLNumber.t()]) :: float() | SQLNumber.special()
  defp sum_floats(values) do
    values |> Enum.map(&SQLNumber.to_float/1) |> Enum.reduce(0.0, &add(&2, &1))
  end

  # DataFusion's median: the middle value, or for an even count the mean of
  # the two middle values — computed in the column's type, so two integers
  # add (wrapping) and halve with integer division (median of 1 and 4 is 2,
  # not 2.5).
  @spec median([SQLNumber.t()]) :: SQLNumber.t()
  defp median(values) do
    sorted = Enum.sort(values, &SQLSort.value_order/2)
    size = length(sorted)
    middle = div(size, 2)

    if rem(size, 2) == 1 do
      Enum.at(sorted, middle)
    else
      halve(add(Enum.at(sorted, middle - 1), Enum.at(sorted, middle)))
    end
  end

  @spec halve(SQLNumber.t()) :: SQLNumber.t()
  defp halve({:u, value}), do: {:u, div(value, 2)}
  defp halve({:int, bits, value}), do: {:int, bits, div(value, 2)}
  defp halve({:dec, coefficient, scale}), do: {:dec, div(coefficient, 2), scale}
  defp halve(value), do: SQLNumber.arithmetic(:/, value, if(is_integer(value), do: 2, else: 2.0))

  # The sample or population variance or deviation of the values. Sample forms need at least two
  # values, exactly as the real engine (STDDEV of one row is null); population forms are defined
  # for one.
  @spec spread([SQLNumber.t()], SQLParser.aggregate(), boolean()) :: term()
  defp spread([], _agg, _scalar?), do: nil
  defp spread([_one], agg, _scalar?) when agg in [:var, :stddev], do: nil

  defp spread(values, agg, scalar?) do
    divisor = if agg in [:var, :stddev], do: length(values) - 1, else: length(values)
    variance = variance(values, divisor, scalar?)
    if agg in [:var, :var_pop], do: variance, else: square_root(variance)
  end

  # The variance of the values over `divisor`, by the engine's own one-pass accumulator
  # (Welford). The engine runs it per partition of the scan and merges the partitions, so its
  # last digits depend on how the scan was split and are not reproducible (see `values/2`);
  # for typical data the single pass here matches it far more often than an exact variance
  # does (measured: 49 of 60 small groups against 31). Equal values have a variance of exactly
  # zero.
  @spec variance([SQLNumber.t()], pos_integer(), boolean()) :: float() | SQLNumber.special()
  defp variance(values, divisor, scalar?) do
    {count, mean, squares} = Enum.reduce(values, {0, 0.0, 0.0}, &welford/2)
    divide(merged(scalar? and count == 1, mean, squares), divisor * 1.0)
  end

  # The engine merges the accumulator into an empty one for the final result, and the merge
  # adds `delta * delta * 0` for the distance `delta` of the means: no change, unless the square
  # of a mean past 1.3e154 overflows, when it is `inf * 0` and the variance is a NaN (verified:
  # two rows of 1.7e308 have a null deviation). The variance of the whole table that is a single
  # row is not merged (verified: one row of 1e308 has a variance of 0.0, a group of one has none).
  @spec merged(boolean(), SQLNumber.t(), SQLNumber.t()) :: SQLNumber.t()
  defp merged(true, _mean, squares), do: squares

  defp merged(false, mean, squares) do
    delta = SQLNumber.arithmetic(:-, 0.0, mean)
    nothing = SQLNumber.arithmetic(:*, SQLNumber.arithmetic(:*, delta, delta), 0.0)
    add(squares, nothing)
  end

  @spec welford(SQLNumber.t(), {non_neg_integer(), SQLNumber.t(), SQLNumber.t()}) ::
          {pos_integer(), SQLNumber.t(), SQLNumber.t()}
  defp welford(value, {count, mean, squares}) do
    value = SQLNumber.to_float(value)
    count = count + 1
    first_distance = SQLNumber.arithmetic(:-, value, mean)
    mean = add(divide(first_distance, count * 1.0), mean)
    second_distance = SQLNumber.arithmetic(:-, value, mean)
    {count, mean, add(squares, SQLNumber.arithmetic(:*, first_distance, second_distance))}
  end

  @spec square_root(float() | SQLNumber.special()) :: float() | SQLNumber.special()
  defp square_root(special) when special in [:inf, :nan], do: special
  defp square_root(:neg_inf), do: :nan
  defp square_root(value) when value < 0, do: :nan
  defp square_root(value), do: :math.sqrt(value)

  # selector_first/last pick by the ordering column, selector_min/max by the
  # field itself; `['value']` returns the field, `['time']` the row's time.
  @spec selector(
          :first | :last | :min | :max,
          binary(),
          binary(),
          :value | :time | :struct,
          points()
        ) ::
          term()
  defp selector(kind, field, ordering, access, points) do
    candidates = Enum.reject(points, &is_nil(SQLRow.column_value(&1, field)))

    # The engine cannot order a tag: it closes the connection (verified).
    if kind in [:min, :max] and Enum.any?(candidates, &Map.has_key?(&1.tags, field)),
      do: throw({:query_error, SQLError.closed()})

    case pick(kind, candidates, field, ordering) do
      nil -> nil
      point -> selector_access(point, field, access)
    end
  end

  @spec pick(:first | :last | :min | :max, points(), binary(), binary()) :: SQLRow.point() | nil
  defp pick(_kind, [], _field, _ordering), do: nil

  defp pick(kind, points, _field, ordering) when kind in [:first, :last],
    do: pick_by_order(kind, points, ordering)

  defp pick(:min, points, field, _ordering),
    do: Enum.min_by(points, &SQLRow.column_value(&1, field), &SQLSort.value_order/2)

  defp pick(:max, points, field, _ordering),
    do:
      Enum.max_by(points, &SQLRow.column_value(&1, field), fn a, b ->
        SQLSort.value_order(b, a)
      end)

  @spec selector_access(SQLRow.point(), binary(), :value | :time | :struct) :: term()
  defp selector_access(point, field, :value), do: SQLRow.column_value(point, field)
  defp selector_access(point, _field, :time), do: SQLRow.nanoseconds_to_datetime(point.timestamp)

  # The engine's struct (verified): `%{"time" => ..., "value" => ...}`.
  defp selector_access(point, field, :struct) do
    %{
      "time" => SQLRow.nanoseconds_to_datetime(point.timestamp),
      "value" => SQLRow.column_value(point, field)
    }
  end

  # Ordered aggregates: return the field value from the point that comes
  # first (`:first`) or last (`:last`) in the ordering column's ascending
  # order. `first_value(x ORDER BY c DESC)` is the parser's `:last`: a null
  # ordering value sorts last ascending (first descending), as in ORDER BY.
  @spec ordered(:first | :last, binary(), binary(), points()) :: term()
  defp ordered(_agg, _field, _ordering, []), do: nil

  defp ordered(agg, field, ordering, points) do
    agg |> pick_by_order(points, ordering) |> SQLRow.column_value(field)
  end

  # A single pass for the extreme element, not a sort of the whole bucket.
  # Ties resolve to the first point in scan (insertion) order.
  @spec pick_by_order(:first | :last, [SQLRow.point(), ...], binary()) :: SQLRow.point()
  defp pick_by_order(:first, points, ordering) do
    Enum.min_by(points, &SQLRow.sort_value(&1, ordering), fn a, b ->
      SQLSort.value_before?(a, b, @ascending) != :after
    end)
  end

  defp pick_by_order(:last, points, ordering) do
    Enum.max_by(points, &SQLRow.sort_value(&1, ordering), fn a, b ->
      SQLSort.value_before?(b, a, @ascending) != :after
    end)
  end
end
