defmodule InfluxElixir.Client.Local.InfluxQLQuery do
  @moduledoc false
  # The InfluxQL path of `InfluxElixir.Client.Local`: the `SHOW` statements, and
  # `SELECT` planned by `InfluxElixir.Client.Local.InfluxQL` and run over the
  # store through the SQL engine. `Client.Local.query_influxql/3` is the public
  # entry point.

  alias InfluxElixir.Client.Local.{
    Format,
    InfluxQL,
    LineProtocolParser,
    Scope,
    SQLExecutor,
    SQLParser,
    Store
  }

  @spec query_influxql(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  def query_influxql(%{table: table} = conn, influxql, opts \\ []) do
    with :ok <- Scope.require_capability(conn, :query_influxql) do
      Format.answer(
        Scope.query_format(opts),
        fn -> do_query_influxql(table, conn, influxql, opts) end,
        Keyword.get(opts, :database) || Map.get(conn, :database)
      )
    end
  end

  @show_databases ~r/^(?i)SHOW\s+DATABASES\s*;?$/
  @show_measurements ~r/^(?i)SHOW\s+MEASUREMENTS\s*;?$/
  @show_keys ~r/^(?i)SHOW\s+(TAG|FIELD)\s+KEYS(?:\s+FROM\s+("(?:[^"\\]|\\.)+"|\S+?))?\s*;?$/

  @spec do_query_influxql(Store.t(), map(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  defp do_query_influxql(table, conn, raw, opts) do
    # The engine's positions count the text as sent, blanks included.
    influxql = String.trim(raw)

    if String.match?(influxql, @show_databases) do
      {:ok, Enum.map(Scope.database_names(table), &%{"iox::database" => &1, "deleted" => false})}
    else
      # The engine parses the statement before it looks for the database.
      with {:ok, statement} <- influxql_statement(influxql, raw),
           {:ok, database} <- influxql_database(opts, conn),
           :ok <- Scope.database_exists(table, database) do
        case statement do
          :show_measurements -> {:ok, show_measurements(table, database)}
          {:show_keys, match} -> {:ok, show_keys(table, database, match)}
          {:show_tag_values, spec} -> show_tag_values(table, database, spec)
          {:select, query} -> influxql_select(table, database, query)
        end
      end
    end
  end

  @spec influxql_statement(binary(), binary()) ::
          {:ok,
           :show_measurements
           | {:show_keys, [binary()]}
           | {:show_tag_values, map()}
           | {:select, map()}}
          | {:error, term()}
  defp influxql_statement(influxql, raw) do
    cond do
      String.match?(influxql, @show_measurements) ->
        {:ok, :show_measurements}

      match = Regex.run(@show_keys, influxql) ->
        {:ok, {:show_keys, match}}

      show = InfluxQL.parse_show_tag_values(influxql) ->
        case show do
          {:ok, spec} ->
            {:ok, {:show_tag_values, spec}}

          {:error, {:engine, body}} ->
            {:error, %{status: 400, body: body}}

          {:error, message} ->
            {:error, %{status: 400, body: "Client.Local: #{message}: #{influxql}"}}
        end

      true ->
        with {:ok, query} <- influxql_parse(raw, influxql), do: {:ok, {:select, query}}
    end
  end

  # `SHOW TAG VALUES`, as InfluxDB 3 answers it (verified): a row per
  # distinct value of each listed key, by measurement, key and value, plus
  # a row without `value` when a point in range lacks the key; a
  # measurement without the key has no rows. Without a WHERE on `time`,
  # only the last 24 hours count.
  @show_tag_values_window "time >= now() - INTERVAL '86400 seconds'"

  @spec show_tag_values(Store.t(), binary(), map()) :: {:ok, [map()]} | {:error, map()}
  defp show_tag_values(table, database, spec) do
    measurements =
      if spec.measurement, do: [spec.measurement], else: Store.measurements(table, database)

    measurements
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn m, {:ok, acc} ->
      case tag_value_rows(table, database, m, spec) do
        {:ok, rows} -> {:cont, {:ok, [rows | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, groups |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  @spec tag_value_rows(Store.t(), binary(), binary(), map()) :: {:ok, [map()]} | {:error, map()}
  defp tag_value_rows(table, database, measurement, spec) do
    tags = Store.tag_columns(table, database, measurement)
    keys = tags |> Enum.filter(&InfluxQL.key_listed?(&1, spec.keys)) |> Enum.sort()

    with [_first | _rest] <- keys,
         {:ok, where} <- tag_values_where(spec.where, tags) do
      sql = ~s|SELECT * FROM "#{measurement}" WHERE | <> where

      case run_influxql_sql(table, database, sql, tags) do
        {:ok, rows} -> {:ok, Enum.flat_map(keys, &key_value_rows(measurement, &1, rows))}
        {:error, _no_table_or_column} -> {:ok, []}
      end
    else
      [] -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  # The statement's WHERE, parenthesised so an `OR` in it binds before the
  # default window, which applies unless the WHERE bounds `time` itself.
  @spec tag_values_where(binary() | nil, MapSet.t(binary())) ::
          {:ok, binary()} | {:error, map()}
  defp tag_values_where(nil, _tags), do: {:ok, @show_tag_values_window}

  defp tag_values_where(where, tags) do
    case influxql_where(where, tags, %{}, Store.now_ns()) do
      {:ok, %{where: " WHERE " <> sql}} ->
        if InfluxQL.mentions_time?(where),
          do: {:ok, sql},
          else: {:ok, "(#{sql}) AND " <> @show_tag_values_window}

      {:error, %{body: body} = error} ->
        {:error, %{error | body: InfluxQL.unframe_split(body)}}
    end
  end

  @spec key_value_rows(binary(), binary(), [map()]) :: [map()]
  defp key_value_rows(measurement, key, rows) do
    values = for %{^key => value} <- rows, do: value
    base = %{"iox::measurement" => measurement, "key" => key}
    missing = if Enum.any?(rows, &(not Map.has_key?(&1, key))), do: [base], else: []

    (values |> Enum.uniq() |> Enum.sort() |> Enum.map(&Map.put(base, "value", &1))) ++ missing
  end

  # HTTP sends an InfluxQL query without `db` when there is none, and the
  # engine answers this 400 (verified).
  @spec influxql_database(keyword(), InfluxElixir.Client.Local.conn()) ::
          {:ok, binary()} | {:error, map()}
  defp influxql_database(opts, conn) do
    case Scope.resolve_database(opts, conn) do
      {:ok, _database} = ok ->
        ok

      {:error, :no_database_specified} ->
        {:error,
         %{
           status: 400,
           body: "must specify a 'db' parameter, or provide the database in the InfluxQL query"
         }}
    end
  end

  @spec show_measurements(Store.t(), binary()) :: [map()]
  defp show_measurements(table, database) do
    table
    |> Store.measurements(database)
    |> Enum.map(&%{"iox::measurement" => "measurements", "name" => &1})
  end

  # Tag and field keys come from the column schema, in (measurement, key)
  # order.
  @spec show_keys(Store.t(), binary(), [binary()]) :: [map()]
  defp show_keys(table, database, [_full, kind | from]) do
    only =
      case from do
        [m] -> m |> String.trim("\"") |> LineProtocolParser.unescape_measurement()
        [] -> nil
      end

    for {m, column, type} <- Store.columns(table, database),
        only in [nil, m],
        row = key_row(String.upcase(kind), m, column, type),
        row != nil do
      row
    end
  end

  @spec key_row(binary(), term(), binary(), binary()) :: map() | nil
  defp key_row("TAG", m, column, "iox::column_type::tag"),
    do: %{"iox::measurement" => m, "tagKey" => column}

  defp key_row("FIELD", m, column, "iox::column_type::field::" <> _type = kind),
    do: %{
      "iox::measurement" => m,
      "fieldKey" => column,
      "fieldType" => LineProtocolParser.v2_field_type(kind)
    }

  defp key_row(_kind, _m, _column, _type), do: nil

  # The statement's WHERE is evaluated by the SQL engine (the grammar the two
  # share: comparisons, AND/OR/NOT, time literals, now()); InfluxQL then
  # shapes the rows. A measurement or column the engine does not know is an
  # empty InfluxQL result, not an error (verified).
  #
  # The inner query gets typed rows: the caller's `format:` applies once, to
  # the InfluxQL result.
  @spec influxql_select(Store.t(), binary(), InfluxQL.query()) ::
          InfluxElixir.Client.query_result()
  defp influxql_select(table, database, query) do
    tags = Store.tag_columns(table, database, query.measurement)
    types = field_types(table, database, query.measurement)
    now = Store.now_ns()

    with {:ok, plan} <- influxql_where(query.where, tags, types, now),
         :ok <- influxql_items(query, types, tags),
         :ok <- influxql_window(table, database, query),
         :ok <- influxql_deferred(plan) do
      if empty_range?(plan),
        do: {:ok, []},
        else: influxql_rows(table, database, query, plan, types, tags, now)
    end
  end

  # A range the bounds on `time` leave empty answers nothing, as it does there.
  @spec empty_range?(map()) :: boolean()
  defp empty_range?(%{lowers: [_low | _lows] = lowers, uppers: [_up | _ups] = uppers}),
    do: Enum.max(lowers) > Enum.min(uppers)

  defp empty_range?(_plan), do: false

  # The rows of the query, shaped.
  @spec influxql_rows(
          Store.t(),
          binary(),
          InfluxQL.query(),
          map(),
          map(),
          MapSet.t(binary()),
          integer()
        ) ::
          InfluxElixir.Client.query_result()
  defp influxql_rows(table, database, query, plan, types, tags, now) do
    # ORDER BY time sorts on the stored nanoseconds; rows carry microsecond
    # DateTimes, so sorting those alone would tie sub-microsecond points.
    # InfluxQL shapes the rows in that order and sorts nothing again.
    sql = ~s|SELECT * FROM "#{query.measurement}"| <> plan.where <> " ORDER BY time"

    table
    |> run_influxql_sql(database, sql, plan.tags, plan.checks)
    |> influxql_result(query, tags,
      lower: Enum.max(plan.lowers, fn -> nil end),
      upper: Enum.min(plan.uppers, fn -> nil end),
      now: now,
      fields: window_fields(table, database, query),
      types: types
    )
  end

  # The engine's planning error for a select item that is a constant, raised
  # after the `WHERE` is planned and before `LIMIT` is.
  @spec influxql_items(InfluxQL.query(), map(), MapSet.t(binary())) :: :ok | {:error, map()}
  defp influxql_items(query, types, tags) do
    case InfluxQL.plan_select(query, types, tags) do
      :ok -> :ok
      {:error, {:engine, body}} -> {:error, %{status: 400, body: body}}
      {:error, {:engine, status, body}} -> {:error, %{status: status, body: body}}
      {:error, message} -> {:error, %{status: 400, body: "Client.Local: #{message}"}}
    end
  end

  # The type of each field of a measurement, as the WHERE reads it.
  @spec field_types(Store.t(), binary(), binary()) :: %{binary() => atom()}
  defp field_types(table, database, measurement) do
    for {^measurement, column, "iox::column_type::field::" <> type} <-
          Store.columns(table, database),
        into: %{},
        do: {column, field_type(type)}
  end

  @spec field_type(binary()) :: :integer | :unsigned | :float | :string | :boolean
  defp field_type("integer"), do: :integer
  defp field_type("uinteger"), do: :unsigned
  defp field_type("float"), do: :float
  defp field_type("string"), do: :string
  defp field_type("boolean"), do: :boolean

  # A LIMIT or OFFSET beyond the signed 64-bit range is a planning error,
  # raised only for a measurement that exists (verified).
  @spec influxql_window(Store.t(), binary(), InfluxQL.query()) :: :ok | {:error, map()}
  defp influxql_window(table, database, query) do
    with true <- query.measurement in Store.measurements(table, database),
         {:error, {:engine, body}} <- InfluxQL.check_window(query) do
      {:error, %{status: 400, body: body}}
    else
      _in_range_or_absent -> :ok
    end
  end

  # An error the engine raises after it has planned the LIMIT.
  @spec influxql_deferred(map()) :: :ok | {:error, map()}
  defp influxql_deferred(%{deferred: nil}), do: :ok
  defp influxql_deferred(%{deferred: body}), do: {:error, %{status: 400, body: body}}

  # The field names a LIMIT or OFFSET counts per field, from the schema;
  # a query without either does not read them.
  @spec window_fields(Store.t(), binary(), InfluxQL.query()) :: [binary()] | nil
  defp window_fields(_table, _database, %{limit: nil, offset: 0}), do: nil

  defp window_fields(table, database, query) do
    for {measurement, column, "iox::column_type::field::" <> _type} <-
          Store.columns(table, database),
        measurement == query.measurement,
        do: column
  end

  # The WHERE as SQL (with its leading ` WHERE `, or nothing), the lower
  # bounds it puts on `time`, and the tag columns it names: only those
  # need the missing-tag fill.
  @spec influxql_where(binary() | nil, MapSet.t(binary()), %{binary() => atom()}, integer()) ::
          {:ok,
           %{
             where: binary(),
             lowers: [InfluxQL.bound()],
             uppers: [InfluxQL.bound()],
             checks: [term()],
             tags: MapSet.t(binary()),
             deferred: binary() | nil
           }}
          | {:error, map()}
  defp influxql_where(nil, _tags, _types, _now) do
    {:ok, %{where: "", lowers: [], uppers: [], checks: [], tags: MapSet.new(), deferred: nil}}
  end

  defp influxql_where(where, tags, types, now) do
    case InfluxQL.where_plan(where, tags, types, now: now) do
      {:ok, plan} ->
        {:ok,
         %{
           where: " WHERE " <> plan.sql,
           lowers: plan.lowers,
           uppers: plan.uppers,
           checks: plan.checks,
           tags: MapSet.intersection(tags, plan.idents),
           deferred: plan.deferred
         }}

      {:error, {:engine, body}} ->
        {:error, %{status: 400, body: body}}

      {:error, {:engine, status, body}} ->
        {:error, %{status: status, body: body}}

      {:error, message} ->
        {:error, %{status: 400, body: "Client.Local: #{message}"}}
    end
  end

  # InfluxQL reads a tag a point lacks as the empty string (verified), so
  # the WHERE runs over points with every missing tag it names filled with
  # "". A stored tag value is never empty (line protocol forbids it), so the
  # filled ones are dropped from the rows again afterwards. A tag the WHERE
  # does not name is not filled, and a query without a WHERE makes no extra
  # pass. InfluxQL identifiers are case-sensitive: the SQL written from
  # them is read as it is, not folded as a user's SQL would be.
  #
  # A comparison the SQL engine does not read as the engine does is a `check`:
  # its answer for each point is a boolean column of its own that the SQL
  # reads, so `AND`, `OR` and parentheses combine it with the rest; the
  # columns are dropped from the rows again.
  @spec run_influxql_sql(
          Store.t(),
          binary(),
          binary(),
          MapSet.t(binary()),
          [{binary(), InfluxQL.check()}]
        ) :: {:ok, [map()]} | {:error, term()}
  defp run_influxql_sql(table, database, sql, fill_tags, checks \\ []) do
    blank_tags = Map.new(fill_tags, &{&1, ""})
    columns = Enum.map(checks, &elem(&1, 0))

    fetch = fn measurement ->
      with {:ok, points} <- Scope.point_source(table, database, measurement) do
        {:ok, points |> fill_tags(blank_tags) |> answer_checks(checks)}
      end
    end

    with {:ok, query} <- SQLParser.parse_select(sql, identifiers: :exact),
         rows when is_list(rows) <- SQLExecutor.run_influxql(query, fetch) do
      {:ok, Enum.map(rows, &(&1 |> Map.drop(columns) |> drop_blank_tags(fill_tags)))}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec fill_tags([LineProtocolParser.point()], map()) :: [LineProtocolParser.point()]
  defp fill_tags(points, blank_tags) when blank_tags == %{}, do: points

  defp fill_tags(points, blank_tags),
    do: Enum.map(points, &%{&1 | tags: Map.merge(blank_tags, &1.tags)})

  @spec answer_checks([LineProtocolParser.point()], [{binary(), InfluxQL.check()}]) ::
          [LineProtocolParser.point()]
  defp answer_checks(points, []), do: points

  defp answer_checks(points, checks) do
    Enum.map(points, fn %{fields: fields} = point ->
      answers =
        for {column, check} <- checks, into: %{}, do: {column, InfluxQL.holds?(check, fields)}

      %{point | fields: Map.merge(fields, answers)}
    end)
  end

  @spec drop_blank_tags(map(), MapSet.t(binary())) :: map()
  defp drop_blank_tags(row, tags) do
    Enum.reduce(tags, row, fn tag, row ->
      if Map.get(row, tag) == "", do: Map.delete(row, tag), else: row
    end)
  end

  @spec influxql_result(
          {:ok, [map()]} | {:error, term()},
          InfluxQL.query(),
          MapSet.t(binary()),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  defp influxql_result(result, query, tags, opts) do
    case result do
      {:ok, rows} ->
        run_select(query, rows, tags, opts)

      {:error, %{body: "Error during planning: table " <> _rest}} ->
        {:ok, []}

      {:error, %{body: "Schema error: No field named" <> _rest}} ->
        {:ok, []}

      error ->
        error
    end
  end

  # What the double does not read as the engine, found while the rows are
  # shaped, is refused by name.
  @spec run_select(InfluxQL.query(), [map()], MapSet.t(binary()), keyword()) ::
          InfluxElixir.Client.query_result()
  defp run_select(query, rows, tags, opts) do
    {:ok, InfluxQL.run(query, rows, tags, opts)}
  catch
    {:refused, message} -> {:error, %{status: 400, body: "Client.Local: #{message}"}}
  end

  @spec influxql_parse(binary(), binary()) :: {:ok, InfluxQL.query()} | {:error, map()}
  defp influxql_parse(raw, influxql) do
    case InfluxQL.parse(raw) do
      {:ok, query} -> {:ok, query}
      {:error, {:engine, body}} -> {:error, %{status: 400, body: body}}
      {:error, message} -> {:error, %{status: 400, body: "Client.Local: #{message}: #{influxql}"}}
    end
  end
end
