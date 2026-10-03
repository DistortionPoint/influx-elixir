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
    SQLNumber,
    SQLParser,
    SQLRow,
    SQLSelect,
    SQLSort
  }

  @typedoc "A group's points."
  @type points :: [SQLRow.point()]

  # The order an ascending sort (and `first_value`/`last_value`) puts nulls in.
  @ascending {:asc, :nulls_last}

  @doc """
  One output row of an aggregate or grouped select list: each column over the
  group's `points`; `bucket_ts` is the group's `DATE_BIN` bucket start.
  """
  @spec reduce_columns([SQLSelect.column()], points(), integer() | nil) :: map()
  def reduce_columns(columns, points, bucket_ts) do
    Enum.reduce(columns, %{}, fn column, row ->
      put(row, elem(column, tuple_size(column) - 1), column_result(column, points, bucket_ts))
    end)
  end

  @doc """
  The output rows of one group: its row, unless a `HAVING` leaves it out
  (`having` is `nil` for none). The condition reads the group's first row,
  the aggregates it names and the names of the select list.
  """
  @spec reduce_group(
          [SQLSelect.column()],
          SQLAggExpr.having_t() | nil,
          points(),
          integer() | nil
        ) :: [map()]
  def reduce_group(columns, having, points, bucket_ts) do
    row = reduce_columns(columns, points, bucket_ts)

    if is_nil(having) or having_holds?(having, points, bucket_ts, row), do: [row], else: []
  end

  @spec having_holds?(SQLAggExpr.having_t(), points(), integer() | nil, map()) :: boolean()
  defp having_holds?(%{nodes: nodes, aggs: aggs}, points, bucket_ts, row) do
    SQLCondition.matches_all?(group_row(points, aggs, bucket_ts, row), nodes)
  end

  # The row an expression of a group is evaluated over: the group's first
  # row, the select list's outputs and the values of the aggregates the
  # expression names.
  @spec group_row(points(), [{binary(), SQLSelect.column()}], integer() | nil, map()) ::
          SQLRow.point()
  defp group_row(points, aggs, bucket_ts, outputs \\ %{}) do
    base = List.first(points) || %{measurement: "", tags: %{}, fields: %{}, timestamp: nil}

    values =
      Map.new(aggs, fn {name, column} -> {name, column_result(column, points, bucket_ts)} end)

    %{base | fields: base.fields |> Map.merge(outputs) |> Map.merge(values)}
  end

  # A null result is no key.
  @spec put(map(), binary(), term()) :: map()
  defp put(row, _key, nil), do: row
  defp put(row, key, value), do: Map.put(row, key, value)

  @spec column_result(SQLSelect.column(), points(), integer() | nil) :: term()
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

  defp column_result({:aggregate, agg, expr, _alias}, points, _bucket_ts) do
    values = points |> Enum.map(&SQLEval.eval(expr, &1)) |> Enum.reject(&is_nil/1)
    compute(agg, values)
  end

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

  # An aggregate over the non-null values of one group.
  @spec compute(SQLParser.aggregate(), [term()]) :: term()
  defp compute(:count, values), do: length(values)
  defp compute(_agg, []), do: nil
  defp compute(:avg, values), do: average(values)
  defp compute(:sum, [first | _rest] = values), do: Enum.reduce(values, zero(first), &add(&2, &1))
  # MIN/MAX also run over `time`, so the comparison is the sort's.
  defp compute(:min, values), do: Enum.min(values, &SQLSort.value_order/2)
  defp compute(:max, values), do: Enum.max(values, fn a, b -> SQLSort.value_order(b, a) end)
  defp compute(:median, values), do: median(values)
  # Sample forms need at least two values, exactly as the real engine
  # (STDDEV of one row is null); population forms are defined for one.
  defp compute(:var, [_one]), do: nil
  defp compute(:stddev, [_one]), do: nil
  defp compute(:var, values), do: variance(values, length(values) - 1)
  defp compute(:stddev, values), do: :var |> compute(values) |> square_root()
  defp compute(:var_pop, values), do: variance(values, length(values))
  defp compute(:stddev_pop, values), do: :var_pop |> compute(values) |> square_root()

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

  # The sample or population variance: the squared distances from the mean,
  # over `divisor`.
  @spec variance([SQLNumber.t()], pos_integer()) :: float() | SQLNumber.special()
  defp variance(values, divisor) do
    count = length(values)

    mean =
      if integer_values?(values),
        do: values |> Enum.map(&integer_of/1) |> Enum.sum() |> Kernel./(count),
        else: values |> sum_floats() |> divide(count * 1.0)

    values
    |> Enum.map(&SQLNumber.to_float/1)
    |> Enum.reduce(0.0, fn value, acc -> add(acc, squared_distance(value, mean)) end)
    |> divide(divisor * 1.0)
  end

  @spec squared_distance(float() | SQLNumber.special(), float() | SQLNumber.special()) ::
          float() | SQLNumber.special()
  defp squared_distance(value, mean) do
    distance = SQLNumber.arithmetic(:-, value, mean)
    SQLNumber.arithmetic(:*, distance, distance)
  end

  @spec square_root(float() | SQLNumber.special() | nil) :: float() | SQLNumber.special() | nil
  defp square_root(nil), do: nil
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
    candidates = Enum.reject(points, &is_nil(Map.get(&1.fields, field)))

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
    do: Enum.min_by(points, &Map.get(&1.fields, field), &SQLSort.value_order/2)

  defp pick(:max, points, field, _ordering),
    do: Enum.max_by(points, &Map.get(&1.fields, field), fn a, b -> SQLSort.value_order(b, a) end)

  @spec selector_access(SQLRow.point(), binary(), :value | :time | :struct) :: term()
  defp selector_access(point, field, :value), do: Map.get(point.fields, field)
  defp selector_access(point, _field, :time), do: SQLRow.nanoseconds_to_datetime(point.timestamp)

  # The engine's struct (verified): `%{"time" => ..., "value" => ...}`.
  defp selector_access(point, field, :struct) do
    %{
      "time" => SQLRow.nanoseconds_to_datetime(point.timestamp),
      "value" => Map.get(point.fields, field)
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
