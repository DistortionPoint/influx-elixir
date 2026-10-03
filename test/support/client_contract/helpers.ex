defmodule InfluxElixir.ClientContract.Helpers do
  @moduledoc """
  The helpers of `InfluxElixir.ClientContract` that the contract tests call
  (`InfluxElixir.ClientContract` delegates to them): waiting for a write to be
  visible, scratch databases, and the queries most tests are built from.
  """

  @doc """
  Waits for a write to become visible to queries on the client under test.

  `Client.Local` is synchronous, so its contexts set `query_delay: 0` and this
  returns immediately. Real servers ingest asynchronously and their contexts
  set a delay in milliseconds. Kept in one place so the wait strategy can be
  changed without touching every test.
  """
  @spec settle(map()) :: :ok
  def settle(%{query_delay: delay}) when is_integer(delay) and delay > 0 do
    Process.sleep(delay)
  end

  def settle(_ctx), do: :ok

  @doc """
  The connection with `database` as its default, for either client's
  connection shape (a keyword list over HTTP, a map for `Client.Local`).
  """
  @spec with_database(keyword() | map(), binary()) :: keyword() | map()
  def with_database(conn, database) when is_list(conn),
    do: Keyword.put(conn, :database, database)

  def with_database(conn, database) when is_map(conn), do: Map.put(conn, :database, database)

  @doc false
  # Runs `fun` with the name of a scratch database (`kind` `:database`) or
  # bucket (`:bucket`), unique by `prefix`, and drops it afterwards, whatever
  # the outcome. The drop runs in the test's own process: a `Client.Local`
  # connection's store dies with that process, before any `on_exit` callback.
  # A drop of what the test already dropped answers an error, which is ignored.
  @spec with_scratch(module(), map(), :database | :bucket, binary(), (binary() -> term())) ::
          term()
  def with_scratch(client, ctx, kind, prefix, fun) do
    name = InfluxElixir.IntegrationHelper.unique_name(prefix)

    try do
      fun.(name)
    after
      _result =
        case kind do
          :database -> client.delete_database(ctx.conn, name)
          :bucket -> client.delete_bucket(ctx.conn, name)
        end
    end
  end

  @doc false
  # Like `with_scratch/5` for `count` databases or buckets: `fun` receives
  # their names, all sharing one unique `prefix`, and every one is dropped
  # afterwards, whatever the outcome.
  @spec with_scratch_many(
          module(),
          map(),
          :database | :bucket,
          binary(),
          pos_integer(),
          ([binary(), ...] -> term())
        ) :: term()
  def with_scratch_many(client, ctx, kind, prefix, count, fun) do
    unique = InfluxElixir.IntegrationHelper.unique_name(prefix)
    names = for i <- 1..count, do: "#{unique}_#{i}"

    try do
      fun.(names)
    after
      Enum.each(names, fn name ->
        _result =
          case kind do
            :database -> client.delete_database(ctx.conn, name)
            :bucket -> client.delete_bucket(ctx.conn, name)
          end
      end)
    end
  end

  @doc false
  # Runs `sql` with `__M__` replaced by the context's measurement name.
  @spec don(module(), map(), binary()) :: term()
  def don(client, ctx, sql) do
    client.query_sql(ctx.conn, String.replace(sql, "__M__", ctx.m), database: ctx.database)
  end

  @doc false
  # Runs `sql` with `__M__` replaced by the context's measurement name, quoted.
  @spec ident(module(), map(), binary()) :: term()
  def ident(client, ctx, sql) do
    client.query_sql(ctx.conn, String.replace(sql, "__M__", ~s("#{ctx.m}")),
      database: ctx.database
    )
  end

  @doc false
  # The result of `sql` on the context's database.
  @spec run(module(), map(), binary()) :: term()
  def run(client, ctx, sql), do: client.query_sql(ctx.conn, sql, database: ctx.database)

  @doc false
  # The rows `sql` returns; the query must succeed.
  @spec rows(module(), map(), binary()) :: [map()]
  def rows(client, ctx, sql) do
    {:ok, rows} = run(client, ctx, sql)
    rows
  end

  @doc false
  # The `key` column of the rows `sql` returns.
  @spec column(module(), map(), binary(), binary()) :: [term()]
  def column(client, ctx, key, sql) do
    client |> rows(ctx, sql) |> Enum.map(& &1[key])
  end

  @doc false
  # The `v` column of an InfluxQL SELECT over the context's measurement `m`.
  @spec where_values(module(), map(), binary()) :: [term()]
  def where_values(client, ctx, where) do
    {:ok, rows} =
      client.query_influxql(ctx.conn, "SELECT v FROM #{ctx.m} WHERE #{where}",
        database: ctx.database
      )

    Enum.map(rows, & &1["v"])
  end

  @doc false
  # The times, as unix seconds in time order, of the rows of `m` matching `where`.
  @spec unix_times(module(), map(), binary()) :: [integer()]
  def unix_times(client, ctx, where) do
    client
    |> rows(ctx, "SELECT time FROM #{ctx.m} WHERE #{where} ORDER BY time")
    |> Enum.map(&DateTime.to_unix(&1["time"]))
  end

  @doc false
  # InfluxDB 3's answer to a `precision` it does not know.
  @spec bad_precision(binary()) :: binary()
  def bad_precision(name) do
    "serde error: unknown variant `#{name}`, expected one of `auto`, `s`, `second`, " <>
      "`millisecond`, `ms`, `microsecond`, `u`, `us`, `n`, `nanosecond`, `ns`"
  end

  @doc false
  # The engine's message for a column it cannot find, exactly:
  # `Schema error: No field named <printed>. Valid fields are ...`. `columns`
  # are the table's, qualified by `table` and sorted by bytes; `projection`
  # are the select list's own fields (already rendered), which ORDER BY and
  # GROUP BY list first.
  @spec no_field(binary(), binary(), [binary()], [binary()]) :: binary()
  def no_field(printed, table, columns, projection \\ []) do
    InfluxElixir.Contract.SQLParser.no_field(
      printed,
      projection ++ InfluxElixir.Contract.SQLParser.fields(table, Enum.sort(columns))
    )
  end

  # ---------------------------------------------------------------------------
  # Health (all profiles)
  # ---------------------------------------------------------------------------
end
