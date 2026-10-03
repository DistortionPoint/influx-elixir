defmodule InfluxElixir.Client.Local.SQLGrouping do
  @moduledoc false
  # The engine's check that a projected plain column of an aggregate query is
  # grouped (verified against InfluxDB 3 Core): planning fails otherwise, and
  # its message lists what does satisfy the requirement, the `GROUP BY` terms
  # and then the aggregates in select order, each as the planner prints it.
  # The double refuses by name a query whose terms it cannot print.

  alias InfluxElixir.Client.Local.{SQLError, SQLExpr, SQLParser}

  @doc """
  `:ok`, or the engine's planning error for a projected plain column of an
  aggregate query that is not in its `GROUP BY`.
  """
  @spec check(SQLParser.parsed_query()) :: :ok | {:error, term()}
  def check(%{select_columns: nil}), do: :ok

  def check(query) do
    grouped = query.group_by_columns || []

    ungrouped =
      Enum.find_value(query.select_columns, fn
        {:grouping_column, source, _alias} -> if source in grouped, do: nil, else: source
        _other -> nil
      end)

    case ungrouped do
      nil -> :ok
      column -> {:error, ungrouped_error(query, column)}
    end
  end

  @spec ungrouped_error(SQLParser.parsed_query(), binary()) :: map()
  defp ungrouped_error(query, column) do
    case satisfying_terms(query) do
      {:ok, terms} ->
        %{
          status: 400,
          body:
            "Error during planning: Column in SELECT must be in GROUP BY or an aggregate " <>
              "function: While expanding wildcard, column \"#{query.qualifier}.#{column}\" " <>
              "must appear in the GROUP BY clause or must be part of an aggregate function, " <>
              "currently only \"#{Enum.join(terms, ", ")}\" appears in the SELECT clause " <>
              "satisfies this requirement"
        }

      :unrenderable ->
        SQLError.refusal(
          "column \"#{column}\" must appear in the GROUP BY clause or be part of an " <>
            "aggregate function; the double cannot print this query's terms as the " <>
            "engine's error does"
        )
    end
  end

  @day_ns 86_400_000_000_000

  @spec satisfying_terms(SQLParser.parsed_query()) :: {:ok, [binary()]} | :unrenderable
  defp satisfying_terms(%{cross_join: nil, qualifier: table} = query) do
    columns = Enum.map(query.group_by_columns || [], &"#{table}.#{&1}")

    with {:ok, groups} <- group_terms(query.group_by_interval, columns, table),
         {:ok, aggregates} <- aggregate_terms(query.select_columns, table) do
      {:ok, groups ++ aggregates}
    end
  end

  # The qualifier of a column of a joined query depends on its side.
  defp satisfying_terms(_joined_query), do: :unrenderable

  # DATE_BIN prints its interval as months, days and nanoseconds. The double
  # keeps nanoseconds only, so a whole number of days (which the engine may
  # hold as days) and a DATE_BIN beside other terms (their order is lost)
  # are not printed.
  @spec group_terms(non_neg_integer() | nil, [binary()], binary()) ::
          {:ok, [binary()]} | :unrenderable
  defp group_terms(nil, columns, _table), do: {:ok, columns}
  defp group_terms(_interval_ns, [_column | _rest], _table), do: :unrenderable
  defp group_terms(interval_ns, [], _table) when rem(interval_ns, @day_ns) == 0, do: :unrenderable

  defp group_terms(interval_ns, [], table) do
    interval = "IntervalMonthDayNano { months: 0, days: 0, nanoseconds: #{interval_ns} }"
    {:ok, [~s|date_bin(IntervalMonthDayNano("#{interval}"),#{table}.time)|]}
  end

  @spec aggregate_terms([SQLParser.select_column()], binary()) ::
          {:ok, [binary()]} | :unrenderable
  defp aggregate_terms(select_columns, table) do
    terms = Enum.map(select_columns, &aggregate_term(&1, table))

    if :unrenderable in terms,
      do: :unrenderable,
      else: {:ok, Enum.reject(terms, &is_nil/1)}
  end

  @spec aggregate_term(SQLParser.select_column(), binary()) :: binary() | nil | :unrenderable
  defp aggregate_term({:count_star, _alias}, _table), do: "count(Int64(1))"

  defp aggregate_term({:count_distinct, column, _alias}, table),
    do: "count(DISTINCT #{table}.#{column})"

  defp aggregate_term({:aggregate, agg, expr, _alias}, table) do
    "#{agg}(#{SQLExpr.render(expr, table, :refuse)})"
  catch
    :unrenderable -> :unrenderable
  end

  # The first or last in an order cannot be told from the other written
  # with the opposite direction (the parser folds them), and a selector
  # prints its access.
  defp aggregate_term({:ordered_aggregate, _agg, _field, _ordering, _alias}, _table),
    do: :unrenderable

  defp aggregate_term({:selector, _kind, _field, _ordering, _access, _alias}, _table),
    do: :unrenderable

  defp aggregate_term(_group_or_constant, _table), do: nil
end
