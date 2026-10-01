defmodule InfluxElixir.Client.LocalTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  # Client.Local's refusal of a `time` comparand the engine rejects; the
  # comparand as written follows it.
  @time_comparand_rejected "Client.Local: InfluxDB rejects this `time` comparand " <>
                             "(a Timestamp compares only with an ISO-8601 string or now() " <>
                             "+/- INTERVAL 'N unit', never a bare integer): "

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  # Host tags of the rows a query returns, in order.
  defp hosts(conn, db, sql) do
    {:ok, rows} = Local.query_sql(conn, sql, database: db)
    Enum.map(rows, & &1["host"])
  end

  # Level tags of the rows a query returns, in order.
  defp levels(conn, db, sql) do
    {:ok, rows} = Local.query_sql(conn, sql, database: db)
    Enum.map(rows, & &1["level"])
  end

  defp v2_flux(measurement) do
    ~s'from(bucket: "metrics") |> range(start: 0) |> filter(fn: (r) => r._measurement == "#{measurement}")'
  end

  # {line_number, error_message} pairs from a partial-write response body.
  defp partial_errors(body) do
    %{"error" => "partial write of line protocol occurred", "data" => data} = Jason.decode!(body)
    Enum.map(data, &{&1["line_number"], &1["error_message"]})
  end

  # {line_number, error_message, original_line} of an `accept_partial: false`
  # rejection body.
  defp atomic_error(body) do
    %{"error" => "line protocol parsing error", "data" => data} = Jason.decode!(body)
    {data["line_number"], data["error_message"], data["original_line"]}
  end

  # The rows a SQL query returns.
  defp sql_rows(conn, db, sql) do
    {:ok, rows} = Local.query_sql(conn, sql, database: db)
    rows
  end

  # The value of `key` in each row a query returns, in order.
  defp column_values(conn, db, sql, key) do
    conn |> sql_rows(db, sql) |> Enum.map(& &1[key])
  end

  # The tickers a WHERE clause over `holdings` selects, in time order.
  defp holding_tickers(conn, db, where) do
    column_values(conn, db, "SELECT * FROM holdings WHERE #{where} ORDER BY time", "ticker")
  end

  # The sorted {host, usage} pairs a parameterised query selects.
  defp param_rows(conn, db, sql, params) do
    {:ok, rows} = Local.query_sql(conn, sql, params: params, database: db)
    rows |> Enum.map(&{&1["host"], &1["usage"]}) |> Enum.sort()
  end

  # The start of the `hour`-th hour since the epoch.
  defp hour_start(hour), do: DateTime.from_unix!(hour * 3_600_000_000, :microsecond)

  # InfluxQL against the "iq" database of the InfluxQL fixture.
  defp iq_query(conn, statement), do: Local.query_influxql(conn, statement, database: "iq")

  # The instant `us` microseconds past 1_700_000_000 s.
  defp iq_time(us), do: DateTime.from_unix!(1_700_000_000_000_000 + us, :microsecond)

  # Flux over bucket "b" of the Flux pipeline fixture, with `tail` appended.
  defp flux_b(conn, tail) do
    Local.query_flux(conn, ~s|from(bucket: "b") \|> range(start: 0, stop: 1800000000)| <> tail)
  end

  # {table, host, _value} of each Flux row.
  defp flux_values(rows), do: Enum.map(rows, &{&1["table"], &1["host"], &1["_value"]})

  # SQL against the "g" database of the GROUP BY / ORDER BY fixture.
  defp g_query(conn, sql), do: Local.query_sql(conn, sql, database: "g")

  # The rows of a SQL query against the "nl" database of the null-semantics fixture.
  defp nl_rows(conn, sql) do
    {:ok, rows} = Local.query_sql(conn, sql, database: "nl")
    rows
  end

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  describe "supports?/2" do
    test "answers per profile, matching the capability table in the moduledoc" do
      {:ok, core} = Local.start(profile: :v3_core)
      {:ok, enterprise} = Local.start(profile: :v3_enterprise)
      {:ok, v2} = Local.start(profile: :v2)
      on_exit(fn -> Enum.each([core, enterprise, v2], &Local.stop/1) end)

      assert Local.supports?(core, :query_sql)
      refute Local.supports?(core, :query_flux)
      assert Local.supports?(core, :create_token)

      assert Local.supports?(enterprise, :create_token)
      refute Local.supports?(enterprise, :create_bucket)

      assert Local.supports?(v2, :query_flux)
      assert Local.supports?(v2, :create_bucket)
      refute Local.supports?(v2, :query_sql)

      # An operation no profile knows is simply unsupported.
      refute Local.supports?(core, :not_an_operation)
    end
  end

  describe "start/1 and stop/1" do
    test "a stopped connection can no longer be used" do
      {:ok, conn} = Local.start(databases: ["gone"])
      assert {:ok, :written} = Local.write(conn, "m v=1i 1")
      assert :ok = Local.stop(conn)

      assert_raise ArgumentError, fn ->
        Local.query_sql(conn, "SELECT v FROM m", database: "gone")
      end
    end

    test "pre-creates databases from options, listed with the engine's _internal" do
      {:ok, conn} = Local.start(databases: ["db2", "db1"])
      assert {:ok, dbs} = Local.list_databases(conn)
      assert Enum.map(dbs, & &1["name"]) == ["_internal", "db1", "db2"]
      Local.stop(conn)
    end

    test "stop is safe to call twice" do
      {:ok, conn} = Local.start()
      assert :ok = Local.stop(conn)
      assert :ok = Local.stop(conn)
    end

    test "each instance is isolated" do
      {:ok, conn_a} = Local.start(databases: ["only_a"])
      {:ok, conn_b} = Local.start(databases: ["only_b"])

      {:ok, dbs_a} = Local.list_databases(conn_a)
      {:ok, dbs_b} = Local.list_databases(conn_b)

      names_a = Enum.map(dbs_a, & &1["name"])
      names_b = Enum.map(dbs_b, & &1["name"])

      assert "only_a" in names_a
      refute "only_b" in names_a
      assert "only_b" in names_b
      refute "only_a" in names_b

      Local.stop(conn_a)
      Local.stop(conn_b)
    end

    test ":database is the connection-level default and is pre-created" do
      {:ok, conn} = Local.start(database: "metrics")
      assert {:ok, :written} = Local.write(conn, "m v=1i")
      assert {:ok, [%{"v" => 1}]} = Local.query_sql(conn, "SELECT v FROM m", database: "metrics")
      assert {:ok, [_internal, %{"name" => "metrics"}]} = Local.list_databases(conn)
      Local.stop(conn)
    end

    test "without :database the first of :databases is the default, as over HTTP" do
      # Client.HTTP.init_connection/1 does the same; Local used to write to
      # a "default" database instead, so the same config diverged.
      {:ok, conn} = Local.start(databases: ["x", "y"])
      assert {:ok, :written} = Local.write(conn, "m v=1i")
      assert {:ok, [%{"v" => 1}]} = Local.query_sql(conn, "SELECT v FROM m", database: "x")
      Local.stop(conn)
    end

    test "pre-creates both :database and :databases when both are given" do
      {:ok, conn} = Local.start(database: "primary", databases: ["a", "b"])
      assert {:ok, dbs} = Local.list_databases(conn)
      assert Enum.map(dbs, & &1["name"]) == ["_internal", "a", "b", "primary"]
      assert {:ok, :written} = Local.write(conn, "m v=1i")
      assert {:ok, [_row]} = Local.query_sql(conn, "SELECT v FROM m", database: "primary")
      Local.stop(conn)
    end

    test "refuses a database the engine would refuse, with the engine's message" do
      assert_raise ArgumentError, ~r/a\.b: .*invalid character in database or rp name/, fn ->
        Local.start(databases: ["a.b"])
      end

      assert_raise ArgumentError, ~r/exceed limit of 5 databases/, fn ->
        Local.start(databases: Enum.map(1..6, &"db#{&1}"))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Connection-level :database resolution
  #
  # Regression coverage for issue #2: Local previously ignored connection
  # config's singular :database key. Both impls must resolve the same database
  # for the same config, so a typo (e.g. :default_database) cannot silently
  # pass tests against Local while breaking against HTTP.
  # ---------------------------------------------------------------------------

  describe "init_connection/1 — :database resolution parity" do
    test "init_connection passes :database through to conn-level default" do
      {:ok, conn} = Local.init_connection(database: "metrics")
      assert conn.database == "metrics"
      Local.stop(conn)
    end

    test "write uses connection-level :database when opts omits it" do
      {:ok, conn} = Local.init_connection(database: "primary")
      assert {:ok, :written} = Local.write(conn, "cpu value=1.0")

      {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM cpu")
      assert row["value"] == 1.0

      # The write created no other database.
      assert {:ok, [%{"name" => "_internal"}, %{"name" => "primary"}]} =
               Local.list_databases(conn)

      Local.stop(conn)
    end

    test "opts :database still wins over connection-level default" do
      {:ok, conn} = Local.init_connection(database: "primary", databases: ["other"])

      assert {:ok, :written} =
               Local.write(conn, "cpu value=1.0", database: "other")

      assert {:error,
              %{status: 400, body: "Error during planning: table 'public.iox.cpu' not found"}} =
               Local.query_sql(conn, "SELECT * FROM cpu")

      assert {:ok, [_row]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: "other")

      Local.stop(conn)
    end

    test "with no database anywhere, each operation answers as Client.HTTP does" do
      # Local used to fall back to a "default" database the server does not
      # have: code that forgot `database:` passed against the double and
      # failed against InfluxDB.
      {:ok, conn} = Local.init_connection([])
      on_exit(fn -> Local.stop(conn) end)

      assert {:error, :no_database_specified} = Local.write(conn, "cpu value=1.0")
      assert {:error, :no_database_specified} = Local.query_sql(conn, "SELECT 1")
      assert {:error, :no_database_specified} = Local.execute_sql(conn, "SELECT 1")

      error =
        assert_raise InfluxElixir.StreamError, fn ->
          conn |> Local.query_sql_stream("SELECT 1") |> Enum.to_list()
        end

      assert error.kind == :no_database

      # HTTP sends the InfluxQL without `db`; this is the engine's answer.
      assert {:error,
              %{
                status: 400,
                body:
                  "must specify a 'db' parameter, or provide the database in the InfluxQL query"
              }} =
               Local.query_influxql(conn, "SHOW MEASUREMENTS")

      assert {:ok, [%{"iox::database" => "_internal"}]} =
               Local.query_influxql(conn, "SHOW DATABASES")
    end

    test "init_connection ignores unknown keys without auto-pre-creating them" do
      # A typo like :default_database must not silently become a database.
      {:ok, conn} = Local.init_connection(default_database: "typo_db")
      assert {:ok, [%{"name" => "_internal"}]} = Local.list_databases(conn)
      assert {:error, :no_database_specified} = Local.write(conn, "m v=1i")
      Local.stop(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Write — basic
  # ---------------------------------------------------------------------------

  describe "write/3 — basic" do
    test "v3_enterprise profile auto-creates database on write" do
      {:ok, ent_conn} =
        Local.start(databases: ["ent_db"], profile: :v3_enterprise)

      on_exit(fn -> Local.stop(ent_conn) end)

      assert {:ok, :written} =
               Local.write(ent_conn, "cpu value=1.0", database: "auto_db")

      assert {:ok, dbs} = Local.list_databases(ent_conn)
      assert Enum.map(dbs, & &1["name"]) == ["_internal", "auto_db", "ent_db"]
    end
  end

  # ---------------------------------------------------------------------------
  # Write — line protocol round-trips
  # ---------------------------------------------------------------------------

  describe "write/3 — line protocol round-trip" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "rt")
      {:ok, db: "rt"}
    end

    test "boolean false field", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m active=false", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["active"] == false
    end

    test "multiple tags are preserved", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m,host=s1,region=us-east value=1i", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["host"] == "s1"
      assert row["region"] == "us-east"
    end

    test "multiple fields are preserved", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m a=1i,b=2.0,c=\"hi\"", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["a"] == 1
      assert row["b"] == 2.0
      assert row["c"] == "hi"
    end

    test "timestamp is returned as a microsecond-precision DateTime", %{conn: conn, db: db} do
      ts = 1_630_424_257_123_456_789
      {:ok, :written} = Local.write(conn, "m value=1.0 #{ts}", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["time"] == ~U[2021-08-31 15:37:37.123456Z]
    end

    test "multi-line write stores multiple points", %{conn: conn, db: db} do
      lp = "m value=1.0 1\nm value=2.0 2\nm value=3.0 3"
      {:ok, :written} = Local.write(conn, lp, database: db)
      assert {:ok, rows} = Local.query_sql(conn, "SELECT * FROM m ORDER BY time", database: db)
      assert Enum.map(rows, & &1["value"]) == [1.0, 2.0, 3.0]
    end
  end

  # ---------------------------------------------------------------------------
  # Write — timestamp precision
  # ---------------------------------------------------------------------------

  describe "write/3 — timestamp precision" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "prec")
      {:ok, db: "prec"}
    end

    test "the engine's spellings are accepted as atoms or strings; the unit is the same",
         %{conn: conn, db: db} do
      # Verified against InfluxDB 3: every spelling below is a 204 there.
      for {{precision, ts}, i} <-
            Enum.with_index([
              {:ns, 1_000_000_000},
              {"n", 1_000_000_000},
              {"nanosecond", 1_000_000_000},
              {:us, 1_000_000},
              {:u, 1_000_000},
              {"microsecond", 1_000_000},
              {:ms, 1_000},
              {"millisecond", 1_000},
              {:s, 1},
              {"second", 1}
            ]) do
        {:ok, :written} =
          Local.write(conn, "p,s=#{i} value=1i #{ts}", database: db, precision: precision)
      end

      assert {:ok, [%{"n" => 10}]} =
               Local.query_sql(
                 conn,
                 "SELECT COUNT(value) AS n FROM p WHERE time = '1970-01-01T00:00:01'",
                 database: db
               )
    end

    test ":auto guesses the unit from the magnitude at the engine's thresholds",
         %{conn: conn, db: db} do
      # Verified against InfluxDB 3: |ts| < 5e9 is seconds, < 5e12 milliseconds,
      # < 5e15 microseconds, else nanoseconds.
      for {ts, expected} <- [
            {4_999_999_999, ~U[2128-06-11 08:53:19.000000Z]},
            {5_000_000_000, ~U[1970-02-27 20:53:20.000000Z]},
            {4_999_999_999_999, ~U[2128-06-11 08:53:19.999000Z]},
            {5_000_000_000_000, ~U[1970-02-27 20:53:20.000000Z]},
            {4_999_999_999_999_999, ~U[2128-06-11 08:53:19.999999Z]},
            {5_000_000_000_000_000, ~U[1970-02-27 20:53:20.000000Z]},
            {-9_999_999_999, ~U[1969-09-07 06:13:20.001000Z]},
            {1_700_000_000, ~U[2023-11-14 22:13:20.000000Z]}
          ] do
        m = "auto_#{System.unique_integer([:positive])}"
        {:ok, :written} = Local.write(conn, "#{m} value=1i #{ts}", database: db, precision: :auto)

        assert {:ok, [%{"time" => ^expected}]} =
                 Local.query_sql(conn, "SELECT time FROM #{m}", database: db),
               inspect(ts)
      end
    end

    test "an unknown precision is the engine's 400, case-sensitively", %{conn: conn, db: db} do
      for precision <- [:bogus, "NS", "nanoseconds"] do
        assert {:error, %{status: 400, body: body}} =
                 Local.write(conn, "q value=1i 1", database: db, precision: precision)

        assert body ==
                 "serde error: unknown variant `#{precision}`, expected one of `auto`, `s`, " <>
                   "`second`, `millisecond`, `ms`, `microsecond`, `u`, `us`, `n`, `nanosecond`, `ns`"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — SELECT
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — SELECT" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "qdb")

      lp = """
      cpu,host=web01,region=us-east usage=10i,idle=90i 1000
      cpu,host=web02,region=us-west usage=20i,idle=80i 2000
      cpu,host=web01,region=us-east usage=30i,idle=70i 3000
      """

      {:ok, :written} =
        Local.write(conn, String.trim(lp), database: "qdb", precision: :nanosecond)

      {:ok, db: "qdb"}
    end

    test "returns all rows for bare SELECT *", %{conn: conn, db: db} do
      assert {:ok, rows} = Local.query_sql(conn, "SELECT * FROM cpu ORDER BY time", database: db)

      assert Enum.map(rows, &{&1["host"], &1["region"], &1["usage"], &1["idle"]}) == [
               {"web01", "us-east", 10, 90},
               {"web02", "us-west", 20, 80},
               {"web01", "us-east", 30, 70}
             ]
    end

    test "WHERE tag = 'value' filters rows", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM cpu WHERE host = 'web01' ORDER BY time",
                 database: db
               )

      assert Enum.map(rows, &{&1["host"], &1["usage"]}) == [{"web01", 10}, {"web01", 30}]
    end

    test "WHERE field comparisons filter rows", %{conn: conn, db: db} do
      usages = fn operator, n ->
        {:ok, rows} =
          Local.query_sql(
            conn,
            "SELECT usage FROM cpu WHERE usage #{operator} #{n} ORDER BY time",
            database: db
          )

        Enum.map(rows, & &1["usage"])
      end

      assert usages.(">", 15) == [20, 30]
      assert usages.("<", 15) == [10]
      assert usages.(">=", 20) == [20, 30]
      assert usages.("<=", 20) == [10, 20]
    end

    test "ORDER BY time ASC sorts points written out of order", %{conn: conn, db: db} do
      {:ok, :written} =
        Local.write(conn, "ooo v=3i 3000\nooo v=1i 1000\nooo v=2i 2000", database: db)

      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM ooo ORDER BY time ASC", database: db)

      assert Enum.map(rows, &{&1["time"], &1["v"]}) == [
               {~U[1970-01-01 00:00:00.000001Z], 1},
               {~U[1970-01-01 00:00:00.000002Z], 2},
               {~U[1970-01-01 00:00:00.000003Z], 3}
             ]
    end

    test "ORDER BY time DESC", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM cpu ORDER BY time DESC", database: db)

      assert Enum.map(rows, &{&1["time"], &1["usage"]}) == [
               {~U[1970-01-01 00:00:00.000003Z], 30},
               {~U[1970-01-01 00:00:00.000002Z], 20},
               {~U[1970-01-01 00:00:00.000001Z], 10}
             ]
    end

    test "LIMIT reduces number of results", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT usage FROM cpu ORDER BY time LIMIT 2", database: db)

      assert rows == [%{"usage" => 10}, %{"usage" => 20}]
    end

    test "combined WHERE + ORDER BY + LIMIT", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE region = 'us-east' ORDER BY time DESC LIMIT 1"
      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["region"] == "us-east"
      assert row["time"] == ~U[1970-01-01 00:00:00.000003Z]
    end

    test "each row has fields, tags, and time but no _measurement key",
         %{conn: conn, db: db} do
      assert {:ok, [row | _rest]} =
               Local.query_sql(conn, "SELECT * FROM cpu ORDER BY time", database: db)

      assert row == %{
               "time" => ~U[1970-01-01 00:00:00.000001Z],
               "host" => "web01",
               "region" => "us-east",
               "usage" => 10,
               "idle" => 90
             }
    end

    test "a statement that is not a query gets execute_sql's answer", %{conn: conn, db: db} do
      assert {:error,
              %{status: 400, body: "Error during planning: DML not supported: Insert Into"}} =
               Local.query_sql(conn, "INSERT INTO cpu VALUES (1)", database: db)
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — multi-column projection (issue #3)
  #
  # Selecting specific columns instead of `*` must work for production-realistic
  # SQL: SELECT a, b, time FROM x WHERE ... ORDER BY time DESC LIMIT 1.
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — multi-column projection" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "proj_db")

      lp = """
      account_balances,account_id=abc net_value=100.0,total_balance=120.0 1000
      account_balances,account_id=abc net_value=110.0,total_balance=130.0 2000
      account_balances,account_id=xyz net_value=50.0,total_balance=55.0 3000
      """

      {:ok, :written} =
        Local.write(conn, String.trim(lp), database: "proj_db", precision: :nanosecond)

      {:ok, db: "proj_db"}
    end

    test "selects specific columns by name", %{conn: conn, db: db} do
      sql = "SELECT net_value, total_balance, time FROM account_balances ORDER BY time"

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows == [
               %{
                 "net_value" => 100.0,
                 "total_balance" => 120.0,
                 "time" => ~U[1970-01-01 00:00:00.000001Z]
               },
               %{
                 "net_value" => 110.0,
                 "total_balance" => 130.0,
                 "time" => ~U[1970-01-01 00:00:00.000002Z]
               },
               %{
                 "net_value" => 50.0,
                 "total_balance" => 55.0,
                 "time" => ~U[1970-01-01 00:00:00.000003Z]
               }
             ]
    end

    test "respects WHERE, ORDER BY, LIMIT (issue #3 reproduction)",
         %{conn: conn, db: db} do
      sql = """
      SELECT net_value, total_balance, time
      FROM account_balances
      WHERE account_id = 'abc'
      ORDER BY time DESC
      LIMIT 1
      """

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)

      assert row == %{
               "net_value" => 110.0,
               "total_balance" => 130.0,
               "time" => ~U[1970-01-01 00:00:00.000002Z]
             }
    end

    test "supports AS aliases on projection columns", %{conn: conn, db: db} do
      sql =
        "SELECT net_value AS nv, total_balance AS tb FROM account_balances WHERE account_id = 'xyz'"

      assert {:ok, [%{"nv" => 50.0, "tb" => 55.0} = row]} =
               Local.query_sql(conn, sql, database: db)

      assert Map.keys(row) == ["nv", "tb"]
    end

    test "selecting a tag column returns the tag value",
         %{conn: conn, db: db} do
      sql = "SELECT account_id, net_value FROM account_balances WHERE account_id = 'xyz'"

      assert {:ok, [%{"account_id" => "xyz", "net_value" => 50.0} = row]} =
               Local.query_sql(conn, sql, database: db)

      assert Map.keys(row) == ["account_id", "net_value"]
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — parameterised queries
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — parameterised queries" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "pdb")

      {:ok, :written} =
        Local.write(
          conn,
          "cpu,host=web01 usage=10i\ncpu,host=web02 usage=20i",
          database: "pdb"
        )

      {:ok, db: "pdb"}
    end

    test "string param substitution", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE host = $host"
      assert param_rows(conn, db, sql, %{"$host" => "web01"}) == [{"web01", 10}]
    end

    test "integer param substitution", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE usage > $min"
      assert param_rows(conn, db, sql, %{"$min" => 15}) == [{"web02", 20}]
    end

    test "atom key params without $ prefix", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE host = $host"
      assert param_rows(conn, db, sql, %{host: "web01"}) == [{"web01", 10}]
    end

    test "string key params without $ prefix", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE host = $host"
      assert param_rows(conn, db, sql, %{"host" => "web01"}) == [{"web01", 10}]
    end

    test "atom key params with multiple conditions", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE host = $host AND usage > $min"
      assert param_rows(conn, db, sql, %{host: "web02", min: 15}) == [{"web02", 20}]
    end

    test "a placeholder that prefixes another is substituted whole",
         %{conn: conn, db: db} do
      # Sequential replacement rewrote `$h` inside `$hmin`, producing
      # `'web02'min` and a parse failure.
      sql = "SELECT * FROM cpu WHERE host = $h AND usage > $hmin"
      assert param_rows(conn, db, sql, %{h: "web02", hmin: 15}) == [{"web02", 20}]
    end

    test "an unbound placeholder is the engine's planning error", %{conn: conn, db: db} do
      # InfluxDB 3: "No value found for placeholder with name $host". Matching
      # nothing would hide a missing binding.
      sql = "SELECT * FROM cpu WHERE host = $host AND usage > $min"
      params = %{min: 15}

      assert {:error,
              %{
                status: 400,
                body: "Error during planning: No value found for placeholder with name $host"
              }} = Local.query_sql(conn, sql, params: params, database: db)
    end

    test "a substituted value is never re-substituted", %{conn: conn, db: db} do
      # A string value containing another placeholder's name must stay literal:
      # were `$min` substituted again, the query would select host "15".
      {:ok, :written} =
        Local.write(conn, "sub,host=$min usage=20i 1\nsub,host=15 usage=30i 2", database: db)

      sql = "SELECT * FROM sub WHERE host = $host AND usage > $min"
      params = %{host: "$min", min: 15}

      assert param_rows(conn, db, sql, params) == [{"$min", 20}]
    end
  end

  # ---------------------------------------------------------------------------
  # Query formats and query_sql_stream/3
  # ---------------------------------------------------------------------------

  describe "query formats" do
    test "format: :parquet is refused by name, over SQL and InfluxQL", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "m v=1i", database: "test_db")

      for query <- [&Local.query_sql/3, &Local.query_influxql/3] do
        assert {:error,
                %{
                  status: 400,
                  body:
                    "Client.Local: format: :parquet is not supported by the test double; " <>
                      "cover Parquet in the integration tier"
                }} = query.(conn, "SELECT v FROM m", database: "test_db", format: :parquet)
      end
    end
  end

  describe "query_sql_stream/3" do
    test "stream yields the rows query_sql returns", %{conn: conn} do
      :ok = Local.create_database(conn, "sdb")

      {:ok, :written} =
        Local.write(conn, "m value=1i 1000\nm value=2i 2000", database: "sdb")

      sql = "SELECT * FROM m ORDER BY time"
      {:ok, direct} = Local.query_sql(conn, sql, database: "sdb")
      stream_rows = conn |> Local.query_sql_stream(sql, database: "sdb") |> Enum.to_list()

      expected = [
        %{"time" => ~U[1970-01-01 00:00:00.000001Z], "value" => 1},
        %{"time" => ~U[1970-01-01 00:00:00.000002Z], "value" => 2}
      ]

      assert direct == expected
      assert stream_rows == expected
    end

    # Parity with Client.HTTP (issue #11): a query error must raise
    # InfluxElixir.StreamError on enumeration, never surface as an empty stream.
    test "raises StreamError on a query error instead of yielding []",
         %{conn: conn} do
      {:ok, :written} = Local.write(conn, "cpu v=1i 1", database: "test_db")

      # The table exists, so the error is the unknown column, not a missing table.
      stream =
        Local.query_sql_stream(conn, "SELECT * FROM cpu WHERE nosuch = 1", database: "test_db")

      error = assert_raise InfluxElixir.StreamError, fn -> Enum.to_list(stream) end

      assert %InfluxElixir.StreamError{
               kind: :http_status,
               status: 500,
               body: "Schema error: No field named nosuch. Valid fields are time, v.",
               message:
                 "streaming query failed with HTTP status 500: " <>
                   "Schema error: No field named nosuch. Valid fields are time, v."
             } = error
    end

    test "construction is lazy — the raise is deferred to enumeration",
         %{conn: conn} do
      {:ok, :written} = Local.write(conn, "cpu v=1i 1", database: "test_db")

      # Building the stream must not raise; only consuming it does.
      stream =
        Local.query_sql_stream(conn, "SELECT * FROM cpu WHERE nosuch = 1", database: "test_db")

      assert Enumerable.impl_for(stream)

      assert_raise InfluxElixir.StreamError,
                   "streaming query failed with HTTP status 500: " <>
                     "Schema error: No field named nosuch. Valid fields are time, v.",
                   fn -> Enum.to_list(stream) end
    end

    test "raises StreamError with :unsupported when the profile lacks streaming" do
      {:ok, v2_conn} = Local.start(profile: :v2, databases: ["v2_db"])
      on_exit(fn -> Local.stop(v2_conn) end)

      stream = Local.query_sql_stream(v2_conn, "SELECT * FROM cpu")

      error = assert_raise InfluxElixir.StreamError, fn -> Enum.to_list(stream) end
      assert %InfluxElixir.StreamError{kind: :unsupported, reason: :unsupported_operation} = error
    end
  end

  # ---------------------------------------------------------------------------
  # execute_sql/3
  # ---------------------------------------------------------------------------

  describe "execute_sql/3" do
    # Every answer below was taken from influxdb:3-core.
    test "DML is the engine's planning error on v3_core", %{conn: conn} do
      for {sql, kind} <- [
            {"DELETE FROM cpu", "Delete"},
            {"delete from cpu where v = 1", "Delete"},
            {"INSERT INTO cpu (time, v) VALUES ('2023-11-14T22:13:20Z', 5)", "Insert Into"},
            {"UPDATE cpu SET v = 2", "Update"}
          ] do
        assert {:error, %{status: 400, body: body}} = Local.execute_sql(conn, sql)
        assert body == "Error during planning: DML not supported: " <> kind, sql
      end
    end

    test "DDL is the engine's planning error; anything else is its 405", %{conn: conn} do
      for {sql, kind} <- [
            {"CREATE TABLE foo (id INT)", "CreateMemoryTable"},
            {"CREATE VIEW vv AS SELECT * FROM cpu", "CreateView"},
            {"CREATE DATABASE x", "CreateCatalog"},
            {"DROP TABLE cpu", "DropTable"},
            {"DROP VIEW vv", "DropView"}
          ] do
        assert {:error, %{status: 400, body: body}} = Local.execute_sql(conn, sql)
        assert body == "Error during planning: DDL not supported: " <> kind, sql
      end

      for sql <- ["ALTER TABLE cpu ADD COLUMN y INT", "TRUNCATE cpu"] do
        assert {:error, %{status: 405, body: body}} = Local.execute_sql(conn, sql)
        assert body == "This feature is not implemented: Unsupported SQL statement: " <> sql
      end
    end

    test "a SELECT or WITH runs as a query", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "sel v=1i 1700000000000000000")

      assert {:ok, [%{"v" => 1}]} = Local.execute_sql(conn, "SELECT v FROM sel")

      assert {:ok, [%{"v" => 1}]} =
               Local.execute_sql(conn, "WITH w AS (SELECT v FROM sel) SELECT v FROM w")
    end
  end

  # ---------------------------------------------------------------------------
  # query_flux/3
  # ---------------------------------------------------------------------------

  describe "query_flux/3" do
    test "returns the bucket's rows tagged with their measurement" do
      {:ok, v2_conn} = Local.start(profile: :v2)
      on_exit(fn -> Local.stop(v2_conn) end)
      :ok = Local.create_bucket(v2_conn, "test")
      {:ok, :written} = Local.write(v2_conn, "cpu value=1.0", database: "test")

      flux = "from(bucket: \"test\") |> range(start: -1h)"

      assert {:ok, [%{"_measurement" => "cpu", "_field" => "value", "_value" => 1.0}]} =
               Local.query_flux(v2_conn, flux)
    end
  end

  # ---------------------------------------------------------------------------
  # Database admin — LocalClient-specific (error shape details)
  # ---------------------------------------------------------------------------

  describe "database admin — error details" do
    test "delete_database/2 returns 404 with the engine's body", %{conn: conn} do
      assert {:error, %{status: 404, body: body}} =
               Local.delete_database(conn, "not_here")

      assert body == "the requested resource was not found: not_here"
    end
  end

  # Bucket admin covered by contract tests (contract_local_v2_test.exs)

  # Token admin covered by contract tests (contract_local_v3_enterprise_test.exs)

  # Health covered by contract tests (all contract_local_*_test.exs)

  # ---------------------------------------------------------------------------
  # execute_sql/3 — DELETE support
  # ---------------------------------------------------------------------------

  describe "execute_sql/3 — DELETE (v3_core rejects)" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "del_db")

      {:ok, :written} =
        Local.write(
          conn,
          "cpu,host=web01 value=10i 1\ncpu,host=web02 value=20i 2\ncpu,host=web01 value=30i 3",
          database: "del_db"
        )

      {:ok, db: "del_db"}
    end

    test "DELETE FROM is refused on v3_core and removes nothing", %{conn: conn, db: db} do
      assert {:error, %{status: 400, body: "Error during planning: DML not supported: Delete"}} =
               Local.execute_sql(conn, "DELETE FROM cpu", database: db)

      assert {:ok, rows} = Local.query_sql(conn, "SELECT * FROM cpu ORDER BY time", database: db)

      assert Enum.map(rows, &{&1["host"], &1["value"]}) == [
               {"web01", 10},
               {"web02", 20},
               {"web01", 30}
             ]
    end
  end

  describe "execute_sql/3 — DELETE (v3_enterprise supports)" do
    setup do
      {:ok, conn} =
        Local.start(
          databases: ["del_db"],
          profile: :v3_enterprise
        )

      {:ok, :written} =
        Local.write(
          conn,
          "cpu,host=web01 value=10i 1\ncpu,host=web02 value=20i 2\ncpu,host=web01 value=30i 3",
          database: "del_db"
        )

      on_exit(fn -> Local.stop(conn) end)
      {:ok, conn: conn, db: "del_db"}
    end

    test "DELETE FROM removes every point and leaves an empty table", %{conn: conn, db: db} do
      assert {:ok, %{"rows_affected" => 3}} =
               Local.execute_sql(conn, "DELETE FROM cpu", database: db)

      # The table stays in the catalog: no rows, not "table not found".
      assert {:ok, []} = Local.query_sql(conn, "SELECT * FROM cpu", database: db)
    end

    test "DELETE follows SQL's identifier rules, as SELECT does", %{conn: conn, db: db} do
      {:ok, :written} =
        Local.write(conn, "Cpu,Host=a v=1i 1\nCpu,Host=b v=2i 2", database: db)

      # Unquoted names fold: `Cpu` and `HOST` are table cpu and its host tag.
      assert {:ok, %{"rows_affected" => 2}} =
               Local.execute_sql(conn, ~s|DELETE FROM Cpu WHERE HOST = 'web01'|, database: db)

      assert {:ok, [%{"host" => "web02"}]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: db)

      assert {:ok, %{"rows_affected" => 1}} =
               Local.execute_sql(conn, ~s|DELETE FROM "Cpu" WHERE "Host" = 'a'|, database: db)

      assert {:ok, [%{"Host" => "b"}]} =
               Local.query_sql(conn, ~s|SELECT * FROM "Cpu"|, database: db)
    end

    test "DELETE FROM with WHERE removes matching points only",
         %{conn: conn, db: db} do
      assert {:ok, %{"rows_affected" => 2}} =
               Local.execute_sql(
                 conn,
                 "DELETE FROM cpu WHERE host = 'web01'",
                 database: db
               )

      assert {:ok, [%{"host" => "web02", "value" => 20}]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: db)
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — WHERE clause edge cases
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — WHERE edge cases" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "where_db")

      {:ok, :written} =
        Local.write(
          conn,
          "m,host=alpha active=true,temp=98.6,count=10i 1000\n" <>
            "m,host=beta active=false,temp=37.2,count=20i 2000\n" <>
            "m,host=gamma active=true,temp=100.1,count=30i 3000",
          database: "where_db"
        )

      {:ok, db: "where_db"}
    end

    test "WHERE field != value", %{conn: conn, db: db} do
      assert hosts(conn, db, "SELECT * FROM m WHERE host != 'alpha' ORDER BY time") ==
               ["beta", "gamma"]
    end

    test "WHERE with boolean value", %{conn: conn, db: db} do
      assert hosts(conn, db, "SELECT * FROM m WHERE active = true ORDER BY time") ==
               ["alpha", "gamma"]
    end

    test "WHERE with float comparison", %{conn: conn, db: db} do
      assert hosts(conn, db, "SELECT * FROM m WHERE temp > 98.5 ORDER BY time") ==
               ["alpha", "gamma"]
    end

    test "WHERE compound AND conditions", %{conn: conn, db: db} do
      sql = "SELECT * FROM m WHERE active = true AND count > 15"

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["host"] == "gamma"
    end

    test "case insensitive SELECT", %{conn: conn, db: db} do
      assert hosts(conn, db, "select * from m where host = 'alpha'") == ["alpha"]
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — WHERE time conditions
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — WHERE time conditions" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "time_db")

      # Three points at known timestamps:
      # t1 = 2026-03-17T12:00:00Z = 1773748800000000000 ns
      # t2 = 2026-03-17T12:01:00Z = 1773748860000000000 ns
      # t3 = 2026-03-17T12:02:00Z = 1773748920000000000 ns
      lines =
        Enum.join(
          [
            "prices,symbol=AAPL price=150.0 1773748800000000000",
            "prices,symbol=GOOG price=2800.0 1773748860000000000",
            "prices,symbol=MSFT price=300.0 1773748920000000000"
          ],
          "\n"
        )

      {:ok, :written} = Local.write(conn, lines, database: "time_db")
      {:ok, db: "time_db"}
    end

    test "SELECT * with time >= and time <", %{conn: conn, db: db} do
      sql =
        "SELECT * FROM prices WHERE time >= '2026-03-17T12:00:00Z' " <>
          "AND time < '2026-03-17T12:02:00Z' ORDER BY time"

      assert column_values(conn, db, sql, "symbol") == ["AAPL", "GOOG"]
    end

    test "a bare integer comparand is rejected, as DataFusion rejects it", %{conn: conn, db: db} do
      # InfluxDB 3: "Cannot infer common argument type for comparison
      # operation Timestamp(ns) >= Int64". Matching nothing here would let a
      # query pass tests and 400 in production.
      assert {:error,
              %{
                status: 400,
                body:
                  "type_coercion\ncaused by\nError during planning: Cannot infer common " <>
                    "argument type for comparison operation Timestamp(ns) >= Int64"
              }} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM prices WHERE time >= 1773748800000000000",
                 database: db
               )
    end

    test "SELECT * with ISO 8601 time params", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM prices WHERE time >= $start AND time < $end ORDER BY time",
          database: db,
          params: %{
            "$start" => "2026-03-17T12:00:00Z",
            "$end" => "2026-03-17T12:02:00Z"
          }
        )

      assert Enum.map(rows, & &1["symbol"]) == ["AAPL", "GOOG"]
    end

    test "aggregate query with time WHERE", %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 minute', time) AS time,
        AVG(price) AS avg_price
      FROM "prices"
      WHERE time >= $start AND time < $end
      GROUP BY DATE_BIN(INTERVAL '1 minute', time)
      ORDER BY time ASC
      """

      {:ok, rows} =
        Local.query_sql(conn, sql,
          database: db,
          params: %{
            "$start" => "2026-03-17T12:00:00Z",
            "$end" => "2026-03-17T12:02:00Z"
          }
        )

      assert rows == [
               %{"time" => ~U[2026-03-17 12:00:00.000000Z], "avg_price" => 150.0},
               %{"time" => ~U[2026-03-17 12:01:00.000000Z], "avg_price" => 2800.0}
             ]
    end

    test "time WHERE combined with tag filter", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM prices WHERE time >= $start AND time < $end AND symbol = 'AAPL'",
          database: db,
          params: %{
            "$start" => "2026-03-17T12:00:00Z",
            "$end" => "2026-03-17T12:05:00Z"
          }
        )

      assert [%{"symbol" => "AAPL", "price" => 150.0, "time" => ~U[2026-03-17 12:00:00.000000Z]}] =
               rows
    end

    test "time WHERE excludes all points", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM prices WHERE time >= $start AND time < $end",
          database: db,
          params: %{
            "$start" => "2026-03-18T00:00:00Z",
            "$end" => "2026-03-18T01:00:00Z"
          }
        )

      assert rows == []
    end

    # Regression coverage for issue #4: bare ISO dates ("YYYY-MM-DD") must
    # be parsed as midnight UTC. Previously they returned nil from
    # to_nanoseconds and Elixir term ordering produced wrong-but-plausible
    # results in compare/3 (e.g. `5 > nil` is `true`).
    test "bare ISO date in WHERE includes points on or before midnight UTC",
         %{conn: conn, db: db} do
      # All three points are 2026-03-17. A WHERE time <= '2026-03-18'
      # accepts all three; WHERE time <= '2026-03-17' accepts none
      # (since midnight 03-17 is before all three timestamps).
      sql = "SELECT * FROM prices WHERE time <= '2026-03-18' ORDER BY time"
      assert column_values(conn, db, sql, "symbol") == ["AAPL", "GOOG", "MSFT"]

      assert {:ok, []} =
               Local.query_sql(conn, "SELECT * FROM prices WHERE time <= '2026-03-17'",
                 database: db
               )
    end

    test "bare ISO date range filters across day boundaries",
         %{conn: conn, db: db} do
      sql =
        "SELECT * FROM prices WHERE time >= '2026-03-17' AND time <= '2026-03-18' ORDER BY time"

      assert column_values(conn, db, sql, "symbol") == ["AAPL", "GOOG", "MSFT"]
    end

    test "an unparseable date string is rejected, as the engine rejects it",
         %{conn: conn, db: db} do
      # InfluxDB 3 fails the query ("Error parsing timestamp from 'totally
      # garbage'"); returning [] would hide the mistake.
      assert {:error, %{status: 400, body: @time_comparand_rejected <> "'totally garbage'"}} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM prices WHERE time > 'totally garbage'",
                 database: db
               )
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — IN / NOT IN clauses (issue #5)
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — IN / NOT IN clauses" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "in_db")

      lines =
        Enum.join(
          [
            "holdings,ticker=AAPL,account=acct1 shares=10i 1000",
            "holdings,ticker=GOOG,account=acct1 shares=5i 2000",
            "holdings,ticker=MSFT,account=acct2 shares=20i 3000"
          ],
          "\n"
        )

      {:ok, :written} = Local.write(conn, lines, database: "in_db", precision: :nanosecond)
      {:ok, db: "in_db"}
    end

    test "IN with multiple tag values filters correctly", %{conn: conn, db: db} do
      assert holding_tickers(conn, db, "ticker IN ('AAPL', 'MSFT')") == ["AAPL", "MSFT"]
    end

    test "IN with a single value matches one row", %{conn: conn, db: db} do
      assert holding_tickers(conn, db, "ticker IN ('GOOG')") == ["GOOG"]
    end

    test "empty IN () matches no rows", %{conn: conn, db: db} do
      assert holding_tickers(conn, db, "ticker IN ()") == []
    end

    test "IN works on field columns", %{conn: conn, db: db} do
      assert holding_tickers(conn, db, "shares IN (10, 20)") == ["AAPL", "MSFT"]
    end

    test "NOT IN excludes listed values", %{conn: conn, db: db} do
      assert holding_tickers(conn, db, "ticker NOT IN ('AAPL', 'GOOG')") == ["MSFT"]
    end

    test "IN combines with binary operators via AND", %{conn: conn, db: db} do
      assert holding_tickers(conn, db, "ticker IN ('AAPL', 'GOOG', 'MSFT') AND shares > 5") ==
               ["AAPL", "MSFT"]
    end

    test "IN list with parameter substitution narrows correctly", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM holdings WHERE ticker IN ($t0, $t1) ORDER BY time",
          database: db,
          params: %{"$t0" => "AAPL", "$t1" => "MSFT"}
        )

      assert Enum.map(rows, & &1["ticker"]) == ["AAPL", "MSFT"]
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — non-time GROUP BY (issue #6)
  #
  # Real InfluxDB v3 SQL allows GROUP BY on tag/field columns alongside
  # aggregates. LocalClient must match so that production-realistic
  # group-and-aggregate queries can be tested.
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — GROUP BY column" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "group_db")

      lines =
        Enum.join(
          [
            "account_holdings,ticker=AAPL,holding_type=stock,account_id=abc value=100.0 1000",
            "account_holdings,ticker=AAPL,holding_type=stock,account_id=abc value=200.0 2000",
            "account_holdings,ticker=GOOG,holding_type=stock,account_id=abc value=300.0 3000",
            "account_holdings,ticker=AAPL,holding_type=etf,account_id=abc value=50.0 4000"
          ],
          "\n"
        )

      {:ok, :written} = Local.write(conn, lines, database: "group_db", precision: :nanosecond)
      {:ok, db: "group_db"}
    end

    test "single column GROUP BY emits one row per unique value",
         %{conn: conn, db: db} do
      sql = """
      SELECT ticker, AVG(value) AS avg_value
      FROM account_holdings
      WHERE account_id = 'abc'
      GROUP BY ticker
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      # AAPL: (100 + 200 + 50) / 3
      assert rows |> Enum.map(&{&1["ticker"], &1["avg_value"]}) |> Enum.sort() ==
               [{"AAPL", 116.66666666666667}, {"GOOG", 300.0}]
    end

    test "multi-column GROUP BY uses tuple of values (issue #6 reproduction)",
         %{conn: conn, db: db} do
      sql = """
      SELECT ticker, AVG(value) AS average_balance, holding_type
      FROM account_holdings
      WHERE account_id = 'abc'
      GROUP BY ticker, holding_type
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows
             |> Enum.map(&{&1["ticker"], &1["holding_type"], &1["average_balance"]})
             |> Enum.sort() ==
               [{"AAPL", "etf", 50.0}, {"AAPL", "stock", 150.0}, {"GOOG", "stock", 300.0}]
    end

    test "GROUP BY supports AS alias on grouping columns",
         %{conn: conn, db: db} do
      sql = """
      SELECT ticker AS sym, COUNT(value) AS n
      FROM account_holdings
      GROUP BY ticker
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows |> Enum.sort_by(& &1["sym"]) == [
               %{"sym" => "AAPL", "n" => 3},
               %{"sym" => "GOOG", "n" => 1}
             ]
    end

    test "GROUP BY with no matching rows yields no rows",
         %{conn: conn, db: db} do
      sql = """
      SELECT ticker, COUNT(value) AS n
      FROM account_holdings
      WHERE account_id = 'no_such'
      GROUP BY ticker
      """

      assert {:ok, []} = Local.query_sql(conn, sql, database: db)
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — Decimal SQL params (issue #7)
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — Decimal params" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "dec_db")

      lines =
        Enum.join(
          [
            "cash_flows,account_id=abc amount=500.0 1000",
            "cash_flows,account_id=abc amount=5000.0 2000",
            "cash_flows,account_id=abc amount=12000.0 3000"
          ],
          "\n"
        )

      {:ok, :written} = Local.write(conn, lines, database: "dec_db", precision: :nanosecond)
      {:ok, db: "dec_db"}
    end

    test "Decimal param serialises as numeric literal (issue #7 reproduction)",
         %{conn: conn, db: db} do
      sql = """
      SELECT amount FROM cash_flows
      WHERE account_id = $a AND amount >= $min
      ORDER BY time
      """

      params = %{"$a" => "abc", "$min" => Decimal.new("1000.00")}

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db, params: params)
      assert rows == [%{"amount" => 5000.0}, %{"amount" => 12_000.0}]
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — coverage for error/edge branches
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — error and edge branches" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "edge_db")
      {:ok, db: "edge_db"}
    end

    test "SELECT DISTINCT with no column list is one empty row, as on the engine",
         %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "prices price=1i 1", database: db)

      assert {:ok, [%{}]} = Local.query_sql(conn, "SELECT DISTINCT FROM prices", database: db)
    end

    test "WHERE time with an integer param is rejected, as over HTTP", %{conn: conn, db: db} do
      # The engine plans `Timestamp(ns) >= UInt64` as an error for a JSON
      # integer param; the double must not accept what production refuses.
      {:ok, :written} = Local.write(conn, "m val=1i 5000", database: db)

      assert {:error,
              %{
                status: 400,
                body:
                  "type_coercion\ncaused by\nError during planning: Cannot infer common " <>
                    "argument type for comparison operation Timestamp(ns) >= UInt64"
              }} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM m WHERE time >= $t",
                 database: db,
                 params: %{"$t" => 5000}
               )
    end

    test "WHERE time with a DateTime param renders as the ISO string Jason sends",
         %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m val=1i 5000\nm val=2i 6000", database: db)

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM m WHERE time >= $t",
          database: db,
          params: %{"$t" => ~U[1970-01-01 00:00:00.000006Z]}
        )

      assert rows == [%{"val" => 2, "time" => ~U[1970-01-01 00:00:00.000006Z]}]
    end

    test "WHERE time with non-matching filter returns empty",
         %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m val=1i 5000", database: db)

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM m WHERE time > '1970-01-01T00:00:00.000009999Z'",
          database: db
        )

      assert rows == []
    end

    test "a double-quoted WHERE operand is a column, not a string", %{conn: conn, db: db} do
      # SQL quotes identifiers with "..." and strings with '...'. The double
      # used to read "hello" as a string, so a query the engine refuses
      # (verified: No field named hello) passed against it.
      {:ok, :written} = Local.write(conn, ~s(m,tag=hello val=1i), database: db)

      assert {:error,
              %{
                status: 500,
                body: "Schema error: No field named hello. Valid fields are tag, time, val."
              }} = Local.query_sql(conn, ~s(SELECT * FROM m WHERE tag = "hello"), database: db)

      assert {:ok, [%{"tag" => "hello", "val" => 1}]} =
               Local.query_sql(conn, ~s(SELECT * FROM m WHERE tag = 'hello'), database: db)
    end

    test "float param in SQL literal", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m val=3.14", database: db)

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM m WHERE val > $v",
          database: db,
          params: %{"$v" => 3.0}
        )

      assert [%{"val" => 3.14}] = rows
    end
  end

  # ---------------------------------------------------------------------------
  # write/3 — line protocol edge cases
  # ---------------------------------------------------------------------------

  describe "write/3 — line protocol edge cases" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "lp_edge")
      {:ok, db: "lp_edge"}
    end

    test "tag value with escaped equals sign", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m,k=v\\=1 f=1i", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["k"] == "v=1"
    end

    test "measurement name with escaped comma", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "my\\,measurement field=1i", database: db)

      assert {:ok, [%{"field" => 1}]} =
               Local.query_sql(conn, ~s|SELECT field FROM "my,measurement"|, database: db)
    end

    test "field with negative integer", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m value=-42i", database: db)

      assert {:ok, [%{"value" => -42}]} =
               Local.query_sql(conn, "SELECT value FROM m", database: db)
    end

    test "field with negative float", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m value=-3.14", database: db)

      assert {:ok, [%{"value" => -3.14}]} =
               Local.query_sql(conn, "SELECT value FROM m", database: db)
    end

    test "field with scientific notation", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m value=1.5e10", database: db)

      assert {:ok, [%{"value" => 15_000_000_000.0}]} =
               Local.query_sql(conn, "SELECT value FROM m", database: db)
    end

    test "comments and blank lines are ignored", %{conn: conn, db: db} do
      lp = "# This is a comment\n\nm value=1i 1\n\n# Another comment\nm value=2i 2\n"
      {:ok, :written} = Local.write(conn, lp, database: db)

      assert {:ok, [%{"value" => 1}, %{"value" => 2}]} =
               Local.query_sql(conn, "SELECT value FROM m ORDER BY time", database: db)
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — multi-database isolation
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — multi-database isolation" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "db_a")
      :ok = Local.create_database(conn, "db_b")
      {:ok, :written} = Local.write(conn, "m value=1i", database: "db_a")
      {:ok, :written} = Local.write(conn, "m value=2i", database: "db_b")
      :ok
    end

    test "points in db_a are NOT visible from db_b", %{conn: conn} do
      assert {:ok, [%{"value" => 1}]} = Local.query_sql(conn, "SELECT * FROM m", database: "db_a")
      assert {:ok, [%{"value" => 2}]} = Local.query_sql(conn, "SELECT * FROM m", database: "db_b")
    end

    test "a query against a database that does not exist is the engine's 404", %{conn: conn} do
      body = ~s({"error":"query error: database not found: nope"})

      # Any SQL statement, before it is parsed; InfluxQL after parsing.
      for sql <- ["SELECT * FROM m", "SELECT 1", "DELETE FROM m", "SELEC 1"] do
        assert {:error, %{status: 404, body: ^body}} =
                 Local.query_sql(conn, sql, database: "nope")
      end

      assert {:error, %{status: 404, body: ^body}} =
               Local.query_influxql(conn, "SELECT value FROM m", database: "nope")

      assert {:error, %{status: 404, body: ^body}} =
               Local.query_influxql(conn, "SHOW MEASUREMENTS", database: "nope")
    end

    test "query without explicit database uses the connection's default", %{conn: conn} do
      # setup starts with databases: ["test_db"], the default as over HTTP.
      {:ok, :written} = Local.write(conn, "m value=99i", database: "test_db")
      assert {:ok, [%{"value" => 99}]} = Local.query_sql(conn, "SELECT * FROM m")
    end
  end

  # ---------------------------------------------------------------------------
  # query_influxql/3 — InfluxQL-specific commands
  # ---------------------------------------------------------------------------

  describe "query_influxql/3 — InfluxQL commands" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "iql_db")

      {:ok, :written} =
        Local.write(conn, "cpu,host=web01,region=us value=1i 1000", database: "iql_db")

      {:ok, :written} = Local.write(conn, "mem,host=web01 used=512i", database: "iql_db")
      {:ok, db: "iql_db"}
    end

    test "SHOW DATABASES returns all databases with iox::database key", %{conn: conn} do
      assert {:ok, dbs} = Local.query_influxql(conn, "SHOW DATABASES")

      assert Enum.map(dbs, & &1["iox::database"]) == ["_internal", "iql_db", "test_db"]
    end

    test "SHOW MEASUREMENTS returns measurement names with iox::measurement key",
         %{conn: conn, db: db} do
      assert {:ok, measurements} =
               Local.query_influxql(conn, "SHOW MEASUREMENTS", database: db)

      assert measurements == [
               %{"iox::measurement" => "measurements", "name" => "cpu"},
               %{"iox::measurement" => "measurements", "name" => "mem"}
             ]
    end

    test "SHOW TAG KEYS FROM returns tag keys with iox::measurement key",
         %{conn: conn, db: db} do
      assert {:ok, tag_keys} =
               Local.query_influxql(conn, "SHOW TAG KEYS FROM cpu", database: db)

      assert tag_keys == [
               %{"iox::measurement" => "cpu", "tagKey" => "host"},
               %{"iox::measurement" => "cpu", "tagKey" => "region"}
             ]
    end

    test "SELECT * returns every field and tag beside iox::measurement and time",
         %{conn: conn, db: db} do
      assert {:ok, [row]} = Local.query_influxql(conn, "SELECT * FROM cpu", database: db)

      assert row == %{
               "iox::measurement" => "cpu",
               "time" => ~U[1970-01-01 00:00:00.000001Z],
               "host" => "web01",
               "region" => "us",
               "value" => 1
             }
    end
  end

  # ---------------------------------------------------------------------------
  # query_flux/3 — predicate support
  # ---------------------------------------------------------------------------

  describe "query_flux/3 — predicates" do
    setup do
      {:ok, v2_conn} =
        Local.start(databases: ["flux_db"], profile: :v2)

      now = System.os_time(:nanosecond)
      old = now - 7_200_000_000_000

      {:ok, :written} =
        Local.write(
          v2_conn,
          "cpu,host=web01 value=10i #{now}\ncpu,host=web02 value=20i #{old}",
          database: "flux_db"
        )

      on_exit(fn -> Local.stop(v2_conn) end)
      {:ok, v2_conn: v2_conn, db: "flux_db", now: now, old: old}
    end

    test "filter by tag equality", %{v2_conn: conn} do
      flux =
        "from(bucket: \"flux_db\") |> range(start: -24h) |> filter(fn: (r) => r.host == \"web01\")"

      assert {:ok, [%{"host" => "web01", "_field" => "value", "_value" => 10}]} =
               Local.query_flux(conn, flux)
    end

    test "range(start: -1h) filters old points", %{v2_conn: conn} do
      flux = "from(bucket: \"flux_db\") |> range(start: -1h)"

      assert {:ok, [%{"_field" => "value", "_value" => 10, "host" => "web01"}]} =
               Local.query_flux(conn, flux)
    end

    test "rows are long-format with one table per series", %{v2_conn: conn, now: now} do
      flux = "from(bucket: \"flux_db\") |> range(start: -24h)"
      assert {:ok, rows} = Local.query_flux(conn, flux)

      # Two series (host=web01, host=web02) → tables 0 and 1, ordered.
      assert Enum.map(rows, & &1["table"]) == [0, 1]
      assert Enum.all?(rows, &(&1["_measurement"] == "cpu" and &1["result"] == "_result"))

      web01 = Enum.find(rows, &(&1["host"] == "web01"))
      assert web01["_time"] == DateTime.from_unix!(now, :nanosecond)
    end

    test "filter on _field keeps only that field", %{v2_conn: conn} do
      {:ok, :written} = Local.write(conn, "mem,host=web01 used=5i,free=7i", database: "flux_db")

      flux =
        "from(bucket: \"flux_db\") |> range(start: -1h) " <>
          "|> filter(fn: (r) => r._measurement == \"mem\") " <>
          "|> filter(fn: (r) => r._field == \"free\")"

      assert {:ok, [%{"_field" => "free", "_value" => 7}]} = Local.query_flux(conn, flux)
    end

    test "a bucket that does not exist is the engine's 404", %{v2_conn: conn} do
      flux = "from(bucket: \"no_such_bucket\") |> range(start: -1h)"
      assert {:error, %{status: 404, body: body}} = Local.query_flux(conn, flux)

      assert Jason.decode!(body) == %{
               "code" => "not found",
               "message" =>
                 ~s|failed to initialize execute state: could not find bucket "no_such_bucket"|
             }
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — SELECT DISTINCT
  # ---------------------------------------------------------------------------

  # The engine's DISTINCT ON semantics are in the contract; this is the
  # double's own limit.
  describe "query_sql/3 — SELECT DISTINCT ON" do
    test "an expression in ON is refused by name, not answered wrongly", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "m v=1i 1", database: "test_db")

      sql =
        "SELECT DISTINCT ON (date_bin(INTERVAL '2 seconds', time)) v FROM m " <>
          "ORDER BY date_bin(INTERVAL '2 seconds', time)"

      refusal =
        "Client.Local: DISTINCT ON takes column names only: " <>
          "(date_bin(interval '2 seconds', time))"

      assert {:error, %{status: 400, body: ^refusal}} =
               Local.query_sql(conn, sql, database: "test_db")

      assert {:error, %{status: 400, body: ^refusal}} = Local.check_sql(sql)
    end
  end

  describe "query_sql/3 — SELECT DISTINCT" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "dist_db")

      lines =
        Enum.join(
          [
            "prices,symbol=AAPL price=150.0 1000000000",
            "prices,symbol=GOOG price=2800.0 2000000000",
            "prices,symbol=AAPL price=151.0 3000000000",
            "prices,symbol=MSFT price=300.0 4000000000",
            "prices,symbol=GOOG price=2810.0 5000000000"
          ],
          "\n"
        )

      {:ok, :written} =
        Local.write(conn, lines, database: "dist_db")

      {:ok, db: "dist_db"}
    end

    test "returns unique values for a tag column, the table quoted or not",
         %{conn: conn, db: db} do
      for table <- [~s("prices"), "prices"] do
        sql = "SELECT DISTINCT symbol FROM #{table} ORDER BY symbol"
        assert column_values(conn, db, sql, "symbol") == ["AAPL", "GOOG", "MSFT"]
      end
    end

    test "returns unique values for a field column", %{conn: conn, db: db} do
      sql = ~s(SELECT DISTINCT price FROM "prices" ORDER BY price)

      assert column_values(conn, db, sql, "price") == [150.0, 151.0, 300.0, 2800.0, 2810.0]
    end

    test "applies WHERE filter", %{conn: conn, db: db} do
      sql = ~s(SELECT DISTINCT symbol FROM "prices" WHERE price > 200 ORDER BY symbol)

      assert column_values(conn, db, sql, "symbol") == ["GOOG", "MSFT"]
    end

    test "applies LIMIT", %{conn: conn, db: db} do
      sql = ~s(SELECT DISTINCT symbol FROM "prices" ORDER BY symbol LIMIT 2)

      assert column_values(conn, db, sql, "symbol") == ["AAPL", "GOOG"]
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — DATE_BIN + aggregate functions
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — aggregate queries" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "agg_db")

      # 6 points at half-hour offsets to avoid bucket boundary collisions
      # 0.5h, 1.5h, 2.5h, 3.5h, 4.5h, 5.5h
      hour = 3_600_000_000_000
      half = div(hour, 2)

      lines =
        [
          "cpu,host=web01 usage=10i,idle=90i #{0 * hour + half}",
          "cpu,host=web01 usage=20i,idle=80i #{1 * hour + half}",
          "cpu,host=web01 usage=30i,idle=70i #{2 * hour + half}",
          "cpu,host=web02 usage=40i,idle=60i #{3 * hour + half}",
          "cpu,host=web02 usage=50i,idle=50i #{4 * hour + half}",
          "cpu,host=web02 usage=60i,idle=40i #{5 * hour + half}"
        ]
        |> Enum.join("\n")

      {:ok, :written} = Local.write(conn, lines, database: "agg_db", precision: :nanosecond)
      {:ok, db: "agg_db", hour: hour}
    end

    test "AVG with 2-hour buckets", %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '2 hours', time) AS time,
        AVG(usage) AS avg_usage
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '2 hours', time)
      ORDER BY time ASC
      """

      # 0.5h,1.5h → bucket 0; 2.5h,3.5h → bucket 2h; 4.5h,5.5h → bucket 4h
      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows == [
               %{"time" => ~U[1970-01-01 00:00:00.000000Z], "avg_usage" => 15.0},
               %{"time" => ~U[1970-01-01 02:00:00.000000Z], "avg_usage" => 35.0},
               %{"time" => ~U[1970-01-01 04:00:00.000000Z], "avg_usage" => 55.0}
             ]
    end

    test "SUM aggregate", %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '3 hours', time) AS time,
        SUM(usage) AS total
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '3 hours', time)
      ORDER BY time ASC
      """

      # 0.5h,1.5h,2.5h → bucket 0; 3.5h,4.5h,5.5h → bucket 3h
      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows == [
               %{"time" => ~U[1970-01-01 00:00:00.000000Z], "total" => 60},
               %{"time" => ~U[1970-01-01 03:00:00.000000Z], "total" => 150}
             ]
    end

    test "COUNT aggregate", %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '3 hours', time) AS time,
        COUNT(usage) AS cnt
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '3 hours', time)
      ORDER BY time ASC
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows == [
               %{"time" => ~U[1970-01-01 00:00:00.000000Z], "cnt" => 3},
               %{"time" => ~U[1970-01-01 03:00:00.000000Z], "cnt" => 3}
             ]
    end

    test "multiple aggregates in one query",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '6 hours', time) AS time,
        AVG(usage) AS avg_val,
        SUM(usage) AS sum_val,
        COUNT(usage) AS cnt
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '6 hours', time)
      ORDER BY time ASC
      """

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)

      assert row == %{
               "time" => ~U[1970-01-01 00:00:00.000000Z],
               "avg_val" => 35.0,
               "sum_val" => 210,
               "cnt" => 6
             }
    end

    test "aggregate with WHERE filter",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '3 hours', time) AS time,
        AVG(usage) AS avg_usage
      FROM "cpu"
      WHERE host = 'web01'
      GROUP BY DATE_BIN(INTERVAL '3 hours', time)
      ORDER BY time ASC
      """

      # web01 has points at 0.5h, 1.5h, 2.5h → all in bucket 0
      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row == %{"time" => ~U[1970-01-01 00:00:00.000000Z], "avg_usage" => 20.0}
    end

    test "ORDER BY time DESC", %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '3 hours', time) AS time,
        COUNT(usage) AS cnt
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '3 hours', time)
      ORDER BY time DESC
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows == [
               %{"time" => ~U[1970-01-01 03:00:00.000000Z], "cnt" => 3},
               %{"time" => ~U[1970-01-01 00:00:00.000000Z], "cnt" => 3}
             ]
    end

    test "LIMIT on aggregate results",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        AVG(usage) AS avg_usage
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      ORDER BY time ASC
      LIMIT 2
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows == [
               %{"time" => ~U[1970-01-01 00:00:00.000000Z], "avg_usage" => 10.0},
               %{"time" => ~U[1970-01-01 01:00:00.000000Z], "avg_usage" => 20.0}
             ]
    end

    test "interval units: hour, minutes and seconds all name the same one-hour bucket",
         %{conn: conn, db: db} do
      # Six points half an hour into each hour: one point per bucket.
      expected =
        for hour <- 0..5, do: %{"time" => hour_start(hour), "cnt" => 1}

      for interval <- ["1 hour", "60 minutes", "3600 seconds"] do
        sql = """
        SELECT
          DATE_BIN(INTERVAL '#{interval}', time) AS time,
          COUNT(usage) AS cnt
        FROM "cpu"
        GROUP BY DATE_BIN(INTERVAL '#{interval}', time)
        ORDER BY time ASC
        """

        assert {:ok, ^expected} = Local.query_sql(conn, sql, database: db)
      end
    end

    test "unquoted measurement name", %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '6 hours', time) AS time,
        AVG(usage) AS avg_usage
      FROM cpu
      GROUP BY DATE_BIN(INTERVAL '6 hours', time)
      ORDER BY time ASC
      """

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["avg_usage"] == 35.0
    end

    test "non-existent measurement returns error",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        AVG(usage) AS avg_usage
      FROM "nonexistent"
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      ORDER BY time ASC
      """

      assert {:error,
              %{
                status: 400,
                body: "Error during planning: table 'public.iox.nonexistent' not found"
              }} =
               Local.query_sql(conn, sql, database: db)
    end

    test "day interval buckets", %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 day', time) AS time,
        SUM(usage) AS total
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '1 day', time)
      ORDER BY time ASC
      """

      # All 6 points at 0.5h-5.5h → all in day bucket 0
      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["time"] == ~U[1970-01-01 00:00:00.000000Z]
      assert row["total"] == 210
    end

    test "aggregate without ORDER BY returns results", %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '6 hours', time) AS time,
        SUM(usage) AS total
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '6 hours', time)
      """

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["total"] == 210
    end

    test "scalar aggregate without GROUP BY DATE_BIN returns one row",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        AVG(usage) AS avg_usage
      FROM "cpu"
      """

      assert {:ok, [%{"avg_usage" => 35.0}]} = Local.query_sql(conn, sql, database: db)
    end

    test "scalar aggregate honours WHERE filtering", %{conn: conn, db: db} do
      sql = """
      SELECT
        SUM(usage) AS total_usage,
        COUNT(usage) AS row_count
      FROM "cpu"
      WHERE host = 'web01'
      """

      # web01 has usage values 10, 20, 30 → total 60, count 3
      assert {:ok, [%{"total_usage" => 60, "row_count" => 3}]} =
               Local.query_sql(conn, sql, database: db)
    end

    test "scalar COUNT returns 0 when no rows match", %{conn: conn, db: db} do
      sql = """
      SELECT
        COUNT(usage) AS row_count
      FROM "cpu"
      WHERE host = 'no_such_host'
      """

      assert {:ok, [%{"row_count" => 0}]} =
               Local.query_sql(conn, sql, database: db)
    end

    test "scalar AVG omits the column when no rows match", %{conn: conn, db: db} do
      sql = """
      SELECT
        AVG(usage) AS avg_usage
      FROM "cpu"
      WHERE host = 'no_such_host'
      """

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      refute Map.has_key?(row, "avg_usage")
    end

    test "invalid interval unit returns error", %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 fortnight', time) AS time,
        AVG(usage) AS avg_usage
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '1 fortnight', time)
      ORDER BY time ASC
      """

      assert {:error, %{status: 400, body: "Client.Local: unknown interval unit: fortnight"}} =
               Local.query_sql(conn, sql, database: db)
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — first_value() and last_value() ordered aggregates
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — first_value/last_value aggregates" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "ohlcv_db")

      hour = 3_600_000_000_000

      # Simulate trades within two 1-hour windows
      lines =
        [
          # Hour 0: trades at 10m, 30m, 50m
          "trades price=100.0,volume=10i #{div(hour, 6)}",
          "trades price=105.0,volume=20i #{div(hour, 2)}",
          "trades price=102.0,volume=15i #{div(5 * hour, 6)}",
          # Hour 1: trades at 1h10m, 1h30m, 1h50m
          "trades price=110.0,volume=5i #{hour + div(hour, 6)}",
          "trades price=108.0,volume=25i #{hour + div(hour, 2)}",
          "trades price=112.0,volume=30i #{hour + div(5 * hour, 6)}"
        ]
        |> Enum.join("\n")

      {:ok, :written} =
        Local.write(conn, lines,
          database: "ohlcv_db",
          precision: :nanosecond
        )

      {:ok, db: "ohlcv_db", hour: hour}
    end

    test "first_value(field ORDER BY time) returns value at earliest timestamp",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        first_value(price ORDER BY time) AS open
      FROM "trades"
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      ORDER BY time ASC
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows == [
               %{"time" => hour_start(0), "open" => 100.0},
               %{"time" => hour_start(1), "open" => 110.0}
             ]
    end

    test "last_value(field ORDER BY time) returns value at latest timestamp",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        last_value(price ORDER BY time) AS close
      FROM "trades"
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      ORDER BY time ASC
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows == [
               %{"time" => hour_start(0), "close" => 102.0},
               %{"time" => hour_start(1), "close" => 112.0}
             ]
    end

    test "full OHLCV candle query",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        first_value(price ORDER BY time) AS open,
        MAX(price) AS high,
        MIN(price) AS low,
        last_value(price ORDER BY time) AS close,
        SUM(volume) AS volume
      FROM "trades"
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      ORDER BY time ASC
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows == [
               # Hour 0: prices 100, 105, 102 — volumes 10, 20, 15
               %{
                 "time" => hour_start(0),
                 "open" => 100.0,
                 "high" => 105.0,
                 "low" => 100.0,
                 "close" => 102.0,
                 "volume" => 45
               },
               # Hour 1: prices 110, 108, 112 — volumes 5, 25, 30
               %{
                 "time" => hour_start(1),
                 "open" => 110.0,
                 "high" => 112.0,
                 "low" => 108.0,
                 "close" => 112.0,
                 "volume" => 60
               }
             ]
    end

    test "first_value(field ORDER BY time DESC) returns value at latest timestamp",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        first_value(price ORDER BY time DESC) AS latest
      FROM "trades"
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      ORDER BY time ASC
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows == [
               %{"time" => hour_start(0), "latest" => 102.0},
               %{"time" => hour_start(1), "latest" => 112.0}
             ]
    end

    test "last_value(field ORDER BY time DESC) returns value at earliest timestamp",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        last_value(price ORDER BY time DESC) AS earliest
      FROM "trades"
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      ORDER BY time ASC
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows == [
               %{"time" => hour_start(0), "earliest" => 100.0},
               %{"time" => hour_start(1), "earliest" => 110.0}
             ]
    end

    test "first_value without ORDER BY is rejected as non-deterministic",
         %{conn: conn, db: db} do
      # Real DataFusion returns an arbitrary group member here. Certifying
      # "earliest" would be a lie, so the double refuses and says why.
      sql = "SELECT first_value(price) AS open FROM \"trades\""

      assert {:error,
              %{
                status: 400,
                body:
                  "Client.Local: first_value() needs ORDER BY inside the call: InfluxDB v3 " <>
                    "returns an arbitrary row from the group without one, which this test " <>
                    "double cannot reproduce. Write first_value(field ORDER BY time): " <>
                    "first_value(price) as open"
              }} = Local.query_sql(conn, sql, database: db)
    end

    test "InfluxQL FIRST()/LAST() fail planning as invalid functions", %{conn: conn, db: db} do
      # InfluxDB v3 SQL has no FIRST/LAST (#13).
      for {sql, body} <- [
            {"SELECT FIRST(price, time) AS open FROM \"trades\"",
             "Error during planning: Invalid function 'first'.\nDid you mean 'cbrt'?"},
            {"SELECT last(price) AS close FROM \"trades\"",
             "Error during planning: Invalid function 'last'.\nDid you mean 'least'?"}
          ] do
        assert {:error, %{status: 400, body: ^body}} = Local.query_sql(conn, sql, database: db)
      end
    end

    test "a malformed first_value call is rejected", %{conn: conn, db: db} do
      sql = "SELECT first_value(price ORDER BY time, symbol) AS open FROM \"trades\""

      assert {:error,
              %{
                status: 400,
                body:
                  "Client.Local: invalid aggregate: first_value(price order by time, symbol) as open"
              }} = Local.query_sql(conn, sql, database: db)
    end

    test "a second argument to a plain aggregate is rejected", %{conn: conn, db: db} do
      # AVG(price, time) is not SQL; the real engine rejects it.
      sql = "SELECT AVG(price, time) AS avg FROM \"trades\""

      assert {:error,
              %{status: 400, body: "Client.Local: invalid aggregate: avg(price, time) as avg"}} =
               Local.query_sql(conn, sql, database: db)
    end

    test "first_value/last_value with WHERE filter",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '2 hours', time) AS time,
        first_value(price ORDER BY time) AS open,
        last_value(price ORDER BY time) AS close
      FROM "trades"
      WHERE price > 104
      GROUP BY DATE_BIN(INTERVAL '2 hours', time)
      ORDER BY time ASC
      """

      # Prices > 104: 105 (0.5h), 110 (1h10m), 108 (1h30m), 112 (1h50m)
      # All in bucket 0 (2-hour window)
      assert {:ok, [%{"time" => time, "open" => 105.0, "close" => 112.0}]} =
               Local.query_sql(conn, sql, database: db)

      assert time == hour_start(0)
    end
  end

  # ---------------------------------------------------------------------------
  # start/1 — invalid profile validation
  # ---------------------------------------------------------------------------

  describe "start/1 — invalid profile" do
    test "raises ArgumentError naming the profile and listing the valid ones" do
      assert_raise ArgumentError,
                   "invalid profile: :invalid_thing. Must be one of: :v3_core, :v3_enterprise, :v2",
                   fn -> Local.start(profile: :invalid_thing) end
    end
  end

  # ---------------------------------------------------------------------------
  # write/3 — line protocol parse error edge cases
  # ---------------------------------------------------------------------------

  describe "write/3 — line protocol parse errors" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "lp_err")
      {:ok, db: "lp_err"}
    end

    test "an escaped backslash in a tag value is stored as one backslash",
         %{conn: conn, db: db} do
      # cpu,host=web\\01 has a literal backslash in the host tag value
      {:ok, :written} = Local.write(conn, "cpu,host=web\\\\01 value=1i", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM cpu", database: db)
      assert row["host"] == "web\\01"
    end

    test "a field value or timestamp that does not parse is a 400 naming the line and reason",
         %{conn: conn, db: db} do
      for {lp, message} <- [
            # Not a quoted string, an integer (no i suffix), a boolean or a float
            {"cpu value=notanumber", "No fields were provided"},
            {"cpu value=abci", "No fields were provided"},
            {"cpu value=1i badtimestamp",
             "Could not parse entire line. Found trailing content: ` badtimest...`"}
          ] do
        assert {:error, %{status: 400, body: body}} = Local.write(conn, lp, database: db)
        assert [{1, ^message}] = partial_errors(body), lp
      end
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — aggregate SQL parse error edge cases
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — aggregate parse errors" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "agg_err_db")

      {:ok, :written} =
        Local.write(conn, "sensors temp=22i 1000000000", database: "agg_err_db")

      {:ok, db: "agg_err_db"}
    end

    test "aggregate parse errors are 400s naming the part that failed",
         %{conn: conn, db: db} do
      for {column, group, message} <- [
            # A function call that is not DATE_BIN nor a recognised aggregate
            {"weird_func(temp) AS alias", "DATE_BIN(INTERVAL '1 hour', time)",
             "unsupported column expression: weird_func(temp) as alias"},
            {"INVALID_FUNC(temp) AS bad", "DATE_BIN(INTERVAL '1 hour', time)",
             "unsupported column expression: invalid_func(temp) as bad"},
            # DATE_BIN without the INTERVAL keyword
            {"AVG(temp) AS avg_temp", "DATE_BIN('1 hour', time)",
             "invalid DATE_BIN: date_bin('1 hour', time) as time"},
            {"AVG(temp) AS avg_temp", "DATE_BIN(INTERVAL 'lots of hours', time)",
             "invalid interval: lots of hours"}
          ] do
        sql = """
        SELECT
          #{group} AS time,
          #{column}
        FROM sensors
        GROUP BY #{group}
        """

        assert {:error, %{status: 400, body: body}} = Local.query_sql(conn, sql, database: db)
        assert body == "Client.Local: " <> message, sql
      end
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — WHERE value parsing coverage
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — WHERE value type parsing" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "where_val_db")

      {:ok, :written} =
        Local.write(
          conn,
          "sensors,device=alpha temp=98.6,count=5i 1000000000\n" <>
            "sensors,device=beta temp=37.2,count=10i 2000000000",
          database: "where_val_db"
        )

      {:ok, db: "where_val_db"}
    end

    test "WHERE with float comparison filters correctly", %{conn: conn, db: db} do
      sql = "SELECT * FROM sensors WHERE temp > 1.5 ORDER BY time"
      assert column_values(conn, db, sql, "device") == ["alpha", "beta"]
    end

    test "WHERE with float boundary excludes low values", %{conn: conn, db: db} do
      sql = "SELECT * FROM sensors WHERE temp > 50.0 ORDER BY time"
      assert column_values(conn, db, sql, "device") == ["alpha"]
    end

    test "WHERE with unparseable string value is treated as string literal",
         %{conn: conn, db: db} do
      # A value like 'alpha' matches tag values as a string
      sql = "SELECT * FROM sensors WHERE device = 'alpha'"
      assert column_values(conn, db, sql, "device") == ["alpha"]
    end

    test "WHERE clause that matches nothing returns empty list",
         %{conn: conn, db: db} do
      assert {:ok, []} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM sensors WHERE temp > 9999.9",
                 database: db
               )
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — quoted literals are strings (#12)
  #
  # Every expectation below was checked against a live InfluxDB 3 Core
  # (/api/v3/query_sql). DataFusion never re-types a quoted literal, and it
  # compares a numeric column against a string literal by casting the
  # column to text.
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — quoted literals stay strings" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "lit_db")

      {:ok, :written} =
        Local.write(
          conn,
          "acct,repcode=08338636 amount=500.0 1000\n" <>
            "acct,repcode=12345678 amount=5000.0 2000",
          database: "lit_db"
        )

      {:ok, db: "lit_db"}
    end

    test "!= excludes only the matching string tag", %{conn: conn, db: db} do
      sql = "SELECT * FROM acct WHERE repcode != '08338636'"
      assert [%{"repcode" => "12345678", "amount" => 5000.0}] = sql_rows(conn, db, sql)
    end

    test "IN / NOT IN compare zero-padded literals as strings", %{conn: conn, db: db} do
      sql = "SELECT * FROM acct WHERE repcode IN ('08338636')"
      assert [%{"repcode" => "08338636", "amount" => 500.0}] = sql_rows(conn, db, sql)

      sql = "SELECT * FROM acct WHERE repcode NOT IN ('08338636')"
      assert [%{"repcode" => "12345678", "amount" => 5000.0}] = sql_rows(conn, db, sql)
    end

    test "a string literal against a float field compares as text", %{conn: conn, db: db} do
      # Real engine: '500.0' >= '1000.00' lexically, so BOTH rows come back.
      # The double reproduces the footgun so tests fail the way prod does.
      sql = "SELECT amount FROM acct WHERE amount >= '1000.00' ORDER BY time"
      assert sql_rows(conn, db, sql) == [%{"amount" => 500.0}, %{"amount" => 5000.0}]

      # Real engine: 500.0 renders as "500.0", so '500' is not equal ...
      assert [] = sql_rows(conn, db, "SELECT * FROM acct WHERE amount = '500'")

      # ... but '500.0' is.
      assert [%{"amount" => 500.0}] =
               sql_rows(conn, db, "SELECT * FROM acct WHERE amount IN ('500.0')")
    end

    test "a bare numeric literal against a float field compares numerically",
         %{conn: conn, db: db} do
      sql = "SELECT * FROM acct WHERE amount >= 1000.0"
      assert [%{"repcode" => "12345678", "amount" => 5000.0}] = sql_rows(conn, db, sql)
    end
  end

  # ---------------------------------------------------------------------------
  # query_flux/3 — range unit coverage
  # ---------------------------------------------------------------------------

  describe "query_flux/3 — range time units" do
    setup do
      {:ok, v2_conn} = Local.start(databases: ["flux_range_db"], profile: :v2)
      now = System.os_time(:nanosecond)

      # Two points: one recent (5 seconds ago), one old (2 hours ago)
      recent = now - 5_000_000_000
      old = now - 7_200_000_000_000

      {:ok, :written} =
        Local.write(
          v2_conn,
          "sensors,host=new value=1i #{recent}\nsensors,host=old value=2i #{old}",
          database: "flux_range_db"
        )

      on_exit(fn -> Local.stop(v2_conn) end)
      {:ok, v2_conn: v2_conn}
    end

    test "range with seconds unit filters correctly", %{v2_conn: conn} do
      flux = "from(bucket: \"flux_range_db\") |> range(start: -30s)"
      assert {:ok, [%{"host" => "new", "_value" => 1}]} = Local.query_flux(conn, flux)
    end

    test "range with minutes unit filters correctly", %{v2_conn: conn} do
      flux = "from(bucket: \"flux_range_db\") |> range(start: -1m)"
      assert {:ok, [%{"host" => "new", "_value" => 1}]} = Local.query_flux(conn, flux)
    end

    test "range with days unit includes all recent points", %{v2_conn: conn} do
      flux = "from(bucket: \"flux_range_db\") |> range(start: -1d)"
      assert {:ok, rows} = Local.query_flux(conn, flux)
      assert Enum.map(rows, &{&1["host"], &1["_value"]}) == [{"new", 1}, {"old", 2}]
    end

    test "a query without range() is refused as unbounded, as the engine refuses it",
         %{v2_conn: conn} do
      assert {:error, %{status: 400, body: body}} =
               Local.query_flux(conn, "from(bucket: \"flux_range_db\")")

      assert Jason.decode!(body) == %{
               "code" => "invalid",
               "message" =>
                 "error in building plan while starting program: cannot submit unbounded " <>
                   ~s|read to "flux_range_db"; try bounding 'from' with a call to 'range'|
             }
    end

    test "flux filter predicate on tag field", %{v2_conn: conn} do
      flux =
        "from(bucket: \"flux_range_db\") |> range(start: -1d) |> filter(fn: (r) => r.host == \"new\")"

      assert {:ok, [%{"host" => "new", "_value" => 1}]} = Local.query_flux(conn, flux)
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — boolean parameter substitution
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — boolean and nil parameter substitution" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "bool_param_db")

      {:ok, :written} =
        Local.write(
          conn,
          "devices,id=d1 active=true\ndevices,id=d2 active=false",
          database: "bool_param_db"
        )

      {:ok, db: "bool_param_db"}
    end

    test "boolean params select by the flag", %{conn: conn, db: db} do
      for {flag, id} <- [{true, "d1"}, {false, "d2"}] do
        assert {:ok, [%{"id" => ^id, "active" => ^flag}]} =
                 Local.query_sql(
                   conn,
                   "SELECT * FROM devices WHERE active = $flag",
                   database: db,
                   params: %{"$flag" => flag}
                 )
      end
    end

    test "a nil param renders as NULL, which never matches", %{conn: conn, db: db} do
      # Jason sends nil as JSON null and `id = NULL` is never true on the
      # engine; the double renders NULL and matches nothing either.
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM devices WHERE id = $val",
                 database: db,
                 params: %{"$val" => nil}
               )

      assert rows == []
    end
  end

  # ---------------------------------------------------------------------------
  # execute_sql/3 — DELETE on non-existent measurement (v3_enterprise)
  # ---------------------------------------------------------------------------

  describe "execute_sql/3 — DELETE non-existent measurement" do
    setup do
      {:ok, conn} = Local.start(databases: ["del_ne_db"], profile: :v3_enterprise)
      on_exit(fn -> Local.stop(conn) end)
      {:ok, conn: conn, db: "del_ne_db"}
    end

    test "DELETE FROM non-existent measurement returns 0 rows affected",
         %{conn: conn, db: db} do
      assert {:ok, %{"rows_affected" => 0}} =
               Local.execute_sql(conn, "DELETE FROM nonexistent", database: db)
    end

    test "DELETE honours OR, NOT and parentheses in its WHERE", %{conn: conn, db: db} do
      # The delete path folded predicates with the pre-boolean-expression
      # helper and crashed on an {:or, _} node.
      {:ok, :written} =
        Local.write(conn, "m,host=a v=1i\nm,host=b v=2i\nm,host=c v=3i\nm,host=d v=4i",
          database: db
        )

      assert {:ok, %{"rows_affected" => 2}} =
               Local.execute_sql(conn, "DELETE FROM m WHERE host = 'a' OR host = 'b'",
                 database: db
               )

      assert {:ok, %{"rows_affected" => 1}} =
               Local.execute_sql(conn, "DELETE FROM m WHERE NOT (host = 'c' OR v > 9)",
                 database: db
               )

      assert {:ok, [%{"host" => "c"}]} =
               Local.query_sql(conn, "SELECT host FROM m", database: db)
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — aggregate on empty bucket (WHERE filters all points)
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — aggregate on empty filtered bucket" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "empty_agg_db")

      # Write points that will be completely filtered out by the WHERE clause
      {:ok, :written} =
        Local.write(
          conn,
          "sensors temp=22i 1000000000\nsensors temp=25i 2000000000",
          database: "empty_agg_db"
        )

      {:ok, db: "empty_agg_db"}
    end

    test "aggregate where WHERE filters out all points returns empty list",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        AVG(temp) AS avg_temp
      FROM sensors
      WHERE temp > 9999
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      ORDER BY time ASC
      """

      assert {:ok, []} = Local.query_sql(conn, sql, database: db)
    end

    test "untimed lines of one write share the server's time, so one series is one point",
         %{conn: conn, db: db} do
      # Both engines stamp every untimed line of a write with the request's
      # time (verified): the two lines are one point, the later value wins.
      {:ok, :written} = Local.write(conn, "no_ts val=10i\nno_ts val=20i", database: db)

      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        SUM(val) AS total
      FROM no_ts
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      """

      assert {:ok, [%{"total" => 20, "time" => time}]} = Local.query_sql(conn, sql, database: db)

      # The bucket is the server-assigned hour, not the epoch: it starts on the
      # hour, within the last hour.
      assert %DateTime{minute: 0, second: 0, microsecond: {0, 6}} = time
      assert DateTime.diff(DateTime.utc_now(), time, :second) in 0..3600
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — first/last with non-time ordering field
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — first_value/last_value with non-time ordering" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "ord_db")
      hour = 3_600_000_000_000

      # Points with a custom numeric field "priority" for ordering
      lines = [
        "events,type=a value=100i,priority=3i #{div(hour, 4)}",
        "events,type=b value=200i,priority=1i #{div(hour, 2)}",
        "events,type=c value=300i,priority=2i #{div(3 * hour, 4)}"
      ]

      {:ok, :written} = Local.write(conn, Enum.join(lines, "\n"), database: "ord_db")
      {:ok, db: "ord_db"}
    end

    test "first_value(value ORDER BY priority) returns value at lowest priority",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        first_value(value ORDER BY priority) AS first_val
      FROM events
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      """

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      # priority=1 (type=b) is the minimum → first value is 200
      assert row["first_val"] == 200
    end

    test "last_value(value ORDER BY priority) returns value at highest priority",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        last_value(value ORDER BY priority) AS last_val
      FROM events
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      """

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      # priority=3 (type=a) is the maximum → last value is 100
      assert row["last_val"] == 100
    end
  end

  # ---------------------------------------------------------------------------
  # Regression coverage for bug reports filed by consuming applications.
  # Each scenario reproduces a real downstream failure reported against this
  # library (see the GitHub issues and CHANGELOG for the original reports).
  # ---------------------------------------------------------------------------

  describe "bug regression — concurrent writes to one database (#15)" do
    # Points were stored as one list per measurement and every write
    # read-modify-wrote it, so parallel writers overwrote each other:
    # 159 of 480 rows survived while every call returned {:ok, :written}.
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "shared_db")
      {:ok, db: "shared_db"}
    end

    test "every one of 480 parallel writes is stored", %{conn: conn, db: db} do
      writers = 8
      per_writer = 60

      tasks =
        for w <- 1..writers do
          Task.async(fn ->
            for i <- 1..per_writer do
              {:ok, :written} =
                Local.write(conn, "prices,symbol=W#{w}X#{i} price=1.0", database: db)
            end
          end)
        end

      Enum.each(tasks, &Task.await(&1, 30_000))

      expected = for w <- 1..writers, i <- 1..per_writer, do: "W#{w}X#{i}"
      symbols = column_values(conn, db, "SELECT symbol FROM prices", "symbol")

      assert Enum.sort(symbols) == Enum.sort(expected)
    end

    test "parallel create_database calls all register" do
      # Enterprise: Core allows only 5 databases.
      {:ok, conn} = Local.start(profile: :v3_enterprise)
      on_exit(fn -> Local.stop(conn) end)
      names = for i <- 1..16, do: "par_db_#{i}"

      names
      |> Enum.map(&Task.async(fn -> Local.create_database(conn, &1) end))
      |> Enum.each(&Task.await/1)

      assert {:ok, dbs} = Local.list_databases(conn)
      assert dbs |> Enum.map(& &1["name"]) |> Enum.sort() == Enum.sort(["_internal" | names])
    end

    test "a DELETE running beside writes only removes what it matched", %{db: db} do
      {:ok, ent} = Local.start(databases: [db], profile: :v3_enterprise)
      on_exit(fn -> Local.stop(ent) end)

      # Explicit timestamps: the untimed lines of one write share a time
      # and would be one point, as on the engines.
      {:ok, :written} =
        Local.write(ent, Enum.map_join(1..50, "\n", &"m,k=old v=#{&1}i #{&1}"), database: db)

      writer =
        Task.async(fn ->
          for i <- 1..50, do: Local.write(ent, "m,k=new v=#{i}i #{100 + i}", database: db)
        end)

      {:ok, %{"rows_affected" => 50}} =
        Local.execute_sql(ent, "DELETE FROM m WHERE k = 'old'", database: db)

      Task.await(writer)

      assert {:ok, rows} = Local.query_sql(ent, "SELECT k, v FROM m ORDER BY v", database: db)
      assert Enum.map(rows, &{&1["k"], &1["v"]}) == for(i <- 1..50, do: {"new", i})
    end
  end

  describe "bug regression — write preserves provided timestamps" do
    # Bug: ignores-write-timestamp. Writes of N points at fixed spacing
    # returned timestamps microseconds apart because store_point/3 substituted
    # System.os_time/1 over the parsed timestamp.
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "ts_keep_db")
      {:ok, db: "ts_keep_db"}
    end

    test "six points written 900 seconds apart, out of order, read back in time order",
         %{conn: conn, db: db} do
      base_ns = 1_700_000_000_000_000_000
      step_ns = 900 * 1_000_000_000

      lines =
        for i <- [3, 0, 5, 1, 4, 2] do
          "candles,symbol=BTC close=#{100 + i}.0 #{base_ns + i * step_ns}"
        end

      {:ok, :written} = Local.write(conn, Enum.join(lines, "\n"), database: db)

      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM candles ORDER BY time ASC",
                 database: db
               )

      assert Enum.map(rows, &{&1["time"], &1["close"]}) == [
               {~U[2023-11-14 22:13:20.000000Z], 100.0},
               {~U[2023-11-14 22:28:20.000000Z], 101.0},
               {~U[2023-11-14 22:43:20.000000Z], 102.0},
               {~U[2023-11-14 22:58:20.000000Z], 103.0},
               {~U[2023-11-14 23:13:20.000000Z], 104.0},
               {~U[2023-11-14 23:28:20.000000Z], 105.0}
             ]
    end

    test "ORDER BY time ASC returns oldest-first with explicit timestamps",
         %{conn: conn, db: db} do
      base_ns = 1_700_000_000_000_000_000
      step_ns = 60 * 1_000_000_000

      lp =
        Enum.map_join([2, 0, 3, 1], "\n", fn i ->
          "obs val=#{i}i #{base_ns + i * step_ns}"
        end)

      {:ok, :written} = Local.write(conn, lp, database: db)

      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM obs ORDER BY time ASC", database: db)

      assert Enum.map(rows, & &1["val"]) == [0, 1, 2, 3]
    end
  end

  describe "bug regression — unrecognised WHERE clauses do not silently drop" do
    # Bug: in-operator (corollary). The fix list says: clauses the parser cannot
    # recognise must not produce wrong rows. Today they yield []; with this
    # regression test we lock in that behaviour into an explicit error so a
    # future "LIKE 'foo%'" clause cannot silently match everything.
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "where_strict_db")

      {:ok, :written} =
        Local.write(
          conn,
          "alerts,severity=high msg=\"fire\" 1000000000\n" <>
            "alerts,severity=low msg=\"info\" 2000000000",
          database: "where_strict_db"
        )

      {:ok, db: "where_strict_db"}
    end

    test "unknown WHERE clause returns an error rather than wrong rows",
         %{conn: conn, db: db} do
      assert {:error,
              %{
                status: 400,
                body: "Client.Local: unsupported WHERE clause: severity similar to 'h%'"
              }} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM alerts WHERE severity SIMILAR TO 'h%'",
                 database: db
               )
    end
  end

  describe "bug regression — COUNT(*) aggregate" do
    # Bug: count-star. parse_agg_column/1 required \w+ inside the parens, so
    # COUNT(*) failed parsing and the query 400'd.
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "count_star_db")

      day_ns = 86_400_000_000_000

      lines =
        for i <- 0..4 do
          # Two days, 3 rows on day 1 and 2 rows on day 2
          day = if i < 3, do: 0, else: 1
          offset = rem(i, 3)
          ts = day * day_ns + offset * 3_600_000_000_000
          "decision_traces,strategy_id=s1 prob=#{0.1 + i / 10} #{ts}"
        end

      {:ok, :written} = Local.write(conn, Enum.join(lines, "\n"), database: "count_star_db")
      {:ok, db: "count_star_db"}
    end

    test "scalar COUNT(*) returns total row count", %{conn: conn, db: db} do
      assert {:ok, [%{"n" => 5}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT COUNT(*) AS n FROM "decision_traces"|,
                 database: db
               )
    end

    test "COUNT(*) with DATE_BIN buckets by day", %{conn: conn, db: db} do
      sql = """
      SELECT DATE_BIN(INTERVAL '1 day', time) AS day, COUNT(*) AS n
      FROM "decision_traces"
      GROUP BY DATE_BIN(INTERVAL '1 day', time)
      ORDER BY day ASC
      """

      assert {:ok, [day1, day2]} = Local.query_sql(conn, sql, database: db)
      assert day1 == %{"day" => ~U[1970-01-01 00:00:00.000000Z], "n" => 3}
      assert day2 == %{"day" => ~U[1970-01-02 00:00:00.000000Z], "n" => 2}
    end

    test "COUNT(*) ignores field nullity (counts rows missing the field)",
         %{conn: conn, db: db} do
      # Add a row whose field is a different name — COUNT(prob) would skip it,
      # COUNT(*) must include it.
      {:ok, :written} =
        Local.write(
          conn,
          "decision_traces,strategy_id=s1 other_field=1i 5000000000",
          database: db
        )

      assert {:ok, [%{"n" => 6}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT COUNT(*) AS n FROM "decision_traces"|,
                 database: db
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Issues #16 and #17: statistical aggregates, arithmetic inside aggregates,
  # selector functions, multi-column DISTINCT, ORDER BY alias, null omission.
  # Expected values were recorded from InfluxDB 3 Core (see
  # docs/design/2026-09-14_local-sql-stats-selectors-distinct.md).
  # ---------------------------------------------------------------------------

  describe "bug regression — statistical aggregates (#16)" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "stats_db")

      lines =
        Enum.join(
          [
            "m,provider=a,symbol=X value=10.0 1000000000",
            "m,provider=a,symbol=X value=20.0 2000000000",
            "m,provider=a,symbol=X value=30.0 3000000000",
            "m,provider=b,symbol=Y value=5.0 4000000000"
          ],
          "\n"
        )

      {:ok, :written} = Local.write(conn, lines, database: "stats_db")
      {:ok, db: "stats_db"}
    end

    test "STDDEV, STDDEV_SAMP, STDDEV_POP, VAR, VAR_SAMP and VAR_POP match v3",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        STDDEV(value) AS sd,
        STDDEV_SAMP(value) AS sd_samp,
        STDDEV_POP(value) AS sd_pop,
        VAR(value) AS v,
        VAR_SAMP(value) AS v_samp,
        VAR_POP(value) AS v_pop
      FROM "m"
      WHERE provider = 'a'
      """

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["sd"] == 10.0
      assert row["sd_samp"] == 10.0
      assert row["sd_pop"] == 8.16496580927726
      assert row["v"] == 100.0
      assert row["v_samp"] == 100.0
      assert row["v_pop"] == 66.66666666666667
    end

    test "sample statistics over one row are null and the column is omitted",
         %{conn: conn, db: db} do
      sql = """
      SELECT STDDEV(value) AS sd, VAR(value) AS v, VAR_POP(value) AS v_pop
      FROM "m"
      WHERE provider = 'b'
      """

      assert {:ok, [%{"v_pop" => +0.0} = row]} = Local.query_sql(conn, sql, database: db)
      assert Map.keys(row) == ["v_pop"]
    end

    test "an empty group keeps only COUNT (0); every other aggregate is omitted",
         %{conn: conn, db: db} do
      sql = """
      SELECT COUNT(value) AS n, AVG(value) AS a, STDDEV(value) AS sd
      FROM "m"
      WHERE provider = 'none'
      """

      assert {:ok, [%{"n" => 0} = row]} = Local.query_sql(conn, sql, database: db)
      assert Map.keys(row) == ["n"]
    end

    test "VARIANCE is not a DataFusion function and is rejected", %{conn: conn, db: db} do
      assert {:error,
              %{status: 400, body: "Client.Local: unsupported column: variance(value) as v"}} =
               Local.query_sql(conn, ~s|SELECT VARIANCE(value) AS v FROM "m"|, database: db)
    end

    test "arithmetic inside an aggregate is evaluated per row", %{conn: conn, db: db} do
      sql = """
      SELECT
        SUM(value * value) AS sum_sq,
        AVG(value / 2) AS half_avg,
        MAX(value - 1) AS max_less_one,
        MIN((value + 10) * 2) AS min_shifted
      FROM "m"
      WHERE provider = 'a'
      """

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["sum_sq"] == 1400.0
      assert row["half_avg"] == 10.0
      assert row["max_less_one"] == 29.0
      assert row["min_shifted"] == 40.0
    end

    test "integer operands divide as integers, like DataFusion", %{conn: conn, db: db} do
      {:ok, :written} =
        Local.write(conn, "ints n=3i 1000000000\nints n=5i 2000000000", database: db)

      sql = ~s|SELECT SUM(n / 2) AS halves, SUM(n * n) AS squares, AVG(n) AS a FROM "ints"|

      assert {:ok, [%{"halves" => 3, "squares" => 34, "a" => 4.0}]} =
               Local.query_sql(conn, sql, database: db)
    end

    # A float over zero is infinity on the engine, which COUNT counts and SUM
    # turns to NaN; the double cannot hold either, so it refuses by name.
    test "a float divided by zero inside an aggregate is refused by name, not a crash",
         %{conn: conn, db: db} do
      sql = ~s|SELECT SUM(value / 0) AS s, COUNT(value / 0) AS n FROM "m"|

      assert {:error,
              %{
                status: 400,
                body:
                  "Client.Local: a float divided by zero is IEEE infinity or NaN on the " <>
                    "engine, which the double cannot hold"
              }} = Local.query_sql(conn, sql, database: db)
    end

    test "a malformed expression is rejected with a Client.Local error", %{conn: conn, db: db} do
      for {expression, rendered} <- [
            {"AVG(value, other)", "avg(value, other)"},
            {"AVG(value +)", "avg(value +)"},
            {"AVG((value)", "avg((value)"},
            {"AVG(value $ 2)", "avg(value $ 2)"}
          ] do
        sql = ~s|SELECT #{expression} AS a FROM "m"|

        assert {:error, %{status: 400, body: body}} = Local.query_sql(conn, sql, database: db)
        assert body == "Client.Local: invalid aggregate: #{rendered} as a", sql
      end
    end

    test "ORDER BY a non-time projected column sorts groups", %{conn: conn, db: db} do
      sql = """
      SELECT provider, SUM(value) AS total
      FROM "m"
      GROUP BY provider
      ORDER BY total DESC
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows == [
               %{"provider" => "a", "total" => 60.0},
               %{"provider" => "b", "total" => 5.0}
             ]
    end
  end

  describe "bug regression — selector functions and DATE_BIN ordering (#17)" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "sel_db")

      # Two 1-minute buckets: [10, 30, 20] then [5]. Timestamps are seconds
      # after the epoch so bucket boundaries are obvious.
      lines =
        Enum.join(
          [
            "m,symbol=X value=10.0 0",
            "m,symbol=X value=30.0 20000000000",
            "m,symbol=X value=20.0 40000000000",
            "m,symbol=X value=5.0 70000000000"
          ],
          "\n"
        )

      {:ok, :written} = Local.write(conn, lines, database: "sel_db")
      {:ok, db: "sel_db"}
    end

    test "selector_first/last/min/max return the chosen row's value or time",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        selector_first(value, time)['value'] AS first_v,
        selector_first(value, time)['time'] AS first_t,
        selector_last(value, time)['value'] AS last_v,
        selector_last(value, time)['time'] AS last_t,
        selector_min(value, time)['value'] AS min_v,
        selector_min(value, time)['time'] AS min_t,
        selector_max(value, time)['value'] AS max_v,
        selector_max(value, time)['time'] AS max_t
      FROM "m"
      """

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["first_v"] == 10.0
      assert row["first_t"] == ~U[1970-01-01 00:00:00.000000Z]
      assert row["last_v"] == 5.0
      assert row["last_t"] == ~U[1970-01-01 00:01:10.000000Z]
      assert row["min_v"] == 5.0
      assert row["min_t"] == ~U[1970-01-01 00:01:10.000000Z]
      assert row["max_v"] == 30.0
      assert row["max_t"] == ~U[1970-01-01 00:00:20.000000Z]
    end

    test "selectors combine with DATE_BIN and ORDER BY the bin alias DESC",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 minute', time) AS bucket,
        selector_first(value, time)['value'] AS open,
        selector_max(value, time)['value'] AS high,
        selector_min(value, time)['value'] AS low,
        selector_last(value, time)['value'] AS close,
        COUNT(value) AS n
      FROM "m"
      GROUP BY DATE_BIN(INTERVAL '1 minute', time)
      ORDER BY bucket DESC
      """

      assert {:ok, [late, early]} = Local.query_sql(conn, sql, database: db)

      assert late["bucket"] == ~U[1970-01-01 00:01:00.000000Z]
      assert late["open"] == 5.0 and late["close"] == 5.0 and late["n"] == 1

      assert early["bucket"] == ~U[1970-01-01 00:00:00.000000Z]
      assert early["open"] == 10.0
      assert early["high"] == 30.0
      assert early["low"] == 10.0
      assert early["close"] == 20.0
      assert early["n"] == 3
    end

    test "an empty selector group omits the column", %{conn: conn, db: db} do
      sql = ~s|SELECT selector_last(value, time)['value'] AS v FROM "m" WHERE symbol = 'nope'|

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row == %{}
    end

    test "a selector without an accessor is the engine's time/value struct", %{conn: conn, db: db} do
      assert {:ok, [%{"v" => %{"time" => %DateTime{} = time, "value" => 5.0}}]} =
               Local.query_sql(conn, ~s|SELECT selector_last(value, time) AS v FROM "m"|,
                 database: db
               )

      assert {:ok, [%{"t" => ^time, "x" => 5.0}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT selector_last(value, time)['time'] AS t, selector_last(value, time)['value'] AS x FROM "m"|,
                 database: db
               )
    end
  end

  describe "bug regression — null omission (#17)" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "md_db")

      lines =
        Enum.join(
          [
            "m,provider=a,symbol=X value=1.0 1000000000",
            "m,provider=a,symbol=X value=2.0 2000000000",
            "m,provider=b,symbol=Y value=3.0 3000000000",
            "m,provider=b,symbol=Y other=4.0 4000000000"
          ],
          "\n"
        )

      {:ok, :written} = Local.write(conn, lines, database: "md_db")
      {:ok, db: "md_db"}
    end

    test "SELECT * omits a column that is null for that row, like v3", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, ~s|SELECT * FROM "m" WHERE provider = 'b'|, database: db)

      [with_value, with_other] = Enum.sort_by(rows, & &1["time"], DateTime)
      assert with_value["value"] == 3.0
      refute Map.has_key?(with_value, "other")
      assert with_other["other"] == 4.0
      refute Map.has_key?(with_other, "value")
    end

    test "an explicit column list omits a missing field rather than nil-filling it",
         %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 ~s|SELECT provider, other FROM "m" WHERE provider = 'a'|,
                 database: db
               )

      assert rows == [%{"provider" => "a"}, %{"provider" => "a"}]
    end
  end

  describe "check_sql/1" do
    test "returns :ok for a query inside the supported subset" do
      assert :ok =
               Local.check_sql("""
               SELECT DATE_BIN(INTERVAL '5 minutes', time) AS t, STDDEV(value) AS sd
               FROM "m" GROUP BY DATE_BIN(INTERVAL '5 minutes', time) ORDER BY t DESC
               """)
    end

    test "returns the same 400 Client.Local error query_sql/3 would" do
      sql = ~s|SELECT approx_median(value) AS m FROM "m"|

      assert {:error,
              %{
                status: 400,
                body: "Client.Local: unsupported column expression: approx_median(value) as m"
              } = err} = Local.check_sql(sql)

      {:ok, conn} = Local.start(databases: ["chk"])
      on_exit(fn -> Local.stop(conn) end)
      assert {:error, ^err} = Local.query_sql(conn, sql, database: "chk")
    end
  end

  # ---------------------------------------------------------------------------
  # Quality sweep 2026-09-14: divergences found by probing the double against
  # InfluxDB 3 Core (see docs/design/2026-09-14_local-time-filters-count-distinct.md).
  # ---------------------------------------------------------------------------

  describe "bug regression — now() time filters, IS NULL, COUNT(DISTINCT), time aggregates" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "sweep_db")
      now_ns = System.os_time(:nanosecond)

      lines =
        Enum.join(
          [
            "q,provider=a,symbol=X price=1.0,bid=1.0 #{now_ns - 60_000_000_000}",
            "q,provider=a,symbol=X price=2.0 #{now_ns - 600_000_000_000}",
            "q,provider=b,symbol=Y price=3.0,bid=3.0 #{now_ns - 3_600_000_000_000}",
            "q,provider=c,symbol=Z price=4.0 #{now_ns - 7_200_000_000_000}"
          ],
          "\n"
        )

      {:ok, :written} = Local.write(conn, lines, database: "sweep_db")
      {:ok, db: "sweep_db"}
    end

    test "now() - INTERVAL is evaluated at query time", %{conn: conn, db: db} do
      assert {:ok, [%{"price" => 1.0}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT price FROM "q" WHERE time >= now() - INTERVAL '2 minutes'|,
                 database: db
               )

      sql =
        ~s|SELECT price FROM "q" WHERE time >= now() - INTERVAL '1 hour' - INTERVAL '30 minutes' | <>
          ~s|AND time < NOW() + INTERVAL '1 day' ORDER BY price|

      assert column_values(conn, db, sql, "price") == [1.0, 2.0, 3.0]
    end

    test "an unknown function as a time comparand is rejected", %{conn: conn, db: db} do
      assert {:error, %{status: 400, body: @time_comparand_rejected <> "foo()"}} =
               Local.query_sql(conn, ~s|SELECT price FROM "q" WHERE time >= foo()|, database: db)
    end

    test "COUNT(DISTINCT col) is 0 over no rows and counts per group", %{conn: conn, db: db} do
      assert {:ok, [%{"n" => 0}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT COUNT(DISTINCT provider) AS n FROM "q" WHERE provider = 'zzz'|,
                 database: db
               )

      assert {:ok,
              [
                %{"provider" => "a", "n" => 1},
                %{"provider" => "b", "n" => 1},
                %{"provider" => "c", "n" => 1}
              ]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT provider, COUNT(DISTINCT symbol) AS n FROM "q" GROUP BY provider ORDER BY provider|,
                 database: db
               )
    end

    test "aggregates over time other than MIN, MAX and COUNT fail planning as on the engine",
         %{conn: conn, db: db} do
      for {expression, body} <- [
            {"AVG(time) AS s",
             "Error during planning: Execution error: Function 'avg' user-defined coercion " <>
               "failed with \"Error during planning: Avg does not support inputs of type " <>
               "Timestamp(ns).\" No function matches the given name and argument types " <>
               "'avg(Timestamp(ns))'. You might need to add explicit type casts.\n" <>
               "\tCandidate functions:\n\tavg(UserDefined)"},
            {"SUM(time) AS s",
             "Error during planning: Execution error: Function 'sum' user-defined coercion " <>
               "failed with \"Execution error: Sum not supported for Timestamp(ns)\" No " <>
               "function matches the given name and argument types 'sum(Timestamp(ns))'. You " <>
               "might need to add explicit type casts.\n\tCandidate functions:\n\tsum(UserDefined)"},
            {"STDDEV(time) AS s",
             "Error during planning: Function 'stddev' expects NativeType::Numeric but " <>
               "received NativeType::Timestamp(Nanosecond, None) No function matches the " <>
               "given name and argument types 'stddev(Timestamp(ns))'. You might need to add " <>
               "explicit type casts.\n\tCandidate functions:\n\tstddev(Numeric(1))"}
          ] do
        assert {:error, %{status: 400, body: ^body}} =
                 Local.query_sql(conn, ~s|SELECT #{expression} FROM "q"|, database: db)
      end

      # Arithmetic on `time` inside an aggregate (verified on Core).
      assert {:error,
              %{
                status: 400,
                body:
                  "Error during planning: Cannot coerce arithmetic expression " <>
                    "Timestamp(ns) - Int64 to valid types"
              }} = Local.query_sql(conn, ~s|SELECT MAX(time - 1) AS s FROM "q"|, database: db)
    end

    test "SELECT DISTINCT honours ORDER BY on a selected column", %{conn: conn, db: db} do
      assert {:ok, [%{"provider" => "c"}, %{"provider" => "b"}, %{"provider" => "a"}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT DISTINCT provider FROM "q" ORDER BY provider DESC|,
                 database: db
               )
    end

    test "SELECT DISTINCT rejects ORDER BY a column outside the select list",
         %{conn: conn, db: db} do
      assert {:error,
              %{
                status: 400,
                body:
                  "Error during planning: For SELECT DISTINCT, ORDER BY expressions " <>
                    "q.price must appear in select list"
              }} =
               Local.query_sql(
                 conn,
                 ~s|SELECT DISTINCT provider FROM "q" ORDER BY price|,
                 database: db
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Issue #18: projected arithmetic, CTEs, table qualifiers. Expected values
  # recorded from InfluxDB 3 Core (docs/design/2026-09-15_local-ctes-projected-expressions.md).
  # ---------------------------------------------------------------------------

  describe "bug regression — projected expressions, CTEs and qualifiers (#18)" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "cte_db")

      lines =
        Enum.join(
          [
            "q,provider=a bid=1.0,ask=3.0 1000000000",
            "q,provider=a bid=2.0,ask=4.0 61000000000",
            "q,provider=b bid=10.0 121000000000",
            "q,provider=b bid=5.0,ask=7.0 122000000000"
          ],
          "\n"
        )

      {:ok, :written} = Local.write(conn, lines, database: "cte_db")
      {:ok, db: "cte_db"}
    end

    test "arithmetic in a projected column; a null operand omits the column",
         %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 ~s|SELECT (bid + ask) / 2 AS mid, time FROM "q" ORDER BY time|,
                 database: db
               )

      assert rows == [
               %{"mid" => 2.0, "time" => ~U[1970-01-01 00:00:01.000000Z]},
               %{"mid" => 3.0, "time" => ~U[1970-01-01 00:01:01.000000Z]},
               %{"time" => ~U[1970-01-01 00:02:01.000000Z]},
               %{"mid" => 6.0, "time" => ~U[1970-01-01 00:02:02.000000Z]}
             ]
    end

    test "an expression without AS alias is rejected with the reason", %{conn: conn, db: db} do
      assert {:error,
              %{
                status: 400,
                body: "Client.Local: unsupported column (an expression needs AS alias): bid * 2"
              }} =
               Local.query_sql(conn, ~s|SELECT bid * 2 FROM "q"|, database: db)
    end

    test "a CTE feeds GROUP BY DATE_BIN qualified by the CTE alias", %{conn: conn, db: db} do
      sql = """
      WITH w AS (SELECT bid, time FROM "q")
      SELECT DATE_BIN(INTERVAL '1 minute', w.time) AS time, MAX(w.bid) AS hi
      FROM w GROUP BY DATE_BIN(INTERVAL '1 minute', w.time) ORDER BY time
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows == [
               %{"time" => ~U[1970-01-01 00:00:00.000000Z], "hi" => 1.0},
               %{"time" => ~U[1970-01-01 00:01:00.000000Z], "hi" => 2.0},
               %{"time" => ~U[1970-01-01 00:02:00.000000Z], "hi" => 10.0}
             ]
    end

    test "a CTE shadows nothing it does not name", %{conn: conn, db: db} do
      sql = ~s|WITH w AS (SELECT bid FROM "q") SELECT * FROM "q"|
      assert column_values(conn, db, sql, "bid") |> Enum.sort() == [1.0, 2.0, 5.0, 10.0]

      assert {:ok, [%{"n" => 4}]} =
               Local.query_sql(
                 conn,
                 ~s|WITH w AS (SELECT bid FROM "q") SELECT COUNT(*) AS n FROM w|,
                 database: db
               )
    end

    test "a CTE over a missing table reports the engine's table-not-found error",
         %{conn: conn, db: db} do
      assert {:error,
              %{status: 400, body: "Error during planning: table 'public.iox.nope' not found"}} =
               Local.query_sql(conn, ~s|WITH w AS (SELECT bid FROM nope) SELECT * FROM w|,
                 database: db
               )
    end

    test "table aliases and qualified columns are accepted in every clause", %{conn: conn, db: db} do
      assert {:ok, [%{"bid" => 1.0, "time" => ~U[1970-01-01 00:00:01.000000Z]}]} =
               Local.query_sql(conn, ~s|SELECT q.bid, q.time FROM q AS q ORDER BY q.time LIMIT 1|,
                 database: db
               )

      assert {:ok,
              [
                %{"b" => ~U[1970-01-01 00:00:00.000000Z], "n" => 1},
                %{"b" => ~U[1970-01-01 00:01:00.000000Z], "n" => 1},
                %{"b" => ~U[1970-01-01 00:02:00.000000Z], "n" => 2}
              ]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT DATE_BIN(INTERVAL '1 minute', q.time) AS b, COUNT(*) AS n FROM q GROUP BY DATE_BIN(INTERVAL '1 minute', q.time) ORDER BY b|,
                 database: db
               )

      # A qualifier-looking string literal is untouched.
      assert {:ok, []} =
               Local.query_sql(conn, ~s|SELECT provider FROM q WHERE provider = 'q.x'|,
                 database: db
               )
    end

    test "joins, set operations and windows are rejected by name, not ignored",
         %{conn: conn, db: db} do
      for {sql, construct, rendered} <- [
            {~s|SELECT bid FROM "q" INNER JOIN "q" AS r ON q.time = r.time|, "JOIN",
             "select bid from q inner join q as r on time = r.time"},
            {~s|SELECT bid FROM "q" UNION SELECT ask FROM "q"|, "UNION",
             "select bid from q union select ask from q"},
            {~s|SELECT provider, COUNT(*) AS n FROM "q" GROUP BY provider HAVING n > 1|, "HAVING",
             "select provider, count(*) as n from q group by provider having n > 1"}
          ] do
        assert {:error, %{status: 400, body: body}} = Local.query_sql(conn, sql, database: db)
        assert body == "Client.Local: unsupported SQL construct #{construct}: #{rendered}", sql
      end
    end
  end

  describe "bug regression — keyword-like column names and literals are not constructs" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "kw_db")

      {:ok, :written} =
        Local.write(
          conn,
          ~s|m,tag=x offset=1i,over=2i,note="select from join" 1000000000\n| <>
            ~s|m,tag=y offset=3i,over=4i,note="plain" 2000000000|,
          database: "kw_db"
        )

      {:ok, db: "kw_db"}
    end

    test "columns named offset and over are selectable, as on the engine", %{conn: conn, db: db} do
      assert {:ok, [%{"offset" => 1, "over" => 2}, %{"offset" => 3, "over" => 4}]} =
               Local.query_sql(conn, ~s|SELECT offset, over FROM "m" ORDER BY time|, database: db)
    end

    test "keywords inside a string literal are just text", %{conn: conn, db: db} do
      assert {:ok, [%{"tag" => "x"}]} =
               Local.query_sql(conn, ~s|SELECT tag FROM "m" WHERE note = 'select from join'|,
                 database: db
               )
    end

    test "a window function is still refused by name", %{conn: conn, db: db} do
      assert {:error,
              %{
                status: 400,
                body:
                  "Client.Local: unsupported SQL construct OVER: " <>
                    "select tag, row_number() over (order by time) as n from m"
              }} =
               Local.query_sql(
                 conn,
                 ~s|SELECT tag, ROW_NUMBER() OVER (ORDER BY time) AS n FROM "m"|,
                 database: db
               )
    end
  end

  # ---------------------------------------------------------------------------
  # WHERE boolean logic, BETWEEN, LIKE, <>, LIMIT 0 and string-vs-number
  # comparison. Every expected value recorded from InfluxDB 3 Core first
  # (docs/design/2026-09-15_local-where-boolean-logic.md).
  # ---------------------------------------------------------------------------

  describe "bug regression — WHERE OR / NOT / parentheses, BETWEEN, LIKE, <>, LIMIT 0" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "where_db")

      lines =
        Enum.join(
          [
            "m,host=a,rack=1 v=1.0,n=1i 1000000000",
            "m,host=b,rack=2 v=2.5,n=2i 2000000000",
            "m,host=c v=3.0,n=3i 3000000000",
            "m,host=d,rack=4 v=4.0,n=4i 4000000000",
            "m,host=e,rack=10 v=5.0,n=5i 5000000000"
          ],
          "\n"
        )

      {:ok, :written} = Local.write(conn, lines, database: "where_db")
      {:ok, db: "where_db"}
    end

    test "AND binds tighter than OR, also beside IN", %{conn: conn, db: db} do
      assert hosts(
               conn,
               db,
               ~s|SELECT host FROM "m" WHERE v > 3 OR v < 2 AND host = 'a' ORDER BY host|
             ) ==
               ["a", "d", "e"]

      assert hosts(
               conn,
               db,
               ~s|SELECT host FROM "m" WHERE host IN ('a', 'c') OR v = 4.0 ORDER BY host|
             ) ==
               ["a", "c", "d"]
    end

    test "NOT negates a predicate, an IS NULL test or an IN list", %{conn: conn, db: db} do
      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE NOT host = 'a' ORDER BY host|) ==
               ["b", "c", "d", "e"]

      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE NOT rack IS NULL ORDER BY host|) ==
               ["a", "b", "d", "e"]

      assert hosts(
               conn,
               db,
               ~s|SELECT host FROM "m" WHERE host NOT IN ('a', 'b') AND v > 3 ORDER BY host|
             ) ==
               ["d", "e"]
    end

    test "_ in LIKE is one character and a null never matches", %{conn: conn, db: db} do
      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE host LIKE '_' ORDER BY host|) ==
               ~w(a b c d e)

      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE rack LIKE '1%' ORDER BY host|) ==
               ["a", "e"]
    end

    test "LIKE over a numeric column is the engine's planning error", %{conn: conn, db: db} do
      assert {:error,
              %{
                status: 400,
                body:
                  "type_coercion\ncaused by\nError during planning: There isn't a common " <>
                    "type to coerce Float64 and Utf8 in LIKE expression"
              }} =
               Local.query_sql(conn, ~s|SELECT host FROM "m" WHERE v LIKE '1%'|, database: db)
    end

    test "a string column against a numeric literal compares the literal's text, lexically",
         %{conn: conn, db: db} do
      # rack is a tag: "1", "2", "4", "10". DataFusion keeps the column Utf8
      # and renders the literal, so "10" sorts before "3" and "2" >= "10".
      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE rack BETWEEN 1 AND 3 ORDER BY host|) ==
               ["a", "b", "e"]

      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE host > 1 ORDER BY host|) ==
               ~w(a b c d e)

      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE host = 2|) == []
    end

    test "keywords inside string literals are text", %{conn: conn, db: db} do
      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE host = 'x AND y' OR host = 'a'|) == [
               "a"
             ]
    end

    test "LIMIT 0 returns no rows; a negative or non-numeric LIMIT is rejected",
         %{conn: conn, db: db} do
      assert {:ok, []} = Local.query_sql(conn, ~s|SELECT host FROM "m" LIMIT 0|, database: db)

      assert {:error,
              %{
                status: 400,
                body:
                  "Optimizer rule 'eliminate_limit' failed\ncaused by\nError during " <>
                    "planning: LIMIT must be >= 0, '-1' was provided"
              }} = Local.query_sql(conn, ~s|SELECT host FROM "m" LIMIT -1|, database: db)

      assert {:error, %{status: 500, body: "Schema error: No field named abc."}} =
               Local.query_sql(conn, ~s|SELECT host FROM "m" LIMIT abc|, database: db)
    end

    test "malformed boolean expressions are rejected, not truncated", %{conn: conn, db: db} do
      assert {:error, %{status: 400, body: "Client.Local: unbalanced parenthesis in WHERE"}} =
               Local.query_sql(conn, ~s|SELECT host FROM "m" WHERE (host = 'a'|, database: db)

      assert {:error, %{status: 400, body: "Client.Local: unsupported WHERE clause"}} =
               Local.query_sql(conn, ~s|SELECT host FROM "m" WHERE host = 'a' AND|, database: db)
    end
  end

  # ---------------------------------------------------------------------------
  # Issue #19: median(), CROSS JOIN, expression comparands. Expected values
  # recorded from InfluxDB 3 Core (docs/design/2026-09-15_local-median-cross-join.md).
  # ---------------------------------------------------------------------------

  describe "bug regression — median, CROSS JOIN and expression comparands (#19)" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "med_db")

      lines =
        Enum.join(
          [
            "p,symbol=X,provider=a price=1.0,volume=10.0 1700000000000000000",
            "p,symbol=X,provider=a price=2.5,volume=20.0 1700000010000000000",
            "p,symbol=X,provider=a price=3.0,volume=30.0 1700000070000000000",
            "p,symbol=X,provider=a price=4.0,volume=40.0 1700000080000000000",
            "p,symbol=X,provider=a price=100.0,volume=1.0 1700000090000000000",
            "q n=1i 1700000000000000000",
            "q n=2i 1700000001000000000",
            "q n=3i 1700000002000000000",
            "q n=4i 1700000003000000000"
          ],
          "\n"
        )

      {:ok, :written} = Local.write(conn, lines, database: "med_db", precision: :nanosecond)
      {:ok, db: "med_db"}
    end

    test "median: mean of the two middles, integer division, per bucket, never over time",
         %{conn: conn, db: db} do
      assert {:ok, [%{"med" => 2.5}]} =
               Local.query_sql(conn, ~s|SELECT median(price) AS med FROM "p" WHERE price < 4|,
                 database: db
               )

      # Integers: (1 + 4) / 2 with integer division.
      assert {:ok, [%{"med" => 2}]} =
               Local.query_sql(conn, ~s|SELECT median(n) AS med FROM "q" WHERE n IN (1, 4)|,
                 database: db
               )

      assert {:ok, [%{"med" => 1.75}, %{"med" => 4.0}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT DATE_BIN(INTERVAL '1 minute', time) AS t, median(price) AS med FROM "p" GROUP BY DATE_BIN(INTERVAL '1 minute', time) ORDER BY t|,
                 database: db
               )

      assert {:error,
              %{
                status: 400,
                body:
                  "Error during planning: Function 'median' expects NativeType::Numeric but " <>
                    "received NativeType::Timestamp(Nanosecond, None) No function matches the " <>
                    "given name and argument types 'median(Timestamp(ns))'. You might need to " <>
                    "add explicit type casts.\n\tCandidate functions:\n\tmedian(Numeric(1))"
              }} = Local.query_sql(conn, ~s|SELECT median(time) AS med FROM "q"|, database: db)
    end

    test "the median-screened candle query from the issue", %{conn: conn, db: db} do
      sql = """
      WITH w AS (
        SELECT price, volume, time FROM "p"
        WHERE time >= $start AND time < $end AND symbol = $symbol AND provider = $provider
      ),
      ref AS (SELECT median(price) AS med FROM w)
      SELECT
        DATE_BIN(INTERVAL '1 minute', w.time) AS time,
        selector_first(w.price, w.time)['value'] AS open,
        max(w.price) AS high,
        min(w.price) AS low,
        selector_last(w.price, w.time)['value'] AS close,
        sum(w.volume) AS volume
      FROM w CROSS JOIN ref
      WHERE ref.med <= 0
         OR (w.price <= ref.med * 3 AND w.price >= ref.med / 3)
      GROUP BY DATE_BIN(INTERVAL '1 minute', w.time)
      ORDER BY time ASC
      """

      params = %{
        start: ~U[2023-11-14 00:00:00Z],
        end: ~U[2023-11-15 00:00:00Z],
        symbol: "X",
        provider: "a"
      }

      # The 100.0 outlier (median 3.0, bound 9.0) is screened out of the second candle.
      assert {:ok,
              [
                %{
                  "time" => ~U[2023-11-14 22:13:00.000000Z],
                  "open" => 1.0,
                  "high" => 2.5,
                  "low" => 1.0,
                  "close" => 2.5,
                  "volume" => 30.0
                },
                %{
                  "time" => ~U[2023-11-14 22:14:00.000000Z],
                  "open" => 3.0,
                  "high" => 4.0,
                  "low" => 3.0,
                  "close" => 4.0,
                  "volume" => 70.0
                }
              ]} = Local.query_sql(conn, sql, database: db, params: params)
    end

    test "CROSS JOIN is a cartesian product; a column on both sides is ambiguous",
         %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 ~s|WITH r AS (SELECT n FROM "q" WHERE n <= 2) SELECT p.price, r.n FROM "p" CROSS JOIN r WHERE p.price >= 4 ORDER BY p.price|,
                 database: db
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
               Local.query_sql(
                 conn,
                 ~s|WITH ref AS (SELECT median(price) AS price FROM "p") SELECT price FROM "p" CROSS JOIN ref|,
                 database: db
               )

      # Only `time` is shared, so `price` resolves and the product is answered.
      assert {:ok, rows} =
               Local.query_sql(conn, ~s|SELECT price FROM "p" CROSS JOIN "q"|, database: db)

      assert rows |> Enum.map(& &1["price"]) |> Enum.frequencies() ==
               %{1.0 => 4, 2.5 => 4, 3.0 => 4, 4.0 => 4, 100.0 => 4}

      # Both sides carry `time`.
      assert {:error,
              %{
                status: 500,
                body: "Schema error: Ambiguous reference to unqualified field time"
              }} =
               Local.query_sql(conn, ~s|SELECT price, time FROM "p" CROSS JOIN "q"|, database: db)

      assert {:error,
              %{status: 400, body: "Error during planning: table 'public.iox.nope' not found"}} =
               Local.query_sql(conn, ~s|SELECT price FROM "p" CROSS JOIN nope|, database: db)
    end

    test "arithmetic on the left side of a WHERE comparison", %{conn: conn, db: db} do
      assert {:ok, [%{"price" => 100.0}]} =
               Local.query_sql(conn, ~s|SELECT price FROM "p" WHERE 2 * price > volume|,
                 database: db
               )
    end

    test "a bare word is a column; an unknown one is the engine's schema error",
         %{conn: conn, db: db} do
      assert {:error,
              %{
                status: 500,
                body:
                  "Schema error: No field named prod. " <>
                    "Valid fields are price, provider, symbol, time, volume."
              }} =
               Local.query_sql(conn, ~s|SELECT price FROM "p" WHERE symbol = prod|, database: db)
    end
  end

  describe "bug regression — an unknown column anywhere is the engine's schema error" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "schema_db")

      {:ok, :written} =
        Local.write(
          conn,
          "p,host=a v=1.0 1700000000000000000\np,host=b v=2.0 1700000001000000000",
          database: "schema_db",
          precision: :nanosecond
        )

      {:ok, db: "schema_db"}
    end

    test "SELECT, aggregates, selectors, WHERE, GROUP BY, ORDER BY and DISTINCT",
         %{conn: conn, db: db} do
      # Every one of these is a 500 "Schema error: No field named nosuch" on
      # InfluxDB 3 Core; before, the double answered with rows, no rows, or
      # unsorted rows, depending on the clause.
      for sql <- [
            ~s|SELECT nosuch FROM "p"|,
            ~s|SELECT host, nosuch AS n FROM "p"|,
            ~s|SELECT * FROM "p" WHERE nosuch = 1|,
            ~s|SELECT * FROM "p" WHERE nosuch IS NULL|,
            ~s|SELECT * FROM "p" WHERE nosuch IN ('a')|,
            ~s|SELECT * FROM "p" WHERE v > 0 OR nosuch LIKE 'a%'|,
            ~s|SELECT * FROM "p" ORDER BY nosuch|,
            ~s|SELECT host FROM "p" GROUP BY nosuch|,
            ~s|SELECT MAX(nosuch) AS m FROM "p"|,
            ~s|SELECT MAX(v + nosuch) AS m FROM "p"|,
            ~s|SELECT nosuch, COUNT(*) AS n FROM "p" GROUP BY nosuch|,
            ~s|SELECT DISTINCT nosuch FROM "p"|,
            ~s|SELECT selector_first(nosuch, time)['value'] AS f FROM "p"|,
            ~s|SELECT selector_first(v, nosuch)['value'] AS f FROM "p"|,
            ~s|SELECT first_value(nosuch ORDER BY time) AS f FROM "p"|,
            ~s|SELECT COUNT(DISTINCT nosuch) AS n FROM "p"|
          ] do
        assert {:error,
                %{
                  status: 500,
                  body: "Schema error: No field named nosuch. Valid fields are host, time, v."
                }} = Local.query_sql(conn, sql, database: db),
               sql
      end

      # A CTE exposes only the columns it selects.
      assert {:error,
              %{
                status: 500,
                body: "Schema error: No field named nosuch. Valid fields are host, time."
              }} =
               Local.query_sql(
                 conn,
                 ~s|WITH w AS (SELECT host FROM "p") SELECT nosuch FROM w|,
                 database: db
               )
    end

    test "an output alias is a valid ORDER BY target and a source column need not be projected",
         %{conn: conn, db: db} do
      assert {:ok, [%{"h" => "b"}, %{"h" => "a"}]} =
               Local.query_sql(conn, ~s|SELECT host AS h FROM "p" ORDER BY h DESC|, database: db)

      assert {:ok, [%{"host" => "b"}, %{"host" => "a"}]} =
               Local.query_sql(conn, ~s|SELECT host FROM "p" ORDER BY v DESC|, database: db)

      assert {:ok, [%{"n" => 2}]} =
               Local.query_sql(conn, ~s|SELECT COUNT(*) AS n FROM "p" ORDER BY n|, database: db)
    end

    test "with no rows the schema is unknown and nothing is checked", %{conn: conn, db: db} do
      assert {:ok, []} =
               Local.query_sql(
                 conn,
                 ~s|WITH w AS (SELECT host FROM "p" WHERE v > 100) SELECT nosuch FROM w|,
                 database: db
               )
    end
  end

  describe "bug regression — GROUP BY without an aggregate, ungrouped projections, grouped ORDER BY" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "grp_db")

      {:ok, :written} =
        Local.write(
          conn,
          Enum.join(
            [
              "p,host=a v=1.0 1700000000000000000",
              "p,host=b v=2.0 1700000001000000000",
              "p,host=b v=5.0 1700000002000000000"
            ],
            "\n"
          ),
          database: "grp_db",
          precision: :nanosecond
        )

      {:ok, db: "grp_db"}
    end

    test "GROUP BY without an aggregate yields one row per group", %{conn: conn, db: db} do
      # Before, GROUP BY on a plain projection was silently ignored.
      assert {:ok, [%{"host" => "a"}, %{"host" => "b"}]} =
               Local.query_sql(conn, ~s|SELECT host FROM "p" GROUP BY host ORDER BY host|,
                 database: db
               )

      assert {:ok, [%{"h" => "b"}, %{"h" => "a"}]} =
               Local.query_sql(conn, ~s|SELECT host AS h FROM "p" GROUP BY host ORDER BY h DESC|,
                 database: db
               )
    end

    test "a projected column that is neither grouped nor aggregated is the engine's planning error",
         %{conn: conn, db: db} do
      date_bin =
        ~S|date_bin(IntervalMonthDayNano("IntervalMonthDayNano { months: 0, days: 0, | <>
          ~S|nanoseconds: 60000000000 }"),p.time), max(p.v)|

      for {sql, column, appears} <- [
            {~s|SELECT host, v FROM "p" GROUP BY host|, "p.v", "p.host"},
            {~s|SELECT host, MAX(v) AS m FROM "p"|, "p.host", "max(p.v)"},
            {~s|SELECT host, DATE_BIN(INTERVAL '1 minute', time) AS t, MAX(v) AS m FROM "p" GROUP BY DATE_BIN(INTERVAL '1 minute', time)|,
             "p.host", date_bin}
          ] do
        assert {:error, %{status: 400, body: body}} = Local.query_sql(conn, sql, database: db)

        assert body ==
                 "Error during planning: Column in SELECT must be in GROUP BY or an aggregate " <>
                   "function: While expanding wildcard, column \"#{column}\" must appear in " <>
                   "the GROUP BY clause or must be part of an aggregate function, currently " <>
                   "only \"#{appears}\" appears in the SELECT clause satisfies this requirement",
               sql
      end

      assert {:error, %{status: 400, body: "Client.Local: unsupported column expression: *"}} =
               Local.query_sql(conn, ~s|SELECT * FROM "p" GROUP BY host|, database: db)
    end

    test "ORDER BY is honoured on GROUP BY <column> aggregates", %{conn: conn, db: db} do
      # Before, only DATE_BIN groups were ordered; column groups came back in map order.
      assert {:ok, [%{"host" => "b", "t" => 7.0}, %{"host" => "a", "t" => 1.0}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT host, SUM(v) AS t FROM "p" GROUP BY host ORDER BY t DESC|,
                 database: db
               )

      assert {:ok, [%{"n" => 1}, %{"n" => 2}]} =
               Local.query_sql(conn, ~s|SELECT COUNT(*) AS n FROM "p" GROUP BY host ORDER BY n|,
                 database: db
               )
    end
  end

  # ---------------------------------------------------------------------------
  # Issue #20: CAST in WHERE (and everywhere an expression is allowed),
  # `::TYPE`, ORDER BY expressions and multiple terms. Expected values
  # recorded from InfluxDB 3 Core (docs/design/2026-09-16_local-cast-order-by.md).
  # ---------------------------------------------------------------------------

  # The engine's order for rows that tie on every key is arbitrary; the
  # double keeps the order the points were written, so a test's expected
  # rows are deterministic. Keys are read once per row, not per comparison.
  describe "query_sql/3 — multi-key ORDER BY" do
    test "each key in turn, nulls per direction, full ties in write order",
         %{conn: conn} do
      {:ok, :written} =
        Local.write(
          conn,
          Enum.join(
            [
              "sk,rack=b,host=h1 n=1i 1",
              "sk,rack=a,host=h2 n=2i 2",
              "sk,host=h3 n=3i 3",
              "sk,rack=a,host=h2 n=4i 4",
              "sk,rack=b,host=h9 n=5i 5",
              "sk,rack=a,host=h1 n=6i 6"
            ],
            "\n"
          ),
          database: "test_db",
          precision: :nanosecond
        )

      order = fn sql ->
        {:ok, rows} = Local.query_sql(conn, sql, database: "test_db")
        Enum.map(rows, & &1["n"])
      end

      # rack ascending (nulls last), then host descending; n=2 and n=4 tie
      # on both keys and keep their write order.
      assert order.("SELECT n FROM sk ORDER BY rack, host DESC") == [2, 4, 6, 5, 1, 3]

      # rack descending puts nulls first; NULLS LAST overrides it.
      assert order.("SELECT n FROM sk ORDER BY rack DESC, host") == [3, 1, 5, 6, 2, 4]
      assert order.("SELECT n FROM sk ORDER BY rack DESC NULLS LAST, host") == [1, 5, 6, 2, 4, 3]
    end
  end

  describe "bug regression — CAST, ::TYPE and multi-term ORDER BY (#20)" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "cast_db")

      lines =
        Enum.join(
          [
            "orderbooks,symbol=X,provider=a,level=5 price=2.7,qty=1i 1700000000000000000",
            "orderbooks,symbol=X,provider=a,level=20 price=3.2,qty=2i 1700000001000000000",
            "orderbooks,symbol=X,provider=a,level=100 price=9.9,qty=3i 1700000002000000000",
            "orderbooks,symbol=Y,provider=a,level=20 price=1.1,qty=9i 1700000003000000000",
            "bad,level=abc price=1.0 1700000000000000000",
            "bad,level=2.5 price=1.0 1700000001000000000"
          ],
          "\n"
        )

      {:ok, :written} = Local.write(conn, lines, database: "cast_db", precision: :nanosecond)
      {:ok, db: "cast_db"}
    end

    test "the reported orderbook query: CAST(level AS INTEGER) <= $depth on a string tag",
         %{conn: conn, db: db} do
      sql = """
      SELECT *
      FROM "orderbooks"
      WHERE time >= $start_time
        AND symbol = $symbol
        AND provider = $provider
        AND CAST(level AS INTEGER) <= $depth
      ORDER BY time DESC
      LIMIT $row_limit
      """

      params = %{
        start_time: ~U[2023-01-01 00:00:00Z],
        symbol: "X",
        provider: "a",
        depth: 20,
        row_limit: 10
      }

      # Numeric depth: "100" is excluded although it sorts before "20" as text.
      assert {:ok, [%{"level" => "20"}, %{"level" => "5"}]} =
               Local.query_sql(conn, sql, database: db, params: params)

      # The uncast comparison is the lexical one the report describes.
      assert levels(
               conn,
               db,
               ~s|SELECT level FROM "orderbooks" WHERE level <= '20' ORDER BY time|
             ) ==
               ["20", "100", "20"]
    end

    test "CAST spellings and targets", %{conn: conn, db: db} do
      for sql <- [
            ~s|SELECT level FROM "orderbooks" WHERE CAST(level AS INTEGER) <= 20 AND symbol = 'X' ORDER BY time|,
            ~s|SELECT level FROM "orderbooks" WHERE CAST(level AS BIGINT) <= 20 AND symbol = 'X' ORDER BY time|,
            ~s|SELECT level FROM "orderbooks" WHERE CAST(level AS INT) <= 20 AND symbol = 'X' ORDER BY time|,
            ~s|SELECT level FROM "orderbooks" WHERE level::INTEGER <= 20 AND symbol = 'X' ORDER BY time|,
            ~s|SELECT level FROM "orderbooks" WHERE CAST(level AS DOUBLE) <= 20.5 AND symbol = 'X' ORDER BY time|,
            ~s|SELECT level FROM "orderbooks" WHERE CAST(level AS INTEGER) * 2 <= 40 AND symbol = 'X' ORDER BY time|,
            ~s|SELECT level FROM "orderbooks" WHERE CAST(level AS INTEGER) BETWEEN 5 AND 20 AND symbol = 'X' ORDER BY time|
          ] do
        assert levels(conn, db, sql) == ["5", "20"], sql
      end

      assert levels(conn, db, ~s|SELECT level FROM "orderbooks" WHERE CAST(qty AS VARCHAR) = '2'|) ==
               ["20"]

      assert levels(
               conn,
               db,
               ~s|SELECT level FROM "orderbooks" WHERE CAST(qty AS VARCHAR) LIKE '2%'|
             ) == ["20"]
    end

    test "CAST in a projection, an aggregate and arithmetic", %{conn: conn, db: db} do
      assert {:ok, [%{"lvl" => 5}, %{"lvl" => 20}, %{"lvl" => 20}, %{"lvl" => 100}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT CAST(level AS INTEGER) AS lvl FROM "orderbooks" ORDER BY lvl|,
                 database: db
               )

      assert {:ok, [%{"m" => 100}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT MAX(CAST(level AS INTEGER)) AS m FROM "orderbooks"|,
                 database: db
               )

      # float -> integer truncates; integer -> double widens
      assert {:ok, [%{"p" => 1}, %{"p" => 2}, %{"p" => 3}, %{"p" => 9}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT CAST(price AS INTEGER) AS p FROM "orderbooks" ORDER BY p|,
                 database: db
               )

      assert {:ok, [%{"q" => 1.0} | _rest]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT CAST(qty AS DOUBLE) AS q FROM "orderbooks" ORDER BY q|,
                 database: db
               )

      assert {:ok, [%{"s" => 6}, %{"s" => 22}, %{"s" => 29}, %{"s" => 103}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT CAST(level AS INTEGER) + qty AS s FROM "orderbooks" ORDER BY s|,
                 database: db
               )
    end

    test "a cast that cannot be performed fails the query as the engine does", %{
      conn: conn,
      db: db
    } do
      # InfluxDB 3 Core drops the connection mid-response; Client.HTTP reports
      # {:connection_error, %Mint.TransportError{reason: :closed}}.
      closed = {:error, {:connection_error, %Mint.TransportError{reason: :closed}}}

      assert ^closed =
               Local.query_sql(
                 conn,
                 ~s|SELECT level FROM "bad" WHERE CAST(level AS INTEGER) <= 20|,
                 database: db
               )

      assert ^closed =
               Local.query_sql(
                 conn,
                 ~s|SELECT CAST(time AS INTEGER) AS t FROM "orderbooks" LIMIT 1|,
                 database: db
               )

      # A whole-string float is a DOUBLE, not an INTEGER.
      assert levels(
               conn,
               db,
               ~s|SELECT level FROM "bad" WHERE level = '2.5' AND CAST(level AS DOUBLE) <= 20|
             ) ==
               ["2.5"]

      assert {:error,
              %{
                status: 400,
                body: "Client.Local: unsupported column: cast(level as boolean) as b"
              }} =
               Local.query_sql(conn, ~s|SELECT CAST(level AS BOOLEAN) AS b FROM "orderbooks"|,
                 database: db
               )
    end

    test "ORDER BY an expression, and by several terms with their own directions",
         %{conn: conn, db: db} do
      assert levels(
               conn,
               db,
               ~s|SELECT level FROM "orderbooks" WHERE symbol = 'X' ORDER BY CAST(level AS INTEGER)|
             ) ==
               ["5", "20", "100"]

      assert levels(
               conn,
               db,
               ~s|SELECT level FROM "orderbooks" ORDER BY CAST(level AS INTEGER) DESC LIMIT 2|
             ) ==
               ["100", "20"]

      # Before, only the first ORDER BY term was applied and the rest ignored.
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 ~s|SELECT symbol, level FROM "orderbooks" ORDER BY level, symbol DESC|,
                 database: db
               )

      assert Enum.map(rows, &{&1["symbol"], &1["level"]}) == [
               {"X", "100"},
               {"Y", "20"},
               {"X", "20"},
               {"X", "5"}
             ]

      assert {:ok, [%{"m" => 9.9, "symbol" => "X"}, %{"m" => 1.1, "symbol" => "Y"}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT symbol, MAX(price) AS m FROM "orderbooks" GROUP BY symbol ORDER BY m DESC, symbol|,
                 database: db
               )

      assert {:error,
              %{
                status: 400,
                body:
                  "Client.Local: ORDER BY an expression is not supported in an aggregate query"
              }} =
               Local.query_sql(
                 conn,
                 ~s|SELECT level, MAX(price) AS m FROM "orderbooks" GROUP BY level ORDER BY CAST(level AS INTEGER)|,
                 database: db
               )
    end
  end

  describe "bug regression — IN-list items are comparands; constants in a select list" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "const_db")

      {:ok, :written} =
        Local.write(
          conn,
          "p,host=a,rack=2 v=1.0,other=1.0 1700000000000000000\n" <>
            "p,host=b,rack=4 v=2.0,other=5.0 1700000001000000000",
          database: "const_db",
          precision: :nanosecond
        )

      {:ok, db: "const_db"}
    end

    test "a bare word in an IN list is a column reference, as on the engine", %{
      conn: conn,
      db: db
    } do
      # `host IN (a, b)` was read as the strings "a" and "b"; the engine
      # resolves columns and fails on the unknown one.
      assert {:error,
              %{
                status: 500,
                body:
                  "Schema error: No field named a. Valid fields are host, other, rack, time, v."
              }} =
               Local.query_sql(conn, ~s|SELECT host FROM "p" WHERE host IN (a, b)|, database: db)

      assert hosts(conn, db, ~s|SELECT host FROM "p" WHERE v IN (1, other) ORDER BY host|) == [
               "a"
             ]

      assert hosts(conn, db, ~s|SELECT host FROM "p" WHERE v IN (other * 2)|) == []

      assert hosts(conn, db, ~s|SELECT host FROM "p" WHERE rack IN (2, 4) ORDER BY host|) == [
               "a",
               "b"
             ]

      assert hosts(conn, db, ~s|SELECT host FROM "p" WHERE host NOT IN ('a') ORDER BY host|) == [
               "b"
             ]
    end

    test "constants with an alias in projections and aggregates", %{conn: conn, db: db} do
      assert {:ok, [%{"one" => 1}]} =
               Local.query_sql(conn, ~s|SELECT 1 AS one FROM "p" LIMIT 1|, database: db)

      assert {:ok, [%{"host" => "a", "label" => "x"}, %{"host" => "b", "label" => "x"}]} =
               Local.query_sql(conn, ~s|SELECT host, 'x' AS label FROM "p" ORDER BY host|,
                 database: db
               )

      assert {:ok, [%{"host" => "a", "volume" => +0.0}, %{"host" => "b", "volume" => +0.0}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT host, 0.0 AS volume FROM "p" GROUP BY host ORDER BY host|,
                 database: db
               )

      assert {:ok, [%{"volume" => +0.0, "m" => 2.0}]} =
               Local.query_sql(conn, ~s|SELECT 0.0 AS volume, MAX(v) AS m FROM "p"|, database: db)

      assert {:ok, [%{"volume" => +0.0, "m" => 2.0, "t" => ~U[2023-11-14 22:13:00.000000Z]}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT DATE_BIN(INTERVAL '1 minute', time) AS t, 0.0 AS volume, MAX(v) AS m FROM "p" GROUP BY DATE_BIN(INTERVAL '1 minute', time)|,
                 database: db
               )
    end

    test "a constant without an alias is refused with the reason", %{conn: conn, db: db} do
      assert {:error,
              %{
                status: 400,
                body: "Client.Local: unsupported column (a constant needs AS alias): 1"
              }} =
               Local.query_sql(conn, ~s|SELECT 1 FROM "p"|, database: db)
    end
  end

  # ---------------------------------------------------------------------------
  # Write rules verified against InfluxDB 3 Core: partial writes, the column
  # schema fixed by first write, reserved `time`, int64 range, newlines in
  # quoted values (docs/design/2026-09-17_local-write-schema-and-partial-writes.md).
  # ---------------------------------------------------------------------------

  describe "write/3 — schema and partial-write rules" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "wr_db")
      {:ok, db: "wr_db"}
    end

    test "a field's type is fixed by the first write; a later conflict is rejected with the engine's message",
         %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "c v=1i 1700000000000000000", database: db)

      assert {:error, %{status: 400, body: body}} =
               Local.write(conn, "c v=2.0 1700000000000000001", database: db)

      assert partial_errors(body) == [
               {1,
                "invalid column type for column 'v', expected iox::column_type::field::integer, " <>
                  "got iox::column_type::field::float"}
             ]

      # tag then field, field then tag, string then float, boolean then integer
      for {first, second, column, expected, got} <- [
            {"t,host=a v=1i", ~s|t host="b",v=2i|, "host", "iox::column_type::tag",
             "iox::column_type::field::string"},
            {~s|f host="a",v=1i|, "f,host=b v=2i", "host", "iox::column_type::field::string",
             "iox::column_type::tag"},
            {~s|s s="x"|, "s s=1.0", "s", "iox::column_type::field::string",
             "iox::column_type::field::float"},
            {"b b=true", "b b=1i", "b", "iox::column_type::field::boolean",
             "iox::column_type::field::integer"}
          ] do
        {:ok, :written} = Local.write(conn, first, database: db)
        assert {:error, %{status: 400, body: body}} = Local.write(conn, second, database: db)

        assert partial_errors(body) ==
                 [
                   {1,
                    "invalid column type for column '#{column}', expected #{expected}, got #{got}"}
                 ],
               second
      end

      # A new column, and the same measurement in another database, are fine.
      {:ok, :written} = Local.write(conn, "c w=1.0 1700000000000000002", database: db)
      :ok = Local.create_database(conn, "wr_other")
      {:ok, :written} = Local.write(conn, "c v=2.0 1700000000000000000", database: "wr_other")
    end

    test "a bad line is dropped and reported; the other lines are stored", %{conn: conn, db: db} do
      conflict =
        "invalid column type for column 'v', expected iox::column_type::field::integer, " <>
          "got iox::column_type::field::float"

      lp = "p v=1i 1700000000000000000\np v=2.0 1700000000000000001\np v=3i 1700000000000000002"
      assert {:error, %{status: 400, body: body}} = Local.write(conn, lp, database: db)

      assert partial_errors(body) == [{2, conflict}]

      assert {:ok, [%{"v" => 1}, %{"v" => 3}]} =
               Local.query_sql(conn, ~s|SELECT v FROM "p" ORDER BY time|, database: db)

      # A syntax error is reported the same way, with every bad line listed.
      lp =
        "q v=1i 1700000000000000000\nq v=\nq v=2.0 1700000000000000002\nq v=3i 1700000000000000003"

      assert {:error, %{status: 400, body: body}} = Local.write(conn, lp, database: db)

      assert partial_errors(body) == [{2, "No fields were provided"}, {3, conflict}]

      assert {:ok, [%{"v" => 1}, %{"v" => 3}]} =
               Local.query_sql(conn, ~s|SELECT v FROM "q" ORDER BY time|, database: db)
    end

    test "time is a reserved column; a key cannot be both tag and field; an integer must fit int64",
         %{conn: conn, db: db} do
      for {lp, message} <- [
            {"m,time=x v=1i", "'time' is a reserved column"},
            {"m time=5i,v=1i", "'time' is a reserved column"},
            {"m,host=a host=1i",
             "invalid column type for column 'host', expected iox::column_type::tag, got iox::column_type::field::integer"},
            {"m v=9223372036854775808i", "Unable to parse integer value `9223372036854775808`"},
            {"m,host= v=1i", "Expected tag value, got ` v=1i`"},
            {"m,=a v=1i", "Expected tag key, got `=a v=1i`"},
            {"m =1i", "No fields were provided"}
          ] do
        assert {:error, %{status: 400, body: body}} = Local.write(conn, lp, database: db)
        assert [{1, ^message}] = partial_errors(body), lp
      end
    end

    test "on an existing table, time as a tag or field is a column-type conflict with the timestamp",
         %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "e,host=a v=1i 1700000000000000000", database: db)

      for {lp, got} <- [
            {"e,time=x v=1i", "iox::column_type::tag"},
            {"e time=5i,v=1i", "iox::column_type::field::integer"}
          ] do
        assert {:error, %{status: 400, body: body}} = Local.write(conn, lp, database: db)

        assert [{1, message}] = partial_errors(body)

        assert message ==
                 "invalid column type for column 'time', expected iox::column_type::timestamp, got " <>
                   got
      end

      # A rejected line still registers the new columns it names, as the
      # engine does: `n` became a tag on the line that failed on `v`.
      assert {:error, _conflict} = Local.write(conn, "e,n=x v=2.0", database: db)
      assert {:error, %{body: body}} = Local.write(conn, "e n=1i", database: db)

      assert [
               {1,
                "invalid column type for column 'n', expected iox::column_type::tag, got iox::column_type::field::integer"}
             ] = partial_errors(body)
    end

    test "int64 extremes and unsigned integers are accepted", %{conn: conn, db: db} do
      {:ok, :written} =
        Local.write(
          conn,
          "n big=9223372036854775807i,small=-9223372036854775808i,u=18446744073709551615u 1700000000000000000",
          database: db
        )

      assert {:ok,
              [
                %{
                  "big" => 9_223_372_036_854_775_807,
                  "small" => -9_223_372_036_854_775_808,
                  "u" => 18_446_744_073_709_551_615
                }
              ]} =
               Local.query_sql(conn, ~s|SELECT big, small, u FROM "n"|, database: db)
    end

    test "an empty payload is rejected", %{conn: conn, db: db} do
      assert {:error, %{status: 400, body: "incoming write was empty"}} =
               Local.write(conn, "", database: db)

      assert {:error, %{status: 400, body: "incoming write was empty"}} =
               Local.write(conn, "# c\n\n", database: db)
    end

    test "deleting a database drops its points and its schema", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "d v=1i 1700000000000000000", database: db)
      :ok = Local.delete_database(conn, db)
      :ok = Local.create_database(conn, db)

      assert {:error,
              %{status: 400, body: "Error during planning: table 'public.iox.d' not found"}} =
               Local.query_sql(conn, ~s|SELECT v FROM "d"|, database: db)

      # The old integer schema is gone: a float is the first writer now.
      assert {:ok, :written} = Local.write(conn, "d v=2.0 1700000000000000000", database: db)
    end
  end

  # ---------------------------------------------------------------------------
  # Issue #21: LIMIT n OFFSET m. Expected values recorded from InfluxDB 3 Core
  # (docs/design/2026-09-22_local-offset.md).
  # ---------------------------------------------------------------------------

  describe "bug regression — LIMIT and OFFSET (#21)" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "off_db")

      lines =
        for {host, i} <- Enum.with_index(~w(a b c d e)),
            do: "p,host=#{host} v=#{i + 1}i #{1_700_000_000_000_000_000 + i * 1_000_000_000}"

      {:ok, :written} =
        Local.write(conn, Enum.join(lines, "\n"), database: "off_db", precision: :nanosecond)

      {:ok, db: "off_db"}
    end

    test "OFFSET 0 skips nothing and an OFFSET without ORDER BY follows write order",
         %{conn: conn, db: db} do
      assert hosts(conn, db, ~s|SELECT host FROM "p" ORDER BY time LIMIT 2 OFFSET 0|) == [
               "a",
               "b"
             ]

      assert hosts(conn, db, ~s|SELECT host FROM "p" LIMIT 2 OFFSET 1|) == ["b", "c"]
    end

    test "OFFSET applies to grouped, DISTINCT and projected rows too", %{conn: conn, db: db} do
      assert {:ok, [%{"host" => "b", "n" => 1}, %{"host" => "c", "n" => 1}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT host, COUNT(*) AS n FROM "p" GROUP BY host ORDER BY host LIMIT 2 OFFSET 1|,
                 database: db
               )

      assert {:ok, [%{"host" => "c"}, %{"host" => "d"}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT DISTINCT host FROM "p" ORDER BY host LIMIT 2 OFFSET 2|,
                 database: db
               )

      assert {:ok, [%{"twice" => 6}, %{"twice" => 8}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT v * 2 AS twice FROM "p" ORDER BY v LIMIT 2 OFFSET 2|,
                 database: db
               )
    end

    test "the reported pagination query", %{conn: conn, db: db} do
      sql = """
      SELECT *
      FROM "p"
      WHERE time >= '2023-11-14T00:00:00Z'
        AND time < '2023-11-15T00:00:00Z'

      ORDER BY time DESC
      LIMIT 100
      OFFSET 1
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)
      assert Enum.map(rows, & &1["host"]) == ["d", "c", "b", "a"]
    end

    test "a negative or non-numeric OFFSET is the engine's error", %{conn: conn, db: db} do
      assert {:error,
              %{
                status: 400,
                body:
                  "Optimizer rule 'push_down_limit' failed\ncaused by\nError during " <>
                    "planning: OFFSET must be >=0, '-1' was provided"
              }} =
               Local.query_sql(conn, ~s|SELECT host FROM "p" LIMIT 2 OFFSET -1|, database: db)

      assert {:error, %{status: 500, body: "Schema error: No field named abc."}} =
               Local.query_sql(conn, ~s|SELECT host FROM "p" LIMIT 2 OFFSET abc|, database: db)
    end
  end

  # ---------------------------------------------------------------------------
  # Write rules under the :v2 profile, verified against InfluxDB 2.7
  # (docs/design/2026-09-22_local-v2-write-rules.md).
  # ---------------------------------------------------------------------------

  describe "write/3 — :v2 profile schema and partial-write rules" do
    setup do
      {:ok, conn} = Local.start(profile: :v2)
      :ok = Local.create_bucket(conn, "metrics")
      on_exit(fn -> Local.stop(conn) end)
      {:ok, conn: conn}
    end

    test "a field type conflict is a 422 partial write naming the first conflict and the dropped count",
         %{conn: conn} do
      {:ok, :written} = Local.write(conn, "d1 v=1i 1700000000000000000", database: "metrics")

      lp =
        "d1 v=2.0 1700000000000000001\nd1 v=3.0 1700000000000000002\nd1 v=4i 1700000000000000003"

      assert {:error, %{status: 422, body: body}} = Local.write(conn, lp, database: "metrics")

      assert Jason.decode!(body) == %{
               "code" => "unprocessable entity",
               "message" =>
                 "failure writing points to database: partial write: field type conflict: " <>
                   ~s|input field "v" on measurement "d1" is type float, already exists as type | <>
                   "integer dropped=2"
             }

      # The good lines were stored (Flux returns one row per field value).
      assert {:ok, rows} =
               Local.query_flux(conn, v2_flux("d1"))

      assert Enum.map(rows, & &1["_value"]) == [1, 4]

      for {first, second, measurement, field, existing, got} <- [
            {~s|s s="x"|, "s s=1.0", "s", "s", "string", "float"},
            {"b b=true", "b b=1i", "b", "b", "boolean", "integer"},
            {"u v=1i", "u v=2u", "u", "v", "integer", "unsigned"}
          ] do
        {:ok, :written} = Local.write(conn, first, database: "metrics")

        assert {:error, %{status: 422, body: body}} =
                 Local.write(conn, second, database: "metrics")

        assert Jason.decode!(body)["message"] ==
                 "failure writing points to database: partial write: field type conflict: " <>
                   ~s|input field "#{field}" on measurement "#{measurement}" is type #{got}, | <>
                   "already exists as type #{existing} dropped=1"
      end
    end

    test "a line that fails to parse rejects the whole payload with 400 and stores nothing",
         %{conn: conn} do
      lp = "p2 v=1i 1700000000000000000\np2 v=\np2 v=3i 1700000000000000002"
      assert {:error, %{status: 400, body: body}} = Local.write(conn, lp, database: "metrics")

      assert %{
               "code" => "invalid",
               "message" => "unable to parse 'p2 v=': missing field value"
             } =
               Jason.decode!(body)

      assert {:ok, []} =
               Local.query_flux(conn, v2_flux("p2"))

      assert {:error, %{status: 400, body: body}} =
               Local.write(conn, "p3 v=9223372036854775808i 1700000000000000000",
                 database: "metrics"
               )

      assert Jason.decode!(body) == %{
               "code" => "invalid",
               "message" =>
                 "unable to parse 'p3 v=9223372036854775808i 1700000000000000000': " <>
                   "unable to parse integer 9223372036854775808: strconv.ParseInt: " <>
                   "parsing \"9223372036854775808\": value out of range"
             }

      # Every failed line is reported, joined by a newline.
      two_bad = "p4 v=1i 1\np4 v=\np4 v=2i 2\np4 w=9223372036854775808i 3"

      assert {:error, %{status: 400, body: body}} =
               Local.write(conn, two_bad, database: "metrics")

      assert Jason.decode!(body) == %{
               "code" => "invalid",
               "message" =>
                 "unable to parse 'p4 v=': missing field value\n" <>
                   "unable to parse 'p4 w=9223372036854775808i 3': unable to parse integer " <>
                   "9223372036854775808: strconv.ParseInt: parsing \"9223372036854775808\": " <>
                   "value out of range"
             }
    end

    test "time as a tag is refused; time as a field is dropped silently; a tag and a field may share a name; an empty payload is accepted",
         %{conn: conn} do
      assert {:error, %{status: 400, body: body}} =
               Local.write(conn, "t1,time=x v=1i 1700000000000000000", database: "metrics")

      assert Jason.decode!(body) == %{
               "code" => "invalid",
               "message" =>
                 "unable to parse 't1,time=x v=1i 1700000000000000000': " <>
                   ~s|cannot use reserved tag key "time"|
             }

      {:ok, :written} =
        Local.write(conn, "t2 time=5i,v=1i 1700000000000000000", database: "metrics")

      assert {:ok, [%{"_field" => "v", "_value" => 1}]} =
               Local.query_flux(conn, v2_flux("t2"))

      {:ok, :written} =
        Local.write(conn, "t3,host=a host=1i 1700000000000000000", database: "metrics")

      {:ok, :written} =
        Local.write(conn, "t3,host=b v=2i 1700000000000000001", database: "metrics")

      assert {:ok, rows} = Local.query_flux(conn, v2_flux("t3"))

      assert rows |> Enum.map(&{&1["host"], &1["_field"], &1["_value"]}) |> Enum.sort() ==
               [{"a", "host", 1}, {"b", "v", 2}]

      assert {:ok, :written} = Local.write(conn, "", database: "metrics")
      assert {:ok, :written} = Local.write(conn, "# only a comment\n", database: "metrics")
    end

    test "precision takes ns, us, ms, s and the long names; auto and the rest are the v2 400",
         %{conn: conn} do
      for precision <- [:ms, "ms", :millisecond, "millisecond"] do
        {:ok, :written} =
          Local.write(conn, "pr value=1i 1700000000000",
            database: "metrics",
            precision: precision
          )
      end

      assert {:ok, rows} = Local.query_flux(conn, v2_flux("pr"))
      assert Enum.map(rows, & &1["_time"]) |> Enum.uniq() == [~U[2023-11-14 22:13:20.000000Z]]

      for precision <- [:auto, :bogus, "NS"] do
        assert {:error, %{status: 400, body: body}} =
                 Local.write(conn, "pr value=1i 1", database: "metrics", precision: precision)

        assert Jason.decode!(body) == %{
                 "code" => "invalid",
                 "message" => "invalid precision; valid precision units are ns, us, ms, and s"
               }
      end
    end
  end

  describe "write/3 — escapes take the careful splitter" do
    # Plain text is split with :binary.split/3; a backslash or a quote
    # sends the token through the escape-aware scan. Both must agree.
    setup do
      {:ok, conn} = Local.start(databases: ["esc"])
      on_exit(fn -> Local.stop(conn) end)
      {:ok, conn: conn}
    end

    test "an escaped equals sign in a tag key and an escaped backslash in a string",
         %{conn: conn} do
      lp = ~S"""
      e,a\=b=x s="ends\\",v=1i 1700000000000000000
      e,a\=b=y s="line1
      line2",v=2i 1700000000000000001
      """

      assert {:ok, :written} = Local.write(conn, String.trim(lp), database: "esc")

      assert {:ok, rows} = Local.query_sql(conn, "SELECT * FROM e ORDER BY time", database: "esc")

      assert Enum.map(rows, &{&1["a=b"], &1["s"], &1["v"]}) == [
               {"x", "ends\\", 1},
               {"y", "line1\nline2", 2}
             ]
    end

    test "a name ending in a backslash is refused on v3; v2 keeps `\\\\,` in a measurement",
         %{conn: conn} do
      message = "Measurements, tag keys and values, and field keys may not end with a backslash"

      for lp <- [~S"bs\\,t=a v=1i 1", ~S"bt,k\\=a v=2i 1", ~S"bv,t=a\\ v=1i 1", ~S"bf k\\=1i 1"] do
        assert {:error, %{status: 400, body: body}} = Local.write(conn, lp, database: "esc")
        assert [{1, ^message}] = partial_errors(body), lp
      end

      {:ok, v2} = Local.start(profile: :v2)
      on_exit(fn -> Local.stop(v2) end)
      :ok = Local.create_bucket(v2, "b")

      assert {:ok, :written} = Local.write(v2, ~S"bs\\,t=a v=1i 1", database: "b")

      assert {:ok, [%{"_measurement" => ~S"bs\,t=a"}]} =
               Local.query_flux(v2, ~s|from(bucket: "b") \|> range(start: 0)|)

      assert {:error, %{status: 400, body: body}} =
               Local.write(v2, ~S"bt,k\\=a v=2i 1", database: "b")

      assert Jason.decode!(body) == %{
               "code" => "invalid",
               "message" => ~S"unable to parse 'bt,k\\=a v=2i 1': missing tag value"
             }
    end
  end

  # ---------------------------------------------------------------------------
  # Duplicate points: same measurement, tags and timestamp are one point.
  # Verified against InfluxDB 3 and 2.7
  # (docs/design/2026-09-23_precision-spellings-and-connection-plumbing.md).
  # ---------------------------------------------------------------------------

  describe "write/3 — a point rewritten at the same tags and time" do
    setup do
      {:ok, conn} = Local.start(databases: ["dup"], profile: :v3_enterprise)
      on_exit(fn -> Local.stop(conn) end)
      {:ok, conn: conn, db: "dup"}
    end

    @t "1700000000000000000"

    test "the later write wins per field and the fields merge", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "a,h=x v=1i #{@t}", database: db)
      {:ok, :written} = Local.write(conn, "a,h=x v=2i #{@t}", database: db)

      assert {:ok, [%{"h" => "x", "v" => 2}]} =
               Local.query_sql(conn, "SELECT * FROM a", database: db)

      {:ok, :written} = Local.write(conn, "b,h=x v=1i #{@t}", database: db)
      {:ok, :written} = Local.write(conn, "b,h=x w=2i #{@t}", database: db)

      assert {:ok, [%{"v" => 1, "w" => 2}]} =
               Local.query_sql(conn, "SELECT * FROM b", database: db)

      {:ok, :written} = Local.write(conn, "c,h=x v=1i,w=1i #{@t}", database: db)
      {:ok, :written} = Local.write(conn, "c,h=x v=2i #{@t}", database: db)

      assert {:ok, [%{"v" => 2, "w" => 1}]} =
               Local.query_sql(conn, "SELECT * FROM c", database: db)
    end

    test "a different tag value is another point; the same series at another time too",
         %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "d,h=x v=1i #{@t}\nd,h=y v=2i #{@t}", database: db)
      {:ok, :written} = Local.write(conn, "d,h=x v=3i 1700000000000000001", database: db)

      assert {:ok, rows} = Local.query_sql(conn, "SELECT h, v FROM d ORDER BY v", database: db)
      assert rows == [%{"h" => "x", "v" => 1}, %{"h" => "y", "v" => 2}, %{"h" => "x", "v" => 3}]
    end

    test "within one payload the last line wins; aggregates see one point", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "e,h=x v=1i #{@t}\ne,h=x v=2i #{@t}", database: db)
      {:ok, :written} = Local.write(conn, "e v=5i #{@t}\ne v=6i #{@t}", database: db)

      assert {:ok, [%{"n" => 2, "s" => 8}]} =
               Local.query_sql(conn, "SELECT COUNT(v) AS n, SUM(v) AS s FROM e", database: db)

      assert {:ok, [%{"v" => 6}]} =
               Local.query_sql(conn, "SELECT v FROM e WHERE h IS NULL", database: db)
    end

    test "DELETE removes the merged point and counts it once", %{conn: conn, db: db} do
      {:ok, :written} =
        Local.write(conn, "f,h=x v=1i #{@t}\nf,h=x w=1i #{@t}\nf,h=y v=9i #{@t}", database: db)

      assert {:ok, %{"rows_affected" => 1}} =
               Local.execute_sql(conn, "DELETE FROM f WHERE w = 1", database: db)

      assert {:ok, [%{"h" => "y", "v" => 9}]} =
               Local.query_sql(conn, "SELECT * FROM f", database: db)
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxQL answers in InfluxDB 3's shape, and sub-microsecond time in SQL.
  # Every expectation below was taken from influxdb:3-core
  # (docs/design/2026-09-23_local-influxql.md).
  # ---------------------------------------------------------------------------

  describe "query_influxql/3 — the engine's InfluxQL answers" do
    setup do
      {:ok, conn} = Local.start(databases: ["iq"])
      on_exit(fn -> Local.stop(conn) end)

      lp = """
      o,h=x v=3i 1700000000000003000
      o,h=y v=1i 1700000000000001000
      o,h=x v=2i 1700000000000002000
      o,h=y w=9i 1700000000000004000
      u x=5u 1700000000000000000
      """

      {:ok, :written} = Local.write(conn, String.trim(lp), database: "iq")
      {:ok, conn: conn}
    end

    test "a SELECT carries iox::measurement and time, in time order, dropping rows with no selected field",
         %{conn: conn} do
      assert {:ok, rows} = iq_query(conn, "SELECT v FROM o")

      assert rows == [
               %{"iox::measurement" => "o", "time" => iq_time(1), "v" => 1},
               %{"iox::measurement" => "o", "time" => iq_time(2), "v" => 2},
               %{"iox::measurement" => "o", "time" => iq_time(3), "v" => 3}
             ]

      assert {:ok, [%{"vee" => 1} | _rest]} = iq_query(conn, "SELECT v AS vee FROM o")
      assert {:ok, [%{"w" => 9, "time" => time}]} = iq_query(conn, "SELECT w FROM o")
      assert time == iq_time(4)
      assert {:ok, []} = iq_query(conn, "SELECT h FROM o")
    end

    test "an unknown column or measurement is an empty result, not an error", %{conn: conn} do
      assert {:ok, []} = iq_query(conn, "SELECT v FROM nope WHERE h = 'x'")
      assert {:ok, []} = iq_query(conn, "SELECT v FROM o WHERE nosuch = 'x'")
      assert {:ok, []} = iq_query(conn, "SELECT MEAN(nothere) FROM o")
    end

    test "aggregates are named after the function and put time at the epoch", %{conn: conn} do
      epoch = DateTime.from_unix!(0, :microsecond)

      assert {:ok,
              [
                %{
                  "iox::measurement" => "o",
                  "time" => ^epoch,
                  "sum" => 6,
                  "mean" => 2.0,
                  "count" => 3
                }
              ]} =
               iq_query(conn, "SELECT SUM(v), MEAN(v), COUNT(v) FROM o")

      assert {:ok, [%{"total" => 6}]} = iq_query(conn, "SELECT SUM(v) AS total FROM o")

      assert {:ok, [%{"min" => 1, "min_1" => 9}]} =
               iq_query(conn, "SELECT MIN(v), MIN(w) FROM o")

      assert {:ok, [%{"time" => ^epoch, "count_v" => 3, "count_w" => 1}]} =
               iq_query(conn, "SELECT COUNT(*) FROM o")
    end

    test "a lone FIRST selector returns its point's time", %{conn: conn} do
      assert {:ok, [%{"first" => 1, "time" => first}]} =
               iq_query(conn, "SELECT FIRST(v) FROM o")

      assert first == iq_time(1)
    end

    test "GROUP BY orders series by tag; ORDER BY time DESC and MEAN apply per series",
         %{conn: conn} do
      assert {:ok, rows} = iq_query(conn, "SELECT v FROM o GROUP BY h ORDER BY time DESC")
      assert Enum.map(rows, &{&1["h"], &1["v"]}) == [{"x", 3}, {"x", 2}, {"y", 1}]

      assert {:ok, rows} = iq_query(conn, "SELECT MEAN(v) FROM o GROUP BY h")
      assert Enum.map(rows, &{&1["h"], &1["mean"]}) == [{"x", 2.5}, {"y", 1.0}]
    end

    test "SHOW FIELD KEYS, SHOW TAG KEYS and SHOW DATABASES", %{conn: conn} do
      assert {:ok, [%{"iox::measurement" => "u", "fieldKey" => "x", "fieldType" => "unsigned"}]} =
               iq_query(conn, "SHOW FIELD KEYS FROM u")

      assert {:ok, keys} = iq_query(conn, "SHOW FIELD KEYS")

      assert Enum.map(keys, &{&1["iox::measurement"], &1["fieldKey"]}) == [
               {"o", "v"},
               {"o", "w"},
               {"u", "x"}
             ]

      assert {:ok, [%{"iox::measurement" => "o", "tagKey" => "h"}]} =
               iq_query(conn, "SHOW TAG KEYS")

      assert {:ok, []} = iq_query(conn, "SHOW TAG KEYS FROM nope")
      assert {:ok, dbs} = iq_query(conn, "SHOW DATABASES")
      assert %{"iox::database" => "iq", "deleted" => false} in dbs
    end

    test "constructs the double does not model are refused by name", %{conn: conn} do
      for {statement, body} <- [
            {"SELECT MEAN(v) FROM o WHERE time > 0 GROUP BY time(1m)",
             "Client.Local: unsupported InfluxQL (GROUP BY time(...)): " <>
               "SELECT MEAN(v) FROM o WHERE time > 0 GROUP BY time(1m)"},
            {"SELECT v FROM o WHERE time > now() - 500ms",
             "Client.Local: unsupported InfluxQL (sub-second duration 500ms)"},
            {"SHOW TAG VALUES WITH KEY = h LIMIT 1",
             "Client.Local: unsupported InfluxQL (SHOW TAG VALUES with LIMIT/OFFSET): " <>
               "SHOW TAG VALUES WITH KEY = h LIMIT 1"},
            {"SELECT MEDIAN(v) FROM o",
             "Client.Local: unsupported InfluxQL function: MEDIAN(v): SELECT MEDIAN(v) FROM o"},
            {"SELECT SUM(*) FROM o",
             "Client.Local: unsupported InfluxQL (sum(*)): SELECT SUM(*) FROM o"},
            {"SELECT MEAN(v), h FROM o",
             "Client.Local: unsupported InfluxQL (columns beside aggregates other than one " <>
               "selector): SELECT MEAN(v), h FROM o"}
          ] do
        assert {:error, %{status: 400, body: ^body}} = iq_query(conn, statement)
      end

      # NOT is no InfluxQL keyword: the engine's parse error, not a refusal.
      assert {:error,
              %{
                status: 400,
                body:
                  "error in InfluxQL statement: parsing error: invalid InfluxQL statement at " <>
                    "pos 26. Parsing Error: Nom(\"h = 'x'\", Tag)"
              }} = iq_query(conn, "SELECT v FROM o WHERE NOT h = 'x'")
    end
  end

  describe "query_sql/3 — time below a microsecond" do
    setup do
      {:ok, conn} = Local.start(databases: ["ns"])
      on_exit(fn -> Local.stop(conn) end)
      lp = "o v=3i 1700000000000000300\no v=1i 1700000000000000100\no v=2i 1700000000000000200"
      {:ok, :written} = Local.write(conn, lp, database: "ns")
      {:ok, conn: conn}
    end

    test "ORDER BY time DESC and an aliased time order points less than a microsecond apart",
         %{conn: conn} do
      for {sql, expected} <- [
            {"SELECT * FROM o ORDER BY time DESC", [3, 2, 1]},
            {"SELECT time AS t, v FROM o ORDER BY t", [1, 2, 3]}
          ] do
        assert {:ok, rows} = Local.query_sql(conn, sql, database: "ns")
        assert Enum.map(rows, & &1["v"]) == expected, sql
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Flux pipelines: every stage applied or refused. Expectations taken from
  # influxdb:2.7 (docs/design/2026-09-24_local-flux-pipeline.md).
  # ---------------------------------------------------------------------------

  describe "query_flux/3 — every stage is applied or refused" do
    setup do
      {:ok, conn} = Local.start(profile: :v2)
      on_exit(fn -> Local.stop(conn) end)
      :ok = Local.create_bucket(conn, "b")

      lp = """
      cpu,host=a v=1.0,n=1i 1700000000000000000
      cpu,host=a v=3.0,n=2i 1700000060000000000
      cpu,host=b v=5.0,n=3i 1700000000000000000
      """

      {:ok, :written} = Local.write(conn, String.trim(lp), database: "b")
      {:ok, conn: conn}
    end

    test "tables are series in measurement, tag, field order; rows carry _start and _stop",
         %{conn: conn} do
      assert {:ok, rows} = flux_b(conn, "")

      assert Enum.map(rows, &{&1["table"], &1["host"], &1["_field"]}) == [
               {0, "a", "n"},
               {0, "a", "n"},
               {1, "a", "v"},
               {1, "a", "v"},
               {2, "b", "n"},
               {3, "b", "v"}
             ]

      assert Enum.all?(rows, &(&1["_start"] == ~U[1970-01-01 00:00:00.000000Z]))
      assert Enum.all?(rows, &(&1["_stop"] == ~U[2027-01-15 08:00:00.000000Z]))
    end

    test "filter predicates: or, !=, not, numeric _value, r[\"key\"], a missing key",
         %{conn: conn} do
      v = ~s| \|> filter(fn: (r) => r._field == "v"|

      assert {:ok, rows} = flux_b(conn, v <> ~s| and (r.host == "a" or r.host == "b"))|)
      assert flux_values(rows) == [{0, "a", 1.0}, {0, "a", 3.0}, {1, "b", 5.0}]

      assert {:ok, [%{"host" => "b", "_value" => 5.0}]} =
               flux_b(conn, v <> ~s| and r.host != "a")|)

      assert {:ok, rows} = flux_b(conn, ~s| \|> filter(fn: (r) => r._value > 2.0)|)
      assert flux_values(rows) == [{0, "a", 3.0}, {1, "b", 3}, {2, "b", 5.0}]
      assert {:ok, rows} = flux_b(conn, ~s| \|> filter(fn: (r) => not (r.host == "a"))|)
      assert Enum.map(rows, & &1["host"]) == ["b", "b"]
      assert {:ok, rows} = flux_b(conn, ~s| \|> filter(fn: (r) => r["host"] == "b")|)
      assert Enum.map(rows, &{&1["host"], &1["_field"]}) == [{"b", "n"}, {"b", "v"}]
      assert {:ok, []} = flux_b(conn, ~s| \|> filter(fn: (r) => r.nosuch == "x")|)
    end

    test "selectors keep their row; mean, sum and count drop _time; limit is per table",
         %{conn: conn} do
      v = ~s| \|> filter(fn: (r) => r._field == "v")|
      assert {:ok, rows} = flux_b(conn, v <> " |> last()")
      assert flux_values(rows) == [{0, "a", 3.0}, {1, "b", 5.0}]

      assert Enum.map(rows, & &1["_time"]) == [
               ~U[2023-11-14 22:14:20.000000Z],
               ~U[2023-11-14 22:13:20.000000Z]
             ]

      assert {:ok, rows} = flux_b(conn, v <> " |> max()")
      assert flux_values(rows) == [{0, "a", 3.0}, {1, "b", 5.0}]

      assert {:ok, rows} = flux_b(conn, v <> " |> mean()")
      assert flux_values(rows) == [{0, "a", 2.0}, {1, "b", 5.0}]
      refute Enum.any?(rows, &Map.has_key?(&1, "_time"))
      assert {:ok, rows} = flux_b(conn, ~s| \|> filter(fn: (r) => r._field == "n") \|> sum()|)
      assert flux_values(rows) == [{0, "a", 3}, {1, "b", 3}]
      assert {:ok, rows} = flux_b(conn, v <> " |> count()")
      assert flux_values(rows) == [{0, "a", 2}, {1, "b", 1}]

      assert {:ok, [%{"host" => "a", "_value" => 3.0}]} =
               flux_b(conn, v <> " |> limit(n: 1, offset: 1)")

      assert {:ok, [%{"_value" => 5.0, "table" => 0}]} =
               flux_b(conn, v <> " |> mean() |> filter(fn: (r) => r._value > 2.0)")

      assert {:ok, rows} = flux_b(conn, v <> ~s| \|> yield(name: "x")|)
      assert Enum.map(rows, &{&1["result"], &1["_value"]}) == [{"x", 1.0}, {"x", 3.0}, {"x", 5.0}]
    end

    test "range(stop:) and an RFC3339 start bound the rows", %{conn: conn} do
      assert {:ok, rows} =
               Local.query_flux(
                 conn,
                 ~s|from(bucket: "b") \|> range(start: 0, stop: 1700000030) \|> filter(fn: (r) => r._field == "v")|
               )

      assert Enum.map(rows, & &1["_value"]) == [1.0, 5.0]

      assert {:ok, [%{"_value" => 3.0}]} =
               Local.query_flux(
                 conn,
                 ~s|from(bucket: "b") \|> range(start: 2023-11-14T22:14:00Z) \|> filter(fn: (r) => r._field == "v")|
               )
    end

    test "a stage the double does not model is refused by name, never skipped", %{conn: conn} do
      for {tail, message} <- [
            {" |> aggregateWindow(every: 1m, fn: mean)",
             "Client.Local: unsupported Flux function: aggregateWindow()"},
            {~s| \|> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")|,
             "Client.Local: unsupported Flux function: pivot()"},
            {" |> group()", "Client.Local: unsupported Flux function: group()"},
            {" |> sort()", "Client.Local: unsupported Flux function: sort()"},
            {~s| \|> filter(fn: (r) => r.host =~ /a/)|,
             "Client.Local: unsupported filter predicate: r.host =~ /a/"}
          ] do
        assert {:error, %{status: 400, body: body}} = flux_b(conn, tail)
        assert Jason.decode!(body) == %{"code" => "invalid", "message" => message}, tail
      end
    end
  end

  # ---------------------------------------------------------------------------
  # GROUP BY / ORDER BY by position and alias; DATE_BIN with grouping
  # columns. Expectations taken from influxdb:3-core
  # (docs/design/2026-09-24_sql-references-and-stream-types.md).
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — GROUP BY and ORDER BY references" do
    setup do
      {:ok, conn} = Local.start(databases: ["g"])
      on_exit(fn -> Local.stop(conn) end)

      lp = """
      m,h=a v=1.5,n=2i 1700000000000000000
      m,h=b v=2.5,n=4i 1700000000123456789
      m,h=a v=3.5,n=6i 1700000090000000000
      """

      {:ok, :written} = Local.write(conn, String.trim(lp), database: "g")
      {:ok, conn: conn}
    end

    test "DATE_BIN with a grouping column gives a row per bucket per value", %{conn: conn} do
      expected = [
        %{"bucket" => ~U[2023-11-14 22:13:00.000000Z], "h" => "a", "c" => 1},
        %{"bucket" => ~U[2023-11-14 22:13:00.000000Z], "h" => "b", "c" => 1},
        %{"bucket" => ~U[2023-11-14 22:14:00.000000Z], "h" => "a", "c" => 1}
      ]

      select = "SELECT DATE_BIN(INTERVAL '1 minute', time) AS bucket, h, COUNT(v) AS c FROM m"

      for group <- ["DATE_BIN(INTERVAL '1 minute', time), h", "bucket, h", "1, 2"] do
        assert {:ok, ^expected} = g_query(conn, "#{select} GROUP BY #{group} ORDER BY bucket, h"),
               group
      end
    end

    test "a select alias or a position names the grouping column", %{conn: conn} do
      expected = [%{"host" => "a", "s" => 8}, %{"host" => "b", "s" => 4}]

      assert {:ok, ^expected} =
               g_query(conn, "SELECT h AS host, SUM(n) AS s FROM m GROUP BY host ORDER BY host")

      assert {:ok, ^expected} =
               g_query(conn, "SELECT h AS host, SUM(n) AS s FROM m GROUP BY 1 ORDER BY 1")
    end

    test "ORDER BY a position sorts by that select item", %{conn: conn} do
      assert {:ok, rows} = g_query(conn, "SELECT h, v FROM m ORDER BY 2 DESC")
      assert Enum.map(rows, & &1["v"]) == [3.5, 2.5, 1.5]

      assert {:ok, [%{"h" => "a", "c" => 2}, %{"h" => "b", "c" => 1}]} =
               g_query(conn, "SELECT h, COUNT(v) AS c FROM m GROUP BY h ORDER BY 2 DESC")
    end

    test "a position outside the select list is the engine's planning error", %{conn: conn} do
      assert {:error, %{status: 400, body: body}} = g_query(conn, "SELECT h, v FROM m GROUP BY 3")

      assert body ==
               "Error during planning: Cannot find column with position 3 in SELECT clause. " <>
                 "Valid columns: 1 to 2"
    end
  end

  # ---------------------------------------------------------------------------
  # NULL semantics, LIKE escapes, bare booleans, % and unary minus.
  # Expectations taken from influxdb:3-core
  # (docs/design/2026-09-25_local-sql-nulls-and-operators.md).
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — nulls and operators as DataFusion has them" do
    setup do
      {:ok, conn} = Local.start(databases: ["nl"])
      on_exit(fn -> Local.stop(conn) end)

      lp = """
      t,host=a,rack=1 v=1.5,n=2i,s="alpha",b=true 1700000000000000000
      t,host=a,rack=2 v=-3.25,n=7i,s="Beta",b=false 1700000060000000000
      t,host=b,rack=1 v=10.0,n=-4i,s="gamma" 1700000120000000000
      t,host=b n=0i,b=true 1700000180000000000
      t,host=c,rack=3 v=0.5,s="al%pha" 1700000240000000000
      """

      {:ok, :written} = Local.write(conn, String.trim(lp), database: "nl")
      {:ok, conn: conn}
    end

    test "nulls sort last ascending, first descending, and where NULLS says", %{conn: conn} do
      racks = fn sql -> conn |> nl_rows(sql) |> Enum.map(& &1["rack"]) end

      assert racks.("SELECT rack FROM t ORDER BY rack, time") == ["1", "1", "2", "3", nil]
      assert racks.("SELECT rack FROM t ORDER BY rack DESC, time") == [nil, "3", "2", "1", "1"]

      assert racks.("SELECT rack FROM t ORDER BY rack NULLS FIRST, time") == [
               nil,
               "1",
               "1",
               "2",
               "3"
             ]

      assert racks.("SELECT rack FROM t ORDER BY rack DESC NULLS LAST, time") == [
               "3",
               "2",
               "1",
               "1",
               nil
             ]

      assert Enum.map(
               nl_rows(conn, "SELECT rack, COUNT(*) AS c FROM t GROUP BY rack ORDER BY rack"),
               & &1["rack"]
             ) ==
               ["1", "2", "3", nil]
    end

    test "NOT, NOT IN and NOT BETWEEN over a null are unknown, so the row is dropped",
         %{conn: conn} do
      hosts = fn sql -> conn |> nl_rows(sql) |> Enum.map(& &1["host"]) end

      assert hosts.("SELECT host FROM t WHERE NOT (rack = '1') ORDER BY time") == ["a", "c"]
      assert hosts.("SELECT host FROM t WHERE NOT (v > 0) ORDER BY time") == ["a"]
      assert hosts.("SELECT host FROM t WHERE rack NOT IN ('1') ORDER BY time") == ["a", "c"]
      assert hosts.("SELECT host FROM t WHERE v NOT BETWEEN 0 AND 2 ORDER BY time") == ["a", "b"]

      assert hosts.("SELECT host FROM t WHERE v > 0 OR rack = '3' ORDER BY time") == [
               "a",
               "b",
               "c"
             ]
    end

    test "a backslash makes % and _ literal in ILIKE and in a pattern with no match",
         %{conn: conn} do
      assert [%{"s" => "al%pha"}] = nl_rows(conn, ~S"SELECT s FROM t WHERE s ILIKE 'AL\%%'")
      assert [] = nl_rows(conn, ~S"SELECT s FROM t WHERE s LIKE 'al\_ha'")
    end

    test "a boolean column is a predicate; a non-boolean one is the planning error",
         %{conn: conn} do
      assert Enum.map(nl_rows(conn, "SELECT host FROM t WHERE b ORDER BY time"), & &1["host"]) ==
               [
                 "a",
                 "b"
               ]

      assert Enum.map(nl_rows(conn, "SELECT host FROM t WHERE NOT b ORDER BY time"), & &1["host"]) ==
               [
                 "a"
               ]

      assert [%{"host" => "a"}] = nl_rows(conn, "SELECT host FROM t WHERE b AND n > 0")

      assert {:error, %{status: 400, body: body}} =
               Local.query_sql(conn, "SELECT host FROM t WHERE n", database: "nl")

      assert body ==
               "Error during planning: Cannot create filter with non-boolean predicate 't.n' returning Int64"
    end

    test "% keeps the dividend's sign and works on floats; unary minus negates", %{conn: conn} do
      assert Enum.map(nl_rows(conn, "SELECT n % 3 AS m FROM t ORDER BY time"), & &1["m"]) == [
               2,
               1,
               -1,
               0,
               nil
             ]

      assert Enum.map(nl_rows(conn, "SELECT v % 2 AS m FROM t ORDER BY time"), & &1["m"]) == [
               1.5,
               -1.25,
               0.0,
               nil,
               0.5
             ]

      assert Enum.map(nl_rows(conn, "SELECT -n AS x FROM t ORDER BY time"), & &1["x"]) == [
               -2,
               -7,
               4,
               0,
               nil
             ]

      assert [%{"host" => "b"}] = nl_rows(conn, "SELECT host FROM t WHERE -n > 0")
    end
  end

  # ---------------------------------------------------------------------------
  # accept_partial: false and no_sync; the engine's rendering of a line in a
  # schema error. Expectations taken from influxdb:3-core
  # (docs/design/2026-09-25_atomic-writes-and-no-sync.md).
  # ---------------------------------------------------------------------------

  describe "write/3 — accept_partial: false, no_sync" do
    setup do
      {:ok, conn} = Local.start(databases: ["aw"])
      on_exit(fn -> Local.stop(conn) end)
      {:ok, conn: conn}
    end

    test "the first bad line in line order rejects the whole payload", %{conn: conn} do
      assert {:error, %{status: 400, body: body}} =
               Local.write(conn, "m1 v=1i 1\nm1 v=\nm1 x=\nm1 v=3i 3",
                 database: "aw",
                 accept_partial: false
               )

      assert atomic_error(body) == {2, "No fields were provided", "m1 v="}

      assert {:error,
              %{status: 400, body: "Error during planning: table 'public.iox.m1' not found"}} =
               Local.query_sql(conn, "SELECT * FROM m1", database: "aw")
    end

    test "a conflict with an earlier line of the payload rejects it and registers no schema",
         %{conn: conn} do
      assert {:error, %{status: 400, body: body}} =
               Local.write(conn, "m2 v=1i 1\nm2 v=2.0 2", database: "aw", accept_partial: false)

      assert atomic_error(body) ==
               {2,
                "invalid column type for column 'v', expected iox::column_type::field::integer, got iox::column_type::field::float",
                "m2 v=2 2"}

      # Nothing was registered: a float is now the first kind of `v`.
      assert {:ok, :written} = Local.write(conn, "m2 v=3.5 3", database: "aw")
      assert {:ok, [%{"v" => 3.5}]} = Local.query_sql(conn, "SELECT v FROM m2", database: "aw")
    end

    test "a clean payload is stored whole; no_sync is accepted", %{conn: conn} do
      assert {:ok, :written} =
               Local.write(conn, "m3 v=1i 1\nm3 v=2i 2",
                 database: "aw",
                 accept_partial: false,
                 no_sync: true
               )

      assert {:ok, [%{"v" => 1}, %{"v" => 2}]} =
               Local.query_sql(conn, "SELECT v FROM m3 ORDER BY time", database: "aw")
    end

    test "time as a tag on a new table is the reserved-column error", %{conn: conn} do
      assert {:error, %{body: body}} =
               Local.write(conn, "m4,time=x v=1i 1", database: "aw", accept_partial: false)

      assert atomic_error(body) == {1, "'time' is a reserved column", "m4,time=x v=1i 1"}
    end

    test "a flag that is not a boolean is the engine's 400", %{conn: conn} do
      for key <- [:accept_partial, :no_sync] do
        assert {:error,
                %{status: 400, body: "serde error: provided string was not `true` or `false`"}} =
                 Local.write(conn, "m5 v=1i 1", [{:database, "aw"}, {key, "yes"}])
      end
    end

    test "the :v2 profile has neither parameter and ignores them" do
      {:ok, v2} = Local.start(profile: :v2)
      on_exit(fn -> Local.stop(v2) end)
      :ok = Local.create_bucket(v2, "b")

      assert {:ok, :written} = Local.write(v2, "m v=1i 1", database: "b", accept_partial: "yes")
    end

    test "a schema error shows the line as the engine renders it", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "r v=1i,a=1i 1", database: "aw")

      for {lp, rendered} <- [
            {"r    v=2.50,a=3i   2", "r v=2.5,a=3i 2"},
            {"r,t=x v=1e3 4", "r,t=x v=1000 4"},
            {~s(r v="s" 6), "r v=s 6"},
            {"r v=1.5e-7 8", "r v=0.00000015 8"}
          ] do
        assert {:error, %{body: body}} = Local.write(conn, lp, database: "aw")
        assert [%{"original_line" => ^rendered}] = Jason.decode!(body)["data"], lp
      end
    end
  end
end
