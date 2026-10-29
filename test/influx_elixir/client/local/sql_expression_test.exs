defmodule InfluxElixir.Client.Local.SqlExpressionTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Client.Local.{SQLCast, SQLCompare, SQLPlan}

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    {:ok, conn: conn}
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
                body:
                  "Client.Local: unsupported column expression: approx_median(value) as m (the " <>
                    "function approx_median is not one the double has)"
              } = err} = Local.check_sql(sql)

      {:ok, conn} = Local.start(databases: ["chk"])
      assert {:error, ^err} = Local.query_sql(conn, sql, database: "chk")
    end
  end

  describe "Client.Local: SQL constructs it does not model" do
    test "joins, set operations and windows are rejected by name, not ignored",
         %{conn: conn} do
      InfluxElixir.TestSupport.Check.each_case(
        [
          {~s|SELECT bid FROM "q" INNER JOIN "q" AS r ON q.time = r.time|, "JOIN",
           "select bid from q inner join q as r on time = r.time"},
          {~s|SELECT bid FROM "q" UNION SELECT ask FROM "q"|, "UNION",
           "select bid from q union select ask from q"},
          {~s|SELECT bid FROM "q" WHERE time > 0 INTERSECT SELECT ask FROM "q"|, "INTERSECT",
           "select bid from q where time > 0 intersect select ask from q"},
          {~s|SELECT tag, ROW_NUMBER() OVER (ORDER BY time) AS n FROM "m"|, "OVER",
           "select tag, row_number() over (order by time) as n from m"}
        ],
        fn {sql, construct, rendered} ->
          assert {:error, %{status: 400, body: body}} =
                   Local.query_sql(conn, sql, database: "test_db")

          assert body === "Client.Local: unsupported SQL construct #{construct}: #{rendered}"
        end
      )
    end
  end

  # The engine answers the CAST spellings and ORDER BY expressions that the
  # contract (`InfluxElixir.ClientContract.SQLQuery`) pins on both tiers. What
  # the double refuses by name is pinned here.
  describe "query_sql/3 — CAST and ORDER BY constructs refused by name" do
    setup %{conn: conn} do
      lines = "orderbooks,level=5 price=2.7,qty=1i 1700000000000000000"
      {:ok, :written} = Local.write(conn, lines, database: "test_db", precision: :nanosecond)
      :ok
    end

    test "a cast to a type the double does not model", %{conn: conn} do
      assert Local.query_sql(
               conn,
               ~s|SELECT CAST(level AS BOOLEAN) AS b FROM "orderbooks"|,
               database: "test_db"
             ) ===
               {:error,
                %{
                  status: 400,
                  body: "Client.Local: a cast to Boolean: the double does not model that type"
                }}
    end

    test "ORDER BY an expression in an aggregate query", %{conn: conn} do
      sql =
        ~s|SELECT level, MAX(price) AS m FROM "orderbooks" GROUP BY level ORDER BY CAST(level AS INTEGER)|

      assert Local.query_sql(conn, sql, database: "test_db") ===
               {:error,
                %{
                  status: 400,
                  body:
                    "Client.Local: ORDER BY an expression is not supported in an aggregate query"
                }}
    end
  end

  describe "query_sql/3 — constructs refused by name" do
    test "SELECT * with GROUP BY is refused by name", %{conn: conn} do
      {:ok, :written} =
        Local.write(conn, "p,host=a v=1.0 1700000000000000000", database: "test_db")

      assert {:error,
              %{
                status: 400,
                body:
                  "Client.Local: unsupported column expression: * (* is a wildcard, not an expression)"
              }} =
               Local.query_sql(conn, ~s|SELECT * FROM "p" GROUP BY host|, database: "test_db")
    end
  end

  describe "timestamp and selector typing, comparisons, DISTINCT order, and SQLCast.fold/2" do
    setup %{conn: conn} do
      # 2025-01-02T00:00:00Z (day 2, month 1) vs 2025-02-01T00:00:00Z (day 1, month 2):
      # Elixir structural map comparison orders :day before :month, which would invert them.
      t1 = DateTime.to_unix(~U[2025-01-02 00:00:00Z], :nanosecond)
      t2 = DateTime.to_unix(~U[2025-02-01 00:00:00Z], :nanosecond)

      lines = "m,host=a v=10i #{t1}\nm,host=b v=20i #{t2}"
      {:ok, :written} = Local.write(conn, lines, database: "test_db", precision: :nanosecond)
      :ok
    end

    test "SQLPlan.arrow_type/1 types DateTime and selector structs from CTEs", %{conn: conn} do
      assert SQLPlan.arrow_type(~U[2025-01-02 00:00:00Z]) == "Timestamp(ns)"

      assert SQLPlan.arrow_type(%{"value" => 10, "time" => ~U[2025-01-02 00:00:00Z]}) ==
               ~s|Struct("value": Int64, "time": Timestamp(ns))|

      assert {:error, %{status: 400, body: plus_body}} =
               Local.query_sql(
                 conn,
                 "WITH c AS (SELECT time AS ts, v FROM m) SELECT ts + 1 FROM c",
                 database: "test_db"
               )

      assert plus_body =~ "Cannot coerce arithmetic expression Timestamp(ns) + Int64"

      assert {:error, %{status: 400, body: upper_ts_body}} =
               Local.query_sql(
                 conn,
                 "WITH c AS (SELECT time AS ts, v FROM m) SELECT upper(ts) FROM c",
                 database: "test_db"
               )

      assert upper_ts_body =~ "upper of a Timestamp(ns)"

      assert {:error, %{status: 400, body: upper_struct_body}} =
               Local.query_sql(
                 conn,
                 "WITH c AS (SELECT selector_first(v, time) AS s FROM m) SELECT upper(s) FROM c",
                 database: "test_db"
               )

      assert upper_struct_body =~ ~s|DataType: Struct("value": Int64, "time": Timestamp(ns))|

      assert {:error, %{status: 400, body: bad_time_body}} =
               Local.query_sql(
                 conn,
                 "SELECT count(*) FROM m HAVING 'not-a-timestamp' < min(time)",
                 database: "test_db"
               )

      assert bad_time_body =~
               "a text the engine cannot read as a timestamp, beside a timestamp that is not the column time"
    end

    test "SQLCompare compares DateTime values chronologically and against timestamp strings",
         %{conn: conn} do
      assert {:ok, [%{"c" => 2}]} =
               Local.query_sql(
                 conn,
                 "SELECT count(*) AS c FROM m HAVING min(time) < max(time)",
                 database: "test_db"
               )

      assert {:ok, [%{"ok" => 1}]} =
               Local.query_sql(
                 conn,
                 "WITH c AS (SELECT min(time) AS t1, max(time) AS t2 FROM m) " <>
                   "SELECT 1 AS ok FROM c WHERE t1 < t2",
                 database: "test_db"
               )

      assert {:ok, [%{"c" => 2}]} =
               Local.query_sql(
                 conn,
                 "SELECT count(*) AS c FROM m " <>
                   "HAVING min(time) = '2025-01-02T00:00:00Z' AND '2025-01-02T00:00:00Z' < max(time)",
                 database: "test_db"
               )

      assert {:ok, [%{"c" => 1}]} =
               Local.query_sql(
                 conn,
                 "WITH c AS (SELECT time AS t FROM m) " <>
                   "SELECT count(*) AS c FROM c " <>
                   "WHERE t > '2025-01-02T00:00:00Z' AND '2025-02-02T00:00:00Z' > t",
                 database: "test_db"
               )

      assert catch_throw(SQLCompare.compare(~U[2025-01-02 00:00:00Z], :eq, "bad")) ==
               {:query_error,
                %{
                  status: 500,
                  body:
                    "Optimizer rule 'simplify_expressions' failed\ncaused by\nArrow error: " <>
                      "Parser error: Error parsing timestamp from 'bad': timestamp must contain " <>
                      "at least 10 characters"
                }}
    end

    test "SELECT DISTINCT without ORDER BY sorts DateTime columns chronologically", %{conn: conn} do
      expected = [
        %{"t" => ~U[2025-01-02 00:00:00.000000Z]},
        %{"t" => ~U[2025-02-01 00:00:00.000000Z]}
      ]

      assert {:ok, ^expected} =
               Local.query_sql(
                 conn,
                 "WITH c AS (SELECT time AS t FROM m) SELECT DISTINCT t FROM c",
                 database: "test_db"
               )

      assert {:ok, ^expected} =
               Local.query_sql(
                 conn,
                 "SELECT DISTINCT min(time) AS t FROM m GROUP BY host HAVING count(*) > 0",
                 database: "test_db"
               )
    end

    test "SQLCast.fold/2 and SQLCast.cast/2 handle DateTime, boolean, and unknown target types" do
      assert SQLCast.fold(~U[2025-01-01 00:00:00Z], :int32) ==
               {:error, "Can't cast value 2025-01-01T00:00:00Z to type Int32"}

      assert SQLCast.fold(true, :decimal) ==
               {:error, "Can't cast value true to type Decimal128(?)"}

      assert catch_throw(SQLCast.cast(1, :unknown_type)) ==
               {:query_error, {:connection_error, %Mint.TransportError{reason: :closed}}}
    end
  end
end
