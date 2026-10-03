defmodule InfluxElixir.Client.Local.SQLGrouping do
  @moduledoc false
  # The engine's check that a projected plain column of an aggregate query is
  # grouped (verified against InfluxDB 3 Core): planning fails otherwise, and
  # its message lists what does satisfy the requirement, the `GROUP BY` terms
  # and then the aggregates in select order, each as the planner prints it.
  # The double refuses by name a query whose terms it cannot print.

  alias InfluxElixir.Client.Local.{
    SQLAggExpr,
    SQLError,
    SQLExpr,
    SQLLiteral,
    SQLParser,
    SQLSchema,
    SQLWhere
  }

  @doc """
  `:ok`, or the engine's planning error for a projected plain column of an
  aggregate query that is not in its `GROUP BY`.
  """
  @spec check(SQLParser.parsed_query(), [SQLSchema.relation()]) :: :ok | {:error, term()}
  def check(%{select_columns: nil}, _relations), do: :ok

  def check(query, relations) do
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
      nil ->
        check_having(query, grouped, relations)

      {:column, column} ->
        {:error, ungrouped_error(query, "#{query.qualifier}.#{column}", "SELECT")}

      {:expression, column} ->
        {:error, ungrouped_refusal(column)}
    end
  end

  # A column a `HAVING` reads that is neither grouped nor an aggregate's. A name the table
  # has is that column; any other is the name of a select item (verified against Core: an
  # alias of an aggregate or an expression is read as the item, and a column of the table
  # wins over an alias of that name), but only a name written without a relation: `t.alias`
  # is a column of `t`, which a `HAVING` that is not grouped refuses, named as written. The
  # `NULL` of `HAVING NULL` reads as a comparison of `time` with null, which reads no column.
  @spec check_having(SQLParser.parsed_query(), [binary()], [SQLSchema.relation()]) ::
          :ok | {:error, term()}
  defp check_having(%{having: nil}, _grouped, _relations), do: :ok

  defp check_having(%{having: %{nodes: nodes}} = query, grouped, relations) do
    outputs = for column <- query.select_columns, do: elem(column, tuple_size(column) - 1)
    columns = SQLSchema.table_columns(relations)

    qualified = for {:qualified, _relation, _name} = ref <- SQLSchema.where_refs(nodes), do: ref

    problem =
      Enum.find_value(
        SQLWhere.conjunction_columns(nodes) ++ qualified,
        &having_problem(&1, query, grouped, outputs, columns)
      )

    case problem do
      nil -> :ok
      {:ungrouped, printed} -> {:error, ungrouped_error(query, printed, "HAVING")}
      {:refuse, why} -> {:error, SQLError.refusal(why)}
    end
  end

  @spec having_problem(
          SQLExpr.column_ref(),
          SQLParser.parsed_query(),
          [binary()],
          [binary()],
          MapSet.t(binary())
        ) :: nil | {:ungrouped, binary()} | {:refuse, binary()}
  defp having_problem({:qualified, relation, _name} = ref, _query, _grouped, outputs, columns) do
    taken = unquoted(relation)

    if taken in outputs or MapSet.member?(columns, taken),
      do:
        {:refuse,
         "a HAVING name #{SQLExpr.ref_text(ref)} whose relation is a column or a select item: " <>
           "the engine reads it as a field of that column"},
      else: {:ungrouped, SQLExpr.ref_text(ref)}
  end

  defp having_problem(name, query, grouped, outputs, columns) do
    cond do
      SQLAggExpr.placeholder?(name) or name in grouped ->
        nil

      MapSet.member?(Map.get(query.qualified_in, :having, MapSet.new()), name) ->
        {:ungrouped, SQLSchema.written_name(name, query.qualified)}

      name in outputs and not MapSet.member?(columns, name) ->
        nil

      true ->
        {:ungrouped, "#{query.qualifier}.#{name}"}
    end
  end

  @spec unquoted(binary()) :: binary()
  defp unquoted(text) do
    if SQLLiteral.identifier?(text), do: SQLLiteral.identifier_name(text), else: text
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
  defp ungrouped_error(query, printed, clause) do
    case satisfying_terms(query) do
      {:ok, terms} ->
        %{
          status: 400,
          body:
            "Error during planning: Column in #{clause} must be in GROUP BY or an aggregate " <>
              "function: While expanding wildcard, column \"#{printed}\" " <>
              "must appear in the GROUP BY clause or must be part of an aggregate function, " <>
              "currently only \"#{Enum.join(terms, ", ")}\" appears in the SELECT clause " <>
              "satisfies this requirement"
        }

      :unrenderable ->
        SQLError.refusal(
          "column \"#{printed}\" must appear in the GROUP BY clause or be part of an " <>
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
