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
    enterprise_ops = profile == :v3_enterprise

    health_tests = health_tests(client)
    write_tests = write_tests(client, profile)

    sql_tests = if v3_sql, do: sql_tests(client), else: nil
    roundtrip_tests = if v3_sql, do: roundtrip_tests(client), else: nil
    stream_tests = if v3_sql, do: stream_tests(client), else: nil
    aggregate_tests = if v3_sql, do: aggregate_tests(client), else: nil
    ordered_agg_tests = if v3_sql, do: ordered_agg_tests(client), else: nil
    distinct_tests = if v3_sql, do: distinct_tests(client), else: nil
    param_tests = if v3_sql, do: param_tests(client), else: nil
    precision_tests = if v3_sql, do: precision_tests(client), else: nil
    gzip_tests = if v3_sql, do: gzip_tests(client), else: nil
    escaping_tests = if v3_sql, do: escaping_tests(client), else: nil
    error_shape_tests = if v3_sql, do: error_shape_tests(client), else: nil

    execute_tests =
      cond do
        profile == :v3_enterprise -> execute_tests_enterprise(client)
        v3_sql -> execute_tests_core(client)
        true -> nil
      end

    influxql_tests = if v3_sql, do: influxql_tests(client), else: nil
    db_admin_tests = if v3_sql, do: db_admin_tests(client), else: nil

    bucket_tests = if v2_ops, do: bucket_tests(client), else: nil
    flux_tests = if v2_ops, do: flux_tests(client), else: nil

    token_tests = if enterprise_ops, do: token_tests(client), else: nil

    blocks =
      [
        health_tests,
        write_tests,
        sql_tests,
        roundtrip_tests,
        stream_tests,
        aggregate_tests,
        ordered_agg_tests,
        distinct_tests,
        param_tests,
        precision_tests,
        gzip_tests,
        escaping_tests,
        error_shape_tests,
        execute_tests,
        influxql_tests,
        db_admin_tests,
        bucket_tests,
        flux_tests,
        token_tests
      ]
      |> Enum.reject(&is_nil/1)

    quote do
      (unquote_splicing(blocks))
    end
  end

  # ---------------------------------------------------------------------------
  # Health (all profiles)
  # ---------------------------------------------------------------------------

  defp health_tests(client) do
    quote do
      describe "health/1" do
        test "returns {:ok, map} with string status key", ctx do
          {:ok, result} = unquote(client).health(ctx.conn)
          assert is_map(result)
          assert Map.has_key?(result, "status")
        end

        test "reports a passing status", ctx do
          {:ok, %{"status" => status}} = unquote(client).health(ctx.conn)
          assert status in ["pass", "ok"]
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
          test "returns {:error, _} for an unknown database", ctx do
            lp = "cpu value=1.0"

            assert {:error, _reason} =
                     unquote(client).write(
                       ctx.conn,
                       lp,
                       database: "ghost_db_contract"
                     )
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

        test "returns {:error, _} for malformed line protocol", ctx do
          assert {:error, _reason} =
                   unquote(client).write(
                     ctx.conn,
                     "this is not line protocol!!",
                     database: ctx.database
                   )
        end
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

        test "each entry is a map with a string name key", ctx do
          {:ok, dbs} = unquote(client).list_databases(ctx.conn)

          Enum.each(dbs, fn db ->
            assert is_map(db)
            assert is_binary(db["name"])
          end)
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
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Query SQL (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp sql_tests(client) do
    quote do
      describe "query_sql/3 — basic SELECT contract" do
        test "returns error for non-existent measurement", ctx do
          result =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM empty_measurement_contract",
              database: ctx.database
            )

          assert {:error, _reason} = result
        end

        test "LIMIT restricts the number of returned rows", ctx do
          Enum.each(1..5, fn i ->
            unquote(client).write(
              ctx.conn,
              "contract_limited value=#{i}i",
              database: ctx.database
            )
          end)

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_limited LIMIT 2",
              database: ctx.database
            )

          assert length(rows) == 2
        end

        test "ORDER BY time DESC returns most-recent rows first", ctx do
          Enum.each([100, 200, 300], fn ts ->
            unquote(client).write(
              ctx.conn,
              "contract_ordered value=#{ts}i #{ts}",
              database: ctx.database
            )
          end)

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_ordered ORDER BY time DESC",
              database: ctx.database
            )

          timestamps = Enum.map(rows, & &1["time"])
          assert timestamps == Enum.sort(timestamps, :desc)
        end

        test "WHERE clause filters by tag value", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_tagged,host=alpha value=1i",
            database: ctx.database
          )

          unquote(client).write(
            ctx.conn,
            "contract_tagged,host=beta value=2i",
            database: ctx.database
          )

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_tagged WHERE host = 'alpha'",
              database: ctx.database
            )

          assert length(rows) == 1
          assert hd(rows)["value"] == 1
        end
      end

      describe "query_sql/3 — multiple measurements contract" do
        test "querying one measurement does not return rows from another",
             ctx do
          unquote(client).write(
            ctx.conn,
            "contract_a value=1i",
            database: ctx.database
          )

          unquote(client).write(
            ctx.conn,
            "contract_b value=2i",
            database: ctx.database
          )

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows_a} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_a",
              database: ctx.database
            )

          {:ok, rows_b} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_b",
              database: ctx.database
            )

          assert length(rows_a) == 1
          assert length(rows_b) == 1
          assert hd(rows_a)["value"] == 1
          assert hd(rows_b)["value"] == 2
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

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_rt WHERE type = 'int' LIMIT 1",
              database: ctx.database
            )

          assert rows != []
          assert is_integer(hd(rows)["count"])
          assert hd(rows)["count"] == ts
        end

        test "float field survives write/query cycle", ctx do
          lp = "contract_rt,type=float ratio=3.14"

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_rt WHERE type = 'float' LIMIT 1",
              database: ctx.database
            )

          assert rows != []
          assert_in_delta hd(rows)["ratio"], 3.14, 1.0e-10
        end

        test "string field survives write/query cycle", ctx do
          lp = ~s(contract_rt,type=string label="hello world")

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_rt WHERE type = 'string' LIMIT 1",
              database: ctx.database
            )

          assert rows != []
          assert hd(rows)["label"] == "hello world"
        end

        test "boolean field survives write/query cycle", ctx do
          lp = "contract_rt,type=bool active=true"

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_rt WHERE type = 'bool' LIMIT 1",
              database: ctx.database
            )

          assert rows != []
          assert hd(rows)["active"] == true
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
            unquote(client).write(
              ctx.conn,
              "contract_stream value=#{i}i #{i * 1_000_000}",
              database: ctx.database
            )
          end)

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          stream =
            unquote(client).query_sql_stream(
              ctx.conn,
              "SELECT * FROM contract_stream",
              database: ctx.database
            )

          rows = Enum.to_list(stream)
          assert rows != []
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
        test "DELETE FROM is not supported on v3 Core", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_del value=1i",
            database: ctx.database
          )

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          assert {:error, _reason} =
                   unquote(client).execute_sql(
                     ctx.conn,
                     "DELETE FROM contract_del",
                     database: ctx.database
                   )
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

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          assert {:ok, result} =
                   unquote(client).execute_sql(
                     ctx.conn,
                     "DELETE FROM contract_del",
                     database: ctx.database
                   )

          assert is_map(result)
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

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

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

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

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
        test "create_bucket returns :ok", ctx do
          assert :ok ==
                   unquote(client).create_bucket(
                     ctx.conn,
                     "contract_bucket",
                     []
                   )
        end

        test "list_buckets returns a list of maps", ctx do
          :ok =
            unquote(client).create_bucket(
              ctx.conn,
              "contract_list_bkt",
              []
            )

          {:ok, buckets} = unquote(client).list_buckets(ctx.conn)
          assert is_list(buckets)
          names = Enum.map(buckets, & &1["name"])
          assert "contract_list_bkt" in names
        end

        test "delete_bucket removes a bucket", ctx do
          :ok =
            unquote(client).create_bucket(
              ctx.conn,
              "contract_del_bkt",
              []
            )

          assert :ok ==
                   unquote(client).delete_bucket(
                     ctx.conn,
                     "contract_del_bkt"
                   )
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
        test "returns {:ok, rows} for a flux query", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_flux value=42.0",
            database: ctx.database
          )

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          flux = """
          from(bucket: "#{ctx.database}")
            |> range(start: -1h)
            |> filter(fn: (r) => r._measurement == "contract_flux")
          """

          {:ok, rows} = unquote(client).query_flux(ctx.conn, flux)
          assert is_list(rows)
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
          # Write points with known timestamps for deterministic aggregation
          base_ts = 1_700_000_000_000_000_000

          Enum.each(0..5, fn i ->
            ts = base_ts + i * 60_000_000_000
            val = (i + 1) * 10

            unquote(client).write(
              ctx.conn,
              "contract_agg value=#{val}i #{ts}",
              database: ctx.database
            )
          end)

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

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

          assert rows != []
          assert is_number(hd(rows)["avg_val"])
          assert is_binary(hd(rows)["time"])
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

          assert rows != []
          # 10+20+30+40+50+60 = 210
          totals = Enum.map(rows, & &1["total"])
          assert Enum.sum(totals) == 210
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

          assert rows != []
          counts = Enum.map(rows, & &1["cnt"])
          assert Enum.sum(counts) == 6
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

          assert rows != []
          all_mins = Enum.map(rows, & &1["min_val"])
          all_maxs = Enum.map(rows, & &1["max_val"])
          assert Enum.min(all_mins) == 10
          assert Enum.max(all_maxs) == 60
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
            "contract_params,host=alpha value=1i\ncontract_params,host=beta value=2i",
            database: ctx.database
          )

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_params WHERE host = $host",
              database: ctx.database,
              params: %{host: "alpha"}
            )

          assert length(rows) == 1
          assert hd(rows)["host"] == "alpha"
          assert hd(rows)["value"] == 1
        end

        test "filters by integer parameter", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_params_int value=100i 1000000000\ncontract_params_int value=200i 2000000000",
            database: ctx.database
          )

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_params_int WHERE value = $val",
              database: ctx.database,
              params: %{val: 100}
            )

          assert length(rows) == 1
          assert hd(rows)["value"] == 100
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

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_prec_s",
              database: ctx.database
            )

          assert length(rows) == 1
          # Time should be an ISO 8601 string matching the epoch second
          assert is_binary(hd(rows)["time"])
          assert String.contains?(hd(rows)["time"], "2023-11-14")
        end

        test "millisecond precision writes correctly", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_prec_ms value=1i 1700000000000",
            database: ctx.database,
            precision: :millisecond
          )

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_prec_ms",
              database: ctx.database
            )

          assert length(rows) == 1
          assert String.contains?(hd(rows)["time"], "2023-11-14")
        end

        test "microsecond precision writes correctly", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_prec_us value=1i 1700000000000000",
            database: ctx.database,
            precision: :microsecond
          )

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_prec_us",
              database: ctx.database
            )

          assert length(rows) == 1
          assert String.contains?(hd(rows)["time"], "2023-11-14")
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Ordered aggregates: FIRST/LAST (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp ordered_agg_tests(client) do
    quote do
      describe "query_sql/3 — FIRST/LAST aggregate contract" do
        setup ctx do
          base_ts = 1_700_000_000_000_000_000

          Enum.each([{10, 100}, {20, 200}, {30, 300}], fn {val, ts_offset} ->
            ts = base_ts + ts_offset * 1_000_000_000

            unquote(client).write(
              ctx.conn,
              "contract_fl value=#{val}i #{ts}",
              database: ctx.database
            )
          end)

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          :ok
        end

        test "FIRST returns the earliest value by time", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '1 hour', time) AS time,
            FIRST(value, time) AS first_val
          FROM contract_fl
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          """

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              sql,
              database: ctx.database
            )

          assert rows != []
          assert hd(rows)["first_val"] == 10
        end

        test "LAST returns the latest value by time", ctx do
          sql = """
          SELECT
            DATE_BIN(INTERVAL '1 hour', time) AS time,
            LAST(value, time) AS last_val
          FROM contract_fl
          GROUP BY DATE_BIN(INTERVAL '1 hour', time)
          """

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              sql,
              database: ctx.database
            )

          assert rows != []
          assert hd(rows)["last_val"] == 30
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
        test "SELECT DISTINCT returns unique values", ctx do
          unquote(client).write(
            ctx.conn,
            "contract_dist,host=a value=1i\ncontract_dist,host=b value=2i\ncontract_dist,host=a value=3i",
            database: ctx.database
          )

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT DISTINCT host FROM contract_dist",
              database: ctx.database
            )

          values = Enum.map(rows, & &1["host"])
          assert "a" in values
          assert "b" in values
          assert length(values) == 2
        end
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

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_gz",
              database: ctx.database
            )

          assert rows != []
          assert hd(rows)["value"] == 42
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

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              ~s(SELECT * FROM "my measurement"),
              database: ctx.database
            )

          assert rows != []
          assert hd(rows)["value"] == 1
        end

        test "tag with special characters round-trips", ctx do
          # Escaped comma in tag value
          lp = "contract_esc,region=us\\,east value=1i 1700000000000000000"

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_esc",
              database: ctx.database
            )

          assert rows != []

          assert hd(rows)["region"] == "us\\,east" or
                   hd(rows)["region"] == "us,east"
        end

        test "string field with escaped quotes round-trips", ctx do
          lp = ~s(contract_esc_str label="say \\"hi\\"" 1700000000000000000)

          {:ok, :written} =
            unquote(client).write(ctx.conn, lp, database: ctx.database)

          if ctx[:query_delay] && ctx.query_delay > 0,
            do: Process.sleep(ctx.query_delay)

          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM contract_esc_str",
              database: ctx.database
            )

          assert rows != []
          assert hd(rows)["label"] == ~s(say "hi")
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Error response shapes (v3_core, v3_enterprise)
  # ---------------------------------------------------------------------------

  defp error_shape_tests(client) do
    quote do
      describe "error response shapes — contract" do
        test "query on non-existent table returns {:error, _} with detail",
             ctx do
          result =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM totally_nonexistent_table_xyz",
              database: ctx.database
            )

          assert {:error, reason} = result
          # Error must provide some diagnostic information
          assert reason != nil
        end

        test "malformed line protocol returns {:error, _} with status info",
             ctx do
          result =
            unquote(client).write(
              ctx.conn,
              "this is not line protocol at all!!",
              database: ctx.database
            )

          assert {:error, reason} = result
          # Must be a map with status (HTTP) or a descriptive term
          assert is_map(reason) or is_tuple(reason) or is_atom(reason)
        end

        test "delete_database for non-existent DB returns {:error, _}",
             ctx do
          result =
            unquote(client).delete_database(
              ctx.conn,
              "contract_db_that_never_existed_xyz"
            )

          assert {:error, reason} = result
          assert reason != nil
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Token admin (v3_enterprise)
  # ---------------------------------------------------------------------------

  defp token_tests(client) do
    quote do
      describe "token admin — contract" do
        test "create_token returns {:ok, map} with string keys", ctx do
          {:ok, token} =
            unquote(client).create_token(
              ctx.conn,
              "contract token",
              []
            )

          assert is_map(token)
          assert is_binary(token["id"])
          assert token["description"] == "contract token"
        end

        test "delete_token returns :ok", ctx do
          {:ok, token} =
            unquote(client).create_token(ctx.conn, "disposable", [])

          assert :ok ==
                   unquote(client).delete_token(ctx.conn, token["id"])
        end
      end
    end
  end
end
