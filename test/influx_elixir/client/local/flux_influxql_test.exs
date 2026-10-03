defmodule InfluxElixir.Client.Local.FluxInfluxqlTest do
  use ExUnit.Case, async: true

  import InfluxElixir.TestSupport.LocalHelpers

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    {:ok, conn: conn}
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

      assert Enum.map(dbs, & &1["iox::database"]) === ["_internal", "iql_db", "test_db"]
    end

    test "SHOW MEASUREMENTS returns measurement names with iox::measurement key",
         %{conn: conn, db: db} do
      assert {:ok, measurements} =
               Local.query_influxql(conn, "SHOW MEASUREMENTS", database: db)

      assert measurements === [
               %{"iox::measurement" => "measurements", "name" => "cpu"},
               %{"iox::measurement" => "measurements", "name" => "mem"}
             ]
    end

    test "SHOW TAG KEYS FROM returns tag keys with iox::measurement key",
         %{conn: conn, db: db} do
      assert {:ok, tag_keys} =
               Local.query_influxql(conn, "SHOW TAG KEYS FROM cpu", database: db)

      assert tag_keys === [
               %{"iox::measurement" => "cpu", "tagKey" => "host"},
               %{"iox::measurement" => "cpu", "tagKey" => "region"}
             ]
    end

    test "SELECT * returns every field and tag beside iox::measurement and time",
         %{conn: conn, db: db} do
      assert {:ok, [row]} = Local.query_influxql(conn, "SELECT * FROM cpu", database: db)

      assert row === %{
               "iox::measurement" => "cpu",
               "time" => ~U[1970-01-01 00:00:00.000001Z],
               "host" => "web01",
               "region" => "us",
               "value" => 1
             }
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

      assert rows === [
               %{"iox::measurement" => "o", "time" => iq_time(1), "v" => 1},
               %{"iox::measurement" => "o", "time" => iq_time(2), "v" => 2},
               %{"iox::measurement" => "o", "time" => iq_time(3), "v" => 3}
             ]

      assert iq_query(conn, "SELECT v AS vee FROM o") ===
               {:ok,
                [
                  %{"iox::measurement" => "o", "time" => iq_time(1), "vee" => 1},
                  %{"iox::measurement" => "o", "time" => iq_time(2), "vee" => 2},
                  %{"iox::measurement" => "o", "time" => iq_time(3), "vee" => 3}
                ]}

      assert iq_query(conn, "SELECT w FROM o") ===
               {:ok, [%{"iox::measurement" => "o", "time" => iq_time(4), "w" => 9}]}

      assert {:ok, []} = iq_query(conn, "SELECT h FROM o")
    end

    test "an unknown column or measurement is an empty result, not an error", %{conn: conn} do
      assert {:ok, []} = iq_query(conn, "SELECT v FROM nope WHERE h = 'x'")
      assert {:ok, []} = iq_query(conn, "SELECT v FROM o WHERE nosuch = 'x'")
      assert {:ok, []} = iq_query(conn, "SELECT MEAN(nothere) FROM o")
    end

    test "aggregates are named after the function and put time at the epoch", %{conn: conn} do
      epoch = DateTime.from_unix!(0, :microsecond)

      assert iq_query(conn, "SELECT SUM(v), MEAN(v), COUNT(v) FROM o") ===
               {:ok,
                [
                  %{
                    "iox::measurement" => "o",
                    "time" => epoch,
                    "sum" => 6,
                    "mean" => 2.0,
                    "count" => 3
                  }
                ]}

      assert iq_query(conn, "SELECT SUM(v) AS total FROM o") ===
               {:ok, [%{"iox::measurement" => "o", "time" => epoch, "total" => 6}]}

      assert iq_query(conn, "SELECT MIN(v), MIN(w) FROM o") ===
               {:ok, [%{"iox::measurement" => "o", "time" => epoch, "min" => 1, "min_1" => 9}]}

      assert iq_query(conn, "SELECT COUNT(*) FROM o") ===
               {:ok,
                [%{"iox::measurement" => "o", "time" => epoch, "count_v" => 3, "count_w" => 1}]}
    end

    test "a lone FIRST selector returns its point's time", %{conn: conn} do
      assert iq_query(conn, "SELECT FIRST(v) FROM o") ===
               {:ok, [%{"iox::measurement" => "o", "time" => iq_time(1), "first" => 1}]}
    end

    test "GROUP BY orders series by tag; ORDER BY time DESC and MEAN apply per series",
         %{conn: conn} do
      assert {:ok, rows} = iq_query(conn, "SELECT v FROM o GROUP BY h ORDER BY time DESC")
      assert Enum.map(rows, &{&1["h"], &1["v"]}) === [{"x", 3}, {"x", 2}, {"y", 1}]

      assert {:ok, rows} = iq_query(conn, "SELECT MEAN(v) FROM o GROUP BY h")
      assert Enum.map(rows, &{&1["h"], &1["mean"]}) === [{"x", 2.5}, {"y", 1.0}]
    end

    test "SHOW FIELD KEYS, SHOW TAG KEYS and SHOW DATABASES", %{conn: conn} do
      assert iq_query(conn, "SHOW FIELD KEYS FROM u") ===
               {:ok, [%{"iox::measurement" => "u", "fieldKey" => "x", "fieldType" => "unsigned"}]}

      assert {:ok, keys} = iq_query(conn, "SHOW FIELD KEYS")

      assert Enum.map(keys, &{&1["iox::measurement"], &1["fieldKey"]}) === [
               {"o", "v"},
               {"o", "w"},
               {"u", "x"}
             ]

      assert iq_query(conn, "SHOW TAG KEYS") ===
               {:ok, [%{"iox::measurement" => "o", "tagKey" => "h"}]}

      assert {:ok, []} = iq_query(conn, "SHOW TAG KEYS FROM nope")
      assert {:ok, dbs} = iq_query(conn, "SHOW DATABASES")
      assert %{"iox::database" => "iq", "deleted" => false} in dbs
    end

    test "constructs the double does not model are refused by name", %{conn: conn} do
      for {statement, body} <- [
            {"SELECT MEAN(v) FROM o WHERE time > 0 GROUP BY time(1m) fill( foo )",
             "Client.Local: unsupported InfluxQL (fill(foo)): " <>
               "SELECT MEAN(v) FROM o WHERE time > 0 GROUP BY time(1m) fill( foo )"},
            {"SHOW TAG VALUES WITH KEY = h LIMIT 1",
             "Client.Local: unsupported InfluxQL (SHOW TAG VALUES with LIMIT/OFFSET): " <>
               "SHOW TAG VALUES WITH KEY = h LIMIT 1"},
            {"SELECT MODE(v) FROM o",
             "Client.Local: unsupported InfluxQL function: MODE(v): SELECT MODE(v) FROM o"},
            {"SELECT SUM(*) FROM o",
             "Client.Local: unsupported InfluxQL (sum(*)): SELECT SUM(*) FROM o"},
            {"SELECT DISTINCT(v) FROM o",
             "Client.Local: unsupported InfluxQL (distinct(): the values come in the engine's " <>
               "order)"}
          ] do
        assert {:error, %{status: 400, body: ^body}} = iq_query(conn, statement)
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
      :ok = Local.create_bucket(conn, "b")

      lp = """
      cpu,host=a v=1.0,n=1i 1700000000000000000
      cpu,host=a v=3.0,n=2i 1700000060000000000
      cpu,host=b v=5.0,n=3i 1700000000000000000
      """

      {:ok, :written} = Local.write(conn, String.trim(lp), database: "b")
      {:ok, conn: conn}
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
        assert Jason.decode!(body) === %{"code" => "invalid", "message" => message}, tail
      end
    end
  end
end
