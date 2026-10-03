defmodule InfluxElixir.Client.Local.WriteTest do
  use ExUnit.Case, async: true

  import InfluxElixir.TestSupport.LocalHelpers

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    {:ok, conn: conn}
  end

  # ---------------------------------------------------------------------------
  # Write — basic
  # ---------------------------------------------------------------------------

  describe "write/3 — basic" do
    test "v3_enterprise profile auto-creates database on write" do
      {:ok, ent_conn} =
        Local.start(databases: ["ent_db"], profile: :v3_enterprise)

      assert {:ok, :written} =
               Local.write(ent_conn, "cpu value=1.0", database: "auto_db")

      assert {:ok, dbs} = Local.list_databases(ent_conn)
      assert Enum.map(dbs, & &1["name"]) === ["_internal", "auto_db", "ent_db"]
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
      assert row["active"] === false
    end

    test "multiple tags are preserved", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m,host=s1,region=us-east value=1i", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["host"] === "s1"
      assert row["region"] === "us-east"
    end

    test "multiple fields are preserved", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m a=1i,b=2.0,c=\"hi\"", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["a"] === 1
      assert row["b"] === 2.0
      assert row["c"] === "hi"
    end

    test "timestamp is returned as a microsecond-precision DateTime", %{conn: conn, db: db} do
      ts = 1_630_424_257_123_456_789
      {:ok, :written} = Local.write(conn, "m value=1.0 #{ts}", database: db)
      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: db)
      assert row["time"] === ~U[2021-08-31 15:37:37.123456Z]
    end

    test "multi-line write stores multiple points", %{conn: conn, db: db} do
      lp = "m value=1.0 1\nm value=2.0 2\nm value=3.0 3"
      {:ok, :written} = Local.write(conn, lp, database: db)
      assert {:ok, rows} = Local.query_sql(conn, "SELECT * FROM m ORDER BY time", database: db)
      assert Enum.map(rows, & &1["value"]) === [1.0, 2.0, 3.0]
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

      assert Local.query_sql(
               conn,
               "SELECT COUNT(value) AS n FROM p WHERE time = '1970-01-01T00:00:01'",
               database: db
             ) === {:ok, [%{"n" => 10}]}
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

        assert Local.query_sql(conn, "SELECT time FROM #{m}", database: db) ===
                 {:ok, [%{"time" => expected}]},
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
      assert row["k"] === "v=1"
    end

    test "measurement name with escaped comma", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "my\\,measurement field=1i", database: db)

      assert Local.query_sql(conn, ~s|SELECT field FROM "my,measurement"|, database: db) ===
               {:ok, [%{"field" => 1}]}
    end

    test "field with negative integer", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m value=-42i", database: db)

      assert Local.query_sql(conn, "SELECT value FROM m", database: db) ===
               {:ok, [%{"value" => -42}]}
    end

    test "field with negative float", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m value=-3.14", database: db)

      assert Local.query_sql(conn, "SELECT value FROM m", database: db) ===
               {:ok, [%{"value" => -3.14}]}
    end

    test "field with scientific notation", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m value=1.5e10", database: db)

      assert Local.query_sql(conn, "SELECT value FROM m", database: db) ===
               {:ok, [%{"value" => 15_000_000_000.0}]}
    end

    test "comments and blank lines are ignored", %{conn: conn, db: db} do
      lp = "# This is a comment\n\nm value=1i 1\n\n# Another comment\nm value=2i 2\n"
      {:ok, :written} = Local.write(conn, lp, database: db)

      assert Local.query_sql(conn, "SELECT value FROM m ORDER BY time", database: db) ===
               {:ok, [%{"value" => 1}, %{"value" => 2}]}
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
      assert row["host"] === "web\\01"
    end
  end

  describe "write/3 — provided timestamps are stored and read back in order" do
    # Points written at a fixed spacing keep their timestamps; the store
    # must never put the server's clock in place of a parsed timestamp.
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

      assert Enum.map(rows, &{&1["time"], &1["close"]}) === [
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

      assert Enum.map(rows, & &1["val"]) === [0, 1, 2, 3]
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
      {:ok, conn: conn}
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
      assert Enum.map(rows, & &1["_time"]) |> Enum.uniq() === [~U[2023-11-14 22:13:20.000000Z]]

      for precision <- [:auto, :bogus, "NS"] do
        assert {:error, %{status: 400, body: body}} =
                 Local.write(conn, "pr value=1i 1", database: "metrics", precision: precision)

        assert Jason.decode!(body) === %{
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

      assert Enum.map(rows, &{&1["a=b"], &1["s"], &1["v"]}) === [
               {"x", "ends\\", 1},
               {"y", "line1\nline2", 2}
             ]
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
      {:ok, conn: conn, db: "dup"}
    end

    @t "1700000000000000000"
    @time ~U[2023-11-14 22:13:20.000000Z]

    test "a different tag value is another point; the same series at another time too",
         %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "d,h=x v=1i #{@t}\nd,h=y v=2i #{@t}", database: db)
      {:ok, :written} = Local.write(conn, "d,h=x v=3i 1700000000000000001", database: db)

      assert {:ok, rows} = Local.query_sql(conn, "SELECT h, v FROM d ORDER BY v", database: db)
      assert rows === [%{"h" => "x", "v" => 1}, %{"h" => "y", "v" => 2}, %{"h" => "x", "v" => 3}]
    end

    test "DELETE removes the merged point and counts it once", %{conn: conn, db: db} do
      {:ok, :written} =
        Local.write(conn, "f,h=x v=1i #{@t}\nf,h=x w=1i #{@t}\nf,h=y v=9i #{@t}", database: db)

      assert Local.execute_sql(conn, "DELETE FROM f WHERE w = 1", database: db) ===
               {:ok, %{"rows_affected" => 1}}

      assert Local.query_sql(conn, "SELECT * FROM f", database: db) ===
               {:ok, [%{"h" => "y", "time" => @time, "v" => 9}]}
    end
  end

  # ---------------------------------------------------------------------------
  # accept_partial: false and no_sync on the double. Expectations taken from
  # influxdb:3-core
  # (docs/design/2026-09-25_atomic-writes-and-no-sync.md).
  # ---------------------------------------------------------------------------

  describe "write/3 — accept_partial: false, no_sync" do
    setup do
      {:ok, conn} = Local.start(databases: ["aw"])
      {:ok, conn: conn}
    end

    test "a clean payload is stored whole; no_sync is accepted", %{conn: conn} do
      assert {:ok, :written} =
               Local.write(conn, "m3 v=1i 1\nm3 v=2i 2",
                 database: "aw",
                 accept_partial: false,
                 no_sync: true
               )

      assert Local.query_sql(conn, "SELECT v FROM m3 ORDER BY time", database: "aw") ===
               {:ok, [%{"v" => 1}, %{"v" => 2}]}
    end

    test "the :v2 profile has neither parameter and ignores them" do
      {:ok, v2} = Local.start(profile: :v2)
      :ok = Local.create_bucket(v2, "b")

      assert {:ok, :written} = Local.write(v2, "m v=1i 1", database: "b", accept_partial: "yes")
    end
  end
end
