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
    write_tests = write_tests(client)

    sql_tests = if v3_sql, do: sql_tests(client), else: nil
    roundtrip_tests = if v3_sql, do: roundtrip_tests(client), else: nil
    stream_tests = if v3_sql, do: stream_tests(client), else: nil
    execute_tests = if v3_sql, do: execute_tests(client), else: nil
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

  defp write_tests(client) do
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

        test "returns {:error, _} for an unknown database", ctx do
          lp = "cpu value=1.0"

          assert {:error, _reason} =
                   unquote(client).write(
                     ctx.conn,
                     lp,
                     database: "ghost_db_contract"
                   )
        end

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
          assert :ok ==
                   unquote(client).create_database(
                     ctx.conn,
                     "contract_new_db",
                     []
                   )
        end

        test "is idempotent — creating a duplicate returns :ok", ctx do
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
        test "returns empty list when no rows match", ctx do
          {:ok, rows} =
            unquote(client).query_sql(
              ctx.conn,
              "SELECT * FROM empty_measurement_contract",
              database: ctx.database
            )

          assert rows == []
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

  defp execute_tests(client) do
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

          names = Enum.map(dbs, & &1["name"])
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
