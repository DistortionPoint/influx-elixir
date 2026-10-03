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
  #     timestamp; the whole struct has no type here
  #
  # A type that is not known is `nil`, which is never refused.

  alias InfluxElixir.Client.Local.{SQLExpr, SQLFunctions, SQLSchema, SQLSelect}

  import SQLFunctions, only: [is_numeric_type: 1]

  @tag "Dictionary(Int32, Utf8)"
  @signed ["Int64", "Int32", "Int16", "Int8"]

  @doc "The columns the aggregates of an expression read."
  @spec fields([{binary(), SQLSelect.column()}]) :: [binary()]
  def fields(aggs) do
    Enum.flat_map(aggs, fn {_name, column} -> column |> argument() |> SQLSchema.expr_fields() end)
  end

  @doc """
  The types of the aggregates of an expression, by the names they stand under
  in it; an aggregate whose type is not known is left out.
  """
  @spec types([{binary(), SQLSelect.column()}], %{binary() => binary()}) :: %{
          binary() => binary()
        }
  def types(aggs, columns) do
    for {name, column} <- aggs,
        type = result(column, columns),
        into: %{},
        do: {name, type}
  end

  @spec result(SQLSelect.column(), %{binary() => binary()}) :: binary() | nil
  defp result({:count_star, _name}, _columns), do: "Int64"
  defp result({:count_distinct, _column, _name}, _columns), do: "Int64"

  defp result({:aggregate, :count, _expr, _name}, _columns), do: "Int64"

  defp result({:aggregate, agg, expr, _name}, columns) do
    kept(agg, SQLFunctions.type_of(expr, columns))
  end

  defp result({:ordered_aggregate, _end, field, _ordering, _name}, columns),
    do: SQLFunctions.type_of({:field, field}, columns)

  defp result({:selector, _selector, field, _ordering, :value, _name}, columns),
    do: SQLFunctions.type_of({:field, field}, columns)

  defp result({:selector, _selector, _field, _ordering, :time, _name}, _columns),
    do: "Timestamp(ns)"

  defp result(_other, _columns), do: nil

  # An aggregate of an argument it does not take (the engine fails the plan with its own
  # error, which `InfluxElixir.Client.Local.SQLPlan` words) has no type here.
  @spec kept(SQLSelect.aggregate(), binary() | nil) :: binary() | nil
  defp kept(_agg, nil), do: nil
  defp kept(agg, @tag) when agg in [:min, :max], do: "Utf8"
  defp kept(agg, type) when agg in [:min, :max], do: type
  defp kept(_agg, type) when not is_numeric_type(type), do: nil
  defp kept(agg, _type) when agg in [:avg, :stddev, :stddev_pop, :var, :var_pop], do: "Float64"
  defp kept(:sum, type) when type in @signed, do: "Int64"
  defp kept(:sum, type) when type in ["UInt64", "Float64"], do: type
  defp kept(:median, type), do: type
  defp kept(_agg, _type), do: nil

  # The expression an aggregate reads.
  @spec argument(SQLSelect.column()) :: [SQLExpr.t()]
  defp argument({:aggregate, _agg, expr, _name}), do: [expr]
  defp argument({:count_distinct, column, _name}), do: [{:field, column}]
  defp argument({:ordered_aggregate, _end, field, _ordering, _name}), do: [{:field, field}]
  defp argument({:selector, _selector, field, _ordering, _kind, _name}), do: [{:field, field}]
  defp argument(_other), do: []
end
