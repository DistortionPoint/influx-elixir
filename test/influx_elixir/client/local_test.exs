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

    test "quoted measurement name in SELECT *", %{conn: conn, db: db} do
      Local.write(conn, "prices value=100.0", database: db)

      assert {:ok, [row]} =
               Local.query_sql(
                 conn,
                 ~s(SELECT * FROM "prices"),
                 database: db
               )

      assert row["value"] == 100.0
      assert row["_measurement"] == "prices"
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
          "SELECT * FROM prices WHERE time >= 1773748800000000000 AND time < 1773748920000000000",
          database: db
        )

      assert length(rows) == 2
      symbols = Enum.map(rows, & &1["symbol"])
      assert "AAPL" in symbols
      assert "GOOG" in symbols
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

    test "returns empty list for no matching data", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          ~s(SELECT DISTINCT symbol FROM "nonexistent"),
          database: db
        )

      assert rows == []
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

    test "AVG with 2-hour buckets", %{conn: conn, db: db, hour: hour} do
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
      assert b1["time"] == 0
      assert b1["avg_usage"] == 15.0
      assert b2["time"] == 2 * hour
      assert b2["avg_usage"] == 35.0
      assert b3["time"] == 4 * hour
      assert b3["avg_usage"] == 55.0
    end

    test "SUM aggregate", %{conn: conn, db: db, hour: hour} do
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
      assert b1["time"] == 0
      assert b1["total"] == 60
      assert b2["time"] == 3 * hour
      assert b2["total"] == 150
    end

    test "COUNT aggregate", %{conn: conn, db: db, hour: hour} do
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
      assert b1["time"] == 0
      assert b1["cnt"] == 3
      assert b2["time"] == 3 * hour
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
      assert row["time"] == 0
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
      assert row["time"] == 0
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
      assert times == Enum.sort(times, :desc)
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

    test "empty result set returns empty list",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        AVG(usage) AS avg_usage
      FROM "nonexistent"
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      ORDER BY time ASC
      """

      assert {:ok, []} = Local.query_sql(conn, sql, database: db)
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
      assert row["time"] == 0
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

    test "missing GROUP BY returns error", %{conn: conn, db: db} do
      sql = """
      SELECT
        AVG(usage) AS avg_usage
      FROM "cpu"
      """

      assert {:error, %{status: 400, body: body}} =
               Local.query_sql(conn, sql, database: db)

      assert body =~ "GROUP BY"
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
  # query_sql/3 — first() and last() ordered aggregates
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — first/last aggregates" do
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

    test "first(field, time) returns value at earliest timestamp",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        first(price, time) AS open
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

    test "last(field, time) returns value at latest timestamp",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        last(price, time) AS close
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
        first(price, time) AS open,
        MAX(price) AS high,
        MIN(price) AS low,
        last(price, time) AS close,
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

    test "single-arg first(field) defaults ordering to time",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        first(price) AS open
      FROM "trades"
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      ORDER BY time ASC
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)
      [h0, _h1] = rows
      assert h0["open"] == 100.0
    end

    test "single-arg last(field) defaults ordering to time",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        last(price) AS close
      FROM "trades"
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      ORDER BY time ASC
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)
      [h0, _h1] = rows
      assert h0["close"] == 102.0
    end

    test "first/last with WHERE filter",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '2 hours', time) AS time,
        first(price, time) AS open,
        last(price, time) AS close
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

    test "first/last on empty result returns nil values",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 hour', time) AS time,
        first(price, time) AS open,
        last(price, time) AS close
      FROM "nonexistent"
      GROUP BY DATE_BIN(INTERVAL '1 hour', time)
      ORDER BY time ASC
      """

      assert {:ok, []} = Local.query_sql(conn, sql, database: db)
    end
  end
end
