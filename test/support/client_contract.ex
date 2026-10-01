defmodule InfluxElixir.ClientContract do
  @moduledoc """
  Shared contract test template for InfluxDB client implementations.

  This module defines a complete set of assertions covering every callback
  in `InfluxElixir.Client`. The **same** assertions run against both
  `InfluxElixir.Client.Local` and `InfluxElixir.Client.HTTP`, proving
  behavioral equivalence.

  ## Usage

  Each "using" module provides connection setup and declares a profile:

      defmodule MyApp.ContractLocalV3CoreTest do
        use InfluxElixir.ClientContract,
          client: InfluxElixir.Client.Local,
          profile: :v3_core

        setup do
          {:ok, conn} = Local.start(databases: ["contract_db"], profile: :v3_core)
          on_exit(fn -> Local.stop(conn) end)
          {:ok, conn: conn, database: "contract_db", query_delay: 0}
        end
      end

  ## Context keys

  The `setup` callback must return:

    * `conn` — client connection (keyword list or map)
    * `database` — test database name
    * `query_delay` — ms to sleep between write and query
      (0 for Local, 500 for real InfluxDB)

  ## Profile gating

  Test blocks are only compiled for profiles that support them.
  The profile is known at compile time, so unsupported test blocks
  are simply not generated — zero runtime overhead.
  """

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)
    profile = Keyword.fetch!(opts, :profile)

    # Determine which feature groups this profile supports
    v3_sql = profile in [:v3_core, :v3_enterprise]
    v2_ops = profile == :v2

    health_tests = health_tests(client, if(v2_ops, do: :v2, else: :v3))
    write_tests = write_tests(client, profile)

    sql_tests = if v3_sql, do: sql_tests(client), else: nil
    roundtrip_tests = if v3_sql, do: roundtrip_tests(client), else: nil
    stream_tests = if v3_sql, do: stream_tests(client), else: nil
    aggregate_tests = if v3_sql, do: aggregate_tests(client), else: nil
    stats_tests = if v3_sql, do: stats_tests(client), else: nil
    time_filter_tests = if v3_sql, do: time_filter_tests(client), else: nil
    cte_tests = if v3_sql, do: cte_tests(client), else: nil
    where_tests = if v3_sql, do: where_tests(client), else: nil
    scalar_function_tests = if v3_sql, do: scalar_function_tests(client), else: nil
    scalar_function_error_tests = if v3_sql, do: scalar_function_error_tests(client), else: nil
    median_join_tests = if v3_sql, do: median_join_tests(client), else: nil
    cast_tests = if v3_sql, do: cast_tests(client), else: nil
    schema_rule_tests = if v3_sql, do: schema_rule_tests(client), else: nil
    write_rule_tests = if v3_sql, do: write_rule_tests(client), else: nil
    duplicate_tests = if v3_sql, do: duplicate_tests(client), else: nil
    offset_tests = if v3_sql, do: offset_tests(client), else: nil
    ordered_agg_tests = if v3_sql, do: ordered_agg_tests(client), else: nil
    distinct_tests = if v3_sql, do: distinct_tests(client), else: nil
    param_tests = if v3_sql, do: param_tests(client), else: nil
    literal_tests = if v3_sql, do: literal_tests(client), else: nil
    precision_tests = if v3_sql, do: precision_tests(client), else: nil
    gzip_tests = if v3_sql, do: gzip_tests(client), else: nil
    escaping_tests = if v3_sql, do: escaping_tests(client), else: nil

    execute_tests =
      cond do
        profile == :v3_enterprise -> execute_tests_enterprise(client)
        v3_sql -> execute_tests_core(client)
        true -> nil
      end

    influxql_tests = if v3_sql, do: influxql_tests(client), else: nil
    influxql_select_tests = if v3_sql, do: influxql_select_tests(client), else: nil
    reference_tests = if v3_sql, do: reference_tests(client), else: nil
    null_semantics_tests = if v3_sql, do: null_semantics_tests(client), else: nil
    atomic_write_tests = if v3_sql, do: atomic_write_tests(client), else: nil
    db_admin_tests = if v3_sql, do: db_admin_tests(client), else: nil
    format_tests = if v3_sql, do: format_tests(client), else: nil
    database_rule_tests = if v3_sql, do: database_rule_tests(client), else: nil
    distinct_on_tests = if v3_sql, do: distinct_on_tests(client), else: nil
    identifier_tests = if v3_sql, do: identifier_tests(client), else: nil
    influxql_where_tests = if v3_sql, do: influxql_where_tests(client), else: nil
    tab_tests = if v3_sql, do: tab_tests(client), else: nil
    timestamp_range_tests = timestamp_range_tests(client, if(v2_ops, do: :v2, else: :v3))

    bucket_tests = if v2_ops, do: bucket_tests(client), else: nil
    v2_write_rule_tests = if v2_ops, do: v2_write_rule_tests(client), else: nil
    v2_body_tests = if v2_ops, do: v2_body_tests(client), else: nil
    v2_precision_tests = if v2_ops, do: v2_precision_tests(client), else: nil
    v2_duplicate_tests = if v2_ops, do: v2_duplicate_tests(client), else: nil
    v2_flux_pipeline_tests = if v2_ops, do: v2_flux_pipeline_tests(client), else: nil
    flux_tests = if v2_ops, do: flux_tests(client), else: nil

    blocks =
      [
        health_tests,
        write_tests,
        sql_tests,
        roundtrip_tests,
        stream_tests,
        aggregate_tests,
        stats_tests,
        time_filter_tests,
        cte_tests,
        where_tests,
        scalar_function_tests,
        scalar_function_error_tests,
        median_join_tests,
        cast_tests,
        schema_rule_tests,
        write_rule_tests,
        duplicate_tests,
        offset_tests,
        ordered_agg_tests,
        distinct_tests,
        param_tests,
        literal_tests,
        precision_tests,
        gzip_tests,
        escaping_tests,
        execute_tests,
        influxql_tests,
        influxql_select_tests,
        reference_tests,
        null_semantics_tests,
        atomic_write_tests,
        db_admin_tests,
        format_tests,
        database_rule_tests,
        distinct_on_tests,
        identifier_tests,
        influxql_where_tests,
        tab_tests,
        timestamp_range_tests,
        bucket_tests,
        v2_write_rule_tests,
        v2_body_tests,
        v2_precision_tests,
        v2_duplicate_tests,
        v2_flux_pipeline_tests,
        flux_tests
      ]
      |> Enum.reject(&is_nil/1)

    quote do
      (unquote_splicing(blocks))
    end
  end

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
  # InfluxDB 3's answer to a `precision` it does not know.
  @spec bad_precision(binary()) :: binary()
  def bad_precision(name) do
    "serde error: unknown variant `#{name}`, expected one of `auto`, `s`, `second`, " <>
      "`millisecond`, `ms`, `microsecond`, `u`, `us`, `n`, `nanosecond`, `ns`"
  end

  @doc false
  # The columns the engine's `Schema error: No field named <name>. Valid fields
  # are ...` lists, as bare names, sorted and without repeats; nil for any
  # other message. The engine qualifies each with its table and quotes a
  # mixed-case one (`"T"."Host"`, `t.price`), and repeats a column the clause
  # refers to; `Client.Local` lists bare names once.
  @spec unknown_field(binary(), binary(), binary()) :: [binary()] | nil
  def unknown_field(body, name, table) do
    prefix = "Schema error: No field named #{name}. Valid fields are "

    if String.starts_with?(body, prefix) do
      body
      |> String.replace_prefix(prefix, "")
      |> String.trim_trailing(".")
      |> String.split(", ")
      |> Enum.map(fn ref ->
        ref
        |> String.replace(~s("#{table}".), "")
        |> String.replace("#{table}.", "")
        |> String.trim(~s("))
      end)
      |> Enum.uniq()
      |> Enum.sort()
    end
  end

  # ---------------------------------------------------------------------------
  # Health (all profiles)
  # ---------------------------------------------------------------------------

  defp health_tests(client, version) do
    quote do
      describe "health/1" do
        test "reports a passing status in the server's shape", ctx do
          {:ok, health} = unquote(client).health(ctx.conn)

          case unquote(version) do
            # InfluxDB 3's /health is a plain "OK".
            :v3 ->
              assert health == %{"status" => "pass"}

            :v2 ->
              assert %{
                       "name" => "influxdb",
                       "message" => "ready for queries and writes",
                       "status" => "pass",
                       "checks" => [],
                       "version" => version,
                       "commit" => commit
                     } = health

              assert is_binary(version) and is_binary(commit)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Write (all profiles)
  # ---------------------------------------------------------------------------

  defp write_tests(client, profile) do
    ghost_db_test =
      if profile in [:v3_core, :v3_enterprise] do
        quote do
          test "accepts write to a non-pre-existing database", ctx do
            on_exit(fn ->
              try do
                unquote(client).delete_database(ctx.conn, "ghost_db_contract")
              rescue
                _err -> :ok
              end
            end)

            lp = "cpu value=1.0"

            assert {:ok, :written} =
                     unquote(client).write(
                       ctx.conn,
                       lp,
                       database: "ghost_db_contract"
                     )
          end
        end
      else
        quote do
          test "a write to a bucket that does not exist is the engine's 404", ctx do
            name = "contract_nowrite_#{System.unique_integer([:positive])}"

            assert {:error, %{status: 404, body: body}} =
                     unquote(client).write(ctx.conn, "m v=1i", database: name)

            assert Jason.decode!(body) == %{
                     "code" => "not found",
                     "message" => ~s|bucket "#{name}" not found|
                   }
          end
        end
      end

    malformed_test =
      if profile == :v2 do
        quote do
          test "malformed line protocol is the engine's 400", ctx do
            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(
                       ctx.conn,
                       "this is not line protocol!!",
                       database: ctx.database
                     )

            assert Jason.decode!(body) == %{
                     "code" => "invalid",
                     "message" =>
                       "unable to parse 'this is not line protocol!!': invalid field format"
                   }
          end
        end
      else
        quote do
          # The engine's body, `original_line` cut to 20 bytes.
          test "malformed line protocol is the engine's 400, line by line", ctx do
            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(
                       ctx.conn,
                       "this is not line protocol!!",
                       database: ctx.database
                     )

            assert Jason.decode!(body) == %{
                     "error" => "partial write of line protocol occurred",
                     "data" => [
                       %{
                         "error_message" => "No fields were provided",
                         "line_number" => 1,
                         "original_line" => "this is not line pro"
                       }
                     ]
                   }
          end
        end
      end

    quote do
      describe "write/3 — contract" do
        test "accepts valid line protocol and returns {:ok, :written}",
             ctx do
          lp = "cpu,host=server01 value=0.64 1630424257000000000"

          assert {:ok, :written} ==
                   unquote(client).write(
                     ctx.conn,
                     lp,
                     database: ctx.database
                   )
        end

        unquote(ghost_db_test)

        unquote(malformed_test)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Database admin (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp db_admin_tests(client) do
    quote do
      describe "create_database/3 — contract" do
        test "returns :ok for a new database name", ctx do
          on_exit(fn ->
            try do
              unquote(client).delete_database(ctx.conn, "contract_new_db")
            rescue
              _err -> :ok
            end
          end)

          assert :ok ==
                   unquote(client).create_database(
                     ctx.conn,
                     "contract_new_db",
                     []
                   )
        end

        test "is idempotent — creating a duplicate returns :ok", ctx do
          on_exit(fn ->
            try do
              unquote(client).delete_database(ctx.conn, "contract_dup")
            rescue
              _err -> :ok
            end
          end)

          assert :ok ==
                   unquote(client).create_database(
                     ctx.conn,
                     "contract_dup",
                     []
                   )

          assert :ok ==
                   unquote(client).create_database(
                     ctx.conn,
                     "contract_dup",
                     []
                   )
        end
      end

      describe "list_databases/1 — contract" do
        test "includes the test database", ctx do
          {:ok, dbs} = unquote(client).list_databases(ctx.conn)
          names = Enum.map(dbs, & &1["name"])
          assert ctx.database in names
        end

        test "includes newly created databases", ctx do
          on_exit(fn ->
            try do
              unquote(client).delete_database(ctx.conn, "contract_extra_db")
            rescue
              _err -> :ok
            end
          end)

          :ok =
            unquote(client).create_database(
              ctx.conn,
              "contract_extra_db",
              []
            )

          {:ok, dbs} = unquote(client).list_databases(ctx.conn)
          names = Enum.map(dbs, & &1["name"])
          assert "contract_extra_db" in names
        end
      end

      describe "delete_database/2 — contract" do
        test "returns :ok for an existing database", ctx do
          :ok =
            unquote(client).create_database(
              ctx.conn,
              "contract_to_delete",
              []
            )

          assert :ok ==
                   unquote(client).delete_database(
                     ctx.conn,
                     "contract_to_delete"
                   )
        end

        test "database is no longer listed after deletion", ctx do
          :ok =
            unquote(client).create_database(
              ctx.conn,
              "contract_gone_db",
              []
            )

          :ok =
            unquote(client).delete_database(ctx.conn, "contract_gone_db")

          {:ok, dbs} = unquote(client).list_databases(ctx.conn)
          names = Enum.map(dbs, & &1["name"])
          refute "contract_gone_db" in names
        end

        test "deleting a database that does not exist is the engine's 404", ctx do
          name = "contract_nodb_#{System.unique_integer([:positive])}"

          assert {:error, %{status: 404, body: "the requested resource was not found: " <> ^name}} =
                   unquote(client).delete_database(ctx.conn, name)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Query SQL (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp sql_tests(client) do
    quote do
      describe "query_sql/3 — basic SELECT contract" do
        test "a line without a timestamp is stamped with the server's current time", ctx do
          # The server's clock may differ from ours by a little, so bracket generously.
          before_write = DateTime.add(DateTime.utc_now(), -60, :second)

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "auto_ts_sql,host=a value=1i",
              database: ctx.database
            )

          after_write = DateTime.add(DateTime.utc_now(), 60, :second)

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [row]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM auto_ts_sql",
                     database: ctx.database
                   )

          assert %{"host" => "a", "value" => 1, "time" => %DateTime{} = time} = row
          assert DateTime.compare(time, before_write) == :gt
          assert DateTime.compare(time, after_write) == :lt
        end

        test "returns error for non-existent measurement", ctx do
          result =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM empty_measurement_contract",
              database: ctx.database
            )

          assert {:error,
                  %{
                    status: 400,
                    body:
                      "Error during planning: table 'public.iox.empty_measurement_contract' not found"
                  }} = result
        end

        test "LIMIT restricts the number of returned rows", ctx do
          Enum.each(1..5, fn i ->
            unquote(client).write(
              ctx.conn,
              "contract_limited value=#{i}i #{i * 1_000_000_000}",
              database: ctx.database
            )
          end)

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok,
                  [
                    %{"value" => 1, "time" => ~U[1970-01-01 00:00:01.000000Z]},
                    %{"value" => 2, "time" => ~U[1970-01-01 00:00:02.000000Z]}
                  ]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_limited ORDER BY time LIMIT 2",
                     database: ctx.database
                   )
        end

        test "ORDER BY time DESC returns most-recent rows first", ctx do
          # Written out of order, so the result can only be ordered by the query.
          Enum.each([2, 3, 1], fn s ->
            unquote(client).write(
              ctx.conn,
              "contract_ordered value=#{s * 100}i #{s * 1_000_000_000}",
              database: ctx.database
            )
          end)

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok,
                  [
                    %{"value" => 300, "time" => ~U[1970-01-01 00:00:03.000000Z]},
                    %{"value" => 200, "time" => ~U[1970-01-01 00:00:02.000000Z]},
                    %{"value" => 100, "time" => ~U[1970-01-01 00:00:01.000000Z]}
                  ]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_ordered ORDER BY time DESC",
                     database: ctx.database
                   )

          assert {:ok, ascending} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT value FROM contract_ordered ORDER BY time ASC",
                     database: ctx.database
                   )

          assert Enum.map(ascending, & &1["value"]) == [100, 200, 300]
        end

        test "WHERE clause filters by tag value", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_tagged,host=alpha value=1i 1000000000",
            database: ctx.database
          )

          unquote(client).write(
            ctx.conn,
            "contract_tagged,host=beta value=2i 2000000000",
            database: ctx.database
          )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok,
                  [%{"host" => "alpha", "value" => 1, "time" => ~U[1970-01-01 00:00:01.000000Z]}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_tagged WHERE host = 'alpha'",
                     database: ctx.database
                   )
        end
      end

      unquote(multi_measurement_tests(client))
    end
  end

  defp multi_measurement_tests(client) do
    quote do
      describe "query_sql/3 — multiple measurements contract" do
        test "querying one measurement does not return rows from another",
             ctx do
          unquote(client).write(
            ctx.conn,
            "contract_a value=1i 1000000000",
            database: ctx.database
          )

          unquote(client).write(
            ctx.conn,
            "contract_b value=2i 2000000000",
            database: ctx.database
          )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"value" => 1, "time" => ~U[1970-01-01 00:00:01.000000Z]}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_a",
                     database: ctx.database
                   )

          assert {:ok, [%{"value" => 2, "time" => ~U[1970-01-01 00:00:02.000000Z]}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_b",
                     database: ctx.database
                   )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Write + query round-trip (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp roundtrip_tests(client) do
    quote do
      describe "field type round-trips — contract" do
        test "integer field survives write/query cycle", ctx do
          ts = System.os_time(:nanosecond)
          lp = "contract_rt,type=int count=#{ts}i #{ts}"

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_rt WHERE type = 'int' LIMIT 1",
              database: ctx.database
            )

          assert [%{"count" => ^ts}] = rows
        end

        test "float field survives write/query cycle", ctx do
          lp = "contract_rt,type=float ratio=3.14"

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_rt WHERE type = 'float' LIMIT 1",
              database: ctx.database
            )

          assert [%{"ratio" => 3.14}] = rows
        end

        test "string field survives write/query cycle", ctx do
          lp = ~s(contract_rt,type=string label="hello world")

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_rt WHERE type = 'string' LIMIT 1",
              database: ctx.database
            )

          assert [%{"label" => "hello world"}] = rows
        end

        test "boolean field survives write/query cycle", ctx do
          lp = "contract_rt,type=bool active=true"

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_rt WHERE type = 'bool' LIMIT 1",
              database: ctx.database
            )

          assert [%{"active" => true}] = rows
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Query SQL stream (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp stream_tests(client) do
    quote do
      describe "query_sql_stream/3 — contract" do
        test "returns enumerable rows", ctx do
          Enum.each(1..5, fn i ->
            {:ok, :written} =
              unquote(client).write(
                ctx.conn,
                "contract_stream value=#{i}i #{i * 1_000_000}",
                database: ctx.database
              )
          end)

          InfluxElixir.ClientContract.settle(ctx)

          stream =
            unquote(client).query_sql_stream(
              ctx.conn,
              "SELECT * FROM contract_stream",
              database: ctx.database
            )

          assert stream |> Enum.to_list() |> Enum.map(& &1["value"]) |> Enum.sort() == [
                   1,
                   2,
                   3,
                   4,
                   5
                 ]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Execute SQL (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp execute_tests_core(client) do
    quote do
      describe "execute_sql/3 — contract" do
        test "DML and DDL are refused with the engine's answer; SELECT returns rows", ctx do
          {:ok, :written} =
            unquote(client).write(ctx.conn, "contract_del value=1i 1700000000000000000",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)
          exec = &unquote(client).execute_sql(ctx.conn, &1, database: ctx.database)

          assert {:error,
                  %{status: 400, body: "Error during planning: DML not supported: Delete"}} =
                   exec.("DELETE FROM contract_del")

          assert {:error,
                  %{
                    status: 400,
                    body: "Error during planning: DDL not supported: CreateMemoryTable"
                  }} =
                   exec.("CREATE TABLE contract_x (id INT)")

          assert {:error,
                  %{
                    status: 405,
                    body:
                      "This feature is not implemented: Unsupported SQL statement: " <>
                        "ALTER TABLE contract_del ADD COLUMN y INT"
                  }} =
                   exec.("ALTER TABLE contract_del ADD COLUMN y INT")

          {:ok, rows} =
            unquote(client).query_sql(ctx.conn, "SELECT * FROM contract_del",
              database: ctx.database
            )

          assert {:ok, ^rows} = exec.("SELECT * FROM contract_del")
          assert [%{"value" => 1, "time" => %DateTime{}}] = rows
        end

        # Client.HTTP dropped `params`, so the placeholder was the engine's
        # 400 "No value found for placeholder with name $host" (verified).
        test "binds params as query_sql/3 does", ctx do
          m = "contract_exparams_#{System.unique_integer([:positive])}"

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},host=a v=1i 1\n#{m},host=b v=2i 2",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"v" => 2}]} =
                   unquote(client).execute_sql(ctx.conn, "SELECT v FROM #{m} WHERE host = $host",
                     database: ctx.database,
                     params: %{host: "b"}
                   )
        end

        # Client.HTTP read `database: nil` as the database; Client.Local
        # and the facade's telemetry as no database given.
        test "database: nil is no database given: the connection's default is used", ctx do
          conn = InfluxElixir.ClientContract.with_database(ctx.conn, ctx.database)
          m = "contract_nildb_#{System.unique_integer([:positive])}"

          assert {:ok, :written} = unquote(client).write(conn, "#{m} v=1i 1", database: nil)
          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"v" => 1}]} =
                   unquote(client).query_sql(conn, "SELECT v FROM #{m}", database: nil)

          assert {:ok, [%{"v" => 1}]} =
                   unquote(client).execute_sql(conn, "SELECT v FROM #{m}", database: nil)
        end
      end
    end
  end

  defp execute_tests_enterprise(client) do
    quote do
      describe "execute_sql/3 — contract" do
        test "DELETE FROM removes written data", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_del value=1i",
            database: ctx.database
          )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, %{"rows_affected" => 1}} =
                   unquote(client).execute_sql(
                     ctx.conn,
                     "DELETE FROM contract_del",
                     database: ctx.database
                   )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxQL (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp influxql_tests(client) do
    quote do
      describe "query_influxql/3 — contract" do
        test "SHOW DATABASES returns list including test database", ctx do
          {:ok, dbs} =
            unquote(client).query_influxql(ctx.conn, "SHOW DATABASES")

          names = Enum.map(dbs, & &1["iox::database"])
          assert ctx.database in names
        end

        test "SHOW MEASUREMENTS returns measurement names", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_iql_m value=1i",
            database: ctx.database
          )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, measurements} =
            unquote(client).query_influxql(
              ctx.conn,
              "SHOW MEASUREMENTS",
              database: ctx.database
            )

          names = Enum.map(measurements, & &1["name"])
          assert "contract_iql_m" in names

          Enum.each(measurements, fn m ->
            assert m["iox::measurement"] == "measurements"
          end)
        end

        test "SHOW TAG KEYS FROM returns tag keys", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_iql_tags,host=web01,region=us value=1i",
            database: ctx.database
          )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, tag_keys} =
            unquote(client).query_influxql(
              ctx.conn,
              "SHOW TAG KEYS FROM contract_iql_tags",
              database: ctx.database
            )

          keys = Enum.map(tag_keys, & &1["tagKey"])
          assert "host" in keys
          assert "region" in keys

          Enum.each(tag_keys, fn tk ->
            assert tk["iox::measurement"] == "contract_iql_tags"
          end)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Bucket admin (v2)
  # ---------------------------------------------------------------------------

  defp bucket_tests(client) do
    quote do
      describe "bucket admin — contract" do
        # A v2 bucket name may hold characters that mean something in a
        # query string. `a&b` used to be written to bucket `a`, `c+d` to
        # `c d` and `e#f` to `e` (verified against InfluxDB 2.7).
        test "a bucket name with &, +, # and = is written to and deleted by name", ctx do
          name = "contract a&b+c#d=e #{System.unique_integer([:positive])}"
          assert :ok = unquote(client).create_bucket(ctx.conn, name, [])

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, "enc v=1i 1",
                     database: name,
                     precision: :second
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"_value" => 1}]} =
                   unquote(client).query_flux(
                     ctx.conn,
                     ~s|from(bucket: "#{name}") \|> range(start: 0)|
                   )

          assert :ok = unquote(client).delete_bucket(ctx.conn, name)
          {:ok, buckets} = unquote(client).list_buckets(ctx.conn)
          refute name in Enum.map(buckets, & &1["name"])
        end

        # InfluxDB 2 pages the list; only its first 20 buckets used to be
        # returned (verified).
        test "list_buckets returns every bucket, past the server's page size", ctx do
          prefix = "contract_page_#{System.unique_integer([:positive])}_"
          names = for i <- 1..101, do: prefix <> Integer.to_string(i)

          Enum.each(names, &(:ok = unquote(client).create_bucket(ctx.conn, &1, [])))

          {:ok, buckets} = unquote(client).list_buckets(ctx.conn)
          listed = for %{"name" => name} <- buckets, String.starts_with?(name, prefix), do: name
          assert Enum.sort(listed) == Enum.sort(names)

          Enum.each(names, &(:ok = unquote(client).delete_bucket(ctx.conn, &1)))
        end

        test "create_bucket returns :ok", ctx do
          assert :ok ==
                   unquote(client).create_bucket(
                     ctx.conn,
                     "contract_bucket",
                     []
                   )
        end

        test "list_buckets lists a created bucket as a user bucket with no expiry", ctx do
          name = "contract_list_bkt_#{System.unique_integer([:positive])}"
          :ok = unquote(client).create_bucket(ctx.conn, name, [])

          {:ok, buckets} = unquote(client).list_buckets(ctx.conn)
          assert Enum.all?(buckets, &is_map/1)

          assert [
                   %{
                     "name" => ^name,
                     "type" => "user",
                     "id" => id,
                     "orgID" => org_id,
                     "retentionRules" => [%{"type" => "expire", "everySeconds" => 0}]
                   }
                 ] = Enum.filter(buckets, &(&1["name"] == name))

          assert is_binary(id) and is_binary(org_id)
          :ok = unquote(client).delete_bucket(ctx.conn, name)
        end

        test "delete_bucket removes a bucket", ctx do
          name = "contract_del_bkt_#{System.unique_integer([:positive])}"
          :ok = unquote(client).create_bucket(ctx.conn, name, [])

          {:ok, before_delete} = unquote(client).list_buckets(ctx.conn)
          assert name in Enum.map(before_delete, & &1["name"])

          assert :ok == unquote(client).delete_bucket(ctx.conn, name)

          {:ok, after_delete} = unquote(client).list_buckets(ctx.conn)
          refute name in Enum.map(after_delete, & &1["name"])
        end

        test "a bucket created via create_bucket accepts writes", ctx do
          :ok = unquote(client).create_bucket(ctx.conn, "contract_write_bkt", [])

          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "contract_bkt_write value=1i",
                     database: "contract_write_bkt"
                   )
        end

        test "a retention rule is stored in seconds; under one hour is refused", ctx do
          name = "contract_ret_#{System.unique_integer([:positive])}"
          :ok = unquote(client).create_bucket(ctx.conn, name, retention: 3600)

          {:ok, buckets} = unquote(client).list_buckets(ctx.conn)
          bucket = Enum.find(buckets, &(&1["name"] == name))
          assert [%{"type" => "expire", "everySeconds" => 3600}] = bucket["retentionRules"]

          assert {:error, %{status: 500, body: body}} =
                   unquote(client).create_bucket(ctx.conn, name <> "_short", retention: 60)

          assert %{"message" => "retention policy duration must be at least 1h0m0s"} =
                   Jason.decode!(body)
        end

        test "deleting a bucket that does not exist is a 404", ctx do
          name = "contract_nobkt_#{System.unique_integer([:positive])}"

          assert {:error, %{status: 404, body: "bucket not found: " <> ^name}} =
                   unquote(client).delete_bucket(ctx.conn, name)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Flux query (v2)
  # ---------------------------------------------------------------------------

  defp flux_tests(client) do
    quote do
      describe "query_flux/3 — contract" do
        test "returns long-format rows with typed values", ctx do
          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "contract_flux,host=web01 value=42.0,count=3i",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          flux = """
          from(bucket: "#{ctx.database}")
            |> range(start: -1h)
            |> filter(fn: (r) => r._measurement == "contract_flux")
          """

          {:ok, rows} = unquote(client).query_flux(ctx.conn, flux)

          # One row per field, values typed, timestamps as DateTime.
          by_field = Map.new(rows, &{&1["_field"], &1})
          assert %{"_value" => 42.0, "host" => "web01"} = by_field["value"]
          assert %{"_value" => 3, "_measurement" => "contract_flux"} = by_field["count"]
          assert %DateTime{} = by_field["value"]["_time"]
          assert Enum.all?(rows, &(&1["result"] == "_result" and is_integer(&1["table"])))
        end

        test "filters on _field keep only that field", ctx do
          # Unique measurement: a real server keeps data between runs.
          measurement = "contract_flux_field_#{System.unique_integer([:positive])}"

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "#{measurement} a=1.0,b=2.0",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          flux = """
          from(bucket: "#{ctx.database}")
            |> range(start: -1h)
            |> filter(fn: (r) => r._measurement == "#{measurement}")
            |> filter(fn: (r) => r._field == "b")
          """

          {:ok, rows} = unquote(client).query_flux(ctx.conn, flux)
          assert [%{"_field" => "b", "_value" => 2.0}] = rows
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Aggregate SQL queries (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp aggregate_tests(client) do
    quote do
      describe "query_sql/3 — aggregate contract" do
        setup ctx do
          # Known timestamps, written out of order
          base_ts = 1_700_000_000_000_000_000

          Enum.each([3, 0, 5, 1, 4, 2], fn i ->
            ts = base_ts + i * 60_000_000_000
            val = (i + 1) * 10

            {:ok, :written} =
              unquote(client).write(
                ctx.conn,
                "contract_agg value=#{val}i #{ts}",
                database: ctx.database
              )
          end)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, agg_base_ts: base_ts}
        end

        test "AVG aggregate with GROUP BY DATE_BIN", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '2 minutes', time) AS time,
            AVG(value) AS avg_val
          FROM contract_agg
          GROUP BY DATE_BIN(INTERVAL '2 minutes', time)
          ORDER BY time ASC
          """

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              sql,
              database: ctx.database
            )

          assert rows == [
                   %{"time" => ~U[2023-11-14 22:12:00.000000Z], "avg_val" => 10.0},
                   %{"time" => ~U[2023-11-14 22:14:00.000000Z], "avg_val" => 25.0},
                   %{"time" => ~U[2023-11-14 22:16:00.000000Z], "avg_val" => 45.0},
                   %{"time" => ~U[2023-11-14 22:18:00.000000Z], "avg_val" => 60.0}
                 ]
        end

        test "SUM aggregate returns total", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '1 hour', time) AS time,
            SUM(value) AS total
          FROM contract_agg
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          """

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              sql,
              database: ctx.database
            )

          # All six points fall in the 22:00 hour: 10+20+30+40+50+60.
          assert [%{"total" => 210}] = rows
        end

        test "COUNT aggregate returns row count", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '1 hour', time) AS time,
            COUNT(value) AS cnt
          FROM contract_agg
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          """

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              sql,
              database: ctx.database
            )

          assert [%{"cnt" => 6}] = rows
        end

        test "MIN and MAX aggregates", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '1 hour', time) AS time,
            MIN(value) AS min_val,
            MAX(value) AS max_val
          FROM contract_agg
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          """

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              sql,
              database: ctx.database
            )

          assert [%{"min_val" => 10, "max_val" => 60}] = rows
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Statistical aggregates, expressions, selectors, ORDER BY alias (#16, #17)
  # ---------------------------------------------------------------------------

  defp stats_tests(client) do
    quote do
      describe "query_sql/3 — statistics and selectors contract" do
        setup ctx do
          # Same six points as the aggregate contract: 10..60 one minute apart.
          base_ts = 1_700_000_000_000_000_000

          Enum.each([3, 0, 5, 1, 4, 2], fn i ->
            ts = base_ts + i * 60_000_000_000
            val = (i + 1) * 10

            {:ok, :written} =
              unquote(client).write(
                ctx.conn,
                "contract_agg value=#{val}i #{ts}",
                database: ctx.database
              )
          end)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, agg_base_ts: base_ts}
        end

        test "STDDEV / VAR family, expression arguments and null omission (#16)",
             ctx do
          sql = """
          SELECT
            COUNT(value) AS n,
            STDDEV(value) AS sd,
            STDDEV_POP(value) AS sd_pop,
            VAR(value) AS v,
            VAR_POP(value) AS v_pop,
            SUM(value * value) AS sum_sq,
            AVG(value / 2) AS half_avg,
            MAX(value - 1) AS max_less_one
          FROM contract_agg
          """

          {:ok, [row]} =
            unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          # values 10..60 step 10
          assert row["n"] == 6
          assert_in_delta row["sd"], 18.708286933869708, 1.0e-9
          assert_in_delta row["sd_pop"], 17.07825127659933, 1.0e-9
          assert_in_delta row["v"], 350.0, 1.0e-9
          assert_in_delta row["v_pop"], 291.6666666666667, 1.0e-9
          assert row["sum_sq"] == 9100
          assert row["half_avg"] == 17.5
          assert row["max_less_one"] == 59

          # A sample statistic over one row is null, and a null column is
          # absent from the row rather than present as nil.
          sql_one = """
          SELECT STDDEV(value) AS sd, COUNT(value) AS n
          FROM contract_agg
          WHERE value = 10
          """

          {:ok, [one]} =
            unquote(client).query_sql(ctx.conn, sql_one, database: ctx.database)

          assert one["n"] == 1
          refute Map.has_key?(one, "sd")
        end

        test "selector functions and ORDER BY the DATE_BIN alias (#17)", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '3 minutes', time) AS bucket,
            selector_first(value, time)['value'] AS open,
            selector_max(value, time)['value'] AS high,
            selector_min(value, time)['time'] AS low_at,
            selector_last(value, time)['value'] AS close
          FROM contract_agg
          GROUP BY DATE_BIN(INTERVAL '3 minutes', time)
          ORDER BY bucket DESC
          """

          {:ok, [late, mid, early]} =
            unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          # base_ts is 22:13:20, so 3-minute bins hold [10,20], [30,40,50], [60].
          assert DateTime.compare(late["bucket"], mid["bucket"]) == :gt
          assert DateTime.compare(mid["bucket"], early["bucket"]) == :gt
          assert early["open"] == 10 and early["high"] == 20 and early["close"] == 20
          assert mid["open"] == 30 and mid["high"] == 50 and mid["close"] == 50
          assert late["open"] == 60 and late["high"] == 60 and late["close"] == 60

          # selector_*['time'] is a DateTime on every transport.
          assert early["low_at"] ==
                   ctx.agg_base_ts
                   |> DateTime.from_unix!(:nanosecond)
                   |> DateTime.truncate(:microsecond)
        end

        test "ORDER BY a projected aggregate alias", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '3 minutes', time) AS bucket,
            SUM(value) AS total
          FROM contract_agg
          GROUP BY DATE_BIN(INTERVAL '3 minutes', time)
          ORDER BY total DESC
          """

          {:ok, rows} =
            unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          assert Enum.map(rows, & &1["total"]) == [120, 60, 30]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Time comparands, null checks, COUNT(DISTINCT), aggregates over `time`,
  # DISTINCT ordering — every value recorded from InfluxDB 3 Core first.
  # ---------------------------------------------------------------------------

  defp time_filter_tests(client) do
    quote do
      describe "query_sql/3 — time comparand, null check and COUNT DISTINCT contract" do
        setup ctx do
          now_ns = System.os_time(:nanosecond)

          lp =
            Enum.join(
              [
                "contract_tf,provider=a,symbol=X price=1.0,bid=1.0 #{now_ns - 60_000_000_000}",
                "contract_tf,provider=a,symbol=X price=2.0 #{now_ns - 600_000_000_000}",
                "contract_tf,provider=b,symbol=Y price=3.0,bid=3.0 #{now_ns - 3_600_000_000_000}",
                "contract_tf,provider=c,symbol=Z price=4.0 #{now_ns - 7_200_000_000_000}"
              ],
              "\n"
            )

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)
          :ok
        end

        test "now() - INTERVAL filters relative to the query time", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT price FROM contract_tf WHERE time >= now() - INTERVAL '2 minutes'",
              database: ctx.database
            )

          assert Enum.map(rows, & &1["price"]) == [1.0]
        end

        test "a bare integer time comparand is rejected", ctx do
          assert {:error,
                  %{
                    status: 400,
                    body:
                      "type_coercion\ncaused by\nError during planning: Cannot infer common " <>
                        "argument type for comparison operation Timestamp(ns) > Int64"
                  }} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT price FROM contract_tf WHERE time > 1000000000",
                     database: ctx.database
                   )
        end

        test "an integer param against time is rejected", ctx do
          assert {:error,
                  %{
                    status: 400,
                    body:
                      "type_coercion\ncaused by\nError during planning: Cannot infer common " <>
                        "argument type for comparison operation Timestamp(ns) > UInt64"
                  }} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT price FROM contract_tf WHERE time > $start",
                     database: ctx.database,
                     params: %{start: 1_000_000_000}
                   )
        end

        test "a DateTime param against time selects by instant", ctx do
          start = DateTime.add(DateTime.utc_now(), -120, :second)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT price FROM contract_tf WHERE time >= $start",
              database: ctx.database,
              params: %{start: start}
            )

          assert Enum.map(rows, & &1["price"]) == [1.0]
        end

        test "IS NULL and IS NOT NULL", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT price FROM contract_tf WHERE bid IS NOT NULL ORDER BY price",
              database: ctx.database
            )

          assert Enum.map(rows, & &1["price"]) == [1.0, 3.0]

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT price FROM contract_tf WHERE bid IS NULL ORDER BY price",
              database: ctx.database
            )

          assert Enum.map(rows, & &1["price"]) == [2.0, 4.0]
        end

        unquote(time_filter_distinct_tests(client))
      end
    end
  end

  defp time_filter_distinct_tests(client) do
    quote do
      test "COUNT(DISTINCT col) counts distinct non-null values", ctx do
        {:ok, [row]} =
          unquote(client).query_sql(
            ctx.conn,
            "SELECT COUNT(DISTINCT provider) AS n, COUNT(DISTINCT bid) AS b FROM contract_tf",
            database: ctx.database
          )

        assert row["n"] == 3
        assert row["b"] == 2
      end

      test "MAX(time) and MIN(time) are DateTimes; AVG(time) is rejected", ctx do
        {:ok, [row]} =
          unquote(client).query_sql(
            ctx.conn,
            "SELECT MAX(time) AS mx, MIN(time) AS mn, COUNT(time) AS n FROM contract_tf",
            database: ctx.database
          )

        assert %DateTime{} = row["mx"]
        assert %DateTime{} = row["mn"]
        assert DateTime.compare(row["mx"], row["mn"]) == :gt
        assert row["n"] == 4

        assert {:error,
                %{
                  status: 400,
                  body:
                    "Error during planning: Execution error: Function 'avg' user-defined " <>
                      "coercion failed with \"Error during planning: Avg does not support " <>
                      "inputs of type Timestamp(ns).\" No function matches the given name and " <>
                      "argument types 'avg(Timestamp(ns))'. You might need to add explicit " <>
                      "type casts.\n\tCandidate functions:\n\tavg(UserDefined)"
                }} =
                 unquote(client).query_sql(
                   ctx.conn,
                   "SELECT AVG(time) AS a FROM contract_tf",
                   database: ctx.database
                 )
      end

      test "SELECT DISTINCT honours ORDER BY DESC and LIMIT", ctx do
        {:ok, rows} =
          unquote(client).query_sql(
            ctx.conn,
            "SELECT DISTINCT provider, symbol FROM contract_tf ORDER BY symbol DESC LIMIT 2",
            database: ctx.database
          )

        assert rows == [
                 %{"provider" => "c", "symbol" => "Z"},
                 %{"provider" => "b", "symbol" => "Y"}
               ]
      end

      test "SELECT DISTINCT rejects ORDER BY a column outside the select list", ctx do
        assert {:error,
                %{
                  status: 400,
                  body:
                    "Error during planning: For SELECT DISTINCT, ORDER BY expressions " <>
                      "contract_tf.price must appear in select list"
                }} =
                 unquote(client).query_sql(
                   ctx.conn,
                   "SELECT DISTINCT provider FROM contract_tf ORDER BY price",
                   database: ctx.database
                 )
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Projected expressions, CTEs and table qualifiers (#18)
  # ---------------------------------------------------------------------------

  defp cte_tests(client) do
    quote do
      describe "query_sql/3 — projected expression and CTE contract" do
        setup ctx do
          lp =
            Enum.join(
              [
                "contract_cte,provider=a bid=1.0,ask=3.0 1700000000000000000",
                "contract_cte,provider=a bid=2.0,ask=4.0 1700000060000000000",
                "contract_cte,provider=b bid=5.0,ask=7.0 1700000121000000000",
                "contract_cte,provider=b bid=10.0 1700000120000000000"
              ],
              "\n"
            )

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)
          :ok
        end

        test "arithmetic in a projected column, null omitted, ORDER BY alias", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT (bid + ask) / 2 AS mid, time FROM contract_cte ORDER BY time",
              database: ctx.database
            )

          assert Enum.map(rows, &Map.get(&1, "mid")) == [2.0, 3.0, nil, 6.0]
          refute Map.has_key?(Enum.at(rows, 2), "mid")

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT (bid + ask) / 2 AS mid FROM contract_cte ORDER BY mid DESC",
              database: ctx.database
            )

          assert Enum.map(rows, &Map.get(&1, "mid")) == [nil, 6.0, 3.0, 2.0]
        end

        test "a CTE with a qualified DATE_BIN GROUP BY", ctx do
          sql = """
          WITH w AS (SELECT bid, time FROM contract_cte)
          SELECT DATE_BIN(INTERVAL '1 minute', w.time) AS time, MAX(w.bid) AS hi
          FROM w GROUP BY DATE_BIN(INTERVAL '1 minute', w.time) ORDER BY time
          """

          {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)
          assert Enum.map(rows, & &1["hi"]) == [1.0, 2.0, 10.0]
          assert Enum.all?(rows, &match?(%DateTime{}, &1["time"]))
        end

        test "the candle shape: derived mid in a CTE, selectors over it", ctx do
          sql = """
          WITH w AS (SELECT (bid + ask) / 2 AS mid, time FROM contract_cte WHERE ask IS NOT NULL)
          SELECT
            DATE_BIN(INTERVAL '1 minute', time) AS time,
            selector_first(mid, time)['value'] AS open,
            MAX(mid) AS high,
            selector_last(mid, time)['value'] AS close
          FROM w
          GROUP BY DATE_BIN(INTERVAL '1 minute', time)
          ORDER BY time
          """

          {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          assert Enum.map(rows, &{&1["open"], &1["high"], &1["close"]}) ==
                   [{2.0, 2.0, 2.0}, {3.0, 3.0, 3.0}, {6.0, 6.0, 6.0}]
        end

        test "chained CTEs and table aliases", ctx do
          sql = """
          WITH w AS (SELECT bid, provider, time FROM contract_cte),
               x AS (SELECT provider, MAX(bid) AS mb FROM w GROUP BY provider)
          SELECT * FROM x ORDER BY provider
          """

          {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)
          assert rows == [%{"provider" => "a", "mb" => 2.0}, %{"provider" => "b", "mb" => 10.0}]

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT t.bid FROM contract_cte t WHERE t.provider = 'b' ORDER BY t.bid",
              database: ctx.database
            )

          assert rows == [%{"bid" => 5.0}, %{"bid" => 10.0}]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # WHERE boolean logic, BETWEEN, LIKE, <>, LIMIT 0, string-vs-number
  # ---------------------------------------------------------------------------

  defp where_tests(client) do
    quote do
      describe "query_sql/3 — WHERE boolean logic contract" do
        setup ctx do
          lp =
            Enum.join(
              [
                "contract_wh,host=a,rack=1 v=1.0 1700000001000000000",
                "contract_wh,host=c v=3.0 1700000003000000000",
                "contract_wh,host=d,rack=4 v=4.0 1700000004000000000",
                "contract_wh,host=e,rack=10 v=5.0 1700000005000000000",
                "contract_wh,host=b,rack=2 v=2.5 1700000002000000000"
              ],
              "\n"
            )

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)
          :ok
        end

        test "OR, NOT, parentheses and precedence", ctx do
          hosts = fn sql ->
            {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)
            Enum.map(rows, & &1["host"])
          end

          assert hosts.("SELECT host FROM contract_wh WHERE v > 3 OR v < 2 ORDER BY host") ==
                   ["a", "d", "e"]

          assert hosts.(
                   "SELECT host FROM contract_wh WHERE host = 'a' OR host = 'b' AND v > 2 ORDER BY host"
                 ) ==
                   ["a", "b"]

          assert hosts.("SELECT host FROM contract_wh WHERE (host = 'a' OR host = 'b') AND v > 2") ==
                   ["b"]

          assert hosts.(
                   "SELECT host FROM contract_wh WHERE NOT (host = 'a' OR host = 'b') ORDER BY host"
                 ) ==
                   ["c", "d", "e"]

          assert hosts.("SELECT host FROM contract_wh WHERE v <> 1.0 ORDER BY host") ==
                   ["b", "c", "d", "e"]
        end

        test "BETWEEN, LIKE, ILIKE and string-vs-number comparison", ctx do
          hosts = fn sql ->
            {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)
            Enum.map(rows, & &1["host"])
          end

          assert hosts.("SELECT host FROM contract_wh WHERE v BETWEEN 2 AND 3 ORDER BY host") ==
                   ["b", "c"]

          assert hosts.("SELECT host FROM contract_wh WHERE v NOT BETWEEN 2 AND 3 ORDER BY host") ==
                   ["a", "d", "e"]

          assert hosts.(
                   "SELECT host FROM contract_wh WHERE time BETWEEN '2023-11-14T22:13:22Z' AND '2023-11-14T22:13:23Z' ORDER BY host"
                 ) ==
                   ["b", "c"]

          assert hosts.("SELECT host FROM contract_wh WHERE host LIKE 'a%'") == ["a"]
          assert hosts.("SELECT host FROM contract_wh WHERE host LIKE 'A%'") == []
          assert hosts.("SELECT host FROM contract_wh WHERE host ILIKE 'A%'") == ["a"]

          assert hosts.("SELECT host FROM contract_wh WHERE host NOT LIKE 'a%' ORDER BY host") ==
                   ["b", "c", "d", "e"]

          assert hosts.("SELECT host FROM contract_wh WHERE rack = 2") == ["b"]
          assert hosts.("SELECT host FROM contract_wh WHERE rack > 3 ORDER BY host") == ["d"]

          assert hosts.("SELECT host FROM contract_wh WHERE rack >= 10 ORDER BY host") ==
                   ["b", "d", "e"]

          assert {:error,
                  %{
                    status: 400,
                    body:
                      "type_coercion\ncaused by\nError during planning: There isn't a common " <>
                        "type to coerce Float64 and Utf8 in LIKE expression"
                  }} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT host FROM contract_wh WHERE v LIKE '1%'",
                     database: ctx.database
                   )
        end

        test "LIMIT 0 returns no rows and LIMIT -1 is rejected", ctx do
          assert {:ok, []} =
                   unquote(client).query_sql(ctx.conn, "SELECT host FROM contract_wh LIMIT 0",
                     database: ctx.database
                   )

          assert {:error,
                  %{
                    status: 400,
                    body:
                      "Optimizer rule 'eliminate_limit' failed\ncaused by\nError during " <>
                        "planning: LIMIT must be >= 0, '-1' was provided"
                  }} =
                   unquote(client).query_sql(ctx.conn, "SELECT host FROM contract_wh LIMIT -1",
                     database: ctx.database
                   )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # median(), CROSS JOIN, expression comparands (#19)
  # ---------------------------------------------------------------------------

  defp median_join_tests(client) do
    quote do
      describe "query_sql/3 — median and CROSS JOIN contract" do
        setup ctx do
          lp =
            Enum.join(
              [
                "contract_mj,symbol=X price=1.0,volume=10.0 1700000000000000000",
                "contract_mj,symbol=X price=2.5,volume=20.0 1700000010000000000",
                "contract_mj,symbol=X price=3.0,volume=30.0 1700000070000000000",
                "contract_mj,symbol=X price=4.0,volume=40.0 1700000080000000000",
                "contract_mj,symbol=X price=100.0,volume=1.0 1700000090000000000",
                "contract_mj_int n=1i 1700000000000000000",
                "contract_mj_int n=2i 1700000001000000000",
                "contract_mj_int n=3i 1700000002000000000",
                "contract_mj_int n=4i 1700000003000000000"
              ],
              "\n"
            )

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)
          :ok
        end

        test "median over floats, integers, an empty set and an expression", ctx do
          {:ok, [row]} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT median(price) AS med, median(volume) AS mv, median(price * 2) AS twice FROM contract_mj",
              database: ctx.database
            )

          assert row == %{"med" => 3.0, "mv" => 20.0, "twice" => 6.0}

          {:ok, [row]} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT median(n) AS med FROM contract_mj_int",
              database: ctx.database
            )

          assert row == %{"med" => 2}

          {:ok, [row]} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT median(price) AS med FROM contract_mj WHERE price > 1000",
              database: ctx.database
            )

          refute Map.has_key?(row, "med")
        end

        test "the median-screened candle query", ctx do
          sql = """
          WITH w AS (SELECT price, volume, time FROM contract_mj WHERE symbol = 'X'),
          ref AS (SELECT median(price) AS med FROM w)
          SELECT
            DATE_BIN(INTERVAL '1 minute', w.time) AS time,
            selector_first(w.price, w.time)['value'] AS open,
            max(w.price) AS high,
            min(w.price) AS low,
            selector_last(w.price, w.time)['value'] AS close,
            sum(w.volume) AS volume
          FROM w CROSS JOIN ref
          WHERE ref.med <= 0 OR (w.price <= ref.med * 3 AND w.price >= ref.med / 3)
          GROUP BY DATE_BIN(INTERVAL '1 minute', w.time)
          ORDER BY time ASC
          """

          {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          assert Enum.map(rows, &Map.drop(&1, ["time"])) == [
                   %{
                     "open" => 1.0,
                     "high" => 2.5,
                     "low" => 1.0,
                     "close" => 2.5,
                     "volume" => 30.0
                   },
                   %{"open" => 3.0, "high" => 4.0, "low" => 3.0, "close" => 4.0, "volume" => 70.0}
                 ]
        end

        test "CROSS JOIN cartesian product, ambiguity and expression comparands", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "WITH r AS (SELECT n FROM contract_mj_int WHERE n <= 2) SELECT p.price, r.n FROM contract_mj p CROSS JOIN r WHERE p.price >= 4 ORDER BY p.price, r.n",
              database: ctx.database
            )

          assert Enum.map(rows, &{&1["price"], &1["n"]}) == [
                   {4.0, 1},
                   {4.0, 2},
                   {100.0, 1},
                   {100.0, 2}
                 ]

          assert {:error,
                  %{
                    status: 500,
                    body: "Schema error: Ambiguous reference to unqualified field price"
                  }} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "WITH ref AS (SELECT median(price) AS price FROM contract_mj) SELECT price FROM contract_mj CROSS JOIN ref",
                     database: ctx.database
                   )

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT price FROM contract_mj WHERE price <= volume * 0.2 ORDER BY price",
              database: ctx.database
            )

          assert Enum.map(rows, & &1["price"]) == [1.0, 2.5, 3.0, 4.0]

          # (The engine qualifies the columns it lists, `Client.Local` does not.)
          assert {:error, %{status: 500, body: body}} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT price FROM contract_mj WHERE symbol = prod",
                     database: ctx.database
                   )

          assert InfluxElixir.ClientContract.unknown_field(body, "prod", "contract_mj") ==
                   ["price", "symbol", "time", "volume"]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # CAST, ::TYPE, ORDER BY expressions and multiple terms (#20)
  # ---------------------------------------------------------------------------

  defp cast_tests(client) do
    quote do
      describe "query_sql/3 — CAST and ORDER BY contract" do
        setup ctx do
          lp =
            Enum.join(
              [
                "contract_cast,symbol=X,level=5 price=2.7,qty=1i 1700000000000000000",
                "contract_cast,symbol=X,level=20 price=3.2,qty=2i 1700000001000000000",
                "contract_cast,symbol=X,level=100 price=9.9,qty=3i 1700000002000000000",
                "contract_cast,symbol=Y,level=20 price=1.1,qty=9i 1700000003000000000",
                "contract_cast_bad,level=abc price=1.0 1700000000000000000"
              ],
              "\n"
            )

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)
          :ok
        end

        test "CAST(tag AS INTEGER) compares numerically in WHERE, ORDER BY and an aggregate",
             ctx do
          levels = fn sql ->
            {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)
            Enum.map(rows, & &1["level"])
          end

          assert levels.(
                   "SELECT level FROM contract_cast WHERE CAST(level AS INTEGER) <= 20 AND symbol = 'X' ORDER BY time"
                 ) ==
                   ["5", "20"]

          assert levels.(
                   "SELECT level FROM contract_cast WHERE level::INTEGER <= 20 AND symbol = 'X' ORDER BY time"
                 ) ==
                   ["5", "20"]

          assert levels.(
                   "SELECT level FROM contract_cast WHERE symbol = 'X' ORDER BY CAST(level AS INTEGER) DESC"
                 ) ==
                   ["100", "20", "5"]

          {:ok, [row]} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT MAX(CAST(level AS INTEGER)) AS m, MAX(CAST(price AS INTEGER)) AS p FROM contract_cast",
              database: ctx.database
            )

          assert row == %{"m" => 100, "p" => 9}

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT symbol, level FROM contract_cast ORDER BY symbol DESC, CAST(level AS INTEGER) ASC",
              database: ctx.database
            )

          assert Enum.map(rows, &{&1["symbol"], &1["level"]}) ==
                   [{"Y", "20"}, {"X", "5"}, {"X", "20"}, {"X", "100"}]
        end

        test "a cast that cannot be performed is a transport-level failure", ctx do
          # InfluxDB 3 Core closes the connection mid-response instead of
          # sending an error body; both clients report it as a closed transport.
          assert {:error, {:connection_error, %Mint.TransportError{reason: :closed}}} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT level FROM contract_cast_bad WHERE CAST(level AS INTEGER) <= 20",
                     database: ctx.database
                   )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Schema and grouping rules: unknown columns, IN-list items, constants,
  # ungrouped projections
  # ---------------------------------------------------------------------------

  defp schema_rule_tests(client) do
    quote do
      describe "query_sql/3 — schema and grouping rules contract" do
        setup ctx do
          lp =
            Enum.join(
              [
                "contract_rules,symbol=X price=1.0 1700000000000000000",
                "contract_rules,symbol=X price=100.0 1700000001000000000"
              ],
              "\n"
            )

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)
          :ok
        end

        test "unknown columns, IN-list items, constants and ungrouped projections", ctx do
          # An unknown column in any clause is the engine's schema error, which
          # lists the columns it knows. InfluxDB qualifies each with its table
          # (`contract_rules.price`) and lists one the clause already refers to
          # twice; `Client.Local` lists the bare names once. Everything but that
          # qualification is pinned, by comparing the set of names.
          for sql <- [
                "SELECT nosuch FROM contract_rules",
                "SELECT price FROM contract_rules ORDER BY nosuch",
                "SELECT symbol FROM contract_rules GROUP BY nosuch",
                "SELECT MAX(nosuch) AS m FROM contract_rules"
              ] do
            assert {:error, %{status: 500, body: body}} =
                     unquote(client).query_sql(ctx.conn, sql, database: ctx.database),
                   sql

            assert InfluxElixir.ClientContract.unknown_field(body, "nosuch", "contract_rules") ==
                     ["price", "symbol", "time"],
                   sql
          end

          # IN-list items are comparands; constants need an alias.
          assert {:error, %{status: 500, body: body}} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT symbol FROM contract_rules WHERE symbol IN (a, b)",
                     database: ctx.database
                   )

          assert InfluxElixir.ClientContract.unknown_field(body, "a", "contract_rules") ==
                   ["price", "symbol", "time"]

          {:ok, [row]} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT 0.0 AS volume, 'x' AS label, MAX(price) AS m FROM contract_rules",
              database: ctx.database
            )

          assert row == %{"volume" => 0.0, "label" => "x", "m" => 100.0}

          # A projected column must be grouped or aggregated; GROUP BY without
          # an aggregate is one row per group.
          assert {:error,
                  %{
                    status: 400,
                    body:
                      "Error during planning: Column in SELECT must be in GROUP BY or an " <>
                        "aggregate function: While expanding wildcard, column " <>
                        "\"contract_rules.price\" must appear in the GROUP BY clause or must " <>
                        "be part of an aggregate function, currently only " <>
                        "\"contract_rules.symbol\" appears in the SELECT clause satisfies " <>
                        "this requirement"
                  }} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT symbol, price FROM contract_rules GROUP BY symbol",
                     database: ctx.database
                   )

          assert {:ok, [%{"symbol" => "X"}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT symbol FROM contract_rules GROUP BY symbol",
                     database: ctx.database
                   )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Write rules: partial writes, column schema, reserved time, int64 range
  # ---------------------------------------------------------------------------

  defp write_rule_tests(client) do
    quote do
      describe "write/3 — schema and partial-write contract" do
        test "a type conflict is a 400 partial write that keeps the other lines", ctx do
          {:ok, :written} =
            unquote(client).write(ctx.conn, "contract_wr v=1i 1700000000000000000",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          lp = "contract_wr v=2.0 1700000000000000001\ncontract_wr v=3i 1700000000000000002"

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(ctx.conn, lp, database: ctx.database)

          assert %{"error" => "partial write of line protocol occurred", "data" => [entry]} =
                   Jason.decode!(body)

          assert entry["line_number"] == 1

          assert entry["error_message"] ==
                   "invalid column type for column 'v', expected iox::column_type::field::integer, " <>
                     "got iox::column_type::field::float"

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(ctx.conn, "SELECT v FROM contract_wr ORDER BY time",
              database: ctx.database
            )

          assert Enum.map(rows, & &1["v"]) == [1, 3]
        end

        test "reserved time, tag-and-field key, int64 overflow and an empty payload are 400",
             ctx do
          for {lp, message} <- [
                {"contract_wr2,time=x v=1i", "'time' is a reserved column"},
                {"contract_wr2 time=5i,v=1i", "'time' is a reserved column"},
                {"contract_wr2,host=a host=1i",
                 "invalid column type for column 'host', expected iox::column_type::tag, " <>
                   "got iox::column_type::field::integer"},
                {"contract_wr2 v=9223372036854775808i",
                 "Unable to parse integer value `9223372036854775808`"}
              ] do
            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, lp, database: ctx.database),
                   lp

            # `original_line` is the line cut to 20 bytes.
            assert Jason.decode!(body) == %{
                     "error" => "partial write of line protocol occurred",
                     "data" => [
                       %{
                         "error_message" => message,
                         "line_number" => 1,
                         "original_line" => binary_part(lp, 0, 20)
                       }
                     ]
                   },
                   lp
          end

          assert {:error, %{status: 400, body: "incoming write was empty"}} =
                   unquote(client).write(ctx.conn, "", database: ctx.database)
        end

        # The engine stamps every untimed line of one write with the same
        # time (verified): lines of one series are one point, fields merged,
        # the last write winning.
        test "untimed lines of one write are one point per series", ctx do
          m = "contract_untimed_#{System.unique_integer([:positive])}"

          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "#{m},k=a v=1i\n#{m},k=a v=2i,w=9i\n#{m},k=b v=3i",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok,
                  [
                    %{"k" => "a", "v" => 2, "w" => 9, "time" => time},
                    %{"k" => "b", "v" => 3, "time" => time}
                  ]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     ~s|SELECT k, v, w, time FROM "#{m}" ORDER BY k|,
                     database: ctx.database
                   )

          assert %DateTime{} = time
        end

        test "a newline inside a quoted string value is part of the value", ctx do
          {:ok, :written} =
            unquote(client).write(ctx.conn, ~s|contract_nl s="a\nb" 1700000000000000000|,
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, [row]} =
            unquote(client).query_sql(ctx.conn, "SELECT s FROM contract_nl",
              database: ctx.database
            )

          assert row["s"] == "a\nb"
        end

        test "a name ending in a backslash is refused; an escaped backslash in a string is kept",
             ctx do
          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(ctx.conn, ~S"contract_bs,k\\=a v=1i 1",
                     database: ctx.database
                   )

          assert Jason.decode!(body) == %{
                   "error" => "partial write of line protocol occurred",
                   "data" => [
                     %{
                       "error_message" =>
                         "Measurements, tag keys and values, and field keys may not end " <>
                           "with a backslash",
                       "line_number" => 1,
                       "original_line" => ~S"contract_bs,k\\=a v="
                     }
                   ]
                 }

          m = "contract_bsok_#{System.unique_integer([:positive])}"

          {:ok, :written} =
            unquote(client).write(ctx.conn, ~s(#{m} s="x\\\\",v=1i 1700000000000000000),
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"s" => "x\\", "v" => 1}]} =
                   unquote(client).query_sql(ctx.conn, "SELECT s, v FROM #{m}",
                     database: ctx.database
                   )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # LIMIT / OFFSET pagination (#21)
  # ---------------------------------------------------------------------------

  defp offset_tests(client) do
    quote do
      describe "query_sql/3 — LIMIT and OFFSET contract" do
        setup ctx do
          lines =
            for {host, i} <- Enum.with_index(~w(a b c d e)),
                do:
                  "contract_off,host=#{host} v=#{i + 1}i #{1_700_000_000_000_000_000 + i * 1_000_000_000}"

          {:ok, :written} =
            unquote(client).write(ctx.conn, Enum.join(Enum.reverse(lines), "\n"),
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)
          :ok
        end

        test "OFFSET pages through ordered rows and grouped rows", ctx do
          hosts = fn sql ->
            {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)
            Enum.map(rows, & &1["host"])
          end

          assert hosts.("SELECT host FROM contract_off ORDER BY time LIMIT 2 OFFSET 1") == [
                   "b",
                   "c"
                 ]

          assert hosts.("SELECT host FROM contract_off ORDER BY time LIMIT 2 OFFSET 4") == ["e"]
          assert hosts.("SELECT host FROM contract_off ORDER BY time LIMIT 2 OFFSET 10") == []
          assert hosts.("SELECT host FROM contract_off ORDER BY time OFFSET 3") == ["d", "e"]
          assert hosts.("SELECT host FROM contract_off ORDER BY time OFFSET 3 LIMIT 1") == ["d"]

          assert hosts.(
                   "SELECT host, COUNT(*) AS n FROM contract_off GROUP BY host ORDER BY host LIMIT 2 OFFSET 1"
                 ) ==
                   ["b", "c"]

          assert hosts.("SELECT DISTINCT host FROM contract_off ORDER BY host LIMIT 2 OFFSET 2") ==
                   ["c", "d"]

          assert {:error,
                  %{
                    status: 400,
                    body:
                      "Optimizer rule 'push_down_limit' failed\ncaused by\nError during " <>
                        "planning: OFFSET must be >=0, '-1' was provided"
                  }} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT host FROM contract_off LIMIT 2 OFFSET -1",
                     database: ctx.database
                   )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # InfluxDB 2 write rules (v2)
  # ---------------------------------------------------------------------------

  defp v2_write_rule_tests(client) do
    quote do
      describe "write/3 — v2 schema and partial-write contract" do
        test "a field type conflict is 422 with the dropped count; the other lines are stored",
             ctx do
          m = "contract_v2wr_#{System.unique_integer([:positive])}"

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m} v=1i 1700000000000000000",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          lp = "#{m} v=2.0 1700000000000000001\n#{m} v=3i 1700000000000000002"

          assert {:error, %{status: 422, body: body}} =
                   unquote(client).write(ctx.conn, lp, database: ctx.database)

          assert %{"code" => "unprocessable entity", "message" => message} = Jason.decode!(body)

          assert message ==
                   "failure writing points to database: partial write: field type conflict: " <>
                     ~s|input field "v" on measurement "#{m}" is type float, already exists as | <>
                     "type integer dropped=1"

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_flux(
              ctx.conn,
              ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}")|
            )

          assert Enum.map(rows, & &1["_value"]) == [1, 3]
        end

        # InfluxDB 2 stamps every untimed line of one write with the same
        # time (verified): lines of one series are one point, fields merged,
        # the last write winning.
        test "untimed lines of one write are one point per series", ctx do
          m = "contract_untimed_#{System.unique_integer([:positive])}"

          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "#{m},k=a v=1i\n#{m},k=a v=2i,w=9i\n#{m},k=b v=3i",
                     database: ctx.database
                   )

          InfluxElixir.ClientContract.settle(ctx)

          flux =
            ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) | <>
              ~s|\|> filter(fn: (r) => r._measurement == "#{m}")|

          {:ok, rows} = unquote(client).query_flux(ctx.conn, flux)

          assert rows |> Enum.map(&{&1["k"], &1["_field"], &1["_value"]}) |> Enum.sort() ==
                   [{"a", "v", 2}, {"a", "w", 9}, {"b", "v", 3}]

          assert [_one_time] = rows |> Enum.map(& &1["_time"]) |> Enum.uniq()
        end

        unquote(v2_write_rule_parse_tests(client))
      end
    end
  end

  defp v2_write_rule_parse_tests(client) do
    quote do
      # InfluxDB 2 stores a string field that a \r follows, from after the
      # opening quote up to the \r, closing quote included; a number
      # followed by \r is refused (verified).
      test "a string field before a CRLF ending is stored, closing quote and all", ctx do
        m = "contract_v2cr_#{System.unique_integer([:positive])}"

        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, "#{m} s=\"x\"\r\n#{m} s=\"y\"\r 5\n",
                   database: ctx.database,
                   precision: :nanosecond
                 )

        assert {:error, %{status: 400, body: body}} =
                 unquote(client).write(ctx.conn, "#{m} n=1i\r\n",
                   database: ctx.database,
                   precision: :nanosecond
                 )

        assert Jason.decode!(body) == %{
                 "code" => "invalid",
                 "message" => "unable to parse '#{m} n=1i\r': invalid number"
               }

        InfluxElixir.ClientContract.settle(ctx)

        flux =
          ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) | <>
            ~s|\|> filter(fn: (r) => r._measurement == "#{m}")|

        {:ok, rows} = unquote(client).query_flux(ctx.conn, flux)
        assert rows |> Enum.map(& &1["_value"]) |> Enum.sort() == ["x\"", "y\""]
      end

      test "a parse error rejects the whole payload with 400 and nothing is stored", ctx do
        m = "contract_v2pe_#{System.unique_integer([:positive])}"
        lp = "#{m} v=1i 1700000000000000000\n#{m} v=\n#{m} v=3i 1700000000000000002"

        assert {:error, %{status: 400, body: body}} =
                 unquote(client).write(ctx.conn, lp, database: ctx.database)

        assert Jason.decode!(body) == %{
                 "code" => "invalid",
                 "message" => "unable to parse '#{m} v=': missing field value"
               }

        InfluxElixir.ClientContract.settle(ctx)

        {:ok, rows} =
          unquote(client).query_flux(
            ctx.conn,
            ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}")|
          )

        assert rows == []
      end

      test "time as a tag is 400; time as a field is dropped; a tag and a field may share a name; an empty payload is accepted",
           ctx do
        m = "contract_v2t_#{System.unique_integer([:positive])}"

        assert {:error, %{status: 400, body: body}} =
                 unquote(client).write(ctx.conn, "#{m},time=x v=1i 1700000000000000000",
                   database: ctx.database
                 )

        assert Jason.decode!(body) == %{
                 "code" => "invalid",
                 "message" =>
                   "unable to parse '#{m},time=x v=1i 1700000000000000000': " <>
                     ~s|cannot use reserved tag key "time"|
               }

        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, "#{m} time=5i,v=1i 1700000000000000000",
                   database: ctx.database
                 )

        assert {:ok, :written} =
                 unquote(client).write(ctx.conn, "#{m},host=a host=1i 1700000000000000001",
                   database: ctx.database
                 )

        assert {:ok, :written} = unquote(client).write(ctx.conn, "", database: ctx.database)

        InfluxElixir.ClientContract.settle(ctx)

        {:ok, rows} =
          unquote(client).query_flux(
            ctx.conn,
            ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}")|
          )

        assert Enum.sort(Enum.map(rows, & &1["_field"])) == ["host", "v"]
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # InfluxDB 2 precision spellings (v2)
  # ---------------------------------------------------------------------------

  defp v2_precision_tests(client) do
    quote do
      describe "write/3 — v2 precision contract" do
        test "ms and millisecond both mean milliseconds; auto is refused with 400", ctx do
          m = "contract_v2prec_#{System.unique_integer([:positive])}"

          for precision <- [:ms, "millisecond"] do
            assert {:ok, :written} =
                     unquote(client).write(ctx.conn, "#{m} v=1i 1700000000000",
                       database: ctx.database,
                       precision: precision
                     )
          end

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(ctx.conn, "#{m} v=1i 1",
                     database: ctx.database,
                     precision: :auto
                   )

          assert Jason.decode!(body) == %{
                   "code" => "invalid",
                   "message" => "invalid precision; valid precision units are ns, us, ms, and s"
                 }

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_flux(
              ctx.conn,
              ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}")|
            )

          assert Enum.map(rows, & &1["_time"]) == [~U[2023-11-14 22:13:20.000000Z]]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Duplicate points (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp duplicate_tests(client) do
    quote do
      describe "write/3 — duplicate point contract" do
        test "a point rewritten at the same tags and time merges, the later write winning",
             ctx do
          m = "contract_dup_#{System.unique_integer([:positive])}"

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},h=x v=1i,w=1i 1700000000000000000",
              database: ctx.database
            )

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "#{m},h=x v=2i 1700000000000000000\n#{m},h=y v=3i 1700000000000000000",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(ctx.conn, "SELECT h, v, w FROM #{m} ORDER BY h",
              database: ctx.database
            )

          assert rows == [%{"h" => "x", "v" => 2, "w" => 1}, %{"h" => "y", "v" => 3}]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Duplicate points (v2)
  # ---------------------------------------------------------------------------

  defp v2_duplicate_tests(client) do
    quote do
      describe "write/3 — v2 duplicate point contract" do
        test "a point rewritten at the same tags and time merges, the later write winning",
             ctx do
          m = "contract_v2dup_#{System.unique_integer([:positive])}"

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},h=x v=1i,w=1i 1700000000000000000",
              database: ctx.database
            )

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},h=x v=2i 1700000000000000000",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_flux(
              ctx.conn,
              ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}")|
            )

          assert Enum.sort(Enum.map(rows, &{&1["_field"], &1["_value"]})) == [{"v", 2}, {"w", 1}]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # InfluxQL SELECT shapes and sub-microsecond time (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  # InfluxQL's WHERE and SHOW TAG VALUES, verified against InfluxDB 3: a
  # missing tag is the empty string, regexes match tags only, ordering a
  # tag is false, durations work with now(), NOT does not exist.
  defp influxql_where_tests(client) do
    quote do
      describe "query_influxql/3 — WHERE and SHOW TAG VALUES contract" do
        setup ctx do
          m = "contract_iqw_#{System.unique_integer([:positive])}"
          now = System.os_time(:second)

          lp =
            Enum.join(
              [
                "#{m},host=h1 v=1i #{now - 7200}",
                "#{m},host=h2 v=2i #{now - 1800}",
                "#{m},host=h12 v=3i #{now - 600}",
                "#{m} v=4i #{now - 300}",
                "#{m},host=H1 v=5i #{now - 60}",
                "#{m},host=old v=6i #{now - 90_000}"
              ],
              "\n"
            )

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database, precision: :second)

          InfluxElixir.ClientContract.settle(ctx)

          vs = fn where ->
            {:ok, rows} =
              unquote(client).query_influxql(ctx.conn, "SELECT v FROM #{m} WHERE #{where}",
                database: ctx.database
              )

            Enum.map(rows, & &1["v"])
          end

          {:ok, m: m, vs: vs}
        end

        test "a missing tag is the empty string; regexes are unanchored", %{vs: vs} do
          assert vs.("host =~ /h1/") == [1, 3]
          assert vs.("host =~ /^h1$/") == [1]
          assert vs.("host =~ /(?i)h1/") == [1, 3, 5]
          assert vs.("host !~ /h1/") == [6, 2, 4, 5]
          assert vs.("host != 'h1'") == [6, 2, 3, 4, 5]
          assert vs.("host = ''") == [4]
        end

        test "ordering a tag, or a regex on a field, is false", %{vs: vs} do
          assert vs.("host > 'h0'") == []
          assert vs.("host >= 'h1' OR v = 4") == [4]
          assert vs.("v =~ /1/") == []
        end

        test "durations with now(), and quoted identifiers", ctx do
          assert ctx.vs.("time > now() - 40m") == [2, 3, 4, 5]
          assert ctx.vs.("time > now() - 1h AND time < now() - 5m") == [2, 3, 4]
          assert ctx.vs.("\"host\" = 'h2'") == [2]
        end

        test "NOT is the engine's parse error", ctx do
          # The position is where the operand after NOT starts.
          prefix = "SELECT v FROM #{ctx.m} WHERE NOT "
          pos = String.length(prefix)

          expected =
            "error in InfluxQL statement: parsing error: invalid InfluxQL statement at " <>
              "pos #{pos}. Parsing Error: Nom(\"host = 'h1'\", Tag)"

          assert {:error, %{status: 400, body: ^expected}} =
                   unquote(client).query_influxql(
                     ctx.conn,
                     prefix <> "host = 'h1'",
                     database: ctx.database
                   )
        end

        test "SHOW TAG VALUES: sorted values, a row for the missing key, the last 24 hours",
             ctx do
          assert {:ok, rows} =
                   unquote(client).query_influxql(
                     ctx.conn,
                     "SHOW TAG VALUES FROM #{ctx.m} WITH KEY = host",
                     database: ctx.database
                   )

          base = %{"iox::measurement" => ctx.m, "key" => "host"}
          values = for v <- ["H1", "h1", "h12", "h2"], do: Map.put(base, "value", v)
          assert rows == values ++ [base]
        end
      end
    end
  end

  defp influxql_select_tests(client) do
    quote do
      describe "query_influxql/3 — SELECT shape contract" do
        setup ctx do
          m = "contract_iqs_#{System.unique_integer([:positive])}"

          lp = """
          #{m},h=x v=3i 1700000000000003000
          #{m},h=y v=1i 1700000000000001000
          #{m},h=x v=2i 1700000000000002000
          #{m},h=y w=9i,s="x" 1700000000000004000
          """

          {:ok, :written} =
            unquote(client).write(ctx.conn, String.trim(lp), database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)
          {:ok, m: m}
        end

        test "rows carry iox::measurement and time, in time order", ctx do
          {:ok, rows} =
            unquote(client).query_influxql(ctx.conn, "SELECT v FROM #{ctx.m}",
              database: ctx.database
            )

          assert Enum.map(rows, &{&1["iox::measurement"], &1["v"]}) == [
                   {ctx.m, 1},
                   {ctx.m, 2},
                   {ctx.m, 3}
                 ]

          assert Enum.all?(rows, &match?(%DateTime{}, &1["time"]))
        end

        test "aggregates are named after the function, a lone selector keeps its point", ctx do
          epoch = DateTime.from_unix!(0, :microsecond)

          {:ok, [row]} =
            unquote(client).query_influxql(
              ctx.conn,
              "SELECT SUM(v), MEAN(v), COUNT(*) FROM #{ctx.m}",
              database: ctx.database
            )

          assert %{"time" => ^epoch, "sum" => 6, "mean" => 2.0, "count_v" => 3, "count_w" => 1} =
                   row

          {:ok, [max]} =
            unquote(client).query_influxql(ctx.conn, "SELECT MAX(v), h FROM #{ctx.m}",
              database: ctx.database
            )

          assert %{"max" => 3, "h" => "x"} = max
          assert max["time"] == DateTime.from_unix!(1_700_000_000_000_003, :microsecond)
        end

        test "GROUP BY with a per-series LIMIT; unknown names are empty; field keys", ctx do
          {:ok, rows} =
            unquote(client).query_influxql(ctx.conn, "SELECT v FROM #{ctx.m} GROUP BY h LIMIT 1",
              database: ctx.database
            )

          assert Enum.map(rows, &{&1["h"], &1["v"]}) == [{"x", 2}, {"y", 1}]

          for statement <- ["SELECT nothere FROM #{ctx.m}", "SELECT v FROM #{ctx.m}_missing"] do
            assert {:ok, []} =
                     unquote(client).query_influxql(ctx.conn, statement, database: ctx.database)
          end

          {:ok, keys} =
            unquote(client).query_influxql(ctx.conn, "SHOW FIELD KEYS FROM #{ctx.m}",
              database: ctx.database
            )

          assert Enum.map(keys, &{&1["fieldKey"], &1["fieldType"]}) ==
                   [{"s", "string"}, {"v", "integer"}, {"w", "integer"}]
        end
      end

      describe "query_sql/3 — sub-microsecond time contract" do
        test "ORDER BY time and a time literal use the nanoseconds", ctx do
          m = "contract_ns_#{System.unique_integer([:positive])}"

          lp =
            "#{m} v=3i 1700000000000000300\n#{m} v=1i 1700000000000000100\n#{m} v=2i 1700000000000000200"

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)

          {:ok, ordered} =
            unquote(client).query_sql(ctx.conn, "SELECT * FROM #{m} ORDER BY time",
              database: ctx.database
            )

          assert Enum.map(ordered, & &1["v"]) == [1, 2, 3]

          {:ok, later} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT v FROM #{m} WHERE time >= '2023-11-14T22:13:20.0000002Z' ORDER BY v",
              database: ctx.database
            )

          assert Enum.map(later, & &1["v"]) == [2, 3]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Flux pipelines (v2)
  # ---------------------------------------------------------------------------

  defp v2_flux_pipeline_tests(client) do
    quote do
      describe "query_flux/3 — pipeline contract" do
        setup ctx do
          m = "contract_fx_#{System.unique_integer([:positive])}"

          lp = """
          #{m},host=a v=1.0,n=1i 1700000000000000000
          #{m},host=a v=3.0,n=2i 1700000060000000000
          #{m},host=b v=5.0,n=3i 1700000000000000000
          """

          {:ok, :written} =
            unquote(client).write(ctx.conn, String.trim(lp), database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          head =
            ~s|from(bucket: "#{ctx.database}") \|> range(start: 0, stop: 1800000000) | <>
              ~s|\|> filter(fn: (r) => r._measurement == "#{m}")|

          {:ok, head: head}
        end

        test "tables, _start/_stop and the filter grammar", ctx do
          {:ok, rows} = unquote(client).query_flux(ctx.conn, ctx.head)

          assert Enum.map(rows, &{&1["table"], &1["_field"]}) == [
                   {0, "n"},
                   {0, "n"},
                   {1, "v"},
                   {1, "v"},
                   {2, "n"},
                   {3, "v"}
                 ]

          assert Enum.all?(rows, &(&1["_stop"] == ~U[2027-01-15 08:00:00.000000Z]))

          {:ok, rows} =
            unquote(client).query_flux(
              ctx.conn,
              ctx.head <>
                ~s| \|> filter(fn: (r) => r._field == "v" and (r.host != "a" or r._value > 2.0))|
            )

          assert Enum.map(rows, & &1["_value"]) == [3.0, 5.0]
        end

        test "mean drops _time, last keeps its row, limit is per table", ctx do
          v = ~s| \|> filter(fn: (r) => r._field == "v")|
          {:ok, means} = unquote(client).query_flux(ctx.conn, ctx.head <> v <> " |> mean()")
          assert Enum.map(means, &{&1["host"], &1["_value"]}) == [{"a", 2.0}, {"b", 5.0}]
          refute Enum.any?(means, &Map.has_key?(&1, "_time"))

          {:ok, lasts} = unquote(client).query_flux(ctx.conn, ctx.head <> v <> " |> last()")
          assert Enum.map(lasts, &{&1["host"], &1["_value"]}) == [{"a", 3.0}, {"b", 5.0}]

          {:ok, limited} =
            unquote(client).query_flux(ctx.conn, ctx.head <> v <> " |> limit(n: 1)")

          assert Enum.map(limited, & &1["_value"]) == [1.0, 5.0]
        end

        test "no range() is 400; a missing bucket is 404; mean of strings is 400", ctx do
          assert {:error, %{status: 400, body: body}} =
                   unquote(client).query_flux(ctx.conn, ~s|from(bucket: "#{ctx.database}")|)

          assert Jason.decode!(body) == %{
                   "code" => "invalid",
                   "message" =>
                     "error in building plan while starting program: cannot submit unbounded " <>
                       ~s|read to "#{ctx.database}"; try bounding 'from' with a call to 'range'|
                 }

          missing = "nope_#{System.unique_integer([:positive])}"

          assert {:error, %{status: 404, body: body}} =
                   unquote(client).query_flux(
                     ctx.conn,
                     ~s|from(bucket: "#{missing}") \|> range(start: 0)|
                   )

          assert Jason.decode!(body) == %{
                   "code" => "not found",
                   "message" =>
                     ~s|failed to initialize execute state: could not find bucket "#{missing}"|
                 }

          m = "contract_fxs_#{System.unique_integer([:positive])}"

          {:ok, :written} =
            unquote(client).write(ctx.conn, ~s|#{m} s="x" 1700000000000000000|,
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).query_flux(
                     ctx.conn,
                     ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}") \|> mean()|
                   )

          assert Jason.decode!(body)["message"] ==
                   "unsupported input type for mean aggregate: string"
        end

        test "a string field with a newline reads back as stored", ctx do
          m = "contract_v2nl_#{System.unique_integer([:positive])}"

          {:ok, :written} =
            unquote(client).write(ctx.conn, ~s|#{m} s="l1\nl2" 1700000000000000000|,
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, [row]} =
            unquote(client).query_flux(
              ctx.conn,
              ~s|from(bucket: "#{ctx.database}") \|> range(start: 0, stop: 1800000000) \|> filter(fn: (r) => r._measurement == "#{m}")|
            )

          assert row["_value"] == "l1\nl2"
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # GROUP BY / ORDER BY references and streamed row types (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp reference_tests(client) do
    quote do
      describe "query_sql/3 — GROUP BY and ORDER BY references contract" do
        setup ctx do
          m = "contract_ref_#{System.unique_integer([:positive])}"

          lp = """
          #{m},h=b v=2.5,n=4i 1700000000123456789
          #{m},h=a v=3.5,n=6i 1700000090000000000
          #{m},h=a v=1.5,n=2i 1700000000000000000
          """

          {:ok, :written} =
            unquote(client).write(ctx.conn, String.trim(lp), database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)
          {:ok, m: m}
        end

        test "GROUP BY an alias, a position, or DATE_BIN with a column", ctx do
          select =
            "SELECT DATE_BIN(INTERVAL '1 minute', time) AS bucket, h, COUNT(v) AS c FROM #{ctx.m}"

          for group <- ["DATE_BIN(INTERVAL '1 minute', time), h", "bucket, h", "1, 2"] do
            {:ok, rows} =
              unquote(client).query_sql(ctx.conn, "#{select} GROUP BY #{group} ORDER BY 1, 2",
                database: ctx.database
              )

            assert Enum.map(rows, &{&1["h"], &1["c"]}) == [{"a", 1}, {"b", 1}, {"a", 1}], group
          end

          assert {:error,
                  %{
                    status: 400,
                    body:
                      "Error during planning: Cannot find column with position 3 in SELECT " <>
                        "clause. Valid columns: 1 to 2"
                  }} =
                   unquote(client).query_sql(ctx.conn, "SELECT h, v FROM #{ctx.m} GROUP BY 3",
                     database: ctx.database
                   )
        end

        test "a streamed row is the same map as the queried row", ctx do
          sql = "SELECT * FROM #{ctx.m} ORDER BY time"
          {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          streamed =
            ctx.conn
            |> unquote(client).query_sql_stream(sql, database: ctx.database)
            |> Enum.to_list()

          assert streamed == rows
          assert Enum.all?(streamed, &match?(%DateTime{}, &1["time"]))
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # NULL semantics and operators (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp null_semantics_tests(client) do
    quote do
      describe "query_sql/3 — nulls and operators contract" do
        setup ctx do
          m = "contract_nl_#{System.unique_integer([:positive])}"

          lp = """
          #{m},host=b n=-4i,b=false 1700000060000000000
          #{m},host=c,rack=2 v=-3.25,n=7i 1700000120000000000
          #{m},host=a,rack=1 v=1.5,n=2i,s="al%pha",b=true 1700000000000000000
          """

          {:ok, :written} =
            unquote(client).write(ctx.conn, String.trim(lp), database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)
          {:ok, m: m}
        end

        test "null ordering, three-valued NOT and the DISTINCT null row", ctx do
          q = fn sql ->
            {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)
            rows
          end

          assert Enum.map(q.("SELECT rack FROM #{ctx.m} ORDER BY rack"), & &1["rack"]) == [
                   "1",
                   "2",
                   nil
                 ]

          assert Enum.map(q.("SELECT rack FROM #{ctx.m} ORDER BY rack DESC"), & &1["rack"]) == [
                   nil,
                   "2",
                   "1"
                 ]

          assert Enum.map(q.("SELECT rack FROM #{ctx.m} ORDER BY rack NULLS FIRST"), & &1["rack"]) ==
                   [nil, "1", "2"]

          assert Enum.map(
                   q.("SELECT host FROM #{ctx.m} WHERE NOT (rack = '1') ORDER BY time"),
                   & &1["host"]
                 ) == ["c"]

          assert q.("SELECT DISTINCT rack FROM #{ctx.m} ORDER BY rack") == [
                   %{"rack" => "1"},
                   %{"rack" => "2"},
                   %{}
                 ]
        end

        test "LIKE escapes, a boolean predicate, % and unary minus", ctx do
          q = fn sql ->
            {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)
            rows
          end

          assert [%{"host" => "a"}] = q.(~s(SELECT host FROM #{ctx.m} WHERE s LIKE 'al\\%%'))

          assert Enum.map(q.("SELECT host FROM #{ctx.m} WHERE NOT b ORDER BY time"), & &1["host"]) ==
                   ["b"]

          assert Enum.map(q.("SELECT n % 3 AS r FROM #{ctx.m} ORDER BY time"), & &1["r"]) == [
                   2,
                   -1,
                   1
                 ]

          assert Enum.map(q.("SELECT -v AS x FROM #{ctx.m} ORDER BY time"), & &1["x"]) == [
                   -1.5,
                   nil,
                   3.25
                 ]

          expected =
            "Error during planning: Cannot create filter with non-boolean " <>
              "predicate '#{ctx.m}.n' returning Int64"

          assert {:error, %{status: 400, body: ^expected}} =
                   unquote(client).query_sql(ctx.conn, "SELECT host FROM #{ctx.m} WHERE n",
                     database: ctx.database
                   )
        end

        test "a selector without a subscript is the time/value struct", ctx do
          q = fn sql ->
            {:ok, rows} = unquote(client).query_sql(ctx.conn, sql, database: ctx.database)
            rows
          end

          assert [%{"sl" => %{"time" => %DateTime{}, "value" => -3.25}}] =
                   q.("SELECT selector_last(v, time) AS sl FROM #{ctx.m}")
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # accept_partial / no_sync write parameters (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp atomic_write_tests(client) do
    quote do
      describe "write/3 — accept_partial and no_sync contract" do
        test "accept_partial: false rejects the payload at its first bad line", ctx do
          m = "contract_atomic_#{System.unique_integer([:positive])}"

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).write(ctx.conn, "#{m} v=1i 1\n#{m} v=2.0 2",
                     database: ctx.database,
                     accept_partial: false
                   )

          # `original_line` is the engine's rendering of the line (2.0 is 2),
          # cut to 20 bytes.
          assert Jason.decode!(body) == %{
                   "error" => "line protocol parsing error",
                   "data" => %{
                     "error_message" =>
                       "invalid column type for column 'v', expected " <>
                         "iox::column_type::field::integer, got iox::column_type::field::float",
                     "line_number" => 2,
                     "original_line" => binary_part("#{m} v=2 2", 0, 20)
                   }
                 }

          InfluxElixir.ClientContract.settle(ctx)

          expected = "Error during planning: table 'public.iox.#{m}' not found"

          assert {:error, %{status: 400, body: ^expected}} =
                   unquote(client).query_sql(ctx.conn, "SELECT * FROM #{m}",
                     database: ctx.database
                   )
        end

        test "no_sync: true and a clean atomic payload are accepted", ctx do
          m = "contract_nosync_#{System.unique_integer([:positive])}"

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, "#{m} v=1i 1\n#{m} v=2i 2",
                     database: ctx.database,
                     accept_partial: false,
                     no_sync: true
                   )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Query formats (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp format_tests(client) do
    quote do
      describe "query formats contract" do
        setup ctx do
          m = "contract_fmt_#{System.unique_integer([:positive])}"

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "#{m},host=b v=1e15 2\n" <>
                "#{m},host=a v=1.5,big=9007199254740993i,tiny=1.5e-7,huge=1e16,b=true,s=\"\" 1",
              database: ctx.database,
              precision: :second
            )

          InfluxElixir.ClientContract.settle(ctx)
          {:ok, m: m}
        end

        test "format: :csv answers every value as the engine's CSV string", ctx do
          assert {:ok, [first, second]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM #{ctx.m} ORDER BY time",
                     database: ctx.database,
                     format: :csv
                   )

          assert first == %{
                   "time" => ~U[1970-01-01 00:00:01.000000Z],
                   "host" => "a",
                   "v" => "1.5",
                   "big" => "9007199254740993",
                   "tiny" => "1.5e-7",
                   "huge" => "1e16",
                   "b" => "true"
                 }

          assert second == %{
                   "time" => ~U[1970-01-01 00:00:02.000000Z],
                   "host" => "b",
                   "v" => "1000000000000000.0"
                 }
        end

        test "format: :csv keeps a one-column row whose value is null or empty", ctx do
          # The engine writes such a row as `""`; the parser took it for a
          # table separator, dropped it and read the next row as a header.
          # `b` is null on the second row; `s` is "" on the first, null on the second.
          for {column, expected} <- [{"b", [%{"b" => "true"}, %{}]}, {"s", [%{}, %{}]}] do
            assert {:ok, ^expected} =
                     unquote(client).query_sql(
                       ctx.conn,
                       "SELECT #{column} FROM #{ctx.m} ORDER BY time",
                       database: ctx.database,
                       format: :csv
                     )
          end
        end

        test "query_influxql format: :csv answers strings too", ctx do
          assert {:ok, [%{"iox::measurement" => m, "v" => "1.5", "b" => "true"}, second]} =
                   unquote(client).query_influxql(ctx.conn, "SELECT v, b FROM #{ctx.m}",
                     database: ctx.database,
                     format: :csv
                   )

          assert m == ctx.m
          refute Map.has_key?(second, "b")
        end

        test "a nested value cannot be written as CSV: the connection closes", ctx do
          assert {:error, {:connection_error, %Mint.TransportError{reason: :closed}}} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT selector_last(v, time) AS s FROM #{ctx.m}",
                     database: ctx.database,
                     format: :csv
                   )
        end

        test "an unknown format is the engine's 400", ctx do
          assert {:error, %{status: 400, body: body}} =
                   unquote(client).query_sql(ctx.conn, "SELECT * FROM #{ctx.m}",
                     database: ctx.database,
                     format: :xml
                   )

          # The column in the engine's message is the position in the request
          # body, which each client serialises in its own way.
          prefix =
            "serde json error: unknown variant `xml`, expected one of `parquet`, `csv`, " <>
              "`pretty`, `json`, `json_lines`, `jsonl` at line 1 column "

          assert String.starts_with?(body, prefix)
          assert String.replace_prefix(body, prefix, "") =~ ~r/\A\d+\z/
        end

        test "a format the client cannot parse is unsupported", ctx do
          assert {:error, {:unsupported_format, :pretty}} =
                   unquote(client).query_sql(ctx.conn, "SELECT * FROM #{ctx.m}",
                     database: ctx.database,
                     format: :pretty
                   )
        end

        test "query_sql_stream answers typed rows whatever format: says", ctx do
          rows =
            ctx.conn
            |> unquote(client).query_sql_stream("SELECT v FROM #{ctx.m} ORDER BY time",
              database: ctx.database,
              format: :csv
            )
            |> Enum.to_list()

          assert rows == [%{"v" => 1.5}, %{"v" => 1.0e15}]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Database names and existence (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp database_rule_tests(client) do
    quote do
      describe "database rules contract" do
        test "a query against a missing database is a 404, SQL and InfluxQL", ctx do
          db = "contract_missing_#{System.unique_integer([:positive])}"
          body = ~s({"error":"query error: database not found: #{db}"})

          assert {:error, %{status: 404, body: ^body}} =
                   unquote(client).query_sql(ctx.conn, "SELECT 1", database: db)

          assert {:error, %{status: 404, body: ^body}} =
                   unquote(client).query_influxql(ctx.conn, "SHOW MEASUREMENTS", database: db)
        end

        test "a name the engine refuses is its 400, in its order", ctx do
          for {name, message} <- [
                {"", "db name cannot be empty"},
                {"_x", "db name did not start with a number or letter"},
                {"a.b/c/d",
                 "invalid character in database or rp name: must be ASCII, containing " <>
                   "only letters, numbers, underscores, or hyphens"},
                {"a/",
                 "db name with invalid retention policy, if providing a retention policy " <>
                   "name, must be of form '<db_name>/<rp_name>'"}
              ] do
            body = Jason.encode!(%{"error" => message})

            assert {:error, %{status: 400, body: ^body}} =
                     unquote(client).create_database(ctx.conn, name, []),
                   inspect(name)

            assert {:error, %{status: 400, body: ^body}} =
                     unquote(client).write(ctx.conn, "m v=1i", database: name),
                   inspect(name)
          end
        end

        test "a database/retention-policy name is written, queried and dropped", ctx do
          name = "contract_rp#{System.unique_integer([:positive])}/autogen"

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, "enc v=1i 1",
                     database: name,
                     precision: :second
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"v" => 1}]} =
                   unquote(client).query_sql(ctx.conn, "SELECT v FROM enc", database: name)

          assert :ok = unquote(client).delete_database(ctx.conn, name)
        end

        # retention: is a duration string; the double used to accept any
        # value, so `retention: 3600` (a v2 bucket's seconds) passed in tests
        # and was the engine's 400 in production.
        test "retention: takes the engine's duration strings and refuses the rest", ctx do
          for retention <- ["30d", "1h 30m", "1.5h", "2 weeks", "1M", "0"] do
            name = "contract_ret_#{System.unique_integer([:positive])}"
            assert :ok = unquote(client).create_database(ctx.conn, name, retention: retention)
            assert :ok = unquote(client).delete_database(ctx.conn, name)
          end

          # The position is the byte before the closing brace of the body
          # {"db":<name>,"retention_period":<retention>}; the name is 24
          # bytes, quotes included, so the body before the value is 50.
          for {retention, what, column} <- [
                {3600, "invalid type: integer `3600`", 54},
                {"1H", ~s|invalid value: string "1H"|, 54},
                {"1", ~s|invalid value: string "1"|, 53},
                {"-1h", ~s|invalid value: string "-1h"|, 55}
              ] do
            name = "contract_ret_#{100_000_000 + System.unique_integer([:positive])}"
            expected = "serde json error: #{what}, expected a duration at line 1 column #{column}"

            assert {:error, %{status: 400, body: ^expected}} =
                     unquote(client).create_database(ctx.conn, name, retention: retention),
                   inspect(retention)
          end
        end

        test "the engine's _internal is listed and cannot be dropped", ctx do
          {:ok, dbs} = unquote(client).list_databases(ctx.conn)
          assert "_internal" in Enum.map(dbs, & &1["name"])

          assert {:ok, rows} = unquote(client).query_influxql(ctx.conn, "SHOW DATABASES")
          assert %{"iox::database" => "_internal", "deleted" => false} in rows

          assert {:error, %{status: 500, body: "cannot delete internal db"}} =
                   unquote(client).delete_database(ctx.conn, "_internal")
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # SELECT DISTINCT ON (v3_core, v3_enterprise) — #23
  # ---------------------------------------------------------------------------

  defp distinct_on_tests(client) do
    quote do
      describe "SELECT DISTINCT ON contract" do
        setup ctx do
          m = "contract_don_#{System.unique_integer([:positive])}"

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              Enum.join(
                [
                  "#{m},k=a v=1i,w=10i 1",
                  "#{m},k=a v=2i 2",
                  "#{m},k=b v=3i,w=30i 3",
                  "#{m},k=b v=4i 4",
                  "#{m},k=c v=5i 5",
                  "#{m},k=a,j=x v=6i 6"
                ],
                "\n"
              ),
              database: ctx.database,
              precision: :second
            )

          InfluxElixir.ClientContract.settle(ctx)
          {:ok, m: m}
        end

        test "keeps the first row per key after ORDER BY: the latest per key", ctx do
          assert {:ok,
                  [
                    %{"k" => "a", "v" => 6, "time" => ~U[1970-01-01 00:00:06.000000Z]},
                    %{"k" => "b", "v" => 4},
                    %{"k" => "c", "v" => 5}
                  ]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) k, v, time FROM __M__ ORDER BY k, time DESC"
                   )

          # A null column of the kept row is absent, as on any row.
          assert {:ok, [%{"k" => "a"} = a, _b, _c]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) k, w FROM __M__ ORDER BY k, time DESC"
                   )

          refute Map.has_key?(a, "w")
        end

        test "composes with WHERE, LIMIT and OFFSET, which apply after it", ctx do
          assert {:ok, [%{"k" => "a", "v" => 6}, %{"k" => "b", "v" => 4}]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) k, v FROM __M__ WHERE v > 1 ORDER BY k, time DESC LIMIT 2"
                   )

          assert {:ok, [%{"k" => "b", "v" => 4}]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) k, v FROM __M__ ORDER BY k, v DESC LIMIT 1 OFFSET 1"
                   )
        end

        test "several keys, a key that is not selected, a null key, SELECT *", ctx do
          assert {:ok, [%{"k" => "a", "j" => "x", "v" => 6}, %{"k" => "a", "v" => 2}, _b, _c]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k, j) k, j, v FROM __M__ ORDER BY k, j, time DESC"
                   )

          assert {:ok, [%{"v" => 6}, %{"v" => 4}, %{"v" => 5}]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) v FROM __M__ ORDER BY k, time DESC"
                   )

          assert {:ok, [%{"v" => 5} = null_key, %{"j" => "x", "v" => 6}]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (j) j, v FROM __M__ ORDER BY j NULLS FIRST, time DESC"
                   )

          refute Map.has_key?(null_key, "j")

          assert {:ok, [%{"k" => "c", "v" => 5}, %{"k" => "b"}, %{"k" => "a"}]} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) * FROM __M__ ORDER BY k DESC, time DESC"
                   )
        end

        test "the engine's refusals", ctx do
          mismatch =
            "Error during planning: SELECT DISTINCT ON expressions must match initial " <>
              "ORDER BY expressions"

          for sql <- [
                "SELECT DISTINCT ON (k) k, v FROM __M__ ORDER BY time DESC",
                "SELECT DISTINCT ON (k, j) k, j, v FROM __M__ ORDER BY j, k"
              ] do
            assert {:error, %{status: 400, body: ^mismatch}} =
                     InfluxElixir.ClientContract.don(unquote(client), ctx, sql)
          end

          # The engine's message ends with a space.
          assert {:error,
                  %{
                    status: 405,
                    body:
                      "This feature is not implemented: DISTINCT ON expressions with GROUP BY, " <>
                        "aggregation or window functions are not supported "
                  }} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) k, max(v) FROM __M__ GROUP BY k ORDER BY k"
                   )

          assert {:error,
                  %{status: 400, body: "Error during planning: No `ON` expressions provided"}} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON () k FROM __M__"
                   )

          # ORDER BY is resolved against the table, not the select list.
          # (The engine qualifies the columns it lists, `Client.Local` does not.)
          assert {:error, %{status: 500, body: body}} =
                   InfluxElixir.ClientContract.don(
                     unquote(client),
                     ctx,
                     "SELECT DISTINCT ON (k) k AS kk, v FROM __M__ ORDER BY kk, time DESC"
                   )

          assert InfluxElixir.ClientContract.unknown_field(body, "kk", ctx.m) ==
                   ["j", "k", "time", "v", "w"]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # SQL identifiers: case folding and quoting (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp identifier_tests(client) do
    quote do
      describe "SQL identifier contract" do
        setup ctx do
          m = "Contract_Ident_#{System.unique_integer([:positive])}"

          {:ok, :written} =
            unquote(client).write(ctx.conn, "#{m},Host=h1,k=a Val=1i,v=2i 1",
              database: ctx.database,
              precision: :second
            )

          InfluxElixir.ClientContract.settle(ctx)
          {:ok, m: m}
        end

        test "an unquoted identifier is folded to lower case, a quoted one is exact", ctx do
          assert {:ok, [%{"k" => "a", "Host" => "h1", "Val" => 1}]} =
                   InfluxElixir.ClientContract.ident(
                     unquote(client),
                     ctx,
                     ~s|SELECT K, "Host", "Val" FROM __M__|
                   )

          for sql <- ["SELECT Host FROM __M__", ~s|SELECT * FROM __M__ WHERE Host = 'h1'|] do
            # (The engine quotes and qualifies the columns it lists.)
            assert {:error, %{status: 500, body: body}} =
                     InfluxElixir.ClientContract.ident(unquote(client), ctx, sql)

            assert InfluxElixir.ClientContract.unknown_field(body, "host", ctx.m) ==
                     ["Host", "Val", "k", "time", "v"]
          end

          assert {:ok, [%{"Host" => "h1"}]} =
                   InfluxElixir.ClientContract.ident(
                     unquote(client),
                     ctx,
                     ~s|SELECT * FROM __M__ WHERE "Host" = 'h1' ORDER BY "Val"|
                   )
        end

        test "aliases fold too unless quoted", ctx do
          assert {:ok, [%{"v" => 2, "V2" => 2, "Mixed Case" => 1, "avg_v" => 2.0}]} =
                   InfluxElixir.ClientContract.ident(
                     unquote(client),
                     ctx,
                     ~s|SELECT v AS V, v AS "V2", "Val" AS "Mixed Case", v * 1.0 AS Avg_V FROM __M__|
                   )
        end

        test "an unquoted mixed-case table name is folded, so it is another table", ctx do
          lower = String.downcase(ctx.m)

          assert {:error, %{status: 400, body: body}} =
                   unquote(client).query_sql(ctx.conn, "SELECT * FROM #{ctx.m}",
                     database: ctx.database
                   )

          assert body == "Error during planning: table 'public.iox.#{lower}' not found"
        end

        test "a double-quoted operand is a column, not a string", ctx do
          assert {:error, %{status: 500, body: body}} =
                   InfluxElixir.ClientContract.ident(
                     unquote(client),
                     ctx,
                     ~s|SELECT * FROM __M__ WHERE k = "hello"|
                   )

          assert InfluxElixir.ClientContract.unknown_field(body, "hello", ctx.m) ==
                   ["Host", "Val", "k", "time", "v"]

          assert {:ok, [_row]} =
                   InfluxElixir.ClientContract.ident(
                     unquote(client),
                     ctx,
                     ~s|SELECT * FROM __M__ WHERE k = "k"|
                   )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Tabs in line protocol (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp tab_tests(client) do
    quote do
      describe "write/3 — tabs in line protocol contract" do
        test "a tab outside a quoted string refuses the line, with the engine's message", ctx do
          m = "contract_tab_#{System.unique_integer([:positive])}"
          space = "Expected at least one space character, got "
          trailing = "Could not parse entire line. Found trailing content: "

          for {lp, message} <- [
                {"#{m},h=a\tb v=1i 1", space <> "`\tb v=1i 1`"},
                {"#{m}\tx v=1i 1", space <> "`\tx v=1i 1`"},
                {"#{m},h\tk=a v=1i 1",
                 "Tag set malformed: could not find equals sign in `h\tk=a v=1i...`"},
                {"#{m},h=\ta v=1i 1", "Expected tag value, got `\ta v=1i 1`"},
                {"#{m} v\tx=1i 1", "No fields were provided"},
                {"#{m} v=1i,w\tx=2i 1", trailing <> "`w\tx=2i 1`"},
                {"#{m} v=1i,w=2i,x\ty=3i 1", trailing <> "`,x\ty=3i 1`"},
                {"#{m} v=1i\t1", trailing <> "`\t1`"}
              ] do
            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, lp, database: ctx.database),
                   inspect(lp)

            assert %{"data" => [%{"error_message" => ^message}]} = Jason.decode!(body),
                   inspect(lp)
          end
        end

        test "a CRLF ending, a stray carriage return, a line of other whitespace", ctx do
          m = "contract_cr_#{System.unique_integer([:positive])}"
          trailing = "Could not parse entire line. Found trailing content: "
          no_space = "Expected at least one space character, got end of input"

          for {lp, number, message, original} <- [
                # CRLF: the \r ends the value; the echoed line drops it.
                {"#{m} v=1i 1\r\n", 1, trailing <> "`\r`", "#{m} v=1i 1"},
                {"#{m} s=\"x\"\r\n", 1, trailing <> "`\r`", "#{m} s=\"x\""},
                # One inside the line stays in the echo.
                {"#{m} v=1i\r 1", 1, trailing <> "`\r 1`", "#{m} v=1i\r 1"},
                # An invalid value before it fails the field.
                {"#{m} v=abc\r\n", 1, "No fields were provided", "#{m} v=abc"},
                # Only spaces and tabs make a blank line.
                {"#{m} v=1i 1\n\v\n", 2, no_space, "\v"},
                {"#{m} v=1i 1\n \n", 2, no_space, " "}
              ] do
            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, lp,
                       database: ctx.database,
                       precision: :second
                     ),
                   inspect(lp)

            assert %{"data" => [%{"line_number" => ^number, "error_message" => ^message} = e]} =
                     Jason.decode!(body),
                   inspect(lp)

            assert e["original_line"] == String.slice(original, 0, 20), inspect(lp)
          end

          # In a tag value a \r is an ordinary character.
          tagged = m <> "_tag"

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, "#{tagged},t=a\rb v=1i 1",
                     database: ctx.database,
                     precision: :second
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"t" => "a\rb"}]} =
                   unquote(client).query_sql(ctx.conn, ~s|SELECT t FROM "#{tagged}"|,
                     database: ctx.database
                   )
        end

        test "a leading tab is whitespace; an escaped tab and one in a string are kept", ctx do
          m = "contract_tab_ok_#{System.unique_integer([:positive])}"

          assert {:ok, :written} =
                   unquote(client).write(
                     ctx.conn,
                     "\t#{m},h=a\\\tb s=\"x\ty\" 1",
                     database: ctx.database,
                     precision: :second
                   )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"h" => "a\\\tb", "s" => "x\ty"}]} =
                   unquote(client).query_sql(ctx.conn, ~s|SELECT h, s FROM "#{m}"|,
                     database: ctx.database
                   )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Timestamp range (every profile)
  # ---------------------------------------------------------------------------

  # A timestamp must fit in a signed 64-bit count of nanoseconds once scaled
  # by the precision; each version refuses the rest in its own words.
  defp timestamp_range_tests(client, version) do
    quote do
      describe "write/3 — timestamp range contract" do
        test "the largest timestamp per precision is stored; one more is refused", ctx do
          m = "contract_ts_#{System.unique_integer([:positive])}"
          v2? = unquote(version) == :v2

          for {ok, over, precision, unit} <- [
                {9_223_372_036, 9_223_372_037, :second, "Second"},
                {9_223_372_036_854, 9_223_372_036_855, :millisecond, "Millisecond"},
                {9_223_372_036_854_775, 9_223_372_036_854_776, :microsecond, "Microsecond"}
              ] do
            assert {:ok, :written} =
                     unquote(client).write(ctx.conn, "#{m} v=1i #{ok}",
                       database: ctx.database,
                       precision: precision
                     )

            assert {:error, %{status: 400, body: body}} =
                     unquote(client).write(ctx.conn, "#{m} v=1i #{over}",
                       database: ctx.database,
                       precision: precision
                     )

            if v2? do
              assert %{"message" => message} = Jason.decode!(body)

              assert message ==
                       "unable to parse '#{m} v=1i #{over}': time outside range " <>
                         "-9223372036854775806 - 9223372036854775806"
            else
              assert %{"data" => [%{"error_message" => message}]} = Jason.decode!(body)
              assert message == "timestamp, #{over}, out of range for precision: #{unit}"
            end
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Parameterized SQL queries (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp param_tests(client) do
    quote do
      describe "query_sql/3 — parameterized query contract" do
        test "filters by string parameter", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_params,host=alpha value=1i 1000000000\ncontract_params,host=beta value=2i 2000000000",
            database: ctx.database
          )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok,
                  [%{"host" => "alpha", "value" => 1, "time" => ~U[1970-01-01 00:00:01.000000Z]}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_params WHERE host = $host",
                     database: ctx.database,
                     params: %{host: "alpha"}
                   )
        end

        # Jason encodes a Decimal as a JSON string, which the engine compared
        # as text: 500.0 passed `>= 1000.00` ("500.0" >= "1000.00") over HTTP
        # while Client.Local compared numbers (verified). Both now compare
        # numbers.
        test "a Decimal param compares as a number", ctx do
          m = "contract_params_dec_#{System.unique_integer([:positive])}"

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "#{m} amount=500.0 1000000000\n#{m} amount=5000.0 2000000000\n" <>
                "#{m} amount=12000.0 3000000000",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          for {decimal, expected} <- [
                {"1000.00", [5000.0, 12_000.0]},
                {"-1", [500.0, 5000.0, 12_000.0]},
                {"1.2E+4", [12_000.0]}
              ] do
            assert {:ok, rows} =
                     unquote(client).query_sql(
                       ctx.conn,
                       "SELECT amount FROM #{m} WHERE amount >= $p ORDER BY amount",
                       database: ctx.database,
                       params: %{p: Decimal.new(decimal)}
                     )

            assert Enum.map(rows, & &1["amount"]) == expected, decimal
          end
        end

        test "accepts params as a keyword list as well as a map", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_params_kw,host=alpha value=1i 1000000000\ncontract_params_kw,host=beta value=2i 2000000000",
            database: ctx.database
          )

          InfluxElixir.ClientContract.settle(ctx)

          # Jason cannot encode tuples, so a keyword list used to raise in
          # Client.HTTP while Client.Local accepted it.
          assert {:ok,
                  [%{"host" => "beta", "value" => 2, "time" => ~U[1970-01-01 00:00:02.000000Z]}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_params_kw WHERE host = $host",
                     database: ctx.database,
                     params: [host: "beta"]
                   )
        end

        test "filters by integer parameter", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_params_int value=100i 1000000000\ncontract_params_int value=200i 2000000000",
            database: ctx.database
          )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"value" => 100, "time" => ~U[1970-01-01 00:00:01.000000Z]}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_params_int WHERE value = $val",
                     database: ctx.database,
                     params: %{val: 100}
                   )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # WHERE literal typing (v3_core, v3_enterprise)
  #
  # Pins the DataFusion rules a test double must reproduce (#12): a quoted
  # literal is a string and is never re-typed; a string literal against a
  # numeric column compares the column's text rendering.
  # ---------------------------------------------------------------------------

  defp literal_tests(client) do
    quote do
      describe "query_sql/3 — WHERE literal typing contract" do
        setup ctx do
          unquote(client).write(
            ctx.conn,
            "contract_lit,repcode=08338636 amount=500.0 1700000000000000000\n" <>
              "contract_lit,repcode=12345678 amount=5000.0 1700000100000000000",
            database: ctx.database
          )

          InfluxElixir.ClientContract.settle(ctx)

          :ok
        end

        test "a zero-padded quoted literal matches a string tag", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_lit WHERE repcode = '08338636'",
              database: ctx.database
            )

          assert [%{"repcode" => "08338636"}] = rows
        end

        test "IN with a bound string param keeps the leading zero", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_lit WHERE repcode IN ($rc)",
              database: ctx.database,
              params: %{rc: "08338636"}
            )

          assert [%{"repcode" => "08338636"}] = rows
        end

        test "a bare numeric literal does not match a string tag", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_lit WHERE repcode = 08338636",
              database: ctx.database
            )

          assert rows == []
        end

        test "a string literal against a float field compares as text", ctx do
          # '500.0' >= '1000.00' lexically — both rows match. Bind a number
          # (or write a bare literal) to get a numeric comparison.
          assert {:ok,
                  [
                    %{
                      "repcode" => "08338636",
                      "amount" => 500.0,
                      "time" => ~U[2023-11-14 22:13:20.000000Z]
                    },
                    %{
                      "repcode" => "12345678",
                      "amount" => 5000.0,
                      "time" => ~U[2023-11-14 22:15:00.000000Z]
                    }
                  ]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT * FROM contract_lit WHERE amount >= '1000.00' ORDER BY time",
                     database: ctx.database
                   )

          {:ok, numeric} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_lit WHERE amount >= $min",
              database: ctx.database,
              params: %{min: 1000.0}
            )

          assert [%{"amount" => 5000.0}] = numeric
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Timestamp precision (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp precision_tests(client) do
    quote do
      describe "write/3 — timestamp precision contract" do
        test "second precision writes and queries correctly", ctx do
          # Write with second precision — InfluxDB converts to nanoseconds
          unquote(client).write(
            ctx.conn,
            "contract_prec_s value=1i 1700000000",
            database: ctx.database,
            precision: :second
          )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_prec_s",
              database: ctx.database
            )

          # 1700000000 s → the same instant on every client and transport
          assert [%{"time" => ~U[2023-11-14 22:13:20.000000Z]}] = rows
        end

        test "millisecond precision writes correctly", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_prec_ms value=1i 1700000000000",
            database: ctx.database,
            precision: :millisecond
          )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_prec_ms",
              database: ctx.database
            )

          assert [%{"time" => ~U[2023-11-14 22:13:20.000000Z]}] = rows
        end

        test "microsecond precision writes correctly", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_prec_us value=1i 1700000000000000",
            database: ctx.database,
            precision: :microsecond
          )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_prec_us",
              database: ctx.database
            )

          assert [%{"time" => ~U[2023-11-14 22:13:20.000000Z]}] = rows
        end

        test "short spellings, strings and auto are the engine's; an unknown precision is 400",
             ctx do
          m = "contract_prec2_#{System.unique_integer([:positive])}"

          for {precision, ts} <- [
                {:ms, 1_700_000_000_000},
                {"s", 1_700_000_000},
                {:auto, 1_700_000_000}
              ] do
            assert {:ok, :written} =
                     unquote(client).write(ctx.conn, "#{m} value=1i #{ts}",
                       database: ctx.database,
                       precision: precision
                     )
          end

          expected = InfluxElixir.ClientContract.bad_precision("bogus")

          assert {:error, %{status: 400, body: ^expected}} =
                   unquote(client).write(ctx.conn, "#{m} value=1i 1",
                     database: ctx.database,
                     precision: :bogus
                   )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(ctx.conn, "SELECT time FROM #{m}", database: ctx.database)

          assert Enum.map(rows, & &1["time"]) == [~U[2023-11-14 22:13:20.000000Z]]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Ordered aggregates: FIRST/LAST (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp ordered_agg_tests(client) do
    quote do
      describe "query_sql/3 — first_value/last_value aggregate contract" do
        setup ctx do
          base_ts = 1_700_000_000_000_000_000

          Enum.each([{20, 200}, {30, 300}, {10, 100}], fn {val, ts_offset} ->
            ts = base_ts + ts_offset * 1_000_000_000

            {:ok, :written} =
              unquote(client).write(
                ctx.conn,
                "contract_fl value=#{val}i #{ts}",
                database: ctx.database
              )
          end)

          InfluxElixir.ClientContract.settle(ctx)

          :ok
        end

        test "first_value(ORDER BY time) returns the earliest value", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '1 hour', time) AS time,
            first_value(value ORDER BY time) AS first_val
          FROM contract_fl
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          """

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              sql,
              database: ctx.database
            )

          assert [%{"first_val" => 10}] = rows
        end

        test "last_value(ORDER BY time) returns the latest value", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '1 hour', time) AS time,
            last_value(value ORDER BY time) AS last_val
          FROM contract_fl
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          """

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              sql,
              database: ctx.database
            )

          assert [%{"last_val" => 30}] = rows
        end

        test "first_value(ORDER BY time DESC) returns the latest value", ctx do
          sql = """
          SELECT first_value(value ORDER BY time DESC) AS latest
          FROM contract_fl
          """

          {:ok, [row]} =
            unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          assert row["latest"] == 30
        end

        test "latest value per group (the #13 shape)", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_latest,symbol=BTC price=1.0 1700000000000000000\n" <>
              "contract_latest,symbol=BTC price=2.0 1700000100000000000\n" <>
              "contract_latest,symbol=ETH price=9.0 1700000200000000000\n" <>
              "contract_latest,symbol=ETH price=8.0 1700000050000000000",
            database: ctx.database
          )

          InfluxElixir.ClientContract.settle(ctx)

          sql = """
          SELECT symbol, last_value(price ORDER BY time) AS price
          FROM contract_latest
          GROUP BY symbol
          """

          {:ok, rows} =
            unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

          assert Map.new(rows, &{&1["symbol"], &1["price"]}) ==
                   %{"BTC" => 2.0, "ETH" => 9.0}
        end

        test "InfluxQL FIRST()/LAST() are not v3 SQL and are rejected", ctx do
          # The engine suggests a similar function, and picks among equally
          # close ones at random ('instr' or 'sqrt' for 'first'), so the
          # suggestion is only checked to be one name.
          for {sql, name} <- [
                {"SELECT FIRST(value, time) AS v FROM contract_fl", "first"},
                {"SELECT LAST(value) AS v FROM contract_fl", "last"}
              ] do
            prefix = "Error during planning: Invalid function '#{name}'.\nDid you mean '"

            assert {:error, %{status: 400, body: body}} =
                     unquote(client).query_sql(ctx.conn, sql, database: ctx.database)

            assert String.starts_with?(body, prefix), sql
            assert String.replace_prefix(body, prefix, "") =~ ~r/\A\w+'\?\z/, sql
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # DISTINCT queries (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp distinct_tests(client) do
    quote do
      describe "query_sql/3 — DISTINCT contract" do
        # Every line has its own time: untimed lines of one series in one
        # write are one point, so they could never repeat a value.
        test "SELECT DISTINCT returns each value once", ctx do
          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              "contract_dist,host=a value=1i 1000000000\n" <>
                "contract_dist,host=b value=2i 2000000000\n" <>
                "contract_dist,host=a value=3i 3000000000",
              database: ctx.database
            )

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"host" => "a"}, %{"host" => "b"}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT DISTINCT host FROM contract_dist ORDER BY host",
                     database: ctx.database
                   )

          assert {:ok, rows} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT host FROM contract_dist ORDER BY host, value",
                     database: ctx.database
                   )

          # Without DISTINCT the repeated value is there.
          assert Enum.map(rows, & &1["host"]) == ["a", "a", "b"]
        end

        test "SELECT DISTINCT over two columns returns unique combinations", ctx do
          lp =
            Enum.join(
              [
                "contract_dist2,provider=p1,symbol=A value=1i 1000000000",
                "contract_dist2,provider=p1,symbol=A value=2i 2000000000",
                "contract_dist2,provider=p2,symbol=B value=3i 3000000000"
              ],
              "\n"
            )

          {:ok, :written} = unquote(client).write(ctx.conn, lp, database: ctx.database)
          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok,
                  [
                    %{"provider" => "p1", "symbol" => "A"},
                    %{"provider" => "p2", "symbol" => "B"}
                  ]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT DISTINCT provider, symbol FROM contract_dist2 ORDER BY provider",
                     database: ctx.database
                   )

          assert {:ok, [%{"n" => 3}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT COUNT(*) AS n FROM contract_dist2",
                     database: ctx.database
                   )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scalar math functions: abs, round, floor, ceil (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp scalar_function_tests(client) do
    quote do
      describe "scalar functions — contract" do
        unquote(scalar_function_setup(client))

        # Issue #25: a transaction's magnitude against a threshold. The
        # double refused the clause by name (and before that read it as a
        # column named `abs(amount)`, returning no rows).
        test "abs() in WHERE compares a magnitude against a parameter", ctx do
          assert {:ok,
                  [%{"amount" => -80_000_000_000, "time" => ~U[1970-01-01 00:00:01.000000Z]}]} =
                   unquote(client).query_sql(
                     ctx.conn,
                     "SELECT amount, time FROM #{ctx.m} WHERE firm = $firm " <>
                       "AND time >= $start AND time <= $end AND abs(amount) >= $threshold",
                     database: ctx.database,
                     params: %{
                       firm: "f1",
                       start: "1970-01-01T00:00:00Z",
                       end: "1970-01-01T00:00:05Z",
                       threshold: 5_000_000_000
                     }
                   )
        end

        test "abs, round, floor and ceil answer as the engine does, null in, null out", ctx do
          assert {:ok, rows} =
                   ctx.sql.(
                     "SELECT abs(amount) AS a, abs(f) AS af, round(f) AS r, round(f, 1) AS r1, " <>
                       "round(1234.5678, -2) AS rn, floor(f) AS fl, ceil(f) AS c, " <>
                       "ROUND(amount) AS ra FROM #{ctx.m} ORDER BY time"
                   )

          assert rows == [
                   %{
                     "a" => 80_000_000_000,
                     "af" => 2.5,
                     "r" => -3.0,
                     "r1" => -2.5,
                     "rn" => 1200.0,
                     "fl" => -3.0,
                     "c" => -2.0,
                     "ra" => -80_000_000_000.0
                   },
                   %{
                     "a" => 100_000_000,
                     "af" => 2.5,
                     "r" => 3.0,
                     "r1" => 2.5,
                     "rn" => 1200.0,
                     "fl" => 2.0,
                     "c" => 3.0,
                     "ra" => 100_000_000.0
                   },
                   %{
                     "af" => 0.4,
                     "r" => 0.0,
                     "r1" => 0.4,
                     "rn" => 1200.0,
                     "fl" => 0.0,
                     "c" => 1.0
                   },
                   %{"a" => 90_000_000_000, "rn" => 1200.0, "ra" => -90_000_000_000.0}
                 ]
        end

        test "a call stands wherever an expression does", ctx do
          times = fn sql ->
            {:ok, rows} = ctx.sql.("SELECT time FROM #{ctx.m} WHERE #{sql} ORDER BY time")
            Enum.map(rows, &DateTime.to_unix(&1["time"]))
          end

          assert times.("abs(f) > 1") == [1, 2]
          assert times.("1 < abs(f)") == [1, 2]
          assert times.("abs(f) BETWEEN 1 AND 3") == [1, 2]
          assert times.("abs(f) IN (2.5)") == [1, 2]
          assert times.("abs(f) NOT IN (2.5)") == [3]
          assert times.("abs(f) IS NULL") == [4]
          assert times.("abs(f * 2) = 5") == [1, 2]
          assert times.("round(f) = 0 OR ceil(f) = 3") == [2, 3]
          assert times.("'1970-01-01T00:00:02Z' < time") == [3, 4]

          assert {:ok, [%{"a" => 2.5}, %{"a" => 2.5}, %{"a" => 0.4}]} =
                   ctx.sql.(
                     "SELECT abs(f) AS a FROM #{ctx.m} WHERE f IS NOT NULL " <>
                       "ORDER BY abs(f) DESC, time"
                   )

          assert {:ok, [%{"s" => 170_100_000_000}]} =
                   ctx.sql.("SELECT sum(abs(amount)) AS s FROM #{ctx.m}")
        end
      end
    end
  end

  defp scalar_function_error_tests(client) do
    quote do
      describe "scalar function errors — contract" do
        unquote(scalar_function_setup(client))

        # The engine types a call's arguments when it plans the query: a
        # wrong one fails it though no row reaches the call (`f = 99`), with
        # the message shaped by where the call stands.
        test "a wrong argument is the engine's planning error, worded per clause", ctx do
          suggestion =
            " No function matches the given name and argument types 'abs(Utf8)'. You might " <>
              "need to add explicit type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"

          head =
            "Error during planning: Function 'abs' expects NativeType::Numeric but received " <>
              "NativeType::String"

          assert {:error, %{status: 400, body: body}} =
                   ctx.sql.("SELECT f FROM #{ctx.m} WHERE abs(s) > 1 AND f = 99")

          assert body == "type_coercion\ncaused by\n" <> head <> suggestion

          assert {:error, %{status: 400, body: body}} =
                   ctx.sql.("SELECT abs(s) AS a FROM #{ctx.m} WHERE f = 99")

          assert body == head <> suggestion

          assert {:error, %{status: 400, body: body}} =
                   ctx.sql.("SELECT f FROM #{ctx.m} ORDER BY abs(s)")

          assert body == "type_coercion\ncaused by\n" <> head

          assert {:error, %{status: 400, body: body}} =
                   ctx.sql.("SELECT f FROM #{ctx.m} WHERE abs(firm) > 1")

          assert body ==
                   "type_coercion\ncaused by\n" <>
                     head <>
                     " No function matches the given name and argument types " <>
                     "'abs(Dictionary(Int32, Utf8))'. You might need to add explicit type " <>
                     "casts.\n\tCandidate functions:\n\tabs(Numeric(1))"

          assert {:error, %{status: 400, body: body}} =
                   ctx.sql.("SELECT f FROM #{ctx.m} WHERE floor(b) > 1")

          assert body ==
                   "type_coercion\ncaused by\nError during planning: Failed to coerce arguments " <>
                     "to satisfy a call to 'floor' function: coercion from Boolean to the " <>
                     "signature Uniform(1, [Float64, Float32]) failed No function matches the " <>
                     "given name and argument types 'floor(Boolean)'. You might need to add " <>
                     "explicit type casts.\n\tCandidate functions:\n\tfloor(Float64/Float32)"

          assert {:error, %{status: 400, body: body}} =
                   ctx.sql.("SELECT f FROM #{ctx.m} ORDER BY abs(time)")

          assert body ==
                   "type_coercion\ncaused by\nError during planning: Function 'abs' expects " <>
                     "NativeType::Numeric but received NativeType::Timestamp(Nanosecond, None)"
        end

        test "a wrong argument count is the engine's error", ctx do
          assert {:error, %{status: 400, body: body}} =
                   ctx.sql.("SELECT f FROM #{ctx.m} WHERE abs(f, 1) > 1")

          assert body ==
                   "type_coercion\ncaused by\nError during planning: Function 'abs' expects 1 " <>
                     "arguments but received 2 No function matches the given name and " <>
                     "argument types 'abs(Float64, Int64)'. You might need to add explicit " <>
                     "type casts.\n\tCandidate functions:\n\tabs(Numeric(1))"

          round_candidates =
            "\n\tCandidate functions:\n\tround(Float64, Int64)\n\tround(Float32, Int64)\n" <>
              "\tround(Float64)\n\tround(Float32)"

          assert {:error, %{status: 400, body: body}} =
                   ctx.sql.("SELECT round() AS r FROM #{ctx.m}")

          assert body ==
                   "Error during planning: 'round' does not support zero arguments No " <>
                     "function matches the given name and argument types 'round()'. You " <>
                     "might need to add explicit type casts." <> round_candidates

          assert {:error, %{status: 400, body: body}} =
                   ctx.sql.("SELECT round(f, 1.5) AS r FROM #{ctx.m}")

          assert body ==
                   "Error during planning: Failed to coerce arguments to satisfy a call to " <>
                     "'round' function: coercion from Float64, Float64 to the signature " <>
                     "OneOf([Exact([Float64, Int64]), Exact([Float32, Int64]), " <>
                     "Exact([Float64]), Exact([Float32])]) failed No function matches the " <>
                     "given name and argument types 'round(Float64, Float64)'. You might " <>
                     "need to add explicit type casts." <> round_candidates

          assert {:error,
                  %{
                    status: 405,
                    body: "This feature is not implemented: CEIL with scale is not supported"
                  }} =
                   ctx.sql.("SELECT f FROM #{ctx.m} WHERE ceil(f, 1) > 1")
        end
      end
    end
  end

  defp scalar_function_setup(client) do
    quote do
      setup ctx do
        m = "contract_fn_#{System.unique_integer([:positive])}"

        {:ok, :written} =
          unquote(client).write(
            ctx.conn,
            "#{m},firm=f1 amount=-80000000000i,f=-2.5,s=\"x\" 1000000000\n" <>
              "#{m},firm=f1 amount=100000000i,f=2.5 2000000000\n" <>
              "#{m},firm=f1 f=0.4 3000000000\n" <>
              "#{m},firm=f2 amount=-90000000000i,b=true 4000000000",
            database: ctx.database
          )

        InfluxElixir.ClientContract.settle(ctx)
        {:ok, m: m, sql: &unquote(client).query_sql(ctx.conn, &1, database: ctx.database)}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Gzip write handling (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp gzip_tests(client) do
    quote do
      describe "write/3 — gzip contract" do
        test "gzip-compressed payload is accepted and queryable", ctx do
          lp = "contract_gz value=42i 1700000000000000000"
          compressed = :zlib.gzip(lp)

          {:ok, :written} =
            unquote(client).write(
              ctx.conn,
              compressed,
              database: ctx.database,
              gzip: true
            )

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_gz",
              database: ctx.database
            )

          assert [%{"value" => 42}] = rows
        end

        # `gzip: true` is the Content-Encoding header: it, not the bytes,
        # decides. Each body below is the engine's own reason (verified).
        test "a body gzip: true cannot decompress is the engine's 400, and nothing is stored",
             ctx do
          db = "contract_gzbad_#{System.unique_integer([:positive])}"
          good = :zlib.gzip("contract_gzbad v=1i 1")
          size = byte_size(good)
          <<body::binary-size(size - 8), _crc::binary-size(4), isize::binary-size(4)>> = good

          cases = [
            {"x", "unexpected end of file"},
            {"contract_gzbad v=1i 1", "invalid gzip header"},
            {binary_part(good, 0, size - 4), "unexpected end of file"},
            {<<0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3>> <> "garbagegarbage",
             "corrupt deflate stream"},
            {body <> <<0, 0, 0, 0>> <> isize,
             "corrupt gzip stream does not have a matching checksum"}
          ]

          for {payload, reason} <- cases do
            assert {:error, %{status: 400, body: "error decoding gzip stream: " <> ^reason}} =
                     unquote(client).write(ctx.conn, payload, database: db, gzip: true)
          end

          # The body is read before the database is created.
          assert {:ok, databases} = unquote(client).list_databases(ctx.conn)
          refute Enum.any?(databases, &(&1["name"] == db))
        end

        test "the request's parameters are read before its body", ctx do
          expected = InfluxElixir.ClientContract.bad_precision("zz")

          assert {:error, %{status: 400, body: ^expected}} =
                   unquote(client).write(ctx.conn, "x",
                     database: ctx.database,
                     gzip: true,
                     precision: "zz"
                   )
        end

        test "concatenated gzip members are one body", ctx do
          m = "contract_gzcat_#{System.unique_integer([:positive])}"
          payload = :zlib.gzip("#{m} v=1i 1\n") <> :zlib.gzip("#{m} v=2i 2")

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, payload, database: ctx.database, gzip: true)

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"v" => 1}, %{"v" => 2}]} =
                   unquote(client).query_sql(ctx.conn, "SELECT v FROM #{m} ORDER BY time",
                     database: ctx.database
                   )
        end

        test "gzip bytes without gzip: true are not UTF-8 to the engine", ctx do
          # 0x1F is ASCII; 0x8B cannot start a character.
          assert {:error,
                  %{
                    status: 400,
                    body:
                      "body content is not valid utf8: invalid utf-8 sequence of 1 bytes " <>
                        "from index 1"
                  }} =
                   unquote(client).write(ctx.conn, :zlib.gzip("m v=1i 1"), database: ctx.database)
        end

        test "a body that is not UTF-8 names the first bad byte as the engine does", ctx do
          cases = [
            {"u v=1i \xFF", "invalid utf-8 sequence of 1 bytes from index 7"},
            {"u v=1i 1\xE2\x82", "incomplete utf-8 byte sequence from index 8"},
            {"u v=\xF0\x9F\x98x", "invalid utf-8 sequence of 3 bytes from index 4"},
            {"u v=\xE0\x80\x80", "invalid utf-8 sequence of 1 bytes from index 4"},
            {"u v=\xED\xA0\x80", "invalid utf-8 sequence of 1 bytes from index 4"}
          ]

          for {payload, reason} <- cases do
            assert {:error, %{status: 400, body: "body content is not valid utf8: " <> ^reason}} =
                     unquote(client).write(ctx.conn, payload, database: ctx.database)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Gzip and non-UTF-8 write bodies (v2)
  # ---------------------------------------------------------------------------

  defp v2_body_tests(client) do
    quote do
      describe "write/3 — v2 body contract" do
        test "a gzip body is read with gzip: true; a plain one then is the engine's 500", ctx do
          m = "contract_v2gz_#{System.unique_integer([:positive])}"

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, :zlib.gzip("#{m} v=1i 1"),
                     database: ctx.database,
                     gzip: true
                   )

          assert {:error, %{status: 500, body: body}} =
                   unquote(client).write(ctx.conn, "#{m} v=2i 2",
                     database: ctx.database,
                     gzip: true
                   )

          assert Jason.decode!(body) == %{
                   "code" => "internal error",
                   "message" => "An internal error has occurred - check server logs"
                 }

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"_value" => 1}]} =
                   unquote(client).query_flux(
                     ctx.conn,
                     ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}")|
                   )
        end

        test "a body that is not UTF-8 is stored byte for byte", ctx do
          m = "contract_v2u8_#{System.unique_integer([:positive])}"

          assert {:ok, :written} =
                   unquote(client).write(ctx.conn, "#{m},t=a\xFFb v=1i 1", database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          assert {:ok, [%{"t" => "a\xFFb", "_value" => 1}]} =
                   unquote(client).query_flux(
                     ctx.conn,
                     ~s|from(bucket: "#{ctx.database}") \|> range(start: 0) \|> filter(fn: (r) => r._measurement == "#{m}")|
                   )
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Line protocol escaping (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp escaping_tests(client) do
    quote do
      describe "write/3 — line protocol escaping contract" do
        test "escaped space in measurement name round-trips", ctx do
          lp = "my\\ measurement value=1i 1700000000000000000"

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              ~s(SELECT * FROM "my measurement"),
              database: ctx.database
            )

          assert [%{"value" => 1}] = rows
        end

        test "tag with special characters round-trips", ctx do
          # Escaped comma in tag value
          lp = "contract_esc,region=us\\,east value=1i 1700000000000000000"

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_esc",
              database: ctx.database
            )

          assert [%{"region" => "us,east"}] = rows
        end

        test "string field with escaped quotes round-trips", ctx do
          lp = ~s(contract_esc_str label="say \\"hi\\"" 1700000000000000000)

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          InfluxElixir.ClientContract.settle(ctx)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_esc_str",
              database: ctx.database
            )

          assert [%{"label" => ~s(say "hi")}] = rows
        end
      end
    end
  end
end
