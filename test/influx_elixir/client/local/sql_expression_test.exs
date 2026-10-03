defmodule InfluxElixir.Client.Local.SqlExpressionTest do
  use ExUnit.Case, async: true

  import InfluxElixir.TestSupport.LocalHelpers

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
                body: "Client.Local: unsupported column expression: approx_median(value) as m"
              } = err} = Local.check_sql(sql)

      {:ok, conn} = Local.start(databases: ["chk"])
      assert {:error, ^err} = Local.query_sql(conn, sql, database: "chk")
    end
  end

  # ---------------------------------------------------------------------------
  # Issue #18: projected arithmetic, CTEs, table qualifiers. Expected values
  # recorded from InfluxDB 3 Core (docs/design/2026-09-15_local-ctes-projected-expressions.md).
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — projected expressions, CTEs and qualifiers" do
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
        assert body === "Client.Local: unsupported SQL construct #{construct}: #{rendered}", sql
      end
    end
  end

  describe "query_sql/3 — keyword-like column names and literals are not constructs" do
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

  describe "query_sql/3 — WHERE OR / NOT / parentheses, BETWEEN, LIKE, <>, LIMIT 0" do
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

    test "malformed boolean expressions are rejected, not truncated", %{conn: conn, db: db} do
      assert {:error, %{status: 400, body: "Client.Local: unbalanced parenthesis in WHERE"}} =
               Local.query_sql(conn, ~s|SELECT host FROM "m" WHERE (host = 'a'|, database: db)

      assert {:error, %{status: 400, body: "Client.Local: unsupported WHERE clause"}} =
               Local.query_sql(conn, ~s|SELECT host FROM "m" WHERE host = 'a' AND|, database: db)
    end
  end

  # ---------------------------------------------------------------------------
  # Issue #20: CAST in WHERE (and everywhere an expression is allowed),
  # `::TYPE`, ORDER BY expressions and multiple terms. Expected values
  # recorded from InfluxDB 3 Core (docs/design/2026-09-16_local-cast-order-by.md).
  # ---------------------------------------------------------------------------
  describe "query_sql/3 — CAST, ::TYPE and multi-term ORDER BY" do
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
      assert Local.query_sql(conn, sql, database: db, params: params) ===
               {:ok,
                [
                  %{
                    "time" => ~U[2023-11-14 22:13:21.000000Z],
                    "symbol" => "X",
                    "provider" => "a",
                    "level" => "20",
                    "price" => 3.2,
                    "qty" => 2
                  },
                  %{
                    "time" => ~U[2023-11-14 22:13:20.000000Z],
                    "symbol" => "X",
                    "provider" => "a",
                    "level" => "5",
                    "price" => 2.7,
                    "qty" => 1
                  }
                ]}

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
        assert levels(conn, db, sql) === ["5", "20"], sql
      end

      assert levels(conn, db, ~s|SELECT level FROM "orderbooks" WHERE CAST(qty AS VARCHAR) = '2'|) ==
               ["20"]

      assert levels(
               conn,
               db,
               ~s|SELECT level FROM "orderbooks" WHERE CAST(qty AS VARCHAR) LIKE '2%'|
             ) === ["20"]
    end

    test "CAST in a projection, an aggregate and arithmetic", %{conn: conn, db: db} do
      assert Local.query_sql(
               conn,
               ~s|SELECT CAST(level AS INTEGER) AS lvl FROM "orderbooks" ORDER BY lvl|,
               database: db
             ) === {:ok, [%{"lvl" => 5}, %{"lvl" => 20}, %{"lvl" => 20}, %{"lvl" => 100}]}

      assert Local.query_sql(
               conn,
               ~s|SELECT MAX(CAST(level AS INTEGER)) AS m FROM "orderbooks"|,
               database: db
             ) === {:ok, [%{"m" => 100}]}

      # float -> integer truncates; integer -> double widens
      assert Local.query_sql(
               conn,
               ~s|SELECT CAST(price AS INTEGER) AS p FROM "orderbooks" ORDER BY p|,
               database: db
             ) === {:ok, [%{"p" => 1}, %{"p" => 2}, %{"p" => 3}, %{"p" => 9}]}

      assert Local.query_sql(
               conn,
               ~s|SELECT CAST(qty AS DOUBLE) AS q FROM "orderbooks" ORDER BY q|,
               database: db
             ) === {:ok, [%{"q" => 1.0}, %{"q" => 2.0}, %{"q" => 3.0}, %{"q" => 9.0}]}

      assert Local.query_sql(
               conn,
               ~s|SELECT CAST(level AS INTEGER) + qty AS s FROM "orderbooks" ORDER BY s|,
               database: db
             ) === {:ok, [%{"s" => 6}, %{"s" => 22}, %{"s" => 29}, %{"s" => 103}]}
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

      assert Enum.map(rows, &{&1["symbol"], &1["level"]}) === [
               {"X", "100"},
               {"Y", "20"},
               {"X", "20"},
               {"X", "5"}
             ]

      assert Local.query_sql(
               conn,
               ~s|SELECT symbol, MAX(price) AS m FROM "orderbooks" GROUP BY symbol ORDER BY m DESC, symbol|,
               database: db
             ) === {:ok, [%{"m" => 9.9, "symbol" => "X"}, %{"m" => 1.1, "symbol" => "Y"}]}

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

  describe "query_sql/3 — constructs refused by name" do
    test "SELECT * with GROUP BY is refused by name", %{conn: conn} do
      {:ok, :written} =
        Local.write(conn, "p,host=a v=1.0 1700000000000000000", database: "test_db")

      assert {:error, %{status: 400, body: "Client.Local: unsupported column expression: *"}} =
               Local.query_sql(conn, ~s|SELECT * FROM "p" GROUP BY host|, database: "test_db")
    end
  end
end
