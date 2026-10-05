defmodule InfluxElixir.Client.Local.SQLAggType do
  @moduledoc false
  # The Arrow type of an aggregate's result, so the planner's checks reach an
  # expression over aggregates (`sum(n) + host`) as they reach one over
  # columns (verified against InfluxDB 3 Core, each aggregate over an
  # `Int64`, a `Float64`, text, a tag, a boolean and a timestamp):
  #
  #   * `count` is an `Int64`; `avg` and the standard deviations and variances
  #     are a `Float64`
  #   * `sum` widens: an `Int64` stays one, an unsigned is a `UInt64`, a float
  #     is a `Float64`
  #   * `min`, `max` and `median` keep the argument's type, except that a tag
  #     comes back as plain text; `first_value` and `last_value` keep it
  #     whole, a tag included
  #   * a selector's `['value']` is its field's type, its `['time']` a
  #     timestamp, the whole struct a `Struct("value": ..., "time": ...)`
  #   * the null as an argument: the statistics are floats
  #
  # The engine types an aggregate twice, as it does any expression (see
  # `InfluxElixir.Client.Local.SQLExprType`): the planner types its argument before the
  # coercion, so the argument of a `CASE` has the type of its first result, and the error of an
  # operator over the aggregate names it (`sum(CASE WHEN b THEN n ELSE v END) + 'a'` is `Int64 +
  # Utf8`); the type coercion then gives the `CASE` the type its results share, and the errors it
  # finds name that (`NOT sum(CASE ...)` is a `Float64`). `types/2` has the second type under
  # the name of the aggregate and, where the first differs, under `plan_key/1` of it.
  #
  # A type that is not known is `nil`, which is never refused.

  alias InfluxElixir.Client.Local.{SQLExpr, SQLExprType, SQLSelect}

  import SQLExprType, only: [is_decimal_type: 1, is_numeric_type: 1]

  @tag "Dictionary(Int32, Utf8)"
  @decimal "Decimal128(?)"
  @signed ["Int64", "Int32", "Int16", "Int8"]

  @doc "The expressions the aggregates of an expression read."
  @spec arguments([{binary(), SQLSelect.column()}]) :: [SQLExpr.t()]
  def arguments(aggs), do: Enum.flat_map(aggs, fn {_name, column} -> argument(column) end)

  @doc """
  The types of the aggregates of an expression, by the names they stand under
  in it; an aggregate whose type is not known is left out.
  """
  @spec types([{binary(), SQLSelect.column()}], %{binary() => binary()}) :: %{
          binary() => binary()
        }
  def types(aggs, columns) do
    Enum.reduce(aggs, %{}, fn {name, column}, found ->
      coerced = result(column, columns, :coerced)
      planned = result(column, columns, :plan)

      found
      |> put_type(name, coerced)
      |> put_type(plan_key(name), if(planned != coerced, do: planned))
    end)
  end

  @plan_prefix "\u0000plan:"

  @doc "The name an aggregate's planner type stands under in the types of the columns."
  @spec plan_key(binary()) :: binary()
  def plan_key(name), do: @plan_prefix <> name

  @doc "Whether a name in the types is the key of an aggregate's planner type."
  @spec plan_key?(binary()) :: boolean()
  def plan_key?(name), do: String.starts_with?(name, @plan_prefix)

  @spec put_type(%{binary() => binary()}, binary(), binary() | nil) :: %{binary() => binary()}
  defp put_type(found, _name, nil), do: found
  defp put_type(found, name, type), do: Map.put(found, name, type)

  @doc """
  The types of the select items output as one of `names`, by that name; an item whose type
  is not known is left out. A `HAVING` names such an item by its alias.
  """
  @spec output_types([SQLSelect.column()], [binary()], %{binary() => binary()}) :: %{
          binary() => binary()
        }
  def output_types(select_columns, names, columns) do
    for column <- select_columns,
        name = output_name(column),
        name in names,
        type = result(column, columns, :coerced),
        into: %{},
        do: {name, type}
  end

  @doc "The expressions the select items output as one of `names` read."
  @spec output_arguments([SQLSelect.column()], [binary()]) :: [SQLExpr.t()]
  def output_arguments(select_columns, names) do
    for column <- select_columns, output_name(column) in names, arg <- argument(column), do: arg
  end

  # The name a select item is output as: the last element of each of its shapes.
  @spec output_name(SQLSelect.column()) :: binary() | nil
  defp output_name(column) do
    name = elem(column, tuple_size(column) - 1)
    if is_binary(name), do: name
  end

  @spec result(SQLSelect.column(), %{binary() => binary()}, SQLExprType.phase()) ::
          binary() | nil
  defp result({:count_star, _name}, _columns, _phase), do: "Int64"
  defp result({:count_distinct, _column, _name}, _columns, _phase), do: "Int64"

  defp result({:aggregate, agg, _expr, _name}, _columns, _phase)
       when agg in [:count, :count_distinct],
       do: "Int64"

  # The null as an argument (verified against Core): the statistics are floats; `MIN` and
  # `MAX` of it are typed by the engine only after the plan (not modelled), `SUM` and `AVG`
  # of it fail the plan before this is read.
  defp result({:aggregate, agg, {:lit, nil}, _name}, _columns, _phase), do: null_result(agg)

  defp result({:aggregate, :sum_distinct, expr, name}, columns, phase),
    do: result({:aggregate, :sum, expr, name}, columns, phase)

  defp result({:aggregate, agg, expr, _name}, columns, phase),
    do: kept(agg, SQLExprType.known_type(expr, columns, [], phase))

  defp result({:ordered_aggregate, _end, field, _ordering, _name}, columns, _phase),
    do: Map.get(columns, field)

  defp result({:selector, _selector, field, _ordering, :value, _name}, columns, _phase),
    do: Map.get(columns, field)

  defp result({:selector, _selector, _field, _ordering, :time, _name}, _columns, _phase),
    do: "Timestamp(ns)"

  defp result({:selector, _selector, field, _ordering, :struct, _name}, columns, _phase) do
    case Map.get(columns, field) do
      nil -> nil
      type -> ~s|Struct("value": #{type}, "time": Timestamp(ns))|
    end
  end

  # An expression over aggregates (`sum(n) + 1`) has the type of its operators over the
  # aggregates' results (an aggregate whose type is not known leaves the expression's so).
  defp result({:expression, expr, aggs, _name}, columns, phase),
    do: SQLExprType.known_type(expr, Map.merge(columns, types(aggs, columns)), [], phase)

  defp result({:grouping_column, source, _name}, columns, _phase), do: Map.get(columns, source)
  defp result(_other, _columns, _phase), do: nil

  @spec null_result(SQLSelect.aggregate()) :: binary() | nil
  defp null_result(agg) when agg in [:min, :max, :sum, :sum_distinct, :avg], do: nil
  defp null_result(_statistic), do: "Float64"

  # An aggregate of an argument it does not take (the engine fails the plan with its own
  # error, which `InfluxElixir.Client.Local.SQLPlan` words) has no type here.
  @spec kept(SQLSelect.aggregate(), binary() | nil) :: binary() | nil
  defp kept(_agg, type) when type in [nil, :mixed], do: nil
  defp kept(agg, @tag) when agg in [:min, :max], do: "Utf8"
  defp kept(agg, type) when agg in [:min, :max], do: type
  defp kept(_agg, type) when not is_numeric_type(type), do: nil
  defp kept(agg, type) when agg in [:sum, :avg] and is_decimal_type(type), do: @decimal
  defp kept(agg, _type) when agg in [:avg, :stddev, :stddev_pop, :var, :var_pop], do: "Float64"
  defp kept(:sum, type) when type in @signed, do: "Int64"
  defp kept(:sum, type) when type in ["UInt64", "Float64"], do: type
  defp kept(:median, type), do: type

  # The expression an aggregate reads.
  @spec argument(SQLSelect.column()) :: [SQLExpr.t()]
  defp argument({:aggregate, _agg, expr, _name}), do: [expr]
  defp argument({:count_distinct, column, _name}), do: [{:field, column}]
  defp argument({:ordered_aggregate, _end, field, _ordering, _name}), do: [{:field, field}]
  defp argument({:selector, _selector, field, _ordering, _kind, _name}), do: [{:field, field}]
  defp argument({:grouping_column, source, _name}), do: [{:field, source}]
  defp argument({:expression, _expr, aggs, _name}), do: arguments(aggs)
  defp argument(_other), do: []
end
