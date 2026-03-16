defmodule InfluxElixir.Client.LocalTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

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
  end

  # ---------------------------------------------------------------------------
  # Write — basic
  # ---------------------------------------------------------------------------

  describe "write/3 — basic" do
    test "returns {:ok, :written} for valid line protocol", %{conn: conn} do
      assert {:ok, :written} = Local.write(conn, "cpu value=1.0", database: "test_db")
    end

    test "returns error when database does not exist", %{conn: conn} do
      assert {:error, %{status: 404, body: body}} =
               Local.write(conn, "cpu value=1.0", database: "no_such_db")

      assert body =~ "database not found"
      assert body =~ "no_such_db"
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

    test "timestamp is stored in nanoseconds", %{conn: conn, db: db} do
      ts = 1_630_424_257_000_000_000
      Local.write(conn, "m value=1.0 #{ts}", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["time"] == ts
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
      assert row["_measurement"] == "my measurement"
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
      assert row["time"] == 1_000_000_000
    end

    test "microsecond precision is multiplied by 1_000", %{conn: conn, db: db} do
      ts = 1_000_000
      Local.write(conn, "m value=1i #{ts}", database: db, precision: :microsecond)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["time"] == 1_000_000_000
    end

    test "millisecond precision is multiplied by 1_000_000", %{conn: conn, db: db} do
      ts = 1_000
      Local.write(conn, "m value=1i #{ts}", database: db, precision: :millisecond)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["time"] == 1_000_000_000
    end

    test "second precision is multiplied by 1_000_000_000", %{conn: conn, db: db} do
      ts = 1
      Local.write(conn, "m value=1i #{ts}", database: db, precision: :second)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["time"] == 1_000_000_000
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

    test "returns empty list for unknown measurement", %{conn: conn, db: db} do
      assert {:ok, []} =
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
      assert times == Enum.sort(times)
    end

    test "ORDER BY time DESC", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM cpu ORDER BY time DESC", database: db)

      times = Enum.map(rows, & &1["time"])
      assert times == Enum.sort(times, :desc)
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
      assert row["time"] == 3000
    end

    test "each row includes _measurement key", %{conn: conn, db: db} do
      assert {:ok, [row | _rest]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: db)

      assert row["_measurement"] == "cpu"
    end

    test "unsupported SQL returns error", %{conn: conn, db: db} do
      assert {:error, _reason} =
               Local.query_sql(conn, "INSERT INTO cpu VALUES (1)", database: db)
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
  end

  # ---------------------------------------------------------------------------
  # execute_sql/3
  # ---------------------------------------------------------------------------

  describe "execute_sql/3" do
    test "returns {:ok, map} for any statement", %{conn: conn} do
      assert {:ok, result} = Local.execute_sql(conn, "DELETE FROM cpu")
      assert is_map(result)
    end
  end

  # ---------------------------------------------------------------------------
  # query_influxql/3
  # ---------------------------------------------------------------------------

  describe "query_influxql/3" do
    test "returns {:ok, rows}", %{conn: conn} do
      assert {:ok, rows} = Local.query_influxql(conn, "SELECT * FROM cpu")
      assert is_list(rows)
    end

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
    test "returns {:ok, rows} for any flux query" do
      {:ok, v2_conn} = Local.start(profile: :v2)
      on_exit(fn -> Local.stop(v2_conn) end)
      flux = "from(bucket: \"test\") |> range(start: -1h)"
      assert {:ok, rows} = Local.query_flux(v2_conn, flux)
      assert is_list(rows)
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

  describe "execute_sql/3 — DELETE" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "del_db")

      Local.write(
        conn,
        "cpu,host=web01 value=10i\ncpu,host=web02 value=20i\ncpu,host=web01 value=30i",
        database: "del_db"
      )

      {:ok, db: "del_db"}
    end

    test "DELETE FROM removes all points for a measurement", %{conn: conn, db: db} do
      assert {:ok, %{"rows_affected" => 3}} =
               Local.execute_sql(conn, "DELETE FROM cpu", database: db)

      assert {:ok, []} = Local.query_sql(conn, "SELECT * FROM cpu", database: db)
    end

    test "DELETE FROM with WHERE removes matching points only",
         %{conn: conn, db: db} do
      assert {:ok, %{"rows_affected" => 2}} =
               Local.execute_sql(
                 conn,
                 "DELETE FROM cpu WHERE host = 'web01'",
                 database: db
               )

      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM cpu", database: db)
      assert row["host"] == "web02"
    end

    test "DELETE FROM non-existent measurement returns 0 rows_affected",
         %{conn: conn, db: db} do
      assert {:ok, %{"rows_affected" => 0}} =
               Local.execute_sql(conn, "DELETE FROM no_such", database: db)
    end

    test "unknown statement returns 0 rows_affected", %{conn: conn, db: db} do
      assert {:ok, %{"rows_affected" => 0}} =
               Local.execute_sql(conn, "CREATE TABLE foo (id INT)", database: db)
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

      assert row["_measurement"] == "my,measurement"
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

    test "SHOW DATABASES returns all databases", %{conn: conn} do
      assert {:ok, dbs} = Local.query_influxql(conn, "SHOW DATABASES")
      names = Enum.map(dbs, & &1["name"])
      assert "iql_db" in names
      assert "test_db" in names
    end

    test "SHOW MEASUREMENTS returns measurement names", %{conn: conn, db: db} do
      assert {:ok, measurements} =
               Local.query_influxql(conn, "SHOW MEASUREMENTS", database: db)

      names = Enum.map(measurements, & &1["name"])
      assert "cpu" in names
      assert "mem" in names
    end

    test "SHOW TAG KEYS FROM measurement returns tag keys", %{conn: conn, db: db} do
      assert {:ok, tag_keys} =
               Local.query_influxql(conn, "SHOW TAG KEYS FROM cpu", database: db)

      keys = Enum.map(tag_keys, & &1["tagKey"])
      assert "host" in keys
      assert "region" in keys
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
      assert {:ok, rows} = Local.query_flux(conn, flux)
      assert length(rows) == 1
      assert hd(rows)["value"] == 10
    end

    test "flux query returns row maps with string keys", %{v2_conn: conn} do
      flux = "from(bucket: \"flux_db\") |> range(start: -24h)"
      assert {:ok, [row | _rest]} = Local.query_flux(conn, flux)
      assert is_binary(row["_measurement"])
      assert Map.has_key?(row, "time")
    end

    test "flux query with no matching bucket returns empty list", %{v2_conn: conn} do
      flux = "from(bucket: \"no_such_bucket\") |> range(start: -1h)"
      assert {:ok, []} = Local.query_flux(conn, flux)
    end
  end
end
