defmodule InfluxElixir.Client.Local.InfluxQLQuery do
  @moduledoc false
  import InfluxElixir.Client.Local.InfluxQLBlankRegex, only: [sigil_q: 2]
  # The InfluxQL path of `InfluxElixir.Client.Local`: the `SHOW` statements, and
  # `SELECT` planned by `InfluxElixir.Client.Local.InfluxQL` and run over the
  # store through the SQL engine. `Client.Local.query_influxql/3` is the public
  # entry point.

  alias InfluxElixir.Client.Local.{
    Format,
    InfluxQL,
    InfluxQLLex,
    InfluxQLPlan,
    InfluxQLRegex,
    InfluxQLShow,
    InfluxQLShowParser,
    InfluxQLTokens,
    InfluxQLWild,
    LineProtocolParser,
    Scope,
    SQLError,
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

  @spec do_query_influxql(Store.t(), map(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  defp do_query_influxql(table, conn, raw, opts) do
    # The engine's positions count the text as sent, blanks included.
    influxql = InfluxQLLex.trim_both_blanks(raw)

    # The engine parses the statement before it looks for the database. Text that is not
    # UTF-8 is refused first: how the engine reads it is not verified, and the double's
    # readers (and its error bodies, which quote the text) take UTF-8.
    with :ok <- utf8(raw),
         {:ok, statement} <- influxql_statement(influxql, raw) do
      case statement do
        {:show, spec} ->
          show(table, conn, opts, spec)

        {:select, query} ->
          with {:ok, database} <- influxql_database(opts, conn),
               :ok <- Scope.database_exists(table, database) do
            influxql_select(table, database, query)
          end
      end
    end
  end

  @spec utf8(binary()) :: :ok | {:error, map()}
  defp utf8(text) do
    if String.valid?(text),
      do: :ok,
      else: {:error, %{status: 400, body: "Client.Local: the InfluxQL text is not valid UTF-8"}}
  end

  @spec influxql_statement(binary(), binary()) ::
          {:ok, {:show, map()} | {:select, map()}} | {:error, term()}
  defp influxql_statement(influxql, raw) do
    case InfluxQLShowParser.parse(raw) do
      nil ->
        with {:ok, query} <- influxql_parse(raw, influxql), do: {:ok, {:select, query}}

      {:ok, spec} ->
        {:ok, {:show, Map.put(spec, :statement, influxql)}}

      {:error, {:engine, body}} ->
        {:error, %{status: 400, body: body}}

      {:error, message} ->
        {:error, %{status: 400, body: "Client.Local: #{message}: #{influxql}"}}
    end
  end

  # `SHOW`, as InfluxDB 3 answers it (verified).
  @spec show(Store.t(), map(), keyword(), map()) :: InfluxElixir.Client.query_result()
  defp show(table, _conn, _opts, %{kind: :databases}) do
    {:ok, Enum.map(Scope.database_names(table), &%{"iox::database" => &1, "deleted" => false})}
  end

  defp show(table, conn, opts, spec) do
    with {:ok, scope} <- show_scope(spec, opts, conn),
         :ok <- show_exists(table, scope),
         :ok <- show_planned(spec) do
      show_rows(table, scope, spec)
    end
  end

  # The database a statement is about: its `ON`, which must be the `db` of the
  # call when the call has one, else that one. `SHOW RETENTION POLICIES` of
  # neither covers every database.
  @spec show_scope(map(), keyword(), InfluxElixir.Client.Local.conn()) ::
          {:ok, binary() | :all} | {:error, map()}
  defp show_scope(%{on: on, kind: kind}, opts, conn) do
    case {on, Scope.resolve_database(opts, conn)} do
      {nil, {:ok, database}} ->
        {:ok, database}

      {nil, {:error, :no_database_specified}} ->
        if kind == :retention, do: {:ok, :all}, else: influxql_database(opts, conn)

      {on, {:error, :no_database_specified}} ->
        {:ok, on}

      {on, {:ok, on}} ->
        {:ok, on}

      {on, {:ok, param}} ->
        {:error,
         %{
           status: 400,
           body:
             "provided a database in both the parameters (#{param}) and query string " <>
               "(#{on}) that do not match, if providing a query that specifies the " <>
               "database, you can omit the 'database' parameter from your request"
         }}
    end
  end

  # What the engine raises when it plans the statement, after the database.
  @spec show_planned(map()) :: :ok | {:error, map()}
  defp show_planned(%{planning: nil}), do: :ok
  defp show_planned(%{planning: {:engine, body}}), do: {:error, %{status: 400, body: body}}

  defp show_planned(%{planning: {:engine, status, body}}),
    do: {:error, %{status: status, body: body}}

  @spec show_exists(Store.t(), binary() | :all) :: :ok | {:error, map()}
  defp show_exists(_table, :all), do: :ok
  defp show_exists(table, database), do: Scope.database_exists(table, database)

  @spec show_rows(Store.t(), binary() | :all, map()) :: InfluxElixir.Client.query_result()
  defp show_rows(table, database, %{kind: :retention}), do: retention_rows(table, database)

  defp show_rows(table, database, %{kind: :measurements} = spec),
    do: measurement_rows(table, database, spec)

  defp show_rows(table, database, %{kind: :tag_keys} = spec),
    do: tag_key_list(table, database, spec)

  defp show_rows(table, database, %{kind: :field_keys} = spec),
    do: field_key_list(table, database, spec)

  defp show_rows(table, database, %{kind: :tag_values} = spec),
    do: tag_value_list(table, database, spec)

  defp retention_rows(table, database) do
    databases = if database == :all, do: Scope.database_names(table), else: [database]

    {:ok,
     InfluxQLShow.retention_rows(for name <- databases, do: {name, Scope.retention(table, name)})}
  end

  # Measurements come sorted. A WHERE keeps those with a point in range that
  # satisfies it; LIMIT and OFFSET count the measurements.
  defp measurement_rows(table, database, spec) do
    names =
      InfluxQLShow.select_measurements(
        Store.measurements(table, database),
        spec.measurement && [spec.measurement]
      )

    with nil <- show_window_error(spec),
         {:ok, kept} <- show_filter(table, database, names, spec) do
      {:ok,
       kept
       |> InfluxQLShow.measurement_window(spec)
       |> Enum.map(&%{"iox::measurement" => "measurements", "name" => &1})}
    end
  end

  # The engine fails a WHERE with a LIMIT or OFFSET on a measurement that
  # exists with an internal error of the SQL engine (verified).
  defp tag_key_list(table, database, spec) do
    names = show_names(table, database, spec)

    tagless_error =
      if spec.where != nil and tagless?(table, database, names),
        do: split_error(table, database, names, spec)

    cond do
      tagless_error != nil ->
        tagless_error

      spec.where != nil and names != [] and (spec.limit != nil or spec.offset > 0) ->
        show_refusal(
          spec,
          "SHOW TAG KEYS with WHERE and LIMIT or OFFSET (the engine fails it with an internal error)"
        )

      spec.where != nil and tagless?(table, database, names) ->
        tagless_where(table, database, names, spec)

      true ->
        show_collect(names, &tag_key_rows(table, database, &1, spec))
    end
  end

  # Whether a measurement of the list has no tag.
  @spec tagless?(Store.t(), binary(), [binary()]) :: boolean()
  defp tagless?(table, database, names),
    do: Enum.any?(names, &Enum.empty?(Store.tag_columns(table, database, &1)))

  # `SHOW TAG KEYS WHERE ...` fails to plan once a measurement it lists has no tag column
  # (verified, whatever the condition): the engine builds an aggregate of nothing. The planner
  # splits the `time` comparisons off the condition before that, so their errors (`time != x`,
  # a time that is no timestamp) come first; a `now()` in the rest of the condition is its
  # error first, which the double does not order.
  @spec tagless_where(Store.t(), binary(), [binary()], map()) :: {:error, map()}
  defp tagless_where(table, database, names, spec) do
    case split_error(table, database, names, spec) do
      {:error, _error} = error ->
        error

      nil ->
        if Regex.match?(~q/\bnow\s*\(/i, spec.where) do
          show_refusal(spec, "SHOW TAG KEYS WHERE now() over a measurement with no tag")
        else
          aggregate_of_nothing()
        end
    end
  end

  @spec split_error(Store.t(), binary(), [binary()], map()) :: {:error, map()} | nil
  defp split_error(table, database, names, spec) do
    name = Enum.find(names, &Enum.empty?(Store.tag_columns(table, database, &1)))
    tags = Store.tag_columns(table, database, name)

    types = field_types(table, database, name)

    case influxql_where(spec.where, tags, types, Store.now_ns(), 0) do
      {:error, %{body: body} = error} ->
        if InfluxQL.mentions_time?(spec.where),
          do: {:error, %{error | body: InfluxQL.unframe_split(body)}}

      {:ok, _plan} ->
        if odd_time?(spec.where),
          do:
            show_refusal(
              spec,
              "SHOW TAG KEYS WHERE with a time in arithmetic or beside a name over a measurement " <>
                "with no tag"
            )
    end
  end

  # A `time` in arithmetic, beside a name or matched by a regular expression: the engine's
  # planning error is its own (`time = time`, `time - 1 > 0`), which the double does not word
  # for a measurement it fails to plan anyway.
  @spec odd_time?(binary()) :: boolean()
  defp odd_time?(where) do
    case InfluxQLTokens.tokenize(where, []) do
      {:ok, tokens} ->
        tokens
        |> Enum.with_index()
        |> Enum.any?(fn {token, at} ->
          InfluxQLTokens.time?(token) and odd_neighbours?(tokens, at)
        end)

      _unread ->
        false
    end
  end

  defp odd_neighbours?(tokens, at) do
    before = if at > 0, do: Enum.at(tokens, at - 1)
    before2 = if at > 1, do: Enum.at(tokens, at - 2)
    next = Enum.at(tokens, at + 1)
    next2 = Enum.at(tokens, at + 2)

    arithmetic?(before) or arithmetic?(next) or
      match?({:op, op} when op in ["=~", "!~"], next) or
      match?({:op, op} when op in ["=~", "!~"], before) or
      (match?({:op, _op}, next) and match?({:ident, _name}, next2)) or
      (match?({:op, _op}, before) and match?({:ident, _name}, before2))
  end

  defp arithmetic?({:raw, op}), do: op in ["+", "-", "*", "/"]
  defp arithmetic?(_token), do: false

  @spec aggregate_of_nothing() :: {:error, map()}
  defp aggregate_of_nothing do
    {:error,
     %{
       status: 400,
       body:
         "Error during planning: Aggregate requires at least one grouping or aggregate " <>
           "expression. Aggregate without grouping expressions nor aggregate expressions is " <>
           "logically equivalent to, but less efficient than, VALUES producing single row. " <>
           "Please use VALUES instead."
     }}
  end

  defp field_key_list(table, database, spec) do
    fields =
      table
      |> Store.columns(database)
      |> Enum.filter(&match?({_m, _column, "iox::column_type::field::" <> _type}, &1))
      |> Enum.group_by(&elem(&1, 0))

    show_collect(show_names(table, database, spec), fn name ->
      rows =
        for {^name, column, kind} <- Map.get(fields, name, []) do
          %{
            "iox::measurement" => name,
            "fieldKey" => column,
            "fieldType" => LineProtocolParser.v2_field_type(kind)
          }
        end

      {:ok, InfluxQLShow.window(rows, spec.limit, spec.offset)}
    end)
  end

  # With a LIMIT or OFFSET and no measurement that has a key to list, the
  # engine fails with an internal error of the SQL engine (verified).
  defp tag_value_list(table, database, spec) do
    names = show_names(table, database, spec)

    if (spec.limit != nil or spec.offset > 0) and
         not Enum.any?(names, &key_listed?(table, database, &1, spec)) do
      show_refusal(
        spec,
        "SHOW TAG VALUES with LIMIT or OFFSET and no key to list (the engine fails it " <>
          "with an internal error)"
      )
    else
      with {:ok, rows} <- show_collect(names, &tag_value_rows(table, database, &1, spec)) do
        one_group(rows, spec)
      end
    end
  end

  # The planning error of a LIMIT or OFFSET the engine reads as negative.
  @spec show_window_error(map()) :: nil | {:error, map()}
  defp show_window_error(spec) do
    case InfluxQLShow.window_error(spec.limit, spec.offset) do
      nil -> nil
      body -> {:error, %{status: 400, body: body}}
    end
  end

  @spec key_listed?(Store.t(), binary(), binary(), map()) :: boolean()
  defp key_listed?(table, database, measurement, spec) do
    table
    |> Store.tag_columns(database, measurement)
    |> Enum.any?(&InfluxQL.key_listed?(&1, spec.keys))
  end

  @spec show_names(Store.t(), binary(), map()) :: [binary()]
  defp show_names(table, database, spec),
    do: InfluxQLShow.select_measurements(Store.measurements(table, database), spec.from)

  # The rows of each measurement in turn, in the order of the measurements.
  @spec show_collect([binary()], (binary() -> {:ok, [map()]} | {:error, map()})) ::
          {:ok, [map()]} | {:error, map()}
  defp show_collect(names, rows_of) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case rows_of.(name) do
        {:ok, rows} -> {:cont, {:ok, [rows | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, groups |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  @spec show_refusal(map(), binary()) :: {:error, map()}
  defp show_refusal(spec, what),
    do:
      {:error,
       %{status: 400, body: "Client.Local: unsupported InfluxQL (#{what}): #{spec.statement}"}}

  # The names with a point in range that satisfies the WHERE; all of them
  # without one.
  @spec show_filter(Store.t(), binary(), [binary()], map()) ::
          {:ok, [binary()]} | {:error, map()}
  defp show_filter(_table, _database, names, %{where: nil}), do: {:ok, names}

  defp show_filter(table, database, names, spec) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, kept} ->
      case show_points(table, database, name, spec) do
        {:ok, []} -> {:cont, {:ok, kept}}
        {:ok, [_point | _rest]} -> {:cont, {:ok, [name | kept]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      error -> error
    end
  end

  # A measurement's tag keys, sorted: with a WHERE, those some point in range
  # that satisfies it has a value for.
  @spec tag_key_rows(Store.t(), binary(), binary(), map()) :: {:ok, [map()]} | {:error, map()}
  defp tag_key_rows(table, database, measurement, spec) do
    tags = table |> Store.tag_columns(database, measurement) |> Enum.sort()

    with {:ok, keys} <- present_tags(table, database, measurement, tags, spec) do
      {:ok,
       keys
       |> InfluxQLShow.window(spec.limit, spec.offset)
       |> Enum.map(&%{"iox::measurement" => measurement, "tagKey" => &1})}
    end
  end

  defp present_tags(_table, _database, _measurement, tags, %{where: nil}), do: {:ok, tags}

  defp present_tags(table, database, measurement, tags, spec) do
    with {:ok, points} <- show_points(table, database, measurement, spec) do
      {:ok, Enum.filter(tags, fn tag -> Enum.any?(points, &Map.has_key?(&1, tag)) end)}
    end
  end

  # A row per distinct value of each listed key, by measurement, key and
  # value, plus a row without `value` when a point in range lacks the key; a
  # measurement without the key has no rows. LIMIT and OFFSET count the rows
  # of each key of each measurement.
  @spec tag_value_rows(Store.t(), binary(), binary(), map()) ::
          {:ok, [map()]} | {:error, map()}
  defp tag_value_rows(table, database, measurement, spec) do
    tags = Store.tag_columns(table, database, measurement)
    keys = tags |> Enum.filter(&InfluxQL.key_listed?(&1, spec.keys)) |> Enum.sort()

    with [_first | _rest] <- keys,
         {:ok, points} <- show_points(table, database, measurement, spec) do
      {:ok, Enum.flat_map(keys, &key_value_rows(measurement, &1, points, spec))}
    else
      [] -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  @spec key_value_rows(binary(), binary(), [map()], map()) :: [map()]
  defp key_value_rows(measurement, key, points, spec) do
    values = for %{^key => value} <- points, do: value
    base = %{"iox::measurement" => measurement, "key" => key}
    missing = if Enum.any?(points, &(not Map.has_key?(&1, key))), do: [base], else: []

    rows =
      (values |> Enum.uniq() |> Enum.sort() |> Enum.map(&Map.put(base, "value", &1))) ++ missing

    InfluxQLShow.window(rows, spec.limit, spec.offset)
  end

  # The engine lists the groups a LIMIT or OFFSET cuts in an order of its own
  # (verified: not the sorted one), so only a single group is answered.
  @spec one_group([map()], map()) :: {:ok, [map()]} | {:error, map()}
  defp one_group(rows, spec) do
    groups = rows |> Enum.uniq_by(&{&1["iox::measurement"], &1["key"]}) |> length()

    if (spec.limit != nil or spec.offset > 0) and groups > 1,
      do:
        show_refusal(
          spec,
          "SHOW TAG VALUES with LIMIT or OFFSET over several measurements or keys: " <>
            "the engine lists them in an order the double does not reproduce"
        ),
      else: {:ok, rows}
  end

  # The points of a measurement a SHOW statement counts: those its WHERE
  # keeps, of the last day unless the WHERE names `time` (verified). A column
  # the measurement lacks keeps none.
  @show_window "time >= now() - INTERVAL '86400 seconds'"

  @spec show_points(Store.t(), binary(), binary(), map()) :: {:ok, [map()]} | {:error, map()}
  defp show_points(table, database, measurement, spec) do
    tags = Store.tag_columns(table, database, measurement)
    types = field_types(table, database, measurement)

    with {:ok, plan} <- show_plan(spec, tags, types) do
      sql = ~s|SELECT * FROM "#{measurement}" WHERE | <> plan.condition

      case run_influxql_sql(table, database, sql, plan.tags, plan.checks) do
        {:ok, points} -> {:ok, points}
        {:error, _no_column} -> no_column(spec)
      end
    end
  end

  # A column the measurement lacks is null to the engine, so a comparison with
  # it keeps nothing; beside an `OR` the rest of the condition still counts,
  # which the double's SQL cannot say.
  @spec no_column(map()) :: {:ok, []} | {:error, map()}
  defp no_column(%{where: where} = spec) do
    if where =~ ~q/\bOR\b/i,
      do: show_refusal(spec, "a WHERE with OR that names a column the measurement lacks"),
      else: {:ok, []}
  end

  # The WHERE, parenthesised so an `OR` in it binds before the window.
  @spec show_plan(map(), MapSet.t(binary()), map()) :: {:ok, map()} | {:error, map()}
  defp show_plan(%{where: nil}, _tags, _types),
    do: {:ok, %{condition: @show_window, tags: MapSet.new(), checks: []}}

  defp show_plan(%{where: where}, tags, types) do
    case influxql_where(where, tags, types, Store.now_ns(), 0) do
      {:ok, %{deferred: {status, body}}} ->
        {:error, %{status: status, body: body}}

      {:ok, %{where: " WHERE " <> sql} = plan} ->
        condition =
          if InfluxQL.mentions_time?(where), do: sql, else: "(#{sql}) AND " <> @show_window

        {:ok, %{condition: condition, tags: plan.tags, checks: plan.checks}}

      {:error, %{body: body} = error} ->
        {:error, %{error | body: InfluxQL.unframe_split(body)}}
    end
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
    with {:ok, names} <- measurement_names(table, database, query) do
      names
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, groups} ->
        case influxql_select_one(table, database, %{query | measurement: name}) do
          {:ok, rows} -> {:cont, {:ok, [rows | groups]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, groups} -> {:ok, groups |> Enum.reverse() |> Enum.concat()}
        error -> error
      end
    end
  end

  # The measurements a `FROM` selects from, by name (verified): the names it
  # lists and those the regular expressions in it match, each once, whatever the
  # order they are written in. The answer has the rows of each in turn, a
  # `LIMIT` counting in each.
  @spec measurement_names(Store.t(), binary(), InfluxQL.query()) ::
          {:ok, [binary()]} | {:error, map()}
  defp measurement_names(table, database, %{sources: sources}) do
    existing = Store.measurements(table, database)

    names =
      Enum.flat_map(sources, fn
        {:name, name} ->
          [name]

        {:regex, source} ->
          regex = InfluxQLRegex.compile(source, :from)
          Enum.filter(existing, &Regex.match?(regex, &1))
      end)

    {:ok, names |> Enum.uniq() |> Enum.sort()}
  catch
    {:refused, {:engine, status, body}} -> {:error, %{status: status, body: body}}
    {:refused, message} -> {:error, %{status: 400, body: "Client.Local: #{message}"}}
  end

  @spec influxql_select_one(Store.t(), binary(), InfluxQL.query()) ::
          InfluxElixir.Client.query_result()
  defp influxql_select_one(table, database, query) do
    tags = Store.tag_columns(table, database, query.measurement)
    types = field_types(table, database, query.measurement)
    now = Store.now_ns()

    with :ok <- influxql_early(query),
         {:ok, query} <- influxql_wild(query, types, tags) do
      influxql_planned(table, database, query, types, tags, now)
    else
      :empty -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  # What the engine raises while it rewrites the statement, before it reads
  # the `WHERE`.
  @spec influxql_early(InfluxQL.query()) :: :ok | {:error, map()}
  defp influxql_early(query) do
    case InfluxQL.early_error(query) do
      :ok -> :ok
      {:error, {:engine, body}} -> {:error, %{status: 400, body: body}}
    end
  end

  # What the engine raises while it expands the projection, before it splits the `WHERE`.
  @spec influxql_expanding(InfluxQL.query(), map(), MapSet.t(binary())) :: :ok | {:error, map()}
  defp influxql_expanding(query, types, tags) do
    case InfluxQL.expand_errors(query, types, tags) do
      :ok -> :ok
      {:error, {:engine, body}} -> {:error, %{status: 400, body: body}}
    end
  end

  defp influxql_planned(table, database, query, types, tags, now) do
    with :ok <- influxql_expanding(query, types, tags),
         {:ok, extend} <- influxql_lookback(query),
         {:ok, plan} <- influxql_planned_where(query, tags, types, now, extend),
         items = influxql_items(query, types, tags),
         :ok <- influxql_selected(items, table, database, query, plan, types),
         :ok <- influxql_window(table, database, query),
         :ok <- influxql_stride(table, database, query),
         :ok <- influxql_deferred(table, database, query, plan) do
      if empty_range?(plan),
        do: {:ok, []},
        else: influxql_rows(table, database, query, plan, types, tags, now)
    else
      :empty -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  # The condition of the statement, planned. What the engine finds wrong in it while it plans
  # the filter is found only for a select list that reads a field (see `influxql_selected/6`):
  # one that reads none is answered empty, but for the errors of rewriting the statement.
  @spec influxql_planned_where(
          InfluxQL.query(),
          MapSet.t(binary()),
          map(),
          integer(),
          non_neg_integer()
        ) :: {:ok, map()} | :empty | {:error, map()}
  defp influxql_planned_where(query, tags, types, now, extend) do
    case influxql_where(query.where, tags, types, now, extend, select_opts(query)) do
      {:error, %{body: body}} = error ->
        if String.starts_with?(body, ["rewriting statement", "Client.Local: "]),
          do: error,
          else: unread_where(error, query, types, tags)

      result ->
        result
    end
  end

  defp unread_where(error, query, types, tags) do
    case influxql_items(query, types, tags) do
      {:error, %{body: "rewriting statement" <> _gather}} = rewriting ->
        rewriting

      _no_rewriting_error ->
        if InfluxQLPlan.reads_field?(query.items, types), do: error, else: :empty
    end
  end

  # The measurement a statement with a `tz()` clause is planned over (each one the `FROM`
  # names or matches, in turn), the engine plans the `WHERE` of as a filter.
  @spec select_opts(InfluxQL.query()) :: keyword()
  defp select_opts(query), do: [filter: filter(query), late_clash: true]

  @spec filter(InfluxQL.query()) :: %{table: binary()} | nil
  defp filter(%{tz: true, measurement: name}), do: %{table: name}
  defp filter(_query), do: nil

  # The wildcards of the select list, written out for this measurement.
  @spec influxql_wild(InfluxQL.query(), map(), MapSet.t(binary())) ::
          {:ok, InfluxQL.query()} | :empty | {:error, map()}
  defp influxql_wild(query, types, tags) do
    case InfluxQLWild.expand(query, types, tags) do
      {:error, message} -> {:error, %{status: 400, body: "Client.Local: #{message}"}}
      other -> other
    end
  catch
    {:refused, {:engine, status, body}} -> {:error, %{status: status, body: body}}
    {:refused, message} -> {:error, %{status: 400, body: "Client.Local: #{message}"}}
  end

  # The transforms that compare with the bucket before scan one bucket before
  # the range.
  @spec influxql_lookback(InfluxQL.query()) :: {:ok, non_neg_integer()} | {:error, map()}
  defp influxql_lookback(query) do
    case InfluxQL.lookback(query) do
      {:ok, extend} -> {:ok, extend}
      {:error, message} -> {:error, %{status: 400, body: "Client.Local: #{message}"}}
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

  # `GROUP BY time(0s)` of a measurement that exists is the engine's execution
  # error, whatever the points (verified); of one that does not, an empty answer.
  @spec influxql_stride(Store.t(), binary(), InfluxQL.query()) :: :ok | {:error, map()}
  defp influxql_stride(table, database, %{group_time: {0, _offset}, measurement: measurement}) do
    if measurement in Store.measurements(table, database),
      do:
        {:error,
         %{
           status: 500,
           body:
             "query error: error while executing plan: " <>
               "Execution error: DATE_BIN stride must be non-zero"
         }},
      else: :ok
  end

  defp influxql_stride(_table, _database, _query), do: :ok

  # What the engine finds of the select list and of the condition, in its order (verified):
  #
  #   1. the errors of rewriting the statement (every one worded `rewriting statement`),
  #      whatever the condition holds
  #   2. a select list that reads no field of the measurement selects no point: an empty
  #      answer, the condition and the window never planned
  #   3. the condition's comparison that cannot be typed (`clash`), raised when the planner
  #      builds the filter, before the select list is planned
  #   4. the select list's own planning errors, the double's refusals among them
  #   5. the condition's error after that (`deferred`), then the rest
  @constants "Client.Local: unsupported InfluxQL (an expression of constants)"

  @spec influxql_selected(
          :ok | {:error, map()},
          Store.t(),
          binary(),
          InfluxQL.query(),
          map(),
          map()
        ) :: :ok | :empty | {:error, map()}
  defp influxql_selected({:error, %{body: body}} = error, table, db, query, plan, types) do
    cond do
      String.starts_with?(body, "rewriting statement") ->
        error

      body == @constants and not InfluxQLPlan.reads_field?(query.items, types) ->
        :empty

      String.starts_with?(body, "Client.Local: ") ->
        refusal_after(error, table, db, query, plan)

      not InfluxQLPlan.reads_field?(query.items, types) ->
        :empty

      true ->
        with :ok <- influxql_clash(table, db, query, plan), do: error
    end
  end

  defp influxql_selected(:ok, table, db, query, plan, types) do
    if InfluxQLPlan.reads_field?(query.items, types),
      do: influxql_clash(table, db, query, plan),
      else: :empty
  end

  # A select list the double refuses by name is a list the engine plans, and the error it
  # raises for the condition (`clash` or `deferred`) stands in its place when it has one; a
  # list it fails to plan is not: the schema error of arithmetic on a selector beside columns,
  # and the coercion error of a function given a string, a boolean or a tag. The planner
  # raises those before the analyzer finds the condition's own (`deferred`), but after the
  # comparisons it cannot type (`clash`).
  @unplanned_call ~q/\(\w+\(\) of an? (?:string|boolean|unsigned|tag|timestamp)\b|several aggregates of a type|arithmetic on a selector beside columns|a transform of a field beside an aggregate|a function of time beside an aggregate|GROUP BY a field that the select list reads/

  @spec refusal_after({:error, map()}, Store.t(), binary(), InfluxQL.query(), map()) ::
          {:error, map()}
  defp refusal_after({:error, %{body: body}} = refusal, table, db, query, plan) do
    if Regex.match?(@unplanned_call, body) do
      with :ok <- influxql_clash(table, db, query, plan), do: refusal
    else
      with :ok <- influxql_clash(table, db, query, plan),
           :ok <- influxql_window(table, db, query),
           :ok <- influxql_stride(table, db, query),
           :ok <- influxql_deferred(table, db, query, plan) do
        refusal
      end
    end
  end

  # The error of a comparison of types that cannot be compared, which the engine raises before
  # it plans the LIMIT, of a measurement that exists.
  @spec influxql_clash(Store.t(), binary(), InfluxQL.query(), map()) :: :ok | {:error, map()}
  defp influxql_clash(table, database, query, %{clash: {status, body}}) do
    if query.measurement in Store.measurements(table, database),
      do: {:error, %{status: status, body: body}},
      else: :ok
  end

  defp influxql_clash(_table, _database, _query, _plan), do: :ok

  # An error the engine raises after it has planned the LIMIT, of a
  # measurement that exists.
  @spec influxql_deferred(Store.t(), binary(), InfluxQL.query(), map()) :: :ok | {:error, map()}
  defp influxql_deferred(_table, _database, _query, %{deferred: nil}), do: :ok

  defp influxql_deferred(table, database, query, %{deferred: {status, body}}) do
    if query.measurement in Store.measurements(table, database),
      do: {:error, %{status: status, body: body}},
      else: :ok
  end

  # The WHERE as SQL (with its leading ` WHERE `, or nothing), the lower
  # bounds it puts on `time`, and the tag columns it names: only those
  # need the missing-tag fill.
  @spec influxql_where(
          binary() | nil,
          MapSet.t(binary()),
          %{binary() => atom()},
          integer(),
          non_neg_integer()
        ) ::
          {:ok,
           %{
             where: binary(),
             lowers: [InfluxQL.bound()],
             uppers: [InfluxQL.bound()],
             checks: [term()],
             tags: MapSet.t(binary()),
             deferred: {pos_integer(), binary()} | nil,
             clash: {pos_integer(), binary()} | nil
           }}
          | {:error, map()}
  defp influxql_where(where, tags, types, now, extend, select_opts \\ [])

  defp influxql_where(nil, _tags, _types, _now, _extend, _select_opts) do
    {:ok,
     %{
       where: "",
       lowers: [],
       uppers: [],
       checks: [],
       tags: MapSet.new(),
       deferred: nil,
       clash: nil
     }}
  end

  defp influxql_where(where, tags, types, now, extend, select_opts) do
    known = MapSet.union(tags, MapSet.new(Map.keys(types)))
    opts = [now: now, extend_lower: extend, known: known] ++ select_opts

    case InfluxQL.where_plan(where, tags, types, opts) do
      {:ok, plan} ->
        {:ok,
         %{
           where: " WHERE " <> plan.sql,
           lowers: plan.lowers,
           uppers: plan.uppers,
           checks: plan.checks,
           tags: MapSet.new(Enum.filter(tags, &MapSet.member?(plan.idents, &1))),
           deferred: plan.deferred,
           clash: plan.clash
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
  defp run_influxql_sql(table, database, sql, fill_tags, checks) do
    blank_tags = Map.new(fill_tags, &{&1, ""})
    columns = Enum.map(checks, &elem(&1, 0))

    fetch = fn measurement ->
      with {:ok, points} <- Scope.point_source(table, database, measurement) do
        {:ok, points |> fill_tags(blank_tags) |> answer_checks(checks)}
      end
    end

    with {:ok, query} <- SQLParser.parse_select(sql, identifiers: :exact),
         rows when is_list(rows) <- SQLExecutor.run_influxql(query, fetch) do
      {:ok, strip_helpers(rows, columns, Enum.to_list(fill_tags))}
    else
      {:error, _reason} = error -> error
    end
  catch
    # What a check finds in the points: the engine breaks the connection, or the double
    # refuses by name.
    :closed_connection -> {:error, SQLError.closed()}
    {:refused, {:engine, status, body}} -> {:error, %{status: status, body: body}}
    {:refused, message} -> {:error, %{status: 400, body: "Client.Local: #{message}"}}
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

  # The check columns and the tags filled with "" are the double's own: they do
  # not reach the answer. With neither, the rows are the answer as they are.
  @spec strip_helpers([map()], [binary()], [binary()]) :: [map()]
  defp strip_helpers(rows, [], []), do: rows

  defp strip_helpers(rows, columns, blank_tags) do
    Enum.map(rows, fn row ->
      Enum.reduce(blank_tags, drop_columns(row, columns), &drop_blank_tag/2)
    end)
  end

  defp drop_columns(row, []), do: row
  defp drop_columns(row, columns), do: Map.drop(row, columns)

  defp drop_blank_tag(tag, row) do
    if Map.get(row, tag) == "", do: Map.delete(row, tag), else: row
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

      # The planner raises its own coercion error, before the analyser that would wrap it.
      {:error,
       %{body: "type_coercion\ncaused by\nError during planning: Cannot coerce arith" <> rest} =
           error} ->
        {:error, %{error | body: "Error during planning: Cannot coerce arith" <> rest}}

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
    :closed_connection -> {:error, SQLError.closed()}
    {:refused, {:engine, status, body}} -> {:error, %{status: status, body: body}}
    {:refused, message} -> {:error, %{status: 400, body: "Client.Local: #{message}"}}
  end

  @spec influxql_parse(binary(), binary()) :: {:ok, InfluxQL.query()} | {:error, map()}
  defp influxql_parse(raw, influxql) do
    case InfluxQL.parse(raw) do
      {:ok, query} -> {:ok, query}
      {:error, {:engine, body}} -> {:error, %{status: 400, body: body}}
      {:error, {:engine, status, body}} -> {:error, %{status: status, body: body}}
      {:error, message} -> {:error, %{status: 400, body: "Client.Local: #{message}: #{influxql}"}}
    end
  end
end
