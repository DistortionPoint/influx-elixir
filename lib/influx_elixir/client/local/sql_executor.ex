defmodule InfluxElixir.Client.Local.SQLExecutor do
  @moduledoc """
  Executes a parsed SQL query for `InfluxElixir.Client.Local`.

  Takes the `t:InfluxElixir.Client.Local.SQLParser.parsed_query/0` the parser
  produced and a function that fetches a measurement's points, and returns
  rows in the shape InfluxDB 3's JSON responses have: string keys, `time` as a
  `DateTime`, null columns omitted. Every rule the double enforces about what
  the engine returns lives in the modules this one calls, in the order the
  engine meets them:

    * `InfluxElixir.Client.Local.SQLJoin` — a `CROSS JOIN`
    * `InfluxElixir.Client.Local.SQLSchema` — the schema errors for a column
      that is not there
    * `InfluxElixir.Client.Local.SQLTyping` and
      `InfluxElixir.Client.Local.SQLPlan` — the types of the expressions and
      the errors the planner finds in them
    * `InfluxElixir.Client.Local.SQLGrouping` — a column that is not grouped
    * `InfluxElixir.Client.Local.SQLFold` — a constant the optimizer cannot
      fold (a `CAST` that cannot be performed)
    * `InfluxElixir.Client.Local.SQLSimplify` — what the optimizer removes of
      the `WHERE` before a row is read
    * `InfluxElixir.Client.Local.SQLRange` — a `WHERE` that leaves no value
      (or a constant that overflows in its analysis)
    * `InfluxElixir.Client.Local.SQLCondition` — the filter itself
    * `InfluxElixir.Client.Local.SQLEval`, `SQLNumber`, `SQLCast` and
      `SQLAggregate` — the values
    * `InfluxElixir.Client.Local.SQLSort` — the order

  Storage, profiles and the other query languages stay in `Client.Local`.

  Pure over the points it is given: no ETS, no connection state.
  """

  alias InfluxElixir.Client.Local.{
    LineProtocolParser,
    SQLAggregate,
    SQLClauses,
    SQLCondition,
    SQLError,
    SQLEval,
    SQLExpr,
    SQLFold,
    SQLGrouping,
    SQLJoin,
    SQLNumber,
    SQLParser,
    SQLPlan,
    SQLRange,
    SQLRow,
    SQLSchema,
    SQLSimplify,
    SQLSort,
    SQLTime,
    SQLTyping
  }

  @typedoc "A stored point, as `InfluxElixir.Client.Local` keeps it."
  @type point :: LineProtocolParser.point()

  @typedoc "Fetches a measurement's points, or `:error` when there is no such measurement."
  @type fetch :: (binary() -> {:ok, [point()]} | :error)

  @typedoc """
  Looks up a stored column's kind from its measurement and name: the
  `iox::column_type::field::<type>` the store registered, or `nil`.
  """
  @type kinds :: (binary(), binary() -> binary() | nil)

  @uinteger_kind "iox::column_type::field::uinteger"

  # CTEs run first, in order, each over the store or an earlier CTE; their
  # rows become the points the next query reads (a CTE shadows a measurement
  # of the same name, as in SQL).
  @doc """
  Runs a parsed query. `fetch` returns a measurement's points, or `:error`
  when the measurement does not exist; CTEs shadow it by name. `params` are
  the engine's values for the query's `$name` placeholders (see
  `InfluxElixir.Client.QueryParams.engine_values/1`). `kinds` tells an
  `Int64` column from a `UInt64` one, which the stored integers do not; a
  query that runs without it reads every integer column as `Int64`.

  This is the engine's SQL: a `WHERE` that leaves a numeric column no value
  fails as it does there (see `InfluxElixir.Client.Local.SQLBounds`).
  """
  @spec run(SQLParser.parsed_query(), fetch(), %{binary() => term()}, kinds() | nil) ::
          [map()] | {:error, term()}
  def run(query, fetch, params, kinds \\ nil), do: run_query(query, fetch, params, kinds)

  @doc """
  Runs the SQL that an InfluxQL query is written as. The engine's InfluxQL
  planner does not fail on a `WHERE` that leaves a numeric column no value
  (verified: it answers `[]`), so that failure is not raised here.
  """
  @spec run_influxql(SQLParser.parsed_query(), fetch()) :: [map()] | {:error, term()}
  def run_influxql(query, fetch), do: run_query(query, fetch, %{}, :unchecked)

  @doc "Whether a point satisfies a parsed `WHERE` conjunction (also used by `DELETE`)."
  @spec matches_all?(point(), [SQLParser.where_node()]) :: boolean()
  defdelegate matches_all?(point, conjunction), to: SQLCondition

  @typep kinds_mode :: kinds() | nil | :unchecked

  @spec run_query(SQLParser.parsed_query(), fetch(), %{binary() => term()}, kinds_mode()) ::
          [map()] | {:error, term()}
  defp run_query(query, fetch, params, kinds) do
    query.ctes
    |> Enum.reduce_while({:ok, %{}}, fn {name, cte_query}, {:ok, sources} ->
      with {:ok, rows, relations} <- select(cte_query, fetch, sources, params, kinds, false),
           :ok <- SQLTyping.check_cte_outputs(cte_query) do
        cte = cte_source(name, rows, relations, cte_query, sources, kinds)
        {:cont, {:ok, Map.put(sources, name, cte)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, sources} -> execute_select(query, fetch, sources, params, kinds)
      {:error, _reason} = error -> error
    end
  end

  # What a query reads from: its points; its columns in order when it is a
  # CTE (a table's are its points', sorted); and whether a filter above it
  # reaches the table underneath (it does not cross an aggregate or a LIMIT).
  @typep source :: SQLJoin.source()

  @spec execute_select(
          SQLParser.parsed_query(),
          fetch(),
          %{binary() => source()},
          %{binary() => term()},
          kinds_mode()
        ) :: [map()] | {:error, term()}
  defp execute_select(query, fetch, sources, params, kinds) do
    case select(query, fetch, sources, params, kinds, true) do
      {:ok, rows, _relations} -> response_rows(rows, query)
      {:error, _reason} = error -> error
    end
  end

  # The rows of a `SELECT *` are the points' own, and `point_to_row/2` has
  # written their `UInt64`s as the response carries them.
  @spec response_rows([map()], SQLParser.parsed_query()) :: [map()]
  defp response_rows(rows, query),
    do: if(SQLSchema.star?(query), do: rows, else: Enum.map(rows, &response_row/1))

  # The row as the response carries it: a `UInt64` and a decimal as the
  # number the engine writes, an infinity or a NaN as the `null` that is
  # there.
  @spec response_row(map()) :: map()
  defp response_row(row) do
    if row |> Map.values() |> convertible?(),
      do: Map.new(row, fn {key, value} -> {key, response_value(value)} end),
      else: row
  end

  # Whether a value the response writes differently is among them: a tuple
  # (a `UInt64`, a decimal, a narrow integer), an infinity or a NaN, or a map.
  @spec convertible?([term()]) :: boolean()
  defp convertible?([]), do: false

  defp convertible?([value | _rest])
       when is_tuple(value) or value === :inf or value === :neg_inf or value === :nan or
              (is_map(value) and not is_struct(value)),
       do: true

  defp convertible?([_value | rest]), do: convertible?(rest)

  @spec response_value(term()) :: term()
  defp response_value(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, inner} -> {key, SQLNumber.row_value(inner)} end)

  defp response_value(value), do: SQLNumber.row_value(value)

  # The rows, with the relations they were read from (after any join, before
  # WHERE): a CTE has the schema of its source, not of the rows it kept. The
  # engine finds a missing table or column first, then the placeholders
  # without a value, then the type errors, then what its optimizer finds
  # folding a constant (a `time` string it cannot read, a negative LIMIT, a
  # cast that cannot be performed),
  # and last, planning the scan, a `WHERE` that leaves no instant of `time`.
  @spec select(
          SQLParser.parsed_query(),
          fetch(),
          %{binary() => source()},
          %{binary() => term()},
          kinds_mode(),
          boolean()
        ) :: {:ok, [map()], [SQLSchema.relation()]} | {:error, term()}
  defp select(%{measurement: m} = query, fetch, sources, params, kinds, final?) do
    unsigned? = unsigned_columns(query, sources, kinds)
    fetch_source = &fetch_source(fetch, &1, sources)

    with {:ok, source} <- source(fetch, m, sources),
         {:ok, joined, relations} <- SQLJoin.cross_join(source, query, fetch_source),
         :ok <- SQLClauses.unreadable_order(query.order_by),
         :ok <- SQLSchema.check(relations, query),
         {:ok, query} <- SQLSchema.resolve_ordinals(query, relations),
         :ok <- plan_error(query),
         {:ok, bound} <- SQLParser.bind(query, params),
         typed = SQLTyping.retype(bound, unsigned?),
         :ok <- SQLPlan.check(joined, typed, unsigned?),
         :ok <- SQLGrouping.check(typed),
         :ok <- SQLTime.first_invalid(typed.where),
         :ok <- limit_error(typed),
         :ok <- SQLFold.check(typed),
         simplified = SQLSimplify.apply(typed),
         :ok <- SQLRange.check_time(simplified, source.pushdown),
         :ok <- check_value_range(simplified, joined, sources, kinds, unsigned?) do
      {:ok, rows(joined, simplified, final?), relations}
    else
      :error -> {:error, table_not_found(m)}
      {:error, _reason} = error -> error
    end
  catch
    # Errors only discoverable per value (a LIKE over a number, a CAST that
    # cannot be performed) are thrown from the evaluator and become the
    # engine's error here.
    {:query_error, error} -> {:error, error}
  end

  # A `LIMIT 0` plans no scan (verified: `WHERE v > 1 / 0 LIMIT 0` is `[]`,
  # where without it the connection closes), so no row is evaluated.
  @spec rows([point()], SQLParser.parsed_query(), boolean()) :: [map()]
  defp rows(_joined, %{limit: 0}, _final?), do: []

  defp rows(joined, query, final?),
    do: query_rows(filter(joined, query.where), ordered(query), final?)

  @spec plan_error(SQLParser.parsed_query()) :: :ok | {:error, SQLError.t()}
  defp plan_error(%{plan_error: nil}), do: :ok
  defp plan_error(%{plan_error: error}), do: {:error, error}

  @spec limit_error(SQLParser.parsed_query()) :: :ok | {:error, SQLError.t()}
  defp limit_error(%{limit_error: nil}), do: :ok
  defp limit_error(%{limit_error: error}), do: {:error, error}

  # Which columns are `UInt64`: those the store registered as unsigned, in the
  # tables the query reads (not in a CTE, whose values carry their types).
  @spec unsigned_columns(SQLParser.parsed_query(), %{binary() => source()}, kinds_mode()) ::
          (binary() -> boolean())
  defp unsigned_columns(_query, _sources, kinds) when kinds in [nil, :unchecked],
    do: fn _column -> false end

  defp unsigned_columns(query, sources, kinds) do
    kind = column_kind(query, sources, kinds)
    fn column -> kind.(column) == @uinteger_kind end
  end

  # A `WHERE` whose top-level comparisons leave a numeric column no value
  # fails in the engine's interval analysis (see `SQLBounds`).
  @spec check_value_range(
          SQLParser.parsed_query(),
          [point()],
          %{binary() => source()},
          kinds_mode(),
          (binary() -> boolean())
        ) :: :ok | {:error, SQLError.t()}
  defp check_value_range(_query, _points, _sources, :unchecked, _unsigned?), do: :ok

  defp check_value_range(query, points, sources, kinds, unsigned?) do
    integer_type = fn column -> if unsigned?.(column), do: :uint64, else: :int64 end

    SQLRange.check_values(
      query,
      points,
      column_kind(query, sources, kinds),
      integer_type,
      is_map_key(sources, query.measurement)
    )
  end

  # A column's registered kind in the tables the query reads (not in a CTE,
  # whose columns the store does not know).
  @spec column_kind(SQLParser.parsed_query(), %{binary() => source()}, kinds_mode()) ::
          (binary() -> binary() | nil)
  defp column_kind(_query, _sources, kinds) when kinds in [nil, :unchecked],
    do: fn _column -> nil end

  defp column_kind(query, sources, kinds) do
    tables = read_tables(query, sources)
    fn column -> Enum.find_value(tables, &kinds.(&1, column)) end
  end

  @spec read_tables(SQLParser.parsed_query(), %{binary() => source()}) :: [binary()]
  defp read_tables(query, sources) do
    [query.measurement | List.wrap(query.cross_join && elem(query.cross_join, 0))]
    |> Enum.reject(&is_map_key(sources, &1))
  end

  # The engine drops an `ORDER BY` term that is a constant (`ORDER BY 1 / 0`
  # fails nothing, verified): it orders no row.
  @spec ordered(SQLParser.parsed_query()) :: SQLParser.parsed_query()
  defp ordered(query) do
    order_by =
      query.order_by
      |> Enum.map(fn
        {{:expr, expr}, direction} -> {{:expr, output_items(expr, query)}, direction}
        column -> column
      end)
      |> Enum.reject(fn
        {{:expr, expr}, _direction} -> SQLExpr.columns(expr) == []
        _column -> false
      end)

    %{query | order_by: order_by}
  end

  # A name in an `ORDER BY` expression that is a select item's output name is
  # that item, not a column of the table of the same name (verified:
  # `SELECT i AS j ... ORDER BY j + 1` sorts by `i + 1`).
  @spec output_items(SQLExpr.t(), SQLParser.parsed_query()) :: SQLExpr.t()
  defp output_items({:field, name} = field, %{projection_columns: projection})
       when is_binary(name) and is_list(projection) do
    case List.keyfind(projection, name, 1) do
      {source, ^name} when is_binary(source) -> {:field, source}
      {expr, ^name} -> expr
      nil -> field
    end
  end

  defp output_items(expr, query), do: SQLExpr.map_children(expr, &output_items(&1, query))

  @spec filter([point()], [SQLParser.where_node()]) :: [point()]
  defp filter(points, conjunction), do: SQLCondition.filter(points, conjunction)

  @spec query_rows([point()], SQLParser.parsed_query(), boolean()) :: [map()]
  defp query_rows(points, query, final?) do
    cond do
      query.distinct_columns ->
        execute_distinct_query(points, query)

      query.select_columns ->
        execute_aggregate_query(points, query)

      query.projection_columns ->
        execute_projection_query(points, query)

      true ->
        points
        |> apply_order_by(query.order_by)
        |> distinct_on(query.distinct_on, & &1)
        |> apply_limit(query.limit, query.offset)
        |> Enum.map(&point_to_row(&1, final?))
    end
  end

  @spec source(fetch(), binary(), %{binary() => source()}) :: {:ok, source()} | :error
  defp source(fetch, measurement, sources) do
    case Map.fetch(sources, measurement) do
      {:ok, cte} ->
        {:ok, cte}

      :error ->
        with {:ok, points} <- fetch.(measurement),
             do: {:ok, %{points: points, columns: nil, pushdown: true}}
    end
  end

  @spec fetch_source(fetch(), binary(), %{binary() => source()}) ::
          {:ok, source()} | {:error, term()}
  defp fetch_source(fetch, name, sources) do
    case source(fetch, name, sources) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, table_not_found(name)}
    end
  end

  # A CTE's rows, read back as the points the next query sees: its columns
  # are those it declared, whether or not any row has a value for them. A
  # column that passes an unsigned column through is tagged `UInt64` again.
  @spec cte_source(
          binary(),
          [map()],
          [SQLSchema.relation()],
          SQLParser.parsed_query(),
          %{binary() => source()},
          kinds_mode()
        ) :: source()
  defp cte_source(name, rows, relations, query, sources, kinds) do
    columns = SQLSchema.output_columns(query, relations)
    unsigned = SQLTyping.unsigned_outputs(query, columns, unsigned_columns(query, sources, kinds))

    below =
      case Map.fetch(sources, query.measurement) do
        {:ok, %{pushdown: pushdown}} -> pushdown
        :error -> true
      end

    %{
      points: rows_to_points(name, rows, columns || [], unsigned),
      columns: columns,
      pushdown:
        below and is_nil(query.select_columns) and is_nil(query.limit) and
          is_nil(query.offset)
    }
  end

  # A CTE's output rows, read back as points: every column but a timestamp
  # `time` is a field (tag/field is a storage distinction the next query
  # cannot see), and a column the row has no value for is a null field. A
  # `time` that is not a timestamp (`SELECT s AS time`) is a field too.
  @spec rows_to_points(binary(), [map()], [binary()], MapSet.t(binary())) :: [point()]
  defp rows_to_points(name, rows, columns, unsigned) do
    nulls = for column <- columns, column != "time", into: %{}, do: {column, nil}

    Enum.map(rows, fn row ->
      {timestamp, fields} =
        case row do
          %{"time" => %DateTime{} = time} ->
            {DateTime.to_unix(time, :nanosecond), Map.delete(row, "time")}

          _no_timestamp ->
            {nil, row}
        end

      fields = unsigned |> Enum.reduce(fields, &tag_unsigned/2)
      %{measurement: name, tags: %{}, fields: Map.merge(nulls, fields), timestamp: timestamp}
    end)
  end

  @spec tag_unsigned(binary(), map()) :: map()
  defp tag_unsigned(column, fields) do
    case fields do
      %{^column => value} when is_integer(value) -> Map.put(fields, column, {:u, value})
      _no_integer -> fields
    end
  end

  # The same shape and wording the real engine returns for a missing table
  # (HTTP 400, planning error), so consumer code matching `%{status: 400}`
  # can be exercised against the double.
  @spec table_not_found(binary()) :: %{status: 400, body: binary()}
  defp table_not_found(measurement) do
    %{
      status: 400,
      body: "Error during planning: table 'public.iox.#{measurement}' not found"
    }
  end

  # SELECT col, expr AS alias, ...: rows are projected first so ORDER BY can
  # name a projected alias (`ORDER BY mid DESC`) as well as any source column.
  @spec execute_projection_query([point()], SQLParser.parsed_query()) :: [map()]
  defp execute_projection_query(points, query) do
    projection = query.projection_columns

    points
    |> Enum.map(fn point -> {point, project_point(point, projection)} end)
    |> order_projected(query.order_by, projection)
    |> distinct_on(query.distinct_on, fn {point, _row} -> point end)
    |> apply_limit(query.limit, query.offset)
    |> Enum.map(fn {_point, row} -> row end)
  end

  # DISTINCT ON: the first row per distinct key, in the order ORDER BY left
  # them; rows missing a key column share the null key. The key is read
  # from the source point, so an ON column need not be selected.
  @spec distinct_on([item], [binary()] | nil, (item -> point())) :: [item] when item: term()
  defp distinct_on(items, nil, _point_of), do: items

  defp distinct_on(items, columns, point_of) do
    {kept, _seen} =
      Enum.reduce(items, {[], MapSet.new()}, fn item, {kept, seen} ->
        point = point_of.(item)
        key = Enum.map(columns, &SQLRow.sort_value(point, &1))

        if MapSet.member?(seen, key),
          do: {kept, seen},
          else: {[item | kept], MapSet.put(seen, key)}
      end)

    Enum.reverse(kept)
  end

  @spec order_projected([{point(), map()}], SQLParser.order_by(), [SQLParser.projection()]) ::
          [{point(), map()}]
  defp order_projected(pairs, [], _projection), do: pairs

  # A key that is the point's own time (`time`, or an alias of it) sorts on
  # the stored nanoseconds: the projected DateTime has microsecond
  # precision, so points less than a microsecond apart would tie and keep
  # insertion order, where the engine orders them by time (verified).
  defp order_projected(pairs, order_by, projection) do
    outputs = Enum.map(projection, fn {_source, output} -> output end)

    keys =
      Enum.map(order_by, fn
        {{:expr, expr}, direction} ->
          {fn {point, _row} -> SQLEval.eval(expr, point) end, direction}

        {column, direction} ->
          {projected_key(column, projection, outputs), direction}
      end)

    SQLSort.sort_by_keys(pairs, keys)
  end

  @spec projected_key(binary(), [SQLParser.projection()], [binary()]) ::
          ({point(), map()} -> term())
  defp projected_key(column, projection, outputs) do
    cond do
      {"time", column} in projection or (column == "time" and column not in outputs) ->
        fn {point, _row} -> SQLRow.sort_value(point, "time") end

      column in outputs ->
        fn {_point, row} -> Map.get(row, column) end

      true ->
        fn {point, _row} -> SQLRow.sort_value(point, column) end
    end
  end

  @spec project_point(point(), [SQLParser.projection()]) :: map()
  defp project_point(point, projection) do
    Enum.reduce(projection, %{}, fn
      {source, output}, acc when is_binary(source) ->
        put_column(acc, output, SQLRow.column_value(point, source))

      {expr, output}, acc ->
        put_column(acc, output, SQLEval.eval(expr, point))
    end)
  end

  # InfluxDB 3 omits a null column from the row entirely (verified on both
  # the JSON and JSONL formats), so a nil never becomes a key here.
  @spec put_column(map(), binary(), term()) :: map()
  defp put_column(row, _key, nil), do: row
  defp put_column(row, key, value), do: Map.put(row, key, value)

  # SELECT DISTINCT a[, b ...]: one row per distinct combination, sorted
  # unless ORDER BY (one of the selected columns) says otherwise. A
  # combination whose columns are all null is a row too (`%{}`), as the
  # engine returns it (verified).
  @spec execute_distinct_query([point()], SQLParser.parsed_query()) :: [map()]
  defp execute_distinct_query(points, query) do
    columns = query.distinct_columns

    points
    |> Enum.map(fn point -> Enum.map(columns, &SQLRow.column_value(point, &1)) end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn values ->
      columns
      |> Enum.zip(values)
      |> Enum.reduce(%{}, fn {column, value}, row -> put_column(row, column, value) end)
    end)
    |> apply_order_by_rows(query.order_by, nil)
    |> apply_limit(query.limit, query.offset)
  end

  @spec execute_aggregate_query([point()], SQLParser.parsed_query()) :: [map()]
  defp execute_aggregate_query(points, %{group_by_interval: nil, group_by_columns: nil} = query) do
    # Scalar aggregate: all filtered points form a single bucket. Always
    # produce one row, even when no points matched (so COUNT returns 0).
    [SQLAggregate.reduce_columns(query.select_columns, points, nil)]
  end

  # One group per (DATE_BIN bucket, grouping-column values) — either part
  # may be absent. `GROUP BY DATE_BIN(...), host` gives a row per bucket per
  # host, as the engine does (verified).
  defp execute_aggregate_query(points, query) do
    interval_ns = query.group_by_interval
    columns = query.group_by_columns || []
    time_alias = if interval_ns, do: find_time_bucket_alias(query.select_columns)

    points
    |> Enum.group_by(fn point ->
      {bucket_start(point, interval_ns), Enum.map(columns, &SQLRow.sort_value(point, &1))}
    end)
    |> Enum.map(fn {{bucket_ts, _values}, bucket_points} ->
      SQLAggregate.reduce_columns(query.select_columns, bucket_points, bucket_ts)
    end)
    |> apply_order_by_rows(query.order_by, time_alias)
    |> apply_limit(query.limit, query.offset)
  end

  # The start of the point's DATE_BIN bucket (nil when there is no bucket).
  # Times before the epoch floor (-5 ns is in the bucket that starts before
  # 1970). An interval of zero is the engine closing the connection on the
  # first row it bins (verified); with no rows it answers none.
  @spec bucket_start(point(), non_neg_integer() | nil) :: integer() | nil
  defp bucket_start(_point, nil), do: nil
  defp bucket_start(_point, 0), do: throw({:query_error, SQLError.closed()})
  defp bucket_start(%{timestamp: nil}, _interval_ns), do: 0

  defp bucket_start(%{timestamp: ts}, interval_ns),
    do: Integer.floor_div(ts, interval_ns) * interval_ns

  # Find the alias of the time_bucket column from select_columns
  @spec find_time_bucket_alias([SQLParser.select_column()]) :: binary() | nil
  defp find_time_bucket_alias(columns) do
    Enum.find_value(columns, fn
      {:time_bucket, alias_name} -> alias_name
      _other -> nil
    end)
  end

  # Order aggregate result rows by any output column. `ORDER BY time`
  # on a DATE_BIN query refers to the bucket, whatever its alias.
  @spec apply_order_by_rows([map()], SQLParser.order_by(), binary() | nil) :: [map()]
  defp apply_order_by_rows(rows, [], _time_alias), do: rows

  defp apply_order_by_rows(rows, order_by, time_alias) do
    keys =
      Enum.map(order_by, fn {column, direction} ->
        key = if column == "time" and time_alias, do: time_alias, else: column
        {&Map.get(&1, key), direction}
      end)

    SQLSort.sort_by_keys(rows, keys)
  end

  # ORDER BY any column on raw rows: `time` sorts by timestamp, anything
  # else by the tag/field value (nil first, as the real engine sorts nulls).
  @spec apply_order_by([point()], SQLParser.order_by()) :: [point()]
  defp apply_order_by(points, []), do: points

  # `time` sorts on the stored nanoseconds, as in `order_projected/3`.
  defp apply_order_by(points, order_by) do
    keys =
      Enum.map(order_by, fn
        {{:expr, expr}, direction} -> {&SQLEval.eval(expr, &1), direction}
        {column, direction} -> {&SQLRow.sort_value(&1, column), direction}
      end)

    SQLSort.sort_by_keys(points, keys)
  end

  # OFFSET skips first, then LIMIT takes, whichever order they were written.
  @spec apply_limit([term()], non_neg_integer() | nil, non_neg_integer() | nil) :: [term()]
  defp apply_limit(items, limit, offset) do
    items
    |> Enum.drop(offset || 0)
    |> then(fn skipped -> if limit, do: Enum.take(skipped, limit), else: skipped end)
  end

  @spec point_to_row(point(), boolean()) :: map()
  # `time` is a DateTime (microsecond precision), as on the HTTP and Flight
  # transports, so consumer code sees one type whichever client is configured.
  defp point_to_row(point, final?) do
    row =
      for {key, value} <- Map.merge(point.fields, point.tags),
          value != nil,
          into: %{},
          do:
            {key,
             case value do
               {:u, number} when final? -> number
               _other -> value
             end}

    put_column(row, "time", SQLRow.column_value(point, "time"))
  end
end
