defmodule InfluxElixir.Client.Local.SQLGrouping do
  @moduledoc false
  # The engine's check that a projected plain column of an aggregate query is
  # grouped (verified against InfluxDB 3 Core): planning fails otherwise, and
  # its message lists what does satisfy the requirement, the `GROUP BY` terms
  # and then the aggregates in select order, each as the planner prints it.
  # The double refuses by name a query whose terms it cannot print.

  alias InfluxElixir.Client.Local.{SQLAggExpr, SQLError, SQLExpr, SQLParser, SQLWhere}

  @doc """
  `:ok`, or the engine's planning error for a projected plain column of an
  aggregate query that is not in its `GROUP BY`.
  """
  @spec check(SQLParser.parsed_query()) :: :ok | {:error, term()}
  def check(%{select_columns: nil}), do: :ok

  def check(query) do
    items = query.group_by_columns || []
    grouped = for item <- items, is_binary(item), do: item
    expressions = for {:expr, expr} <- items, do: expr

    ungrouped =
      Enum.find_value(query.select_columns, fn
        {:grouping_column, source, _alias} ->
          if source in grouped, do: nil, else: {:column, source}

        {:expression, expr, _aggs, _alias} ->
          ungrouped_expression(expr, grouped, expressions)

        _other ->
          nil
      end)

    case ungrouped do
      nil -> check_having(query, grouped)
      {:column, column} -> {:error, ungrouped_error(query, column, "SELECT")}
      {:expression, column} -> {:error, ungrouped_refusal(column)}
    end
  end

  # A column a `HAVING` reads that is neither grouped, an aggregate's nor the
  # name of a grouped column in the select list (verified against Core: the
  # alias of an aggregate or an expression is no column of a `HAVING`). The
  # `NULL` of `HAVING NULL` reads as a comparison of `time` with null, which
  # reads no column.
  @spec check_having(SQLParser.parsed_query(), [binary()]) :: :ok | {:error, term()}
  defp check_having(%{having: nil}, _grouped), do: :ok

  defp check_having(%{having: %{nodes: nodes}} = query, grouped) do
    outputs = for {:grouping_column, _source, output} <- query.select_columns, do: output

    ungrouped =
      Enum.find(SQLWhere.conjunction_columns(nodes), fn name ->
        not (SQLAggExpr.placeholder?(name) or name in grouped or name in outputs)
      end)

    if ungrouped, do: {:error, ungrouped_error(query, ungrouped, "HAVING")}, else: :ok
  end

  # The first column an expression reads outside an aggregate that is not
  # grouped (an expression the `GROUP BY` also holds is grouped whole).
  @spec ungrouped_expression(SQLExpr.t(), [binary()], [SQLExpr.t()]) ::
          nil | {:expression, binary()}
  defp ungrouped_expression(expr, grouped, expressions) do
    cond do
      expr in expressions ->
        nil

      match?({kind, name} when kind in [:field, :uint_col] and is_binary(name), expr) ->
        {_kind, name} = expr

        if SQLAggExpr.placeholder?(name) or name in grouped,
          do: nil,
          else: {:expression, name}

      true ->
        expr
        |> SQLExpr.children()
        |> Enum.find_value(&ungrouped_expression(&1, grouped, expressions))
    end
  end

  @spec ungrouped_refusal(binary()) :: SQLError.t()
  defp ungrouped_refusal(column) do
    SQLError.refusal(
      "column \"#{column}\" in an expression of the select list must appear in the GROUP BY " <>
        "clause or be part of an aggregate function; the double cannot print this query's " <>
        "terms as the engine's error does"
    )
  end

  @spec ungrouped_error(SQLParser.parsed_query(), binary(), binary()) :: map()
  defp ungrouped_error(query, column, clause) do
    case satisfying_terms(query) do
      {:ok, terms} ->
        %{
          status: 400,
          body:
            "Error during planning: Column in #{clause} must be in GROUP BY or an aggregate " <>
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
    items = query.group_by_columns || []

    if Enum.all?(items, &is_binary/1) do
      columns = Enum.map(items, &"#{table}.#{&1}")

      with {:ok, groups} <- group_terms(query.group_by_interval, columns, table),
           {:ok, aggregates} <-
             aggregate_terms(query.select_columns ++ having_columns(query), table) do
        {:ok, groups ++ Enum.uniq(aggregates)}
      end
    else
      :unrenderable
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

  # The aggregates a `HAVING` names, after those of the select list.
  @spec having_columns(SQLParser.parsed_query()) :: [SQLParser.select_column()]
  defp having_columns(%{having: nil}), do: []
  defp having_columns(%{having: %{aggs: aggs}}), do: Enum.map(aggs, &elem(&1, 1))

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

  defp aggregate_term({:expression, _expr, _aggs, _alias}, _table), do: :unrenderable

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
