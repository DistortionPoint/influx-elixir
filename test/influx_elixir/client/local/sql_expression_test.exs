defmodule InfluxElixir.Client.Local.SqlExpressionTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

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
end
