defmodule InfluxElixir.Client.Local.SQLExecutor do
  @moduledoc """
  Executes a parsed SQL query for `InfluxElixir.Client.Local`.

  Takes the `t:InfluxElixir.Client.Local.SQLParser.parsed_query/0` the parser
  produced and a function that fetches a measurement's points, and returns
  rows in the shape InfluxDB 3's JSON responses have: string keys, `time` as a
  `DateTime`, null columns omitted. Every rule the double enforces about what
  the engine returns — null omission, DataFusion's comparison and cast
  semantics, schema errors for unknown columns, the failure shape of a cast
  that cannot be performed — lives here; storage, profiles and the other query
  languages stay in `Client.Local`.

  Pure over the points it is given: no ETS, no connection state.
  """

  alias InfluxElixir.Client.Local.{LineProtocolParser, SQLParser}

  @typedoc "A stored point, as `InfluxElixir.Client.Local` keeps it."
  @type point :: LineProtocolParser.point()

  @typedoc "Fetches a measurement's points, or `:error` when there is no such measurement."
  @type fetch :: (binary() -> {:ok, [point()]} | :error)

  @doc false
  @spec nanoseconds_to_datetime(integer() | nil) :: DateTime.t() | nil
  def nanoseconds_to_datetime(nil), do: nil
  def nanoseconds_to_datetime(ns), do: DateTime.from_unix!(ns, :nanosecond)

  # CTEs run first, in order, each over the store or an earlier CTE; their
  # rows become the points the next query reads (a CTE shadows a measurement
  # of the same name, as in SQL).
  @doc """
  Runs a parsed query. `fetch` returns a measurement's points, or `:error`
  when the measurement does not exist; CTEs shadow it by name.
  """
  @spec run(SQLParser.parsed_query(), fetch()) :: [map()] | {:error, term()}
  def run(query, fetch) do
    query.ctes
    |> Enum.reduce_while({:ok, %{}}, fn {name, cte_query}, {:ok, sources} ->
      case execute_select(cte_query, fetch, sources) do
        {:error, _reason} = error -> {:halt, error}
        rows -> {:cont, {:ok, Map.put(sources, name, rows_to_points(name, rows))}}
      end
    end)
    |> case do
      {:ok, sources} -> execute_select(query, fetch, sources)
      {:error, _reason} = error -> error
    end
  end

  @spec execute_select(SQLParser.parsed_query(), fetch(), %{binary() => [point()]}) ::
          [map()] | {:error, term()}
  defp execute_select(%{measurement: m} = query, fetch, cte_sources) do
    with {:ok, points} <- source_points(fetch, m, cte_sources),
         {:ok, joined} <- cross_join(fetch, points, query.cross_join, cte_sources),
         :ok <- check_query_columns(joined, query),
         :ok <- check_grouping_columns(query),
         {:ok, filtered} <- apply_where(joined, query.where) do
      cond do
        query.distinct_columns ->
          execute_distinct_query(filtered, query)

        query.select_columns ->
          execute_aggregate_query(filtered, query)

        query.projection_columns ->
          execute_projection_query(filtered, query)

        true ->
          filtered
          |> apply_order_by(query.order_by)
          |> apply_limit(query.limit, query.offset)
          |> Enum.map(&point_to_row/1)
      end
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

  @spec source_points(fetch(), binary(), %{binary() => [point()]}) ::
          {:ok, [point()]} | :error
  defp source_points(fetch, measurement, cte_sources) do
    case Map.fetch(cte_sources, measurement) do
      {:ok, points} -> {:ok, points}
      :error -> fetch.(measurement)
    end
  end

  # `FROM w CROSS JOIN ref`: every left point paired with every right point,
  # the right side's columns merged in as fields. Qualifiers were dropped
  # at parse time, so a column present on both sides cannot be told apart
  # any more; the engine refuses an unqualified ambiguous reference and the
  # double refuses the join. A right side that carries `time` is a
  # collision too. Rows are the left side's measurement and timestamp.
  @spec cross_join(fetch(), [point()], {binary(), [binary()]} | nil, %{binary() => [point()]}) ::
          {:ok, [point()]} | {:error, term()}
  defp cross_join(_fetch, points, nil, _cte_sources), do: {:ok, points}

  defp cross_join(fetch, points, {right_name, _aliases}, cte_sources) do
    with {:ok, right_points} <- fetch_source(fetch, right_name, cte_sources),
         :ok <- check_join_collisions(points, right_points, right_name) do
      {:ok,
       for left <- points, right <- right_points do
         %{
           left
           | tags: Map.merge(left.tags, right.tags),
             fields: Map.merge(left.fields, right.fields)
         }
       end}
    end
  end

  @spec fetch_source(fetch(), binary(), %{binary() => [point()]}) ::
          {:ok, [point()]} | {:error, term()}
  defp fetch_source(fetch, name, cte_sources) do
    case source_points(fetch, name, cte_sources) do
      {:ok, points} -> {:ok, points}
      :error -> {:error, table_not_found(name)}
    end
  end

  @spec check_join_collisions([point()], [point()], binary()) :: :ok | {:error, term()}
  defp check_join_collisions(left, right, right_name) do
    right_columns = point_columns(right) |> maybe_add_time(right)
    shared = MapSet.intersection(point_columns(left) |> maybe_add_time(left), right_columns)

    if MapSet.size(shared) == 0 do
      :ok
    else
      {:error,
       %{
         status: 500,
         body:
           "Schema error: Ambiguous reference to unqualified field " <>
             "#{Enum.join(Enum.sort(shared), ", ")} (present on both sides of CROSS JOIN #{right_name})"
       }}
    end
  end

  @spec point_columns([point()]) :: MapSet.t(binary())
  defp point_columns(points) do
    Enum.reduce(points, MapSet.new(), fn point, acc ->
      MapSet.union(acc, point_columns_of(point))
    end)
  end

  @spec point_columns_of(point()) :: MapSet.t(binary())
  defp point_columns_of(point) do
    MapSet.new(Map.keys(point.tags) ++ Map.keys(point.fields))
  end

  @spec maybe_add_time(MapSet.t(binary()), [point()]) :: MapSet.t(binary())
  defp maybe_add_time(columns, points) do
    if Enum.any?(points, &(not is_nil(&1.timestamp))),
      do: MapSet.put(columns, "time"),
      else: columns
  end

  # A column the query names that no row has — in SELECT, an aggregate,
  # WHERE, GROUP BY, ORDER BY or DISTINCT — is the engine's schema error
  # ("No field named prod"), not an empty or unsorted result. The usual
  # cause is a typo or a forgotten pair of quotes around a string literal.
  # With no rows the schema is unknown, so nothing is checked.
  @spec check_query_columns([point()], SQLParser.parsed_query()) :: :ok | {:error, term()}
  defp check_query_columns([], _query), do: :ok

  defp check_query_columns([first | _rest] = points, query) do
    # Almost every query names only columns the first row has, so that row
    # answers first; the full scan (every row's columns) runs only when a
    # name is missing there, which is also when the error message needs it.
    first_row_columns = first |> point_columns_of() |> MapSet.put("time")

    case Enum.reject(referenced_columns(query), &MapSet.member?(first_row_columns, &1)) do
      [] -> :ok
      candidates -> check_against_all_rows(points, candidates)
    end
  end

  @spec check_against_all_rows([point()], [binary()]) :: :ok | {:error, term()}
  defp check_against_all_rows(points, candidates) do
    known = points |> point_columns() |> MapSet.put("time")

    case Enum.reject(candidates, &MapSet.member?(known, &1)) do
      [] ->
        :ok

      [missing | _rest] ->
        {:error,
         %{
           status: 500,
           body:
             "Schema error: No field named #{missing}. Valid fields are " <>
               Enum.join(Enum.sort(known), ", ") <> "."
         }}
    end
  end

  # A projected plain column in an aggregate query must be grouped: the
  # engine fails planning otherwise ("must appear in the GROUP BY clause or
  # must be part of an aggregate function"). Before, the double sampled the
  # group's first row, which is a wrong answer, not a refusal.
  @spec check_grouping_columns(SQLParser.parsed_query()) :: :ok | {:error, term()}
  defp check_grouping_columns(%{select_columns: nil}), do: :ok

  defp check_grouping_columns(query) do
    grouped = query.group_by_columns || []

    ungrouped =
      Enum.find_value(query.select_columns, fn
        {:grouping_column, source, _alias} -> if source in grouped, do: nil, else: source
        _other -> nil
      end)

    case ungrouped do
      nil ->
        :ok

      column ->
        {:error,
         %{
           status: 400,
           body:
             "Error during planning: Column in SELECT must be in GROUP BY or an aggregate " <>
               "function: column \"#{column}\" must appear in the GROUP BY clause or must be " <>
               "part of an aggregate function"
         }}
    end
  end

  # Every source column the query refers to. ORDER BY may name an output
  # alias instead, which is not a source column.
  @spec referenced_columns(SQLParser.parsed_query()) :: [binary()]
  defp referenced_columns(query) do
    aliases = output_aliases(query)

    order_by_refs =
      Enum.flat_map(query.order_by, fn
        {{:expr, expr}, _direction} -> expr_fields(expr)
        {column, _direction} -> if column in aliases, do: [], else: [column]
      end)

    Enum.flat_map(query.projection_columns || [], &projection_refs/1) ++
      Enum.flat_map(query.select_columns || [], &select_column_refs/1) ++
      where_refs(query.where) ++
      (query.group_by_columns || []) ++
      (query.distinct_columns || []) ++
      order_by_refs
  end

  @spec output_aliases(SQLParser.parsed_query()) :: [binary()]
  defp output_aliases(query) do
    Enum.map(query.projection_columns || [], fn {_source, output} -> output end) ++
      Enum.map(query.select_columns || [], &elem(&1, tuple_size(&1) - 1)) ++
      (query.distinct_columns || [])
  end

  @spec projection_refs(SQLParser.projection()) :: [binary()]
  defp projection_refs({source, _output}) when is_binary(source), do: [source]
  defp projection_refs({expr, _output}), do: expr_fields(expr)

  @spec select_column_refs(SQLParser.select_column()) :: [binary()]
  defp select_column_refs({:time_bucket, _alias}), do: ["time"]
  defp select_column_refs({:aggregate, _agg, expr, _alias}), do: expr_fields(expr)
  defp select_column_refs({:count_star, _alias}), do: []
  defp select_column_refs({:count_distinct, column, _alias}), do: [column]

  defp select_column_refs({:ordered_aggregate, _agg, field, ordering, _alias}),
    do: [field, ordering]

  defp select_column_refs({:selector, _kind, field, ordering, _access, _alias}),
    do: [field, ordering]

  defp select_column_refs({:grouping_column, source, _alias}), do: [source]
  defp select_column_refs({:constant, _value, _alias}), do: []

  @spec where_refs([SQLParser.where_node()]) :: [binary()]
  defp where_refs(nodes) do
    Enum.flat_map(nodes, fn
      {:or, branches} -> Enum.flat_map(branches, &where_refs/1)
      {:not, conjunction} -> where_refs(conjunction)
      {_op, left, right} when is_binary(left) -> [left | expr_fields(right)]
      {_op, left, right} -> expr_fields(left) ++ expr_fields(right)
    end)
  end

  @spec expr_fields(term()) :: [binary()]
  defp expr_fields({:expr, expr}), do: expr_fields(expr)
  defp expr_fields({:field, name}), do: [name]
  defp expr_fields({:op, _op, left, right}), do: expr_fields(left) ++ expr_fields(right)
  defp expr_fields({:cast, inner, _type}), do: expr_fields(inner)
  defp expr_fields(items) when is_list(items), do: Enum.flat_map(items, &expr_fields/1)
  defp expr_fields(_other), do: []

  # A CTE's output rows, read back as points: every column but `time` is a
  # field (tag/field is a storage distinction the next query cannot see).
  @spec rows_to_points(binary(), [map()]) :: [point()]
  defp rows_to_points(name, rows) do
    Enum.map(rows, fn row ->
      timestamp =
        case Map.get(row, "time") do
          %DateTime{} = dt -> DateTime.to_unix(dt, :nanosecond)
          nil -> nil
        end

      %{measurement: name, tags: %{}, fields: Map.delete(row, "time"), timestamp: timestamp}
    end)
  end

  # SELECT col, expr AS alias, ...: rows are projected first so ORDER BY can
  # name a projected alias (`ORDER BY mid DESC`) as well as any source column.
  @spec execute_projection_query([point()], SQLParser.parsed_query()) :: [map()]
  defp execute_projection_query(points, query) do
    projection = query.projection_columns

    points
    |> Enum.map(fn point -> {point, project_point(point, projection)} end)
    |> order_projected(query.order_by, projection)
    |> apply_limit(query.limit, query.offset)
    |> Enum.map(fn {_point, row} -> row end)
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
          {fn {point, _row} -> eval_expr(expr, point) end, direction}

        {column, direction} ->
          cond do
            {"time", column} in projection or (column == "time" and column not in outputs) ->
              {fn {point, _row} -> point.timestamp end, direction}

            column in outputs ->
              {fn {_point, row} -> Map.get(row, column) end, direction}

            true ->
              {fn {point, _row} -> point_value(point, column) end, direction}
          end
      end)

    sort_by_keys(pairs, keys)
  end

  # Stable multi-key sort with a direction per key; `DateTime`s compare
  # chronologically and nil (an omitted column) sorts first.
  @spec sort_by_keys([term()], [{(term() -> term()), :asc | :desc}]) :: [term()]
  defp sort_by_keys(items, keys) do
    Enum.sort(items, fn a, b -> keys_before?(a, b, keys) end)
  end

  @spec keys_before?(term(), term(), [{(term() -> term()), :asc | :desc}]) :: boolean()
  defp keys_before?(_a, _b, []), do: true

  defp keys_before?(a, b, [{key_fn, direction} | rest]) do
    x = key_fn.(a)
    y = key_fn.(b)

    cond do
      value_order(x, y) and value_order(y, x) -> keys_before?(a, b, rest)
      direction == :asc -> value_order(x, y)
      true -> value_order(y, x)
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

  @spec project_point(point(), [SQLParser.projection()]) :: map()
  defp project_point(point, projection) do
    Enum.reduce(projection, %{}, fn
      {source, output}, acc when is_binary(source) ->
        put_column(acc, output, point_value(point, source))

      {expr, output}, acc ->
        put_column(acc, output, eval_expr(expr, point))
    end)
  end

  # InfluxDB 3 omits a null column from the row entirely (verified on both
  # the JSON and JSONL formats), so a nil never becomes a key here.
  @spec put_column(map(), binary(), term()) :: map()
  defp put_column(row, _key, nil), do: row
  defp put_column(row, key, value), do: Map.put(row, key, value)

  # SELECT DISTINCT a[, b ...]: one row per distinct combination, sorted
  # unless ORDER BY (one of the selected columns) says otherwise. A row
  # whose columns are all null is dropped, as the real engine does.
  @spec execute_distinct_query([point()], SQLParser.parsed_query()) :: [map()]
  defp execute_distinct_query(points, query) do
    columns = query.distinct_columns

    points
    |> Enum.map(fn point -> Enum.map(columns, &point_value(point, &1)) end)
    |> Enum.reject(&Enum.all?(&1, fn value -> is_nil(value) end))
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

  @spec point_value(point(), binary()) :: term()
  defp point_value(point, "time"), do: nanoseconds_to_datetime(point.timestamp)

  defp point_value(point, column),
    do: Map.get(point.tags, column) || Map.get(point.fields, column)

  @spec execute_aggregate_query([point()], SQLParser.parsed_query()) :: [map()]
  defp execute_aggregate_query(points, %{group_by_columns: cols} = query)
       when is_list(cols) and cols != [] do
    # GROUP BY <col, ...>: bucket points by the tuple of grouping-column
    # values (mirroring how real InfluxDB v3 partitions by tags/fields).
    points
    |> bucket_by_columns(cols)
    |> aggregate_per_column_bucket(query.select_columns)
    |> apply_order_by_rows(query.order_by, nil)
    |> apply_limit(query.limit, query.offset)
  end

  defp execute_aggregate_query(points, %{group_by_interval: nil} = query) do
    # Scalar aggregate: all filtered points form a single bucket. Always
    # produce one row, even when no points matched (so COUNT returns 0).
    [aggregate_one_bucket(points, query.select_columns)]
  end

  defp execute_aggregate_query(points, query) do
    interval_ns = query.group_by_interval

    time_alias = find_time_bucket_alias(query.select_columns)

    points
    |> bucket_by_interval(interval_ns)
    |> aggregate_per_bucket(query.select_columns)
    |> apply_order_by_rows(query.order_by, time_alias)
    |> apply_limit(query.limit, query.offset)
  end

  # Group points by the tuple of values for the GROUP BY columns. Each
  # column is resolved against tags first, then fields.
  @spec bucket_by_columns([point()], [binary()]) :: %{[term()] => [point()]}
  defp bucket_by_columns(points, columns) do
    Enum.group_by(points, fn point ->
      Enum.map(columns, fn col ->
        Map.get(point.tags, col) || Map.get(point.fields, col)
      end)
    end)
  end

  @spec aggregate_per_column_bucket(
          %{[term()] => [point()]},
          [SQLParser.select_column()]
        ) :: [map()]
  defp aggregate_per_column_bucket(buckets, columns) do
    Enum.map(buckets, fn {_key, bucket_points} ->
      reduce_aggregate_columns(columns, bucket_points, nil)
    end)
  end

  # Group points into buckets by flooring timestamp to interval boundary
  @spec bucket_by_interval([point()], pos_integer()) :: %{
          integer() => [point()]
        }
  defp bucket_by_interval(points, interval_ns) do
    Enum.group_by(points, fn point ->
      case point.timestamp do
        nil -> 0
        ts -> div(ts, interval_ns) * interval_ns
      end
    end)
  end

  # Compute aggregates for each bucket and return result rows
  @spec aggregate_per_bucket(
          %{integer() => [point()]},
          [SQLParser.select_column()]
        ) :: [map()]
  defp aggregate_per_bucket(buckets, columns) do
    Enum.map(buckets, fn {bucket_ts, bucket_points} ->
      reduce_aggregate_columns(columns, bucket_points, bucket_ts)
    end)
  end

  # Compute aggregates over a single (un-bucketed) set of points. Used for
  # scalar aggregates (no GROUP BY DATE_BIN) — always yields exactly one row.
  @spec aggregate_one_bucket([point()], [SQLParser.select_column()]) :: map()
  defp aggregate_one_bucket(points, columns) do
    reduce_aggregate_columns(columns, points, nil)
  end

  @spec reduce_aggregate_columns(
          [SQLParser.select_column()],
          [point()],
          integer() | nil
        ) :: map()
  # Null results (an aggregate over no values, a sample statistic of one
  # value, a missing grouping value) are omitted from the row, as the real
  # engine does; COUNT is 0, never null.
  defp reduce_aggregate_columns(columns, points, bucket_ts) do
    Enum.reduce(columns, %{}, fn
      {:time_bucket, alias_name}, row ->
        put_column(row, alias_name, nanoseconds_to_datetime(bucket_ts))

      {:grouping_column, source, alias_name}, row ->
        # All points in a column-grouped bucket share the same value for
        # this column; sample from the first point.
        value =
          case points do
            [first | _rest] -> point_value(first, source)
            [] -> nil
          end

        put_column(row, alias_name, value)

      {:aggregate, agg, expr, alias_name}, row ->
        values = points |> Enum.map(&eval_expr(expr, &1)) |> Enum.reject(&is_nil/1)
        put_column(row, alias_name, compute_aggregate(agg, values))

      {:count_star, alias_name}, row ->
        # COUNT(*) — every matching row counts, regardless of field nullity.
        put_column(row, alias_name, length(points))

      {:constant, value, alias_name}, row ->
        put_column(row, alias_name, value)

      {:count_distinct, column, alias_name}, row ->
        distinct =
          points
          |> Enum.map(&point_value(&1, column))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        put_column(row, alias_name, length(distinct))

      {:ordered_aggregate, agg, field, ordering, alias_name}, row ->
        put_column(row, alias_name, compute_ordered_aggregate(agg, field, ordering, points))

      {:selector, kind, field, ordering, access, alias_name}, row ->
        put_column(row, alias_name, compute_selector(kind, field, ordering, access, points))
    end)
  end

  # Evaluates an aggregate argument for one point. A missing field or a
  # non-numeric operand makes the value null, which the aggregate skips.
  # `time` is the point's timestamp; the parser only lets it reach MIN, MAX
  # and COUNT, the aggregates DataFusion accepts over a Timestamp.
  @spec eval_expr(SQLParser.expr(), point()) :: number() | binary() | DateTime.t() | nil
  defp eval_expr({:field, name}, point), do: point_value(point, name)
  defp eval_expr({:lit, value}, _point), do: value
  defp eval_expr({:cast, inner, type}, point), do: cast(eval_expr(inner, point), type)

  defp eval_expr({:op, op, left, right}, point) do
    with l when is_number(l) <- eval_expr(left, point),
         r when is_number(r) <- eval_expr(right, point) do
      arithmetic(op, l, r)
    else
      _non_number -> nil
    end
  end

  # CAST as DataFusion performs it: text to a number only when the whole
  # string is one ("2.5" is not an integer), a float to an integer by
  # truncation, a number to text by rendering. Null stays null. A cast that
  # cannot be performed — text that is not a number, a timestamp — fails
  # the query on the engine mid-response: InfluxDB 3 Core closes the
  # connection, which `Client.HTTP` reports as a transport error, so the
  # double reports the same shape.
  @spec cast(term(), SQLParser.cast_type()) :: term()
  defp cast(nil, _type), do: nil
  defp cast(value, :integer) when is_integer(value), do: value
  defp cast(value, :integer) when is_float(value), do: trunc(value)
  defp cast(value, :float) when is_float(value), do: value
  defp cast(value, :float) when is_integer(value), do: value * 1.0
  defp cast(value, :string) when is_binary(value), do: value
  defp cast(value, :string) when is_number(value), do: to_string(value)

  defp cast(value, :integer) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _not_an_integer -> cast_failure()
    end
  end

  defp cast(value, :float) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {f, ""} -> f
      _not_a_number -> cast_failure()
    end
  end

  defp cast(_value, _type), do: cast_failure()

  @spec cast_failure() :: no_return()
  defp cast_failure, do: throw({:query_error, {:connection_error, :closed}})

  @spec arithmetic(:+ | :- | :* | :/, number(), number()) :: number() | nil
  defp arithmetic(:+, l, r), do: l + r
  defp arithmetic(:-, l, r), do: l - r
  defp arithmetic(:*, l, r), do: l * r
  # DataFusion divides two integers as integers (3 / 2 = 1), so the double
  # must not promote to float. Division by zero is null here; the real
  # engine's behaviour differs and is documented in the moduledoc.
  defp arithmetic(:/, _l, 0), do: nil
  defp arithmetic(:/, _l, +0.0), do: nil
  defp arithmetic(:/, l, r) when is_integer(l) and is_integer(r), do: div(l, r)
  defp arithmetic(:/, l, r), do: l / r

  @spec compute_aggregate(SQLParser.aggregate(), [number() | DateTime.t()]) ::
          number() | DateTime.t() | nil
  defp compute_aggregate(:count, vals), do: length(vals)
  defp compute_aggregate(_agg, []), do: nil
  defp compute_aggregate(:avg, vals), do: Enum.sum(vals) / length(vals)
  defp compute_aggregate(:sum, vals), do: Enum.sum(vals)
  # MIN/MAX also run over `time`, so the comparison must be DateTime-aware.
  defp compute_aggregate(:min, vals), do: Enum.min(vals, &value_order/2)
  defp compute_aggregate(:max, vals), do: Enum.max(vals, fn a, b -> value_order(b, a) end)
  defp compute_aggregate(:median, vals), do: median(vals)
  # Sample forms need at least two values, exactly as the real engine
  # (STDDEV of one row is null); population forms are defined for one.
  defp compute_aggregate(:var, [_one]), do: nil
  defp compute_aggregate(:stddev, [_one]), do: nil
  defp compute_aggregate(:var, vals), do: sum_of_squares(vals) / (length(vals) - 1)
  defp compute_aggregate(:stddev, vals), do: :math.sqrt(compute_aggregate(:var, vals))
  defp compute_aggregate(:var_pop, vals), do: sum_of_squares(vals) / length(vals)
  defp compute_aggregate(:stddev_pop, vals), do: :math.sqrt(compute_aggregate(:var_pop, vals))

  # DataFusion's median: the middle value, or for an even count the mean of
  # the two middle values — computed in the column's type, so two integers
  # average with integer division (median of 1 and 4 is 2, not 2.5).
  @spec median([number()]) :: number()
  defp median(vals) do
    sorted = Enum.sort(vals)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      low = Enum.at(sorted, mid - 1)
      high = Enum.at(sorted, mid)
      if is_integer(low) and is_integer(high), do: div(low + high, 2), else: (low + high) / 2
    end
  end

  @spec sum_of_squares([number()]) :: float()
  defp sum_of_squares(vals) do
    mean = Enum.sum(vals) / length(vals)
    Enum.reduce(vals, 0.0, fn v, acc -> acc + (v - mean) * (v - mean) end)
  end

  # selector_first/last pick by the ordering column, selector_min/max by the
  # field itself; `['value']` returns the field, `['time']` the row's time.
  @spec compute_selector(
          :first | :last | :min | :max,
          binary(),
          binary(),
          :value | :time,
          [point()]
        ) :: term() | nil
  defp compute_selector(kind, field, ordering, access, points) do
    candidates = Enum.reject(points, &is_nil(Map.get(&1.fields, field)))

    picked =
      case {kind, candidates} do
        {_kind, []} -> nil
        {:first, pts} -> Enum.min_by(pts, &ordering_value(&1, ordering))
        {:last, pts} -> Enum.max_by(pts, &ordering_value(&1, ordering))
        {:min, pts} -> Enum.min_by(pts, &Map.get(&1.fields, field))
        {:max, pts} -> Enum.max_by(pts, &Map.get(&1.fields, field))
      end

    case {picked, access} do
      {nil, _access} -> nil
      {point, :value} -> Map.get(point.fields, field)
      {point, :time} -> nanoseconds_to_datetime(point.timestamp)
    end
  end

  # Ordered aggregates: return the field value from the point with
  # the min (first) or max (last) ordering column value.
  @spec compute_ordered_aggregate(
          :first | :last,
          binary(),
          binary(),
          [point()]
        ) :: term() | nil
  defp compute_ordered_aggregate(_agg, _field, _ordering, []), do: nil

  # A single pass for the extreme element; sorting the whole bucket to take
  # its head was O(n log n) per aggregate column. Ties resolve to the first
  # point in scan (insertion) order, as the stable sort did.
  defp compute_ordered_aggregate(agg, field, ordering, points) do
    picked =
      case agg do
        :first -> Enum.min_by(points, &ordering_value(&1, ordering))
        :last -> Enum.max_by(points, &ordering_value(&1, ordering))
      end

    Map.get(picked.fields, field) || Map.get(picked.tags, field)
  end

  # Resolve the ordering column value from a point.
  # "time" maps to the point's timestamp; anything else is a field/tag.
  @spec ordering_value(point(), binary()) :: term()
  defp ordering_value(point, "time"), do: point.timestamp || 0

  defp ordering_value(point, col) do
    Map.get(point.fields, col) || Map.get(point.tags, col) || 0
  end

  # Find the alias of the time_bucket column from select_columns
  @spec find_time_bucket_alias([SQLParser.select_column()]) :: binary() | nil
  defp find_time_bucket_alias(columns) do
    Enum.find_value(columns, fn
      {:time_bucket, alias_name} -> alias_name
      _other -> nil
    end)
  end

  # Order aggregate result rows by any output column. `ORDER BY time` on a
  # DATE_BIN query refers to the bucket, whatever its alias.
  @spec apply_order_by_rows([map()], SQLParser.order_by(), binary() | nil) :: [map()]
  defp apply_order_by_rows(rows, [], _time_alias), do: rows

  defp apply_order_by_rows(rows, order_by, time_alias) do
    keys =
      Enum.map(order_by, fn {column, direction} ->
        key = if column == "time" and time_alias, do: time_alias, else: column
        {&Map.get(&1, key), direction}
      end)

    sort_by_keys(rows, keys)
  end

  # DateTime structs must be compared chronologically; everything else uses
  # term order (nil, an omitted column, sorts first).
  @spec value_order(term(), term()) :: boolean()
  defp value_order(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) != :gt
  defp value_order(a, b), do: a <= b

  # Per-value failures (a LIKE over a number, a CAST that cannot be
  # performed) are thrown from the evaluator and caught in execute_select/4.
  @spec apply_where([point()], [SQLParser.where_node()]) :: {:ok, [point()]}
  defp apply_where(points, []), do: {:ok, points}

  defp apply_where(points, conjunction) do
    {:ok, Enum.filter(points, &matches_all?(&1, conjunction))}
  end

  @spec matches_all?(point(), [SQLParser.where_node()]) :: boolean()
  @doc "Whether a point satisfies a parsed `WHERE` conjunction (also used by `DELETE`)."
  @spec matches_all?(point(), [SQLParser.where_node()]) :: boolean()
  def matches_all?(point, conjunction), do: Enum.all?(conjunction, &node_matches?(point, &1))

  @spec node_matches?(point(), SQLParser.where_node()) :: boolean()
  defp node_matches?(point, {:or, branches}), do: Enum.any?(branches, &matches_all?(point, &1))
  defp node_matches?(point, {:not, conjunction}), do: not matches_all?(point, conjunction)
  defp node_matches?(point, clause), do: matches_condition?(point, clause)

  @spec matches_condition?(point(), SQLParser.where_clause()) :: boolean()
  defp matches_condition?(point, {:between, "time", {low, high}}) do
    ts = point.timestamp
    not is_nil(ts) and ts >= to_nanoseconds(low) and ts <= to_nanoseconds(high)
  end

  defp matches_condition?(point, {:not_between, "time", range}),
    do: not matches_condition?(point, {:between, "time", range})

  defp matches_condition?(point, {:between, left, {low, high}}) do
    actual = left_value(point, left)
    compare(actual, :gte, low) and compare(actual, :lte, high)
  end

  defp matches_condition?(point, {:not_between, key, range}),
    do: not matches_condition?(point, {:between, key, range})

  defp matches_condition?(point, {:like, left, regex}) do
    case left_value(point, left) do
      nil -> false
      text when is_binary(text) -> Regex.match?(regex, text)
      _number -> throw({:query_error, %{status: 400, body: like_type_error(left)}})
    end
  end

  defp matches_condition?(point, {:not_like, left, regex}) do
    case left_value(point, left) do
      nil -> false
      text when is_binary(text) -> not Regex.match?(regex, text)
      _number -> throw({:query_error, %{status: 400, body: like_type_error(left)}})
    end
  end

  defp matches_condition?(point, {:in, "time", values}) do
    point_in_time_set?(point, values)
  end

  defp matches_condition?(point, {:not_in, "time", values}) do
    not point_in_time_set?(point, values)
  end

  defp matches_condition?(point, {:in, key, values}) do
    actual = point_value(point, key)
    Enum.any?(values, &compare(actual, :eq, right_value(point, &1)))
  end

  defp matches_condition?(point, {:not_in, key, values}) do
    actual = point_value(point, key)
    not Enum.any?(values, &compare(actual, :eq, right_value(point, &1)))
  end

  defp matches_condition?(point, {:is_null, key, _nil}), do: is_nil(point_value(point, key))

  defp matches_condition?(point, {:is_not_null, key, _nil}),
    do: not is_nil(point_value(point, key))

  defp matches_condition?(point, {op, "time", value}) do
    compare(point.timestamp, op, to_nanoseconds(value))
  end

  defp matches_condition?(point, {op, left, right}) do
    compare(left_value(point, left), op, right_value(point, right))
  end

  # The left operand is a column name or an arithmetic expression; the right
  # one is a literal unless the parser tagged it as an expression.
  @spec left_value(point(), SQLParser.operand()) :: term()
  defp left_value(point, {:expr, expr}), do: eval_expr(expr, point)
  defp left_value(point, key), do: point_value(point, key)

  @spec right_value(point(), term()) :: term()
  defp right_value(point, {:expr, expr}), do: eval_expr(expr, point)
  defp right_value(_point, literal), do: literal

  @spec point_in_time_set?(point(), [term()]) :: boolean()
  defp point_in_time_set?(point, values) do
    ts = point.timestamp
    Enum.any?(values, fn v -> ts == to_nanoseconds(v) end)
  end

  # The parser has already turned every `time` comparand into nanoseconds or
  # a `now()` offset; `now()` is resolved here, at execution, as the engine
  # does.
  @spec to_nanoseconds(SQLParser.time_value()) :: integer()
  defp to_nanoseconds(value) when is_integer(value), do: value
  defp to_nanoseconds({:now, offset_ns}), do: System.os_time(:nanosecond) + offset_ns

  # DataFusion: "There isn't a common type to coerce Float64 and Utf8 in
  # LIKE expression".
  @spec like_type_error(SQLParser.operand()) :: binary()
  defp like_type_error(left) do
    "Error during planning: There isn't a common type to coerce a numeric column and " <>
      "Utf8 in LIKE expression: #{inspect(left)}"
  end

  # Both nil-actual (missing column) and nil-value (unparseable comparand)
  # short-circuit to false. Without this guard, Elixir term ordering would
  # silently produce wrong results (e.g. `5 > nil` is `true`).
  #
  # A string literal against a non-string column compares the column's text
  # rendering, which is what DataFusion does (it casts the numeric side to
  # Utf8): `amount >= '1000.00'` is lexical, so 500.0 matches. The double
  # reproduces that so a test written against it fails the same way
  # production would.
  #
  # The other way round — a string column against a numeric literal — the
  # engine keeps the column as text and renders the literal (`rack = 2`
  # matches the tag "2"; `rack > 3` is lexical, so "10" does not match), so
  # the literal is rendered here too.
  @spec compare(term(), atom(), term()) :: boolean()
  defp compare(nil, _op, _value), do: false
  defp compare(_actual, _op, nil), do: false

  defp compare(actual, op, value) when is_binary(value) and not is_binary(actual),
    do: compare(to_string(actual), op, value)

  defp compare(actual, op, value) when is_binary(actual) and is_number(value),
    do: compare(actual, op, to_string(value))

  defp compare(actual, :eq, value), do: actual == value
  defp compare(actual, :ne, value), do: actual != value
  defp compare(actual, :gt, value), do: actual > value
  defp compare(actual, :lt, value), do: actual < value
  defp compare(actual, :gte, value), do: actual >= value
  defp compare(actual, :lte, value), do: actual <= value

  # ORDER BY any column on raw rows: `time` sorts by timestamp, anything
  # else by the tag/field value (nil first, as the real engine sorts nulls).
  @spec apply_order_by([point()], SQLParser.order_by()) :: [point()]
  defp apply_order_by(points, []), do: points

  # `time` sorts on the stored nanoseconds, as in `order_projected/3`.
  defp apply_order_by(points, order_by) do
    keys =
      Enum.map(order_by, fn
        {{:expr, expr}, direction} -> {&eval_expr(expr, &1), direction}
        {"time", direction} -> {& &1.timestamp, direction}
        {column, direction} -> {&point_value(&1, column), direction}
      end)

    sort_by_keys(points, keys)
  end

  # OFFSET skips first, then LIMIT takes, whichever order they were written.
  @spec apply_limit([term()], non_neg_integer() | nil, non_neg_integer() | nil) :: [term()]
  defp apply_limit(items, limit, offset) do
    items
    |> Enum.drop(offset || 0)
    |> then(fn skipped -> if limit, do: Enum.take(skipped, limit), else: skipped end)
  end

  @spec point_to_row(point()) :: map()
  # `time` is a DateTime (microsecond precision), as on the HTTP and Flight
  # transports, so consumer code sees one type whichever client is configured.
  defp point_to_row(point) do
    point.fields
    |> Map.merge(point.tags)
    |> put_column("time", nanoseconds_to_datetime(point.timestamp))
  end
end
