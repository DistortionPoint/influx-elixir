defmodule InfluxElixir.Client.LocalTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

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

  # {line_number, error_message} pairs from a partial-write response body.
  defp v2_flux(measurement) do
    ~s'from(bucket: "metrics") |> range(start: 0) |> filter(fn: (r) => r._measurement == "#{measurement}")'
  end

  defp partial_errors(body) do
    %{"error" => "partial write of line protocol occurred", "data" => data} = Jason.decode!(body)
    Enum.map(data, &{&1["line_number"], &1["error_message"]})
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
      refute Local.supports?(core, :create_token)

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
    test "creates and cleans up ETS table" do
      {:ok, conn} = Local.start()
      assert is_reference(conn.table)
      assert :ok = Local.stop(conn)
      assert :ets.info(conn.table) == :undefined
    end

    test "pre-creates databases from options" do
      {:ok, conn} = Local.start(databases: ["db1", "db2"])
      assert MapSet.member?(conn.databases, "db1")
      assert MapSet.member?(conn.databases, "db2")
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

    test "stores :database singular as connection-level default" do
      {:ok, conn} = Local.start(database: "metrics")
      assert conn.database == "metrics"
      assert MapSet.member?(conn.databases, "metrics")
      Local.stop(conn)
    end

    test ":database is nil when not specified" do
      {:ok, conn} = Local.start(databases: ["x"])
      assert conn.database == nil
      Local.stop(conn)
    end

    test "pre-creates both :database and :databases when both are given" do
      {:ok, conn} = Local.start(database: "primary", databases: ["a", "b"])
      assert conn.database == "primary"
      assert MapSet.member?(conn.databases, "primary")
      assert MapSet.member?(conn.databases, "a")
      assert MapSet.member?(conn.databases, "b")
      Local.stop(conn)
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

      # Other databases don't see the write — still report no table
      assert {:error,
              %{status: 400, body: "Error during planning: table 'public.iox.cpu' not found"}} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: "default")

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

    test "falls back to \"default\" when neither opts nor conn specifies database" do
      {:ok, conn} = Local.init_connection([])
      assert {:ok, :written} = Local.write(conn, "cpu value=1.0")
      {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM cpu")
      assert row["value"] == 1.0
      Local.stop(conn)
    end

    test "init_connection ignores unknown keys without auto-pre-creating them" do
      # A typo like :default_database must not silently become a database.
      {:ok, conn} = Local.init_connection(default_database: "typo_db")
      assert conn.database == nil
      refute MapSet.member?(conn.databases, "typo_db")
      Local.stop(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Write — basic
  # ---------------------------------------------------------------------------

  describe "write/3 — basic" do
    test "returns {:ok, :written} for valid line protocol", %{conn: conn} do
      assert {:ok, :written} = Local.write(conn, "cpu value=1.0", database: "test_db")
    end

    test "auto-creates database on write (v3 Core behavior)", %{conn: conn} do
      assert {:ok, :written} =
               Local.write(conn, "cpu value=1.0", database: "no_such_db")
    end

    test "v2 profile rejects write to non-existent database" do
      {:ok, v2_conn} = Local.start(databases: ["v2_db"], profile: :v2)
      on_exit(fn -> Local.stop(v2_conn) end)

      assert {:error, %{status: 404, body: body}} =
               Local.write(v2_conn, "cpu value=1.0", database: "missing_db")

      assert body =~ "database not found"
    end

    test "v3_enterprise profile auto-creates database on write" do
      {:ok, ent_conn} =
        Local.start(databases: ["ent_db"], profile: :v3_enterprise)

      on_exit(fn -> Local.stop(ent_conn) end)

      assert {:ok, :written} =
               Local.write(ent_conn, "cpu value=1.0", database: "auto_db")

      assert {:ok, dbs} = Local.list_databases(ent_conn)
      names = Enum.map(dbs, & &1["name"])
      assert "auto_db" in names
    end

    test "returns error for invalid line protocol", %{conn: conn} do
      assert {:error, %{status: 400}} =
               Local.write(conn, "this_is_not_valid_lp_at_all!", database: "test_db")
    end

    test "stores points that are later queryable", %{conn: conn} do
      :ok = Local.create_database(conn, "metrics")

      assert {:ok, :written} =
               Local.write(conn, "cpu value=1.0", database: "metrics")

      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM cpu", database: "metrics")
      assert row["value"] == 1.0
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

    test "integer field", %{conn: conn, db: db} do
      Local.write(conn, "m count=42i", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["count"] == 42
    end

    test "float field", %{conn: conn, db: db} do
      Local.write(conn, "m temp=98.6", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["temp"] == 98.6
    end

    test "string field", %{conn: conn, db: db} do
      Local.write(conn, ~S(m label="hello world"), database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["label"] == "hello world"
    end

    test "boolean true field", %{conn: conn, db: db} do
      Local.write(conn, "m active=true", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["active"] == true
    end

    test "boolean false field", %{conn: conn, db: db} do
      Local.write(conn, "m active=false", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["active"] == false
    end

    test "tag is preserved", %{conn: conn, db: db} do
      Local.write(conn, "m,host=server01 value=1i", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["host"] == "server01"
    end

    test "multiple tags are preserved", %{conn: conn, db: db} do
      Local.write(conn, "m,host=s1,region=us-east value=1i", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["host"] == "s1"
      assert row["region"] == "us-east"
    end

    test "multiple fields are preserved", %{conn: conn, db: db} do
      Local.write(conn, "m a=1i,b=2.0,c=\"hi\"", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["a"] == 1
      assert row["b"] == 2.0
      assert row["c"] == "hi"
    end

    test "timestamp is returned as a microsecond-precision DateTime", %{conn: conn, db: db} do
      ts = 1_630_424_257_123_456_789
      Local.write(conn, "m value=1.0 #{ts}", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["time"] == ~U[2021-08-31 15:37:37.123456Z]
    end

    test "multi-line write stores multiple points", %{conn: conn, db: db} do
      lp = "m value=1.0\nm value=2.0\nm value=3.0"
      Local.write(conn, lp, database: db)
      assert {:ok, rows} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert length(rows) == 3
    end

    test "measurement with escaped space in name", %{conn: conn, db: db} do
      Local.write(conn, "my\\ measurement value=1i", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM my\\ measurement", database: db)
      assert row["value"] == 1
    end

    test "quoted measurement name in SELECT *", %{conn: conn, db: db} do
      Local.write(conn, "prices value=100.0", database: db)

      assert {:ok, [row]} =
               Local.query_sql(
                 conn,
                 ~s(SELECT * FROM "prices"),
                 database: db
               )

      assert row["value"] == 100.0
    end

    test "string field with escaped quotes", %{conn: conn, db: db} do
      Local.write(conn, ~S(m msg="say \"hi\""), database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["msg"] == ~s(say "hi")
    end
  end

  # ---------------------------------------------------------------------------
  # Write — gzip decompression
  # ---------------------------------------------------------------------------

  describe "write/3 — gzip" do
    test "decompresses gzipped line protocol", %{conn: conn} do
      :ok = Local.create_database(conn, "gz_db")
      lp = "cpu value=1.0"
      compressed = :zlib.gzip(lp)
      assert {:ok, :written} = Local.write(conn, compressed, database: "gz_db")
      assert {:ok, [_row]} = Local.query_sql(conn, "SELECT * FROM cpu", database: "gz_db")
    end

    test "invalid gzip returns 400 error", %{conn: conn} do
      # gzip magic bytes but garbage body
      bad = <<0x1F, 0x8B, 0x00, 0xFF, 0xFF>>
      assert {:error, %{status: 400}} = Local.write(conn, bad, database: "test_db")
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

    test "nanosecond precision is stored as-is", %{conn: conn, db: db} do
      ts = 1_000_000_000
      Local.write(conn, "m value=1i #{ts}", database: db, precision: :nanosecond)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["time"] == ~U[1970-01-01 00:00:01.000000Z]
    end

    test "microsecond precision is multiplied by 1_000", %{conn: conn, db: db} do
      ts = 1_000_000
      Local.write(conn, "m value=1i #{ts}", database: db, precision: :microsecond)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["time"] == ~U[1970-01-01 00:00:01.000000Z]
    end

    test "millisecond precision is multiplied by 1_000_000", %{conn: conn, db: db} do
      ts = 1_000
      Local.write(conn, "m value=1i #{ts}", database: db, precision: :millisecond)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["time"] == ~U[1970-01-01 00:00:01.000000Z]
    end

    test "second precision is multiplied by 1_000_000_000", %{conn: conn, db: db} do
      ts = 1
      Local.write(conn, "m value=1i #{ts}", database: db, precision: :second)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["time"] == ~U[1970-01-01 00:00:01.000000Z]
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

      Local.write(conn, String.trim(lp), database: "qdb", precision: :nanosecond)
      {:ok, db: "qdb"}
    end

    test "returns error for non-existent measurement", %{conn: conn, db: db} do
      assert {:error,
              %{
                status: 400,
                body: "Error during planning: table 'public.iox.no_such_measurement' not found"
              }} =
               Local.query_sql(conn, "SELECT * FROM no_such_measurement", database: db)
    end

    test "returns all rows for bare SELECT *", %{conn: conn, db: db} do
      assert {:ok, rows} = Local.query_sql(conn, "SELECT * FROM cpu", database: db)
      assert length(rows) == 3
    end

    test "WHERE tag = 'value' filters rows", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM cpu WHERE host = 'web01'", database: db)

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1["host"] == "web01"))
    end

    test "WHERE field > N filters rows", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM cpu WHERE usage > 15", database: db)

      assert length(rows) == 2
    end

    test "WHERE field < N filters rows", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM cpu WHERE usage < 15", database: db)

      assert length(rows) == 1
      assert hd(rows)["usage"] == 10
    end

    test "WHERE field >= N filters rows", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM cpu WHERE usage >= 20", database: db)

      assert length(rows) == 2
    end

    test "WHERE field <= N filters rows", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM cpu WHERE usage <= 20", database: db)

      assert length(rows) == 2
    end

    test "ORDER BY time ASC", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM cpu ORDER BY time ASC", database: db)

      times = Enum.map(rows, & &1["time"])
      assert times == Enum.sort(times, DateTime)
    end

    test "ORDER BY time DESC", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM cpu ORDER BY time DESC", database: db)

      times = Enum.map(rows, & &1["time"])
      assert times == Enum.sort(times, {:desc, DateTime})
    end

    test "LIMIT reduces number of results", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM cpu LIMIT 2", database: db)

      assert length(rows) == 2
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
               Local.query_sql(conn, "SELECT * FROM cpu", database: db)

      assert %DateTime{} = row["time"]
      assert Map.has_key?(row, "usage")
      refute Map.has_key?(row, "_measurement")
    end

    test "unsupported SQL returns error", %{conn: conn, db: db} do
      assert {:error, _reason} =
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

      Local.write(conn, String.trim(lp), database: "proj_db", precision: :nanosecond)
      {:ok, db: "proj_db"}
    end

    test "selects specific columns by name", %{conn: conn, db: db} do
      sql = "SELECT net_value, total_balance, time FROM account_balances"

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)
      assert length(rows) == 3

      Enum.each(rows, fn row ->
        assert Map.keys(row) |> Enum.sort() ==
                 ["net_value", "time", "total_balance"]
      end)
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
      assert row["net_value"] == 110.0
      assert row["total_balance"] == 130.0
      assert %DateTime{} = row["time"]
    end

    test "supports AS aliases on projection columns", %{conn: conn, db: db} do
      sql =
        "SELECT net_value AS nv, total_balance AS tb FROM account_balances WHERE account_id = 'xyz'"

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert Map.keys(row) |> Enum.sort() == ["nv", "tb"]
      assert row["nv"] == 50.0
      assert row["tb"] == 55.0
    end

    test "selecting a tag column returns the tag value",
         %{conn: conn, db: db} do
      sql = "SELECT account_id, net_value FROM account_balances WHERE account_id = 'xyz'"

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["account_id"] == "xyz"
      assert row["net_value"] == 50.0
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — parameterised queries
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — parameterised queries" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "pdb")

      Local.write(
        conn,
        "cpu,host=web01 usage=10i\ncpu,host=web02 usage=20i",
        database: "pdb"
      )

      {:ok, db: "pdb"}
    end

    test "string param substitution", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE host = $host"
      params = %{"$host" => "web01"}
      assert {:ok, rows} = Local.query_sql(conn, sql, params: params, database: db)
      assert length(rows) == 1
      assert hd(rows)["host"] == "web01"
    end

    test "integer param substitution", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE usage > $min"
      params = %{"$min" => 15}
      assert {:ok, rows} = Local.query_sql(conn, sql, params: params, database: db)
      assert length(rows) == 1
    end

    test "atom key params without $ prefix", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE host = $host"
      params = %{host: "web01"}
      assert {:ok, rows} = Local.query_sql(conn, sql, params: params, database: db)
      assert length(rows) == 1
      assert hd(rows)["host"] == "web01"
    end

    test "string key params without $ prefix", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE host = $host"
      params = %{"host" => "web01"}
      assert {:ok, rows} = Local.query_sql(conn, sql, params: params, database: db)
      assert length(rows) == 1
      assert hd(rows)["host"] == "web01"
    end

    test "atom key params with multiple conditions", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE host = $host AND usage > $min"
      params = %{host: "web02", min: 15}
      assert {:ok, rows} = Local.query_sql(conn, sql, params: params, database: db)
      assert length(rows) == 1
      assert hd(rows)["host"] == "web02"
    end

    test "a placeholder that prefixes another is substituted whole",
         %{conn: conn, db: db} do
      # Sequential replacement rewrote `$h` inside `$hmin`, producing
      # `'web02'min` and a parse failure.
      sql = "SELECT * FROM cpu WHERE host = $h AND usage > $hmin"
      params = %{h: "web02", hmin: 15}
      assert {:ok, [row]} = Local.query_sql(conn, sql, params: params, database: db)
      assert row["host"] == "web02"
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
      # A string value containing another placeholder's name must stay literal.
      sql = "SELECT * FROM cpu WHERE host = $host AND usage > $min"
      params = %{host: "$min", min: 15}
      assert {:ok, []} = Local.query_sql(conn, sql, params: params, database: db)
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql_stream/3
  # ---------------------------------------------------------------------------

  describe "query_sql_stream/3" do
    test "returns an enumerable", %{conn: conn} do
      stream = Local.query_sql_stream(conn, "SELECT * FROM cpu")
      assert Enumerable.impl_for(stream)
    end

    test "stream yields same rows as query_sql", %{conn: conn} do
      :ok = Local.create_database(conn, "sdb")
      Local.write(conn, "m value=1i\nm value=2i", database: "sdb")

      {:ok, direct} = Local.query_sql(conn, "SELECT * FROM m", database: "sdb")

      stream_rows =
        conn
        |> Local.query_sql_stream("SELECT * FROM m", database: "sdb")
        |> Enum.to_list()

      assert length(stream_rows) == length(direct)
    end

    # Parity with Client.HTTP (issue #11): a query error must raise
    # InfluxElixir.StreamError on enumeration, never surface as an empty stream.
    test "raises StreamError on a query error instead of yielding []",
         %{conn: conn} do
      # An unrecognised WHERE clause yields {:error, %{status: 400, ...}}.
      stream =
        Local.query_sql_stream(
          conn,
          "SELECT * FROM cpu WHERE x LIKE 'y'",
          database: "test_db"
        )

      error =
        try do
          Enum.to_list(stream)
          nil
        rescue
          e in InfluxElixir.StreamError -> e
        end

      assert error.kind == :http_status
      assert error.status == 400
    end

    test "construction is lazy — the raise is deferred to enumeration",
         %{conn: conn} do
      # Building the stream must not raise; only consuming it does.
      stream =
        Local.query_sql_stream(
          conn,
          "SELECT * FROM cpu WHERE x LIKE 'y'",
          database: "test_db"
        )

      assert Enumerable.impl_for(stream)
      assert_raise InfluxElixir.StreamError, fn -> Enum.to_list(stream) end
    end

    test "raises StreamError with :unsupported when the profile lacks streaming" do
      {:ok, v2_conn} = Local.start(profile: :v2, databases: ["v2_db"])
      on_exit(fn -> Local.stop(v2_conn) end)

      stream = Local.query_sql_stream(v2_conn, "SELECT * FROM cpu")

      error =
        try do
          Enum.to_list(stream)
          nil
        rescue
          e in InfluxElixir.StreamError -> e
        end

      assert error.kind == :unsupported
      assert error.reason == :unsupported_operation
    end
  end

  # ---------------------------------------------------------------------------
  # execute_sql/3
  # ---------------------------------------------------------------------------

  describe "execute_sql/3" do
    test "returns error for DELETE on v3_core", %{conn: conn} do
      assert {:error, :delete_not_supported} =
               Local.execute_sql(conn, "DELETE FROM cpu")
    end

    test "returns zero rows affected for an unknown statement", %{conn: conn} do
      assert {:ok, %{"rows_affected" => 0}} = Local.execute_sql(conn, "ALTER TABLE foo")
    end
  end

  # ---------------------------------------------------------------------------
  # query_influxql/3
  # ---------------------------------------------------------------------------

  describe "query_influxql/3" do
    test "delegates to SQL engine — data is visible", %{conn: conn} do
      :ok = Local.create_database(conn, "iqldb")
      Local.write(conn, "m value=1i", database: "iqldb")
      assert {:ok, [row]} = Local.query_influxql(conn, "SELECT * FROM m", database: "iqldb")
      assert row["value"] == 1
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
    test "delete_database/2 returns 404 with descriptive body", %{conn: conn} do
      assert {:error, %{status: 404, body: body}} =
               Local.delete_database(conn, "not_here")

      assert body =~ "database not found"
      assert body =~ "not_here"
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

      Local.write(
        conn,
        "cpu,host=web01 value=10i\ncpu,host=web02 value=20i\ncpu,host=web01 value=30i",
        database: "del_db"
      )

      {:ok, db: "del_db"}
    end

    test "DELETE FROM returns error on v3_core profile",
         %{conn: conn, db: db} do
      assert {:error, :delete_not_supported} =
               Local.execute_sql(conn, "DELETE FROM cpu", database: db)
    end

    test "unknown statement returns 0 rows_affected", %{conn: conn, db: db} do
      assert {:ok, %{"rows_affected" => 0}} =
               Local.execute_sql(conn, "CREATE TABLE foo (id INT)", database: db)
    end
  end

  describe "execute_sql/3 — DELETE (v3_enterprise supports)" do
    setup do
      {:ok, conn} =
        Local.start(
          databases: ["del_db"],
          profile: :v3_enterprise
        )

      Local.write(
        conn,
        "cpu,host=web01 value=10i\ncpu,host=web02 value=20i\ncpu,host=web01 value=30i",
        database: "del_db"
      )

      on_exit(fn -> Local.stop(conn) end)
      {:ok, conn: conn, db: "del_db"}
    end

    test "DELETE FROM removes all points for a measurement",
         %{conn: conn, db: db} do
      assert {:ok, %{"rows_affected" => 3}} =
               Local.execute_sql(conn, "DELETE FROM cpu", database: db)
    end

    test "DELETE FROM with WHERE removes matching points only",
         %{conn: conn, db: db} do
      assert {:ok, %{"rows_affected" => 2}} =
               Local.execute_sql(
                 conn,
                 "DELETE FROM cpu WHERE host = 'web01'",
                 database: db
               )

      assert {:ok, [row]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: db)

      assert row["host"] == "web02"
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — WHERE clause edge cases
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — WHERE edge cases" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "where_db")

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
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM m WHERE host != 'alpha'", database: db)

      assert length(rows) == 2
      refute Enum.any?(rows, &(&1["host"] == "alpha"))
    end

    test "WHERE with boolean value", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM m WHERE active = true", database: db)

      assert length(rows) == 2
    end

    test "WHERE with float comparison", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM m WHERE temp > 98.5", database: db)

      assert length(rows) == 2
    end

    test "WHERE compound AND conditions", %{conn: conn, db: db} do
      sql = "SELECT * FROM m WHERE active = true AND count > 15"

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["host"] == "gamma"
    end

    test "case insensitive SELECT", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "select * from m where host = 'alpha'", database: db)

      assert length(rows) == 1
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
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM prices WHERE time >= '2026-03-17T12:00:00Z' AND time < '2026-03-17T12:02:00Z'",
          database: db
        )

      assert length(rows) == 2
      symbols = Enum.map(rows, & &1["symbol"])
      assert "AAPL" in symbols
      assert "GOOG" in symbols
    end

    test "a bare integer comparand is rejected, as DataFusion rejects it", %{conn: conn, db: db} do
      # InfluxDB 3: "Cannot infer common argument type for comparison
      # operation Timestamp(ns) >= Int64". Matching nothing here would let a
      # query pass tests and 400 in production.
      assert {:error, %{status: 400, body: "Client.Local: InfluxDB rejects" <> _rest}} =
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
          "SELECT * FROM prices WHERE time >= $start AND time < $end",
          database: db,
          params: %{
            "$start" => "2026-03-17T12:00:00Z",
            "$end" => "2026-03-17T12:02:00Z"
          }
        )

      assert length(rows) == 2
      symbols = Enum.map(rows, & &1["symbol"])
      assert "AAPL" in symbols
      assert "GOOG" in symbols
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

      assert length(rows) == 2
      assert [first_row | _rest] = rows
      assert first_row["avg_price"] == 150.0
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

      assert length(rows) == 1
      assert hd(rows)["symbol"] == "AAPL"
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
      {:ok, all_rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM prices WHERE time <= '2026-03-18'",
          database: db
        )

      assert length(all_rows) == 3

      {:ok, none_rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM prices WHERE time <= '2026-03-17'",
          database: db
        )

      assert none_rows == []
    end

    test "bare ISO date range filters across day boundaries",
         %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM prices WHERE time >= '2026-03-17' AND time <= '2026-03-18'",
          database: db
        )

      assert length(rows) == 3
    end

    test "an unparseable date string is rejected, as the engine rejects it",
         %{conn: conn, db: db} do
      # InfluxDB 3 fails the query ("Error parsing timestamp from 'totally
      # garbage'"); returning [] would hide the mistake.
      assert {:error, %{status: 400, body: "Client.Local: InfluxDB rejects" <> _rest}} =
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

      Local.write(conn, lines, database: "in_db", precision: :nanosecond)
      {:ok, db: "in_db"}
    end

    test "IN with multiple tag values filters correctly",
         %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM holdings WHERE ticker IN ('AAPL', 'MSFT')",
          database: db
        )

      tickers = rows |> Enum.map(& &1["ticker"]) |> Enum.sort()
      assert tickers == ["AAPL", "MSFT"]
    end

    test "IN with a single value matches one row", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM holdings WHERE ticker IN ('GOOG')",
          database: db
        )

      assert length(rows) == 1
      assert hd(rows)["ticker"] == "GOOG"
    end

    test "empty IN () matches no rows", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM holdings WHERE ticker IN ()",
          database: db
        )

      assert rows == []
    end

    test "IN works on field columns", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM holdings WHERE shares IN (10, 20)",
          database: db
        )

      tickers = rows |> Enum.map(& &1["ticker"]) |> Enum.sort()
      assert tickers == ["AAPL", "MSFT"]
    end

    test "NOT IN excludes listed values", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM holdings WHERE ticker NOT IN ('AAPL', 'GOOG')",
          database: db
        )

      assert length(rows) == 1
      assert hd(rows)["ticker"] == "MSFT"
    end

    test "IN combines with binary operators via AND", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM holdings WHERE ticker IN ('AAPL', 'GOOG', 'MSFT') AND shares > 5",
          database: db
        )

      tickers = rows |> Enum.map(& &1["ticker"]) |> Enum.sort()
      assert tickers == ["AAPL", "MSFT"]
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

      Local.write(conn, lines, database: "group_db", precision: :nanosecond)
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
      by_ticker = rows |> Enum.map(&{&1["ticker"], &1["avg_value"]}) |> Map.new()

      # AAPL: (100 + 200 + 50) / 3 = 116.666...
      assert_in_delta by_ticker["AAPL"], 350.0 / 3, 1.0e-9
      assert by_ticker["GOOG"] == 300.0
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

      groups =
        rows
        |> Enum.map(fn row ->
          {{row["ticker"], row["holding_type"]}, row["average_balance"]}
        end)
        |> Map.new()

      assert groups[{"AAPL", "stock"}] == 150.0
      assert groups[{"GOOG", "stock"}] == 300.0
      assert groups[{"AAPL", "etf"}] == 50.0
    end

    test "GROUP BY supports AS alias on grouping columns",
         %{conn: conn, db: db} do
      sql = """
      SELECT ticker AS sym, COUNT(value) AS n
      FROM account_holdings
      GROUP BY ticker
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)
      counts = rows |> Enum.map(&{&1["sym"], &1["n"]}) |> Map.new()
      assert counts["AAPL"] == 3
      assert counts["GOOG"] == 1
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

      Local.write(conn, lines, database: "dec_db", precision: :nanosecond)
      {:ok, db: "dec_db"}
    end

    test "Decimal param serialises as numeric literal (issue #7 reproduction)",
         %{conn: conn, db: db} do
      sql = """
      SELECT amount FROM cash_flows
      WHERE account_id = $a AND amount >= $min
      """

      params = %{"$a" => "abc", "$min" => Decimal.new("1000.00")}

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db, params: params)
      amounts = rows |> Enum.map(& &1["amount"]) |> Enum.sort()
      assert amounts == [5000.0, 12_000.0]
    end

    test "Decimal pre-stringified by caller still compares numerically",
         %{conn: conn, db: db} do
      # Some callers Decimal.to_string/1 their values before passing them.
      # The quoted form must still parse as a number to avoid a silent
      # string-vs-float comparison via Elixir term ordering.
      sql = """
      SELECT amount FROM cash_flows
      WHERE amount >= $min
      """

      params = %{"$min" => "1000.00"}

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db, params: params)
      assert length(rows) == 2
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

    test "invalid DISTINCT syntax returns error", %{conn: conn, db: db} do
      assert {:error, %{status: 400}} =
               Local.query_sql(
                 conn,
                 "SELECT DISTINCT FROM prices",
                 database: db
               )
    end

    test "WHERE time with an integer param is rejected, as over HTTP", %{conn: conn, db: db} do
      # The engine plans `Timestamp(ns) >= UInt64` as an error for a JSON
      # integer param; the double must not accept what production refuses.
      Local.write(conn, "m val=1i 5000", database: db)

      assert {:error, %{status: 400, body: "Client.Local: InfluxDB rejects" <> _rest}} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM m WHERE time >= $t",
                 database: db,
                 params: %{"$t" => 5000}
               )
    end

    test "WHERE time with a DateTime param renders as the ISO string Jason sends",
         %{conn: conn, db: db} do
      Local.write(conn, "m val=1i 5000\nm val=2i 6000", database: db)

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM m WHERE time >= $t",
          database: db,
          params: %{"$t" => ~U[1970-01-01 00:00:00.000006Z]}
        )

      assert [%{"val" => 2}] = rows
    end

    test "WHERE time with non-matching filter returns empty",
         %{conn: conn, db: db} do
      Local.write(conn, "m val=1i 5000", database: db)

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM m WHERE time > '1970-01-01T00:00:00.000009999Z'",
          database: db
        )

      assert rows == []
    end

    test "aggregate on non-existent measurement returns error",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        AVG(val) AS avg_val
      FROM "empty_m"
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      """

      assert {:error,
              %{status: 400, body: "Error during planning: table 'public.iox.empty_m' not found"}} =
               Local.query_sql(conn, sql, database: db)
    end

    test "double-quoted WHERE value parsed as string",
         %{conn: conn, db: db} do
      Local.write(conn, ~s(m,tag=hello val=1i), database: db)

      {:ok, rows} =
        Local.query_sql(
          conn,
          ~s(SELECT * FROM m WHERE tag = "hello"),
          database: db
        )

      assert length(rows) == 1
    end

    test "boolean false param in WHERE", %{conn: conn, db: db} do
      Local.write(conn, "m,active=true val=1i", database: db)

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM m WHERE active = false",
          database: db
        )

      assert rows == []
    end

    test "float param in SQL literal", %{conn: conn, db: db} do
      Local.write(conn, "m val=3.14", database: db)

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM m WHERE val > $v",
          database: db,
          params: %{"$v" => 3.0}
        )

      assert length(rows) == 1
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
      Local.write(conn, "m,k=v\\=1 f=1i", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["k"] == "v=1"
    end

    test "tag value with escaped comma", %{conn: conn, db: db} do
      Local.write(conn, "m,k=v\\,1 f=1i", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["k"] == "v,1"
    end

    test "empty tag set — just measurement + fields", %{conn: conn, db: db} do
      Local.write(conn, "m field=1i", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["field"] == 1
    end

    test "measurement name with escaped comma", %{conn: conn, db: db} do
      Local.write(conn, "my\\,measurement field=1i", database: db)

      assert {:ok, [row]} =
               Local.query_sql(conn, "SELECT * FROM my\\,measurement", database: db)

      assert row["field"] == 1
    end

    test "field with negative integer", %{conn: conn, db: db} do
      Local.write(conn, "m value=-42i", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["value"] == -42
    end

    test "field with negative float", %{conn: conn, db: db} do
      Local.write(conn, "m value=-3.14", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert_in_delta row["value"], -3.14, 1.0e-10
    end

    test "field with scientific notation", %{conn: conn, db: db} do
      Local.write(conn, "m value=1.5e10", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert_in_delta row["value"], 1.5e10, 1.0
    end

    test "comments and blank lines are ignored", %{conn: conn, db: db} do
      lp = "# This is a comment\n\nm value=1i\n\n# Another comment\nm value=2i\n"
      Local.write(conn, lp, database: db)
      assert {:ok, rows} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert length(rows) == 2
    end

    test "gzip: true option is accepted without error", %{conn: conn, db: db} do
      assert {:ok, :written} =
               Local.write(conn, "m value=1i", database: db, gzip: true)
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — multi-database isolation
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — multi-database isolation" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "db_a")
      :ok = Local.create_database(conn, "db_b")
      Local.write(conn, "m value=1i", database: "db_a")
      Local.write(conn, "m value=2i", database: "db_b")
      :ok
    end

    test "points in db_a are NOT visible from db_b", %{conn: conn} do
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: "db_a")
      assert row["value"] == 1

      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: "db_b")
      assert row["value"] == 2
    end

    test "same measurement in two databases returns different data", %{conn: conn} do
      {:ok, rows_a} = Local.query_sql(conn, "SELECT * FROM m", database: "db_a")
      {:ok, rows_b} = Local.query_sql(conn, "SELECT * FROM m", database: "db_b")
      assert hd(rows_a)["value"] != hd(rows_b)["value"]
    end

    test "query without explicit database uses 'default'", %{conn: conn} do
      Local.write(conn, "m value=99i", database: "default")
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m")
      assert row["value"] == 99
    end
  end

  # ---------------------------------------------------------------------------
  # query_influxql/3 — InfluxQL-specific commands
  # ---------------------------------------------------------------------------

  describe "query_influxql/3 — InfluxQL commands" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "iql_db")
      Local.write(conn, "cpu,host=web01,region=us value=1i", database: "iql_db")
      Local.write(conn, "mem,host=web01 used=512i", database: "iql_db")
      {:ok, db: "iql_db"}
    end

    test "SHOW DATABASES returns all databases with iox::database key",
         %{conn: conn} do
      assert {:ok, dbs} = Local.query_influxql(conn, "SHOW DATABASES")
      names = Enum.map(dbs, & &1["iox::database"])
      assert "iql_db" in names
      assert "test_db" in names
    end

    test "SHOW MEASUREMENTS returns measurement names with iox::measurement key",
         %{conn: conn, db: db} do
      assert {:ok, measurements} =
               Local.query_influxql(conn, "SHOW MEASUREMENTS", database: db)

      names = Enum.map(measurements, & &1["name"])
      assert "cpu" in names
      assert "mem" in names

      Enum.each(measurements, fn m ->
        assert m["iox::measurement"] == "measurements"
      end)
    end

    test "SHOW TAG KEYS FROM returns tag keys with iox::measurement key",
         %{conn: conn, db: db} do
      assert {:ok, tag_keys} =
               Local.query_influxql(conn, "SHOW TAG KEYS FROM cpu", database: db)

      keys = Enum.map(tag_keys, & &1["tagKey"])
      assert "host" in keys
      assert "region" in keys

      Enum.each(tag_keys, fn tk ->
        assert tk["iox::measurement"] == "cpu"
      end)
    end

    test "SELECT delegates to SQL engine", %{conn: conn, db: db} do
      assert {:ok, [row]} =
               Local.query_influxql(conn, "SELECT * FROM cpu", database: db)

      assert row["value"] == 1
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

      assert {:ok, rows} = Local.query_flux(conn, flux)
      assert length(rows) == 1
      assert hd(rows)["host"] == "web01"
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
      Local.write(conn, "mem,host=web01 used=5i,free=7i", database: "flux_db")

      flux =
        "from(bucket: \"flux_db\") |> range(start: -1h) " <>
          "|> filter(fn: (r) => r._measurement == \"mem\") " <>
          "|> filter(fn: (r) => r._field == \"free\")"

      assert {:ok, [%{"_field" => "free", "_value" => 7}]} = Local.query_flux(conn, flux)
    end

    test "flux query with no matching bucket returns empty list", %{v2_conn: conn} do
      flux = "from(bucket: \"no_such_bucket\") |> range(start: -1h)"
      assert {:ok, []} = Local.query_flux(conn, flux)
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — SELECT DISTINCT
  # ---------------------------------------------------------------------------

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

    test "returns unique values for a tag column", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          ~s(SELECT DISTINCT symbol FROM "prices"),
          database: db
        )

      values = Enum.map(rows, & &1["symbol"])
      assert length(values) == 3
      assert "AAPL" in values
      assert "GOOG" in values
      assert "MSFT" in values
    end

    test "returns unique values for a field column", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          ~s(SELECT DISTINCT price FROM "prices"),
          database: db
        )

      values = Enum.map(rows, & &1["price"])
      assert length(values) == 5
    end

    test "applies WHERE filter", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          ~s(SELECT DISTINCT symbol FROM "prices" WHERE price > 200),
          database: db
        )

      values = Enum.map(rows, & &1["symbol"])
      assert length(values) == 2
      assert "GOOG" in values
      assert "MSFT" in values
      refute "AAPL" in values
    end

    test "applies LIMIT", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          ~s(SELECT DISTINCT symbol FROM "prices" LIMIT 2),
          database: db
        )

      assert length(rows) == 2
    end

    test "unquoted measurement name", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT DISTINCT symbol FROM prices",
          database: db
        )

      values = Enum.map(rows, & &1["symbol"])
      assert length(values) == 3
    end

    test "returns error for non-existent measurement", %{conn: conn, db: db} do
      assert {:error,
              %{
                status: 400,
                body: "Error during planning: table 'public.iox.nonexistent' not found"
              }} =
               Local.query_sql(
                 conn,
                 ~s(SELECT DISTINCT symbol FROM "nonexistent"),
                 database: db
               )
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

      Local.write(conn, lines, database: "agg_db", precision: :nanosecond)
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

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)
      # 0.5h,1.5h → bucket 0; 2.5h,3.5h → bucket 2h; 4.5h,5.5h → bucket 4h
      assert length(rows) == 3

      [b1, b2, b3] = rows
      assert b1["time"] == ~U[1970-01-01 00:00:00.000000Z]
      assert b1["avg_usage"] == 15.0
      assert b2["time"] == ~U[1970-01-01 02:00:00.000000Z]
      assert b2["avg_usage"] == 35.0
      assert b3["time"] == ~U[1970-01-01 04:00:00.000000Z]
      assert b3["avg_usage"] == 55.0
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

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)
      # 0.5h,1.5h,2.5h → bucket 0; 3.5h,4.5h,5.5h → bucket 3h
      assert length(rows) == 2

      [b1, b2] = rows
      assert b1["time"] == ~U[1970-01-01 00:00:00.000000Z]
      assert b1["total"] == 60
      assert b2["time"] == ~U[1970-01-01 03:00:00.000000Z]
      assert b2["total"] == 150
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

      [b1, b2] = rows
      assert b1["time"] == ~U[1970-01-01 00:00:00.000000Z]
      assert b1["cnt"] == 3
      assert b2["time"] == ~U[1970-01-01 03:00:00.000000Z]
      assert b2["cnt"] == 3
    end

    test "MIN and MAX aggregates", %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '6 hours', time) AS time,
        MIN(usage) AS min_val,
        MAX(usage) AS max_val
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '6 hours', time)
      ORDER BY time ASC
      """

      # All points at 0.5h-5.5h → all in bucket 0
      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["time"] == ~U[1970-01-01 00:00:00.000000Z]
      assert row["min_val"] == 10
      assert row["max_val"] == 60
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
      assert row["avg_val"] == 35.0
      assert row["sum_val"] == 210
      assert row["cnt"] == 6
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

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)
      # web01 has points at 0.5h, 1.5h, 2.5h → all in bucket 0
      assert length(rows) == 1
      [row] = rows
      assert row["time"] == ~U[1970-01-01 00:00:00.000000Z]
      assert row["avg_usage"] == 20.0
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
      times = Enum.map(rows, & &1["time"])
      assert times == Enum.sort(times, {:desc, DateTime})
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
      assert length(rows) == 2
    end

    test "interval with singular unit name (hour vs hours)",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        COUNT(usage) AS cnt
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      ORDER BY time ASC
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)
      assert length(rows) == 6
    end

    test "minute interval", %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '60 minutes', time) AS time,
        COUNT(usage) AS cnt
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '60 minutes', time)
      ORDER BY time ASC
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)
      # 60 min == 1 hour, so 6 buckets
      assert length(rows) == 6
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

    test "second interval", %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '3600 seconds', time) AS time,
        COUNT(usage) AS cnt
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '3600 seconds', time)
      ORDER BY time ASC
      """

      # 3600 seconds == 1 hour, same as 1-hour buckets → 6 buckets
      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)
      assert length(rows) == 6
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

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert is_float(row["avg_usage"])
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
      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["total_usage"] == 60
      assert row["row_count"] == 3
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

      assert {:error, %{status: 400}} =
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
      assert length(rows) == 2

      [h0, h1] = rows
      assert h0["open"] == 100.0
      assert h1["open"] == 110.0
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
      assert length(rows) == 2

      [h0, h1] = rows
      assert h0["close"] == 102.0
      assert h1["close"] == 112.0
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
      assert length(rows) == 2

      [h0, h1] = rows

      # Hour 0: prices 100, 105, 102 — volumes 10, 20, 15
      assert h0["open"] == 100.0
      assert h0["high"] == 105.0
      assert h0["low"] == 100.0
      assert h0["close"] == 102.0
      assert h0["volume"] == 45

      # Hour 1: prices 110, 108, 112 — volumes 5, 25, 30
      assert h1["open"] == 110.0
      assert h1["high"] == 112.0
      assert h1["low"] == 108.0
      assert h1["close"] == 112.0
      assert h1["volume"] == 60
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

      assert {:ok, [h0, h1]} = Local.query_sql(conn, sql, database: db)
      assert h0["latest"] == 102.0
      assert h1["latest"] == 112.0
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

      assert {:ok, [h0, h1]} = Local.query_sql(conn, sql, database: db)
      assert h0["earliest"] == 100.0
      assert h1["earliest"] == 110.0
    end

    test "latest value per group via GROUP BY columns", %{conn: conn, db: db} do
      # The shape from #13: server-side "latest per (symbol, provider)".
      Local.write(
        conn,
        "quotes,symbol=BTC,provider=a price=1.0 100\n" <>
          "quotes,symbol=BTC,provider=a price=2.0 200\n" <>
          "quotes,symbol=ETH,provider=a price=9.0 300\n" <>
          "quotes,symbol=ETH,provider=a price=8.0 150",
        database: db
      )

      sql = """
      SELECT symbol, last_value(price ORDER BY time) AS price
      FROM quotes
      GROUP BY symbol, provider
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)
      by_symbol = Map.new(rows, &{&1["symbol"], &1["price"]})
      assert by_symbol == %{"BTC" => 2.0, "ETH" => 9.0}
    end

    test "first_value without ORDER BY is rejected as non-deterministic",
         %{conn: conn, db: db} do
      # Real DataFusion returns an arbitrary group member here. Certifying
      # "earliest" would be a lie, so the double refuses and says why.
      sql = "SELECT first_value(price) AS open FROM \"trades\""

      assert {:error, %{status: 400, body: body}} =
               Local.query_sql(conn, sql, database: db)

      assert body =~ "Client.Local:"
      assert body =~ "ORDER BY"
      assert body =~ "first_value(field ORDER BY time)"
    end

    test "InfluxQL FIRST()/LAST() are rejected with a pointer to the v3 spelling",
         %{conn: conn, db: db} do
      # InfluxDB v3 SQL fails planning with "Invalid function 'last'" (#13).
      for sql <- [
            "SELECT FIRST(price, time) AS open FROM \"trades\"",
            "SELECT last(price) AS close FROM \"trades\""
          ] do
        assert {:error, %{status: 400, body: body}} =
                 Local.query_sql(conn, sql, database: db)

        assert body =~ "Client.Local:"
        assert body =~ "InfluxQL"
        assert body =~ "last_value(field ORDER BY time)"
      end
    end

    test "a malformed first_value call is rejected", %{conn: conn, db: db} do
      sql = "SELECT first_value(price ORDER BY time, symbol) AS open FROM \"trades\""

      assert {:error, %{status: 400, body: body}} =
               Local.query_sql(conn, sql, database: db)

      assert body =~ "Client.Local: invalid aggregate"
    end

    test "a second argument to a plain aggregate is rejected", %{conn: conn, db: db} do
      # AVG(price, time) is not SQL; the real engine rejects it.
      sql = "SELECT AVG(price, time) AS avg FROM \"trades\""

      assert {:error, %{status: 400, body: body}} =
               Local.query_sql(conn, sql, database: db)

      assert body =~ "Client.Local: invalid aggregate"
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

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      # Prices > 104: 105 (0.5h), 110 (1h10m), 108 (1h30m), 112 (1h50m)
      # All in bucket 0 (2-hour window)
      assert length(rows) == 1
      [row] = rows
      assert row["open"] == 105.0
      assert row["close"] == 112.0
    end

    test "first_value/last_value on non-existent measurement returns error",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        first_value(price ORDER BY time) AS open,
        last_value(price ORDER BY time) AS close
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
  end

  # ---------------------------------------------------------------------------
  # start/1 — invalid profile validation
  # ---------------------------------------------------------------------------

  describe "start/1 — invalid profile" do
    test "raises ArgumentError for unknown profile" do
      assert_raise ArgumentError, ~r/invalid profile/, fn ->
        Local.start(profile: :invalid_thing)
      end
    end

    test "error message lists valid profiles" do
      assert_raise ArgumentError, ~r/:v3_core.*:v3_enterprise.*:v2/s, fn ->
        Local.start(profile: :nonexistent_profile)
      end
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

    test "escaped backslash in measurement name is stored correctly",
         %{conn: conn, db: db} do
      # cpu,host=web\\01 has a literal backslash in the host tag value
      Local.write(conn, "cpu,host=web\\\\01 value=1i", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM cpu", database: db)
      assert row["host"] == "web\\01"
    end

    test "tag with empty key returns 400 error", %{conn: conn, db: db} do
      assert {:error, %{status: 400}} =
               Local.write(conn, "cpu,=val value=1i", database: db)
    end

    test "tag with empty value returns 400 error", %{conn: conn, db: db} do
      assert {:error, %{status: 400}} =
               Local.write(conn, "cpu,key= value=1i", database: db)
    end

    test "field value that is not a valid type returns 400 error",
         %{conn: conn, db: db} do
      # Not quoted string, not int (no i suffix), not bool, not float
      assert {:error, %{status: 400}} =
               Local.write(conn, "cpu value=notanumber", database: db)
    end

    test "field value with i suffix but non-numeric body returns 400 error",
         %{conn: conn, db: db} do
      assert {:error, %{status: 400}} =
               Local.write(conn, "cpu value=abci", database: db)
    end

    test "field pair with empty key returns 400 error", %{conn: conn, db: db} do
      assert {:error, %{status: 400}} =
               Local.write(conn, "cpu =val", database: db)
    end

    test "write with non-numeric trailing timestamp returns 400 error",
         %{conn: conn, db: db} do
      assert {:error, %{status: 400}} =
               Local.write(conn, "cpu value=1i badtimestamp", database: db)
    end

    test "missing timestamp gets server-assigned time (matches real InfluxDB)",
         %{conn: conn, db: db} do
      # Real InfluxDB assigns a server timestamp when none is provided.
      # LocalClient must do the same.
      Local.write(conn, "cpu value=42i", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM cpu", database: db)
      assert row["value"] == 42
      assert %DateTime{} = row["time"]
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — aggregate SQL parse error edge cases
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — aggregate parse errors" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "agg_err_db")
      Local.write(conn, "sensors temp=22i 1000000000", database: "agg_err_db")
      {:ok, db: "agg_err_db"}
    end

    test "aggregate column with unsupported expression returns error",
         %{conn: conn, db: db} do
      # A function call that is not DATE_BIN nor a recognised aggregate
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        weird_func(temp) AS alias
      FROM sensors
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      """

      assert {:error, %{status: 400}} = Local.query_sql(conn, sql, database: db)
    end

    test "DATE_BIN column missing INTERVAL keyword returns error",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN('1 hour', time) AS time,
        AVG(temp) AS avg_temp
      FROM sensors
      GROUP BY DATE_BIN('1 hour', time)
      """

      assert {:error, %{status: 400}} = Local.query_sql(conn, sql, database: db)
    end

    test "malformed aggregate expression with unknown function returns error",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        INVALID_FUNC(temp) AS bad
      FROM sensors
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      """

      # INVALID_FUNC contains none of the aggregate keywords so parse_single_column
      # falls through to the error branch
      assert {:error, %{status: 400}} = Local.query_sql(conn, sql, database: db)
    end

    test "aggregate with invalid interval unit returns error",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 fortnight', time) AS time,
        AVG(temp) AS avg_temp
      FROM sensors
      GROUP BY DATE_BIN(INTERVAL '1 fortnight', time)
      """

      assert {:error, %{status: 400, body: body}} =
               Local.query_sql(conn, sql, database: db)

      assert body =~ "fortnight"
    end

    test "aggregate with malformed interval (no number) returns error",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL 'lots of hours', time) AS time,
        AVG(temp) AS avg_temp
      FROM sensors
      GROUP BY DATE_BIN(INTERVAL 'lots of hours', time)
      """

      assert {:error, %{status: 400}} = Local.query_sql(conn, sql, database: db)
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — WHERE value parsing coverage
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — WHERE value type parsing" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "where_val_db")

      Local.write(
        conn,
        "sensors,device=alpha temp=98.6,count=5i 1000000000\n" <>
          "sensors,device=beta temp=37.2,count=10i 2000000000",
        database: "where_val_db"
      )

      {:ok, db: "where_val_db"}
    end

    test "WHERE with float comparison filters correctly", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM sensors WHERE temp > 1.5",
                 database: db
               )

      assert length(rows) == 2
    end

    test "WHERE with float boundary excludes low values", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM sensors WHERE temp > 50.0",
                 database: db
               )

      assert length(rows) == 1
      assert hd(rows)["device"] == "alpha"
    end

    test "WHERE with unparseable string value is treated as string literal",
         %{conn: conn, db: db} do
      # A value like 'alpha' matches tag values as a string
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM sensors WHERE device = 'alpha'",
                 database: db
               )

      assert length(rows) == 1
      assert hd(rows)["device"] == "alpha"
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

      Local.write(
        conn,
        "acct,repcode=08338636 amount=500.0 1000\n" <>
          "acct,repcode=12345678 amount=5000.0 2000",
        database: "lit_db"
      )

      {:ok, db: "lit_db"}
    end

    test "= keeps the leading zero and matches the string tag", %{conn: conn, db: db} do
      sql = "SELECT * FROM acct WHERE repcode = '08338636'"
      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["repcode"] == "08338636"
    end

    test "!= excludes only the matching string tag", %{conn: conn, db: db} do
      sql = "SELECT * FROM acct WHERE repcode != '08338636'"
      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["repcode"] == "12345678"
    end

    test "IN / NOT IN compare zero-padded literals as strings", %{conn: conn, db: db} do
      assert {:ok, [in_row]} =
               Local.query_sql(conn, "SELECT * FROM acct WHERE repcode IN ('08338636')",
                 database: db
               )

      assert in_row["repcode"] == "08338636"

      assert {:ok, [out_row]} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM acct WHERE repcode NOT IN ('08338636')",
                 database: db
               )

      assert out_row["repcode"] == "12345678"
    end

    test "a bound string param keeps its leading zero", %{conn: conn, db: db} do
      # The exact repro from #12: params %{"rc" => "08338636"}.
      sql = "SELECT * FROM acct WHERE repcode IN ($rc)"

      assert {:ok, [row]} =
               Local.query_sql(conn, sql, database: db, params: %{"rc" => "08338636"})

      assert row["repcode"] == "08338636"
    end

    test "a bare numeric literal does not match a string tag", %{conn: conn, db: db} do
      # Real engine: WHERE repcode = 08338636 returns no rows.
      sql = "SELECT * FROM acct WHERE repcode = 08338636"
      assert {:ok, []} = Local.query_sql(conn, sql, database: db)
    end

    test "a string literal against a float field compares as text", %{conn: conn, db: db} do
      # Real engine: '500.0' >= '1000.00' lexically, so BOTH rows come back.
      # The double reproduces the footgun so tests fail the way prod does.
      sql = "SELECT * FROM acct WHERE amount >= '1000.00'"
      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)
      assert length(rows) == 2

      # Real engine: 500.0 renders as "500.0", so '500' is not equal ...
      assert {:ok, []} =
               Local.query_sql(conn, "SELECT * FROM acct WHERE amount = '500'", database: db)

      # ... but '500.0' is.
      assert {:ok, [row]} =
               Local.query_sql(conn, "SELECT * FROM acct WHERE amount IN ('500.0')", database: db)

      assert row["amount"] == 500.0
    end

    test "a bare numeric literal against a float field compares numerically",
         %{conn: conn, db: db} do
      sql = "SELECT * FROM acct WHERE amount >= 1000.0"
      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["amount"] == 5000.0
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
      assert {:ok, rows} = Local.query_flux(conn, flux)
      assert length(rows) == 1
      assert hd(rows)["host"] == "new"
    end

    test "range with minutes unit filters correctly", %{v2_conn: conn} do
      flux = "from(bucket: \"flux_range_db\") |> range(start: -1m)"
      assert {:ok, rows} = Local.query_flux(conn, flux)
      assert length(rows) == 1
      assert hd(rows)["host"] == "new"
    end

    test "range with days unit includes all recent points", %{v2_conn: conn} do
      flux = "from(bucket: \"flux_range_db\") |> range(start: -1d)"
      assert {:ok, rows} = Local.query_flux(conn, flux)
      assert length(rows) == 2
    end

    test "flux query with no range clause returns all points", %{v2_conn: conn} do
      # No range() pipe — passthrough
      flux = "from(bucket: \"flux_range_db\")"
      assert {:ok, rows} = Local.query_flux(conn, flux)
      assert length(rows) == 2
    end

    test "flux filter predicate on tag field", %{v2_conn: conn} do
      flux =
        "from(bucket: \"flux_range_db\") |> range(start: -1d) |> filter(fn: (r) => r.host == \"new\")"

      assert {:ok, rows} = Local.query_flux(conn, flux)
      assert length(rows) == 1
      assert hd(rows)["host"] == "new"
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — boolean parameter substitution
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — boolean and nil parameter substitution" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "bool_param_db")

      Local.write(
        conn,
        "devices,id=d1 active=true\ndevices,id=d2 active=false",
        database: "bool_param_db"
      )

      {:ok, db: "bool_param_db"}
    end

    test "boolean true param substituted correctly", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM devices WHERE active = $flag",
                 database: db,
                 params: %{"$flag" => true}
               )

      assert length(rows) == 1
      assert hd(rows)["id"] == "d1"
    end

    test "boolean false param substituted correctly", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM devices WHERE active = $flag",
                 database: db,
                 params: %{"$flag" => false}
               )

      assert length(rows) == 1
      assert hd(rows)["id"] == "d2"
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

    test "aggregate on measurement without explicit timestamps uses server time",
         %{conn: conn, db: db} do
      # Points without timestamps get server-assigned time (like real InfluxDB).
      # Both points land in the same 1-hour bucket since they're written together.
      Local.write(conn, "no_ts val=10i\nno_ts val=20i", database: db)

      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        SUM(val) AS total
      FROM no_ts
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      """

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["total"] == 30
      # Bucket time should be the server-assigned hour, not the epoch
      assert %DateTime{} = row["time"]
      refute row["time"] == ~U[1970-01-01 00:00:00.000000Z]
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

      Local.write(conn, Enum.join(lines, "\n"), database: "ord_db")
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

      assert {:ok, rows} = Local.query_sql(conn, "SELECT symbol FROM prices", database: db)
      assert length(rows) == writers * per_writer
      assert rows |> Enum.map(& &1["symbol"]) |> Enum.uniq() |> length() == writers * per_writer
    end

    test "parallel create_database calls all register", %{conn: conn} do
      names = for i <- 1..16, do: "par_db_#{i}"

      names
      |> Enum.map(&Task.async(fn -> Local.create_database(conn, &1) end))
      |> Enum.each(&Task.await/1)

      assert {:ok, dbs} = Local.list_databases(conn)
      listed = Enum.map(dbs, & &1["name"])
      assert Enum.all?(names, &(&1 in listed))
    end

    test "a DELETE running beside writes only removes what it matched", %{db: db} do
      {:ok, ent} = Local.start(databases: [db], profile: :v3_enterprise)
      on_exit(fn -> Local.stop(ent) end)

      Local.write(ent, Enum.map_join(1..50, "\n", &"m,k=old v=#{&1}i"), database: db)

      writer =
        Task.async(fn ->
          for i <- 1..50, do: Local.write(ent, "m,k=new v=#{i}i", database: db)
        end)

      {:ok, %{"rows_affected" => 50}} =
        Local.execute_sql(ent, "DELETE FROM m WHERE k = 'old'", database: db)

      Task.await(writer)

      assert {:ok, rows} = Local.query_sql(ent, "SELECT k FROM m", database: db)
      assert length(rows) == 50
      assert Enum.all?(rows, &(&1["k"] == "new"))
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

    test "six points written 900 seconds apart roundtrip with original spacing",
         %{conn: conn, db: db} do
      base_ns = 1_700_000_000_000_000_000
      step_ns = 900 * 1_000_000_000

      lines =
        for i <- 0..5 do
          ts = base_ns + i * step_ns
          "candles,symbol=BTC close=#{100 + i}.0 #{ts}"
        end

      Local.write(conn, Enum.join(lines, "\n"), database: db)

      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM candles ORDER BY time ASC",
                 database: db
               )

      times = Enum.map(rows, & &1["time"])
      assert length(times) == 6
      assert times == Enum.uniq(times), "timestamps must remain distinct"

      pairs = Enum.zip(times, tl(times))

      for {a, b} <- pairs do
        diff_seconds = DateTime.diff(b, a)
        assert diff_seconds == 900, "expected 900s spacing, got #{diff_seconds}s"
      end
    end

    test "ORDER BY time ASC returns oldest-first with explicit timestamps",
         %{conn: conn, db: db} do
      base_ns = 1_700_000_000_000_000_000
      step_ns = 60 * 1_000_000_000

      lp =
        Enum.map_join(0..3, "\n", fn i ->
          "obs val=#{i}i #{base_ns + i * step_ns}"
        end)

      Local.write(conn, lp, database: db)

      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM obs ORDER BY time ASC", database: db)

      assert Enum.map(rows, & &1["val"]) == [0, 1, 2, 3]
    end
  end

  describe "bug regression — IN operator is parsed and enforced" do
    # Bug: in-operator. parse_single_where_clause silently dropped IN clauses
    # because none of the binary operators matched "IN", so wrong rows came back.
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "in_op_db")

      Local.write(
        conn,
        Enum.join(
          [
            "traces,strategy_id=s1,decision=entered prob=0.9 1000000000",
            "traces,strategy_id=s1,decision=rejected prob=0.1 2000000000",
            "traces,strategy_id=s1,decision=skipped prob=0.4 3000000000"
          ],
          "\n"
        ),
        database: "in_op_db"
      )

      {:ok, db: "in_op_db"}
    end

    test "IN list narrows to listed values only", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM traces WHERE decision IN ('entered')",
                 database: db
               )

      assert length(rows) == 1
      assert hd(rows)["decision"] == "entered"
    end

    test "IN list with parameter substitution narrows correctly",
         %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM traces WHERE decision IN ($d0, $d1)",
                 database: db,
                 params: %{"$d0" => "entered", "$d1" => "skipped"}
               )

      assert Enum.map(rows, & &1["decision"]) |> Enum.sort() ==
               ["entered", "skipped"]
    end
  end

  describe "bug regression — unrecognised WHERE clauses do not silently drop" do
    # Bug: in-operator (corollary). The fix list says: clauses the parser cannot
    # recognise must not produce wrong rows. Today they yield []; with this
    # regression test we lock in that behaviour into an explicit error so a
    # future "LIKE 'foo%'" clause cannot silently match everything.
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "where_strict_db")

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
      assert {:error, %{status: 400, body: body}} =
               Local.query_sql(
                 conn,
                 "SELECT * FROM alerts WHERE severity SIMILAR TO 'h%'",
                 database: db
               )

      assert body =~ "WHERE"
    end
  end

  describe "bug regression — explicit column-list SELECT" do
    # Bug: explicit-column-select. parse_columns_select/1 now handles SELECT
    # col1, col2 ... FROM "measurement" WHERE ... ORDER BY ... LIMIT N.
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "cols_db")

      Local.write(
        conn,
        Enum.join(
          [
            "decision_traces,strategy_id=s1,symbol=BTC decision=\"entered\",trace_json=\"{}\" 1000000000",
            "decision_traces,strategy_id=s1,symbol=ETH decision=\"rejected\",trace_json=\"{}\" 2000000000"
          ],
          "\n"
        ),
        database: "cols_db"
      )

      {:ok, db: "cols_db"}
    end

    test "explicit column list projects only requested columns",
         %{conn: conn, db: db} do
      sql = """
      SELECT time, strategy_id, symbol, decision, trace_json
      FROM "decision_traces"
      WHERE strategy_id = $strategy_id
        AND time >= $start_time
      ORDER BY time DESC
      LIMIT 100
      """

      assert {:ok, rows} =
               Local.query_sql(conn, sql,
                 database: db,
                 params: %{
                   "$strategy_id" => "s1",
                   "$start_time" => "1970-01-01T00:00:00Z"
                 }
               )

      assert length(rows) == 2
      [first | _rest] = rows

      assert Map.keys(first) |> Enum.sort() ==
               ["decision", "strategy_id", "symbol", "time", "trace_json"]
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

      Local.write(conn, Enum.join(lines, "\n"), database: "count_star_db")
      {:ok, db: "count_star_db"}
    end

    test "scalar COUNT(*) returns total row count", %{conn: conn, db: db} do
      assert {:ok, [row]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT COUNT(*) AS n FROM "decision_traces"|,
                 database: db
               )

      assert row["n"] == 5
    end

    test "COUNT(*) with DATE_BIN buckets by day", %{conn: conn, db: db} do
      sql = """
      SELECT DATE_BIN(INTERVAL '1 day', time) AS day, COUNT(*) AS n
      FROM "decision_traces"
      GROUP BY DATE_BIN(INTERVAL '1 day', time)
      ORDER BY day ASC
      """

      assert {:ok, [b1, b2]} = Local.query_sql(conn, sql, database: db)
      assert b1["n"] == 3
      assert b2["n"] == 2
    end

    test "COUNT(*) ignores field nullity (counts rows missing the field)",
         %{conn: conn, db: db} do
      # Add a row whose field is a different name — COUNT(prob) would skip it,
      # COUNT(*) must include it.
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
      assert_in_delta row["sd_pop"], 8.16496580927726, 1.0e-12
      assert row["v"] == 100.0
      assert row["v_samp"] == 100.0
      assert_in_delta row["v_pop"], 66.66666666666667, 1.0e-12
    end

    test "sample statistics over one row are null and the column is omitted",
         %{conn: conn, db: db} do
      sql = """
      SELECT STDDEV(value) AS sd, VAR(value) AS v, VAR_POP(value) AS v_pop
      FROM "m"
      WHERE provider = 'b'
      """

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      refute Map.has_key?(row, "sd")
      refute Map.has_key?(row, "v")
      assert row["v_pop"] == 0.0
    end

    test "an empty group keeps only COUNT (0); every other aggregate is omitted",
         %{conn: conn, db: db} do
      sql = """
      SELECT COUNT(value) AS n, AVG(value) AS a, STDDEV(value) AS sd
      FROM "m"
      WHERE provider = 'none'
      """

      assert {:ok, [%{"n" => 0} = row]} = Local.query_sql(conn, sql, database: db)
      refute Map.has_key?(row, "a")
      refute Map.has_key?(row, "sd")
    end

    test "VARIANCE is not a DataFusion function and is rejected", %{conn: conn, db: db} do
      assert {:error, %{status: 400, body: "Client.Local: " <> _reason}} =
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

    test "division by zero inside an aggregate yields null, not a crash",
         %{conn: conn, db: db} do
      sql = ~s|SELECT SUM(value / 0) AS s, COUNT(value / 0) AS n FROM "m"|

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      refute Map.has_key?(row, "s")
      assert row["n"] == 0
    end

    test "a malformed expression is rejected with a Client.Local error", %{conn: conn, db: db} do
      for sql <- [
            ~s|SELECT AVG(value, other) AS a FROM "m"|,
            ~s|SELECT AVG(value +) AS a FROM "m"|,
            ~s|SELECT AVG((value) AS a FROM "m"|,
            ~s|SELECT AVG(value $ 2) AS a FROM "m"|
          ] do
        assert {:error, %{status: 400, body: "Client.Local: " <> _reason}} =
                 Local.query_sql(conn, sql, database: db),
               sql
      end
    end

    test "ORDER BY a non-time projected column sorts groups", %{conn: conn, db: db} do
      sql = """
      SELECT provider, SUM(value) AS total
      FROM "m"
      GROUP BY provider
      ORDER BY total DESC
      """

      assert {:ok, [first, second]} = Local.query_sql(conn, sql, database: db)
      assert first["provider"] == "a"
      assert first["total"] == 60.0
      assert second["provider"] == "b"
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
      refute Map.has_key?(row, "v")
    end

    test "a selector without the ['value'|'time'] accessor is rejected", %{conn: conn, db: db} do
      assert {:error, %{status: 400, body: "Client.Local: selector functions" <> _reason}} =
               Local.query_sql(conn, ~s|SELECT selector_last(value, time) AS v FROM "m"|,
                 database: db
               )
    end
  end

  describe "bug regression — multi-column DISTINCT and null omission (#17)" do
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

    test "SELECT DISTINCT a, b returns unique combinations", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, ~s|SELECT DISTINCT provider, symbol FROM "m"|, database: db)

      assert Enum.sort_by(rows, & &1["provider"]) == [
               %{"provider" => "a", "symbol" => "X"},
               %{"provider" => "b", "symbol" => "Y"}
             ]
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

      assert {:error, %{status: 400, body: "Client.Local: " <> _reason} = err} =
               Local.check_sql(sql)

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

      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 ~s|SELECT price FROM "q" WHERE time >= now() - INTERVAL '1 hour' - INTERVAL '30 minutes' AND time < NOW() + INTERVAL '1 day'|,
                 database: db
               )

      assert length(rows) == 3
    end

    test "an unknown function as a time comparand is rejected", %{conn: conn, db: db} do
      assert {:error, %{status: 400, body: "Client.Local: InfluxDB rejects" <> _rest}} =
               Local.query_sql(conn, ~s|SELECT price FROM "q" WHERE time >= foo()|, database: db)
    end

    test "IS NULL and IS NOT NULL filter on field presence", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 ~s|SELECT price FROM "q" WHERE bid IS NOT NULL ORDER BY price|,
                 database: db
               )

      assert Enum.map(rows, & &1["price"]) == [1.0, 3.0]

      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 ~s|SELECT price FROM "q" WHERE bid IS NULL AND provider != 'c'|,
                 database: db
               )

      assert Enum.map(rows, & &1["price"]) == [2.0]
    end

    test "COUNT(DISTINCT col) counts distinct non-null values", %{conn: conn, db: db} do
      assert {:ok, [%{"n" => 3, "b" => 2}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT COUNT(DISTINCT provider) AS n, COUNT(DISTINCT bid) AS b FROM "q"|,
                 database: db
               )

      assert {:ok, [%{"n" => 0}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT COUNT(DISTINCT provider) AS n FROM "q" WHERE provider = 'zzz'|,
                 database: db
               )

      assert {:ok, [%{"provider" => "a", "n" => 1} | _rest]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT provider, COUNT(DISTINCT symbol) AS n FROM "q" GROUP BY provider ORDER BY provider|,
                 database: db
               )
    end

    test "MAX(time), MIN(time) and COUNT(time) work; other aggregates over time are rejected",
         %{conn: conn, db: db} do
      assert {:ok, [%{"mx" => %DateTime{} = mx, "mn" => %DateTime{} = mn, "n" => 4}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT MAX(time) AS mx, MIN(time) AS mn, COUNT(time) AS n FROM "q"|,
                 database: db
               )

      assert DateTime.compare(mx, mn) == :gt

      for sql <- [
            ~s|SELECT AVG(time) AS a FROM "q"|,
            ~s|SELECT SUM(time) AS s FROM "q"|,
            ~s|SELECT STDDEV(time) AS s FROM "q"|,
            ~s|SELECT MAX(time - 1) AS s FROM "q"|
          ] do
        assert {:error, %{status: 400, body: "Client.Local: InfluxDB rejects" <> _rest}} =
                 Local.query_sql(conn, sql, database: db),
               sql
      end
    end

    test "SELECT DISTINCT honours ORDER BY on a selected column", %{conn: conn, db: db} do
      assert {:ok, [%{"provider" => "c"}, %{"provider" => "b"}, %{"provider" => "a"}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT DISTINCT provider FROM "q" ORDER BY provider DESC|,
                 database: db
               )

      assert {:ok, [%{"provider" => "c", "symbol" => "Z"}, %{"provider" => "b", "symbol" => "Y"}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT DISTINCT provider, symbol FROM "q" ORDER BY symbol DESC LIMIT 2|,
                 database: db
               )
    end

    test "SELECT DISTINCT rejects ORDER BY a column outside the select list",
         %{conn: conn, db: db} do
      assert {:error, %{status: 400, body: "Client.Local: For SELECT DISTINCT" <> _rest}} =
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

      assert Enum.map(rows, & &1["mid"]) == [2.0, 3.0, nil, 6.0]
      refute Map.has_key?(Enum.at(rows, 2), "mid")
      assert Enum.all?(rows, &match?(%DateTime{}, &1["time"]))
    end

    test "ORDER BY a projected alias", %{conn: conn, db: db} do
      assert {:ok, [%{}, %{"mid" => 6.0}, %{"mid" => 3.0}, %{"mid" => 2.0}]} =
               Local.query_sql(conn, ~s|SELECT (bid + ask) / 2 AS mid FROM "q" ORDER BY mid DESC|,
                 database: db
               )
    end

    test "an expression without AS alias is rejected with the reason", %{conn: conn, db: db} do
      assert {:error,
              %{
                status: 400,
                body: "Client.Local: unsupported column (an expression needs AS alias)" <> _rest
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
      assert Enum.map(rows, & &1["hi"]) == [1.0, 2.0, 10.0]
      assert hd(rows)["time"] == ~U[1970-01-01 00:00:00.000000Z]
    end

    test "the candle shape: a derived mid in a CTE, then selectors over it", %{conn: conn, db: db} do
      sql = """
      WITH w AS (SELECT (bid + ask) / 2 AS mid, time FROM "q" WHERE ask IS NOT NULL)
      SELECT
        DATE_BIN(INTERVAL '1 minute', time) AS time,
        selector_first(mid, time)['value'] AS open,
        MAX(mid) AS high,
        selector_last(mid, time)['value'] AS close
      FROM w
      GROUP BY DATE_BIN(INTERVAL '1 minute', time)
      ORDER BY time
      """

      assert {:ok, [b0, b1, b2]} = Local.query_sql(conn, sql, database: db)
      assert %{"open" => 2.0, "high" => 2.0, "close" => 2.0} = b0
      assert %{"open" => 3.0, "high" => 3.0, "close" => 3.0} = b1
      assert %{"open" => 6.0, "high" => 6.0, "close" => 6.0} = b2
    end

    test "CTEs chain in order and a later one may read an earlier one", %{conn: conn, db: db} do
      sql = """
      WITH w AS (SELECT bid, provider, time FROM "q"),
           x AS (SELECT provider, MAX(bid) AS mb FROM w GROUP BY provider)
      SELECT * FROM x ORDER BY provider
      """

      assert {:ok,
              [%{"provider" => "a", "mb" => 2.0} = first, %{"provider" => "b", "mb" => 10.0}]} =
               Local.query_sql(conn, sql, database: db)

      # x has no time column; none is invented.
      refute Map.has_key?(first, "time")
    end

    test "a CTE shadows nothing it does not name", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, ~s|WITH w AS (SELECT bid FROM "q") SELECT * FROM "q"|,
                 database: db
               )

      assert length(rows) == 4

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
      assert {:ok, [%{"bid" => 1.0, "time" => %DateTime{}}]} =
               Local.query_sql(conn, ~s|SELECT q.bid, q.time FROM q AS q ORDER BY q.time LIMIT 1|,
                 database: db
               )

      assert {:ok, [%{"bid" => 5.0}, %{"bid" => 10.0}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT t.bid FROM q t WHERE t.provider = 'b' ORDER BY t.bid|,
                 database: db
               )

      assert {:ok, [_b0, _b1, %{"n" => 2}]} =
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
      for {sql, construct} <- [
            {~s|SELECT bid FROM "q" INNER JOIN "q" AS r ON q.time = r.time|, "JOIN"},
            {~s|SELECT bid FROM "q" UNION SELECT ask FROM "q"|, "UNION"},
            {~s|SELECT provider, COUNT(*) AS n FROM "q" GROUP BY provider HAVING n > 1|, "HAVING"}
          ] do
        assert {:error, %{status: 400, body: body}} = Local.query_sql(conn, sql, database: db)
        assert body =~ "Client.Local: unsupported SQL construct #{construct}", sql
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
              %{status: 400, body: "Client.Local: unsupported SQL construct OVER" <> _rest}} =
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

    test "OR, and AND binding tighter than OR", %{conn: conn, db: db} do
      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE v > 3 OR v < 2 ORDER BY host|) ==
               ["a", "d", "e"]

      assert hosts(
               conn,
               db,
               ~s|SELECT host FROM "m" WHERE host = 'a' OR host = 'b' AND v > 2 ORDER BY host|
             ) ==
               ["a", "b"]

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

    test "parentheses group, NOT negates a predicate or a group", %{conn: conn, db: db} do
      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE (host = 'a' OR host = 'b') AND v > 2|) ==
               ["b"]

      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE NOT host = 'a' ORDER BY host|) ==
               ["b", "c", "d", "e"]

      assert hosts(
               conn,
               db,
               ~s|SELECT host FROM "m" WHERE NOT (host = 'a' OR host = 'b') ORDER BY host|
             ) ==
               ["c", "d", "e"]

      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE NOT rack IS NULL ORDER BY host|) ==
               ["a", "b", "d", "e"]

      assert hosts(
               conn,
               db,
               ~s|SELECT host FROM "m" WHERE host NOT IN ('a', 'b') AND v > 3 ORDER BY host|
             ) ==
               ["d", "e"]
    end

    test "<> is not-equal", %{conn: conn, db: db} do
      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE v <> 1.0 ORDER BY host|) ==
               ["b", "c", "d", "e"]
    end

    test "BETWEEN and NOT BETWEEN, on fields and on time", %{conn: conn, db: db} do
      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE v BETWEEN 2 AND 3 ORDER BY host|) ==
               ["b", "c"]

      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE v NOT BETWEEN 2 AND 3 ORDER BY host|) ==
               ["a", "d", "e"]

      assert hosts(
               conn,
               db,
               ~s|SELECT host FROM "m" WHERE time BETWEEN '1970-01-01T00:00:02Z' AND '1970-01-01T00:00:03Z' ORDER BY host|
             ) == ["b", "c"]
    end

    test "LIKE is case-sensitive, ILIKE is not, _ is one character, NOT LIKE negates",
         %{conn: conn, db: db} do
      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE host LIKE 'a%'|) == ["a"]
      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE host LIKE 'A%'|) == []
      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE host ILIKE 'A%'|) == ["a"]

      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE host LIKE '_' ORDER BY host|) ==
               ~w(a b c d e)

      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE host NOT LIKE 'a%' ORDER BY host|) ==
               ["b", "c", "d", "e"]

      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE rack LIKE '1%' ORDER BY host|) ==
               ["a", "e"]
    end

    test "LIKE over a numeric column is the engine's planning error", %{conn: conn, db: db} do
      assert {:error,
              %{status: 400, body: "Error during planning: There isn't a common type" <> _rest}} =
               Local.query_sql(conn, ~s|SELECT host FROM "m" WHERE v LIKE '1%'|, database: db)
    end

    test "a string column against a numeric literal compares the literal's text, lexically",
         %{conn: conn, db: db} do
      # rack is a tag: "1", "2", "4", "10". DataFusion keeps the column Utf8
      # and renders the literal, so 10 > 3 is false ("10" < "3") but "2" >= "10".
      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE rack = 2|) == ["b"]
      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE rack > 3 ORDER BY host|) == ["d"]

      assert hosts(conn, db, ~s|SELECT host FROM "m" WHERE rack >= 10 ORDER BY host|) == [
               "b",
               "d",
               "e"
             ]

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

      assert {:error, %{status: 400, body: "Client.Local: LIMIT must be >= 0" <> _rest}} =
               Local.query_sql(conn, ~s|SELECT host FROM "m" LIMIT -1|, database: db)

      assert {:error, %{status: 400, body: "Client.Local: unsupported LIMIT" <> _rest}} =
               Local.query_sql(conn, ~s|SELECT host FROM "m" LIMIT abc|, database: db)
    end

    test "malformed boolean expressions are rejected, not truncated", %{conn: conn, db: db} do
      assert {:error, %{status: 400, body: "Client.Local: unbalanced parenthesis" <> _rest}} =
               Local.query_sql(conn, ~s|SELECT host FROM "m" WHERE (host = 'a'|, database: db)

      assert {:error, %{status: 400, body: "Client.Local: unsupported WHERE clause" <> _rest}} =
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

    test "median: middle value, mean of the two middles in the column's type, null when empty",
         %{conn: conn, db: db} do
      assert {:ok, [%{"med" => 3.0, "mv" => 20.0}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT median(price) AS med, median(volume) AS mv FROM "p"|,
                 database: db
               )

      assert {:ok, [%{"med" => 2.5}]} =
               Local.query_sql(conn, ~s|SELECT median(price) AS med FROM "p" WHERE price < 4|,
                 database: db
               )

      # Integers: (2 + 3) / 2 and (1 + 4) / 2 with integer division.
      assert {:ok, [%{"med" => 2}]} =
               Local.query_sql(conn, ~s|SELECT median(n) AS med FROM "q"|, database: db)

      assert {:ok, [%{"med" => 2}]} =
               Local.query_sql(conn, ~s|SELECT median(n) AS med FROM "q" WHERE n IN (1, 4)|,
                 database: db
               )

      assert {:ok, [row]} =
               Local.query_sql(conn, ~s|SELECT median(price) AS med FROM "p" WHERE price > 1000|,
                 database: db
               )

      refute Map.has_key?(row, "med")

      assert {:ok, [%{"med" => 6.0}]} =
               Local.query_sql(conn, ~s|SELECT median(price * 2) AS med FROM "p"|, database: db)

      assert {:ok, [%{"med" => 1.75}, %{"med" => 4.0}]} =
               Local.query_sql(
                 conn,
                 ~s|SELECT DATE_BIN(INTERVAL '1 minute', time) AS t, median(price) AS med FROM "p" GROUP BY DATE_BIN(INTERVAL '1 minute', time) ORDER BY t|,
                 database: db
               )

      assert {:error, %{status: 400, body: "Client.Local: InfluxDB rejects" <> _rest}} =
               Local.query_sql(conn, ~s|SELECT median(time) AS med FROM "q"|, database: db)
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
                %{"open" => 1.0, "high" => 2.5, "low" => 1.0, "close" => 2.5, "volume" => 30.0},
                %{"open" => 3.0, "high" => 4.0, "low" => 3.0, "close" => 4.0, "volume" => 70.0}
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

      assert {:error, %{status: 500, body: "Schema error: Ambiguous reference" <> _rest}} =
               Local.query_sql(
                 conn,
                 ~s|WITH ref AS (SELECT median(price) AS price FROM "p") SELECT price FROM "p" CROSS JOIN ref|,
                 database: db
               )

      # Both sides carry `time`.
      assert {:error, %{status: 500, body: "Schema error: Ambiguous reference" <> _rest}} =
               Local.query_sql(conn, ~s|SELECT price FROM "p" CROSS JOIN "q"|, database: db)

      assert {:error,
              %{status: 400, body: "Error during planning: table 'public.iox.nope' not found"}} =
               Local.query_sql(conn, ~s|SELECT price FROM "p" CROSS JOIN nope|, database: db)
    end

    test "arithmetic on either side of a WHERE comparison", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 ~s|SELECT price FROM "p" WHERE price <= volume * 0.2 ORDER BY price|,
                 database: db
               )

      assert Enum.map(rows, & &1["price"]) == [1.0, 2.5, 3.0, 4.0]

      assert {:ok, [%{"price" => 100.0}]} =
               Local.query_sql(conn, ~s|SELECT price FROM "p" WHERE 2 * price > volume|,
                 database: db
               )
    end

    test "a bare word is a column; an unknown one is the engine's schema error",
         %{conn: conn, db: db} do
      assert {:error, %{status: 500, body: "Schema error: No field named prod." <> _rest}} =
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
            ~s|SELECT COUNT(DISTINCT nosuch) AS n FROM "p"|,
            ~s|WITH w AS (SELECT host FROM "p") SELECT nosuch FROM w|
          ] do
        assert {:error, %{status: 500, body: "Schema error: No field named nosuch." <> _rest}} =
                 Local.query_sql(conn, sql, database: db),
               sql
      end
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
      for sql <- [
            ~s|SELECT host, v FROM "p" GROUP BY host|,
            ~s|SELECT host, MAX(v) AS m FROM "p"|,
            ~s|SELECT host, DATE_BIN(INTERVAL '1 minute', time) AS t, MAX(v) AS m FROM "p" GROUP BY DATE_BIN(INTERVAL '1 minute', time)|
          ] do
        assert {:error,
                %{
                  status: 400,
                  body: "Error during planning: Column in SELECT must be in GROUP BY" <> _rest
                }} =
                 Local.query_sql(conn, sql, database: db),
               sql
      end

      assert {:error, %{status: 400}} =
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
      assert {:error, {:connection_error, :closed}} =
               Local.query_sql(
                 conn,
                 ~s|SELECT level FROM "bad" WHERE CAST(level AS INTEGER) <= 20|,
                 database: db
               )

      assert {:error, {:connection_error, :closed}} =
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

      assert {:error, %{status: 400, body: "Client.Local: unsupported column" <> _rest}} =
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

      assert {:ok, rows} =
               Local.query_sql(
                 conn,
                 ~s|SELECT symbol, level FROM "orderbooks" ORDER BY symbol DESC, CAST(level AS INTEGER) ASC|,
                 database: db
               )

      assert Enum.map(rows, &{&1["symbol"], &1["level"]}) == [
               {"Y", "20"},
               {"X", "5"},
               {"X", "20"},
               {"X", "100"}
             ]

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
                body: "Client.Local: ORDER BY an expression is not supported" <> _rest
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
      assert {:error, %{status: 500, body: "Schema error: No field named a." <> _rest}} =
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

      assert {:ok, [%{"volume" => +0.0, "m" => 2.0, "t" => %DateTime{}}]} =
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
                body: "Client.Local: unsupported column (a constant needs AS alias)" <> _rest
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
      for {first, second, expected, got} <- [
            {"t,host=a v=1i", ~s|t host="b",v=2i|, "iox::column_type::tag",
             "iox::column_type::field::string"},
            {~s|f host="a",v=1i|, "f,host=b v=2i", "iox::column_type::field::string",
             "iox::column_type::tag"},
            {~s|s s="x"|, "s s=1.0", "iox::column_type::field::string",
             "iox::column_type::field::float"},
            {"b b=true", "b b=1i", "iox::column_type::field::boolean",
             "iox::column_type::field::integer"}
          ] do
        {:ok, :written} = Local.write(conn, first, database: db)
        assert {:error, %{status: 400, body: body}} = Local.write(conn, second, database: db)
        [{1, message}] = partial_errors(body)
        assert message =~ "expected #{expected}, got #{got}", second
      end

      # A new column, and the same measurement in another database, are fine.
      {:ok, :written} = Local.write(conn, "c w=1.0 1700000000000000002", database: db)
      :ok = Local.create_database(conn, "wr_other")
      {:ok, :written} = Local.write(conn, "c v=2.0 1700000000000000000", database: "wr_other")
    end

    test "a bad line is dropped and reported; the other lines are stored", %{conn: conn, db: db} do
      lp = "p v=1i 1700000000000000000\np v=2.0 1700000000000000001\np v=3i 1700000000000000002"
      assert {:error, %{status: 400, body: body}} = Local.write(conn, lp, database: db)

      assert [{2, "invalid column type for column 'v'" <> _rest}] = partial_errors(body)

      assert {:ok, [%{"v" => 1}, %{"v" => 3}]} =
               Local.query_sql(conn, ~s|SELECT v FROM "p" ORDER BY time|, database: db)

      # A syntax error is reported the same way, with every bad line listed.
      lp =
        "q v=1i 1700000000000000000\nq v=\nq v=2.0 1700000000000000002\nq v=3i 1700000000000000003"

      assert {:error, %{status: 400, body: body}} = Local.write(conn, lp, database: db)

      assert [{2, "No fields were provided"}, {3, "invalid column type" <> _rest}] =
               partial_errors(body)

      assert {:ok, [%{"v" => 1}, %{"v" => 3}]} =
               Local.query_sql(conn, ~s|SELECT v FROM "q" ORDER BY time|, database: db)
    end

    test "the original line in a report is truncated to 20 characters, as the engine does",
         %{conn: conn, db: db} do
      assert {:error, %{status: 400, body: body}} =
               Local.write(conn, "r,host=a,rack=1 v=abc 1700000000000000000", database: db)

      %{"data" => [%{"original_line" => original}]} = Jason.decode!(body)
      assert original == "r,host=a,rack=1 v=ab"
    end

    test "time is a reserved column; a key cannot be both tag and field; an integer must fit int64",
         %{conn: conn, db: db} do
      for {lp, message} <- [
            {"m,time=x v=1i", "'time' is a reserved column"},
            {"m time=5i,v=1i", "'time' is a reserved column"},
            {"m,host=a host=1i",
             "invalid column type for column 'host', expected iox::column_type::tag, got iox::column_type::field::integer"},
            {"m v=9223372036854775808i", "Unable to parse integer value `9223372036854775808`"},
            {"m,host= v=1i", "Expected tag value, got `host=`"},
            {"m,=a v=1i", "Expected tag key, got `=a`"},
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

    test "int64 extremes, unsigned integers and a newline inside a quoted value are accepted",
         %{conn: conn, db: db} do
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

      {:ok, :written} = Local.write(conn, ~s|nl s="a\nb" 1700000000000000000|, database: db)

      assert {:ok, [%{"s" => "a\nb"}]} =
               Local.query_sql(conn, ~s|SELECT s FROM "nl"|, database: db)
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

    test "OFFSET skips rows before LIMIT takes them, in either order", %{conn: conn, db: db} do
      assert hosts(conn, db, ~s|SELECT host FROM "p" ORDER BY time LIMIT 2 OFFSET 1|) == [
               "b",
               "c"
             ]

      assert hosts(conn, db, ~s|SELECT host FROM "p" ORDER BY time LIMIT 2 OFFSET 0|) == [
               "a",
               "b"
             ]

      assert hosts(conn, db, ~s|SELECT host FROM "p" ORDER BY time LIMIT 2 OFFSET 4|) == ["e"]
      assert hosts(conn, db, ~s|SELECT host FROM "p" ORDER BY time LIMIT 2 OFFSET 10|) == []
      assert hosts(conn, db, ~s|SELECT host FROM "p" ORDER BY time OFFSET 3|) == ["d", "e"]
      assert hosts(conn, db, ~s|SELECT host FROM "p" ORDER BY time OFFSET 3 LIMIT 1|) == ["d"]
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
      assert {:error, %{status: 400, body: "Client.Local: OFFSET must be >=0" <> _rest}} =
               Local.query_sql(conn, ~s|SELECT host FROM "p" LIMIT 2 OFFSET -1|, database: db)

      assert {:error, %{status: 400, body: "Client.Local: unsupported LIMIT / OFFSET" <> _rest}} =
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

      for {first, second, existing, got} <- [
            {~s|s s="x"|, "s s=1.0", "string", "float"},
            {"b b=true", "b b=1i", "boolean", "integer"},
            {"u v=1i", "u v=2u", "integer", "unsigned"}
          ] do
        {:ok, :written} = Local.write(conn, first, database: "metrics")

        assert {:error, %{status: 422, body: body}} =
                 Local.write(conn, second, database: "metrics")

        assert Jason.decode!(body)["message"] =~
                 "is type #{got}, already exists as type #{existing} dropped=1"
      end
    end

    test "a line that fails to parse rejects the whole payload with 400 and stores nothing",
         %{conn: conn} do
      lp = "p2 v=1i 1700000000000000000\np2 v=\np2 v=3i 1700000000000000002"
      assert {:error, %{status: 400, body: body}} = Local.write(conn, lp, database: "metrics")

      assert %{
               "code" => "invalid",
               "message" => "unable to parse 'p2 v=': No fields were provided"
             } =
               Jason.decode!(body)

      assert {:ok, []} =
               Local.query_flux(conn, v2_flux("p2"))

      assert {:error, %{status: 400, body: body}} =
               Local.write(conn, "p3 v=9223372036854775808i 1700000000000000000",
                 database: "metrics"
               )

      assert Jason.decode!(body)["message"] =~
               "unable to parse 'p3 v=9223372036854775808i 1700000000000000000': Unable to parse integer"
    end

    test "time as a tag is refused; time as a field is dropped silently; a tag and a field may share a name; an empty payload is accepted",
         %{conn: conn} do
      assert {:error, %{status: 400, body: body}} =
               Local.write(conn, "t1,time=x v=1i 1700000000000000000", database: "metrics")

      assert Jason.decode!(body)["message"] =~ ~s|cannot use reserved tag key "time"|

      {:ok, :written} =
        Local.write(conn, "t2 time=5i,v=1i 1700000000000000000", database: "metrics")

      assert {:ok, [%{"_field" => "v", "_value" => 1}]} =
               Local.query_flux(conn, v2_flux("t2"))

      {:ok, :written} =
        Local.write(conn, "t3,host=a host=1i 1700000000000000000", database: "metrics")

      {:ok, :written} =
        Local.write(conn, "t3,host=b v=2i 1700000000000000001", database: "metrics")

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

    test "the :v2 profile merges the same way and Flux reads one row per field" do
      {:ok, conn} = Local.start(profile: :v2)
      on_exit(fn -> Local.stop(conn) end)
      :ok = Local.create_bucket(conn, "metrics")

      {:ok, :written} = Local.write(conn, "g,h=x v=1i,w=1i #{@t}", database: "metrics")
      {:ok, :written} = Local.write(conn, "g,h=x v=2i #{@t}", database: "metrics")

      assert {:ok, rows} = Local.query_flux(conn, v2_flux("g"))
      assert Enum.sort(Enum.map(rows, &{&1["_field"], &1["_value"]})) == [{"v", 2}, {"w", 1}]
    end
  end
end
