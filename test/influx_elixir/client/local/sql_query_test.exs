defmodule InfluxElixir.Client.Local.SqlQueryTest do
  use ExUnit.Case, async: true

  import InfluxElixir.TestSupport.LocalHelpers

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    {:ok, conn: conn}
  end

  # The time every row written with `@ts` reads back as.
  @ts 1_700_000_000_000_000_000

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

      assert Enum.map(rows, &{&1["host"], &1["region"], &1["usage"], &1["idle"]}) === [
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

      assert Enum.map(rows, &{&1["host"], &1["usage"]}) === [{"web01", 10}, {"web01", 30}]
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

      assert usages.(">", 15) === [20, 30]
      assert usages.("<", 15) === [10]
      assert usages.(">=", 20) === [20, 30]
      assert usages.("<=", 20) === [10, 20]
    end

    test "ORDER BY time ASC sorts points written out of order", %{conn: conn, db: db} do
      {:ok, :written} =
        Local.write(conn, "ooo v=3i 3000\nooo v=1i 1000\nooo v=2i 2000", database: db)

      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM ooo ORDER BY time ASC", database: db)

      assert Enum.map(rows, &{&1["time"], &1["v"]}) === [
               {~U[1970-01-01 00:00:00.000001Z], 1},
               {~U[1970-01-01 00:00:00.000002Z], 2},
               {~U[1970-01-01 00:00:00.000003Z], 3}
             ]
    end

    test "SELECT * ORDER BY time DESC lists the points newest first", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM cpu ORDER BY time DESC", database: db)

      assert Enum.map(rows, &{&1["time"], &1["usage"]}) === [
               {~U[1970-01-01 00:00:00.000003Z], 30},
               {~U[1970-01-01 00:00:00.000002Z], 20},
               {~U[1970-01-01 00:00:00.000001Z], 10}
             ]
    end

    test "LIMIT reduces number of results", %{conn: conn, db: db} do
      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT usage FROM cpu ORDER BY time LIMIT 2", database: db)

      assert rows === [%{"usage" => 10}, %{"usage" => 20}]
    end

    test "combined WHERE + ORDER BY + LIMIT", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE region = 'us-east' ORDER BY time DESC LIMIT 1"
      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row["region"] === "us-east"
      assert row["time"] === ~U[1970-01-01 00:00:00.000003Z]
    end

    test "each row has fields, tags, and time but no _measurement key",
         %{conn: conn, db: db} do
      assert {:ok, [row | _rest]} =
               Local.query_sql(conn, "SELECT * FROM cpu ORDER BY time", database: db)

      assert row === %{
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

      assert rows === [
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

      assert row === %{
               "net_value" => 110.0,
               "total_balance" => 130.0,
               "time" => ~U[1970-01-01 00:00:00.000002Z]
             }
    end

    test "supports AS aliases on projection columns", %{conn: conn, db: db} do
      sql =
        "SELECT net_value AS nv, total_balance AS tb FROM account_balances WHERE account_id = 'xyz'"

      assert Local.query_sql(conn, sql, database: db) ===
               {:ok, [%{"nv" => 50.0, "tb" => 55.0}]}
    end

    test "selecting a tag column returns the tag value",
         %{conn: conn, db: db} do
      sql = "SELECT account_id, net_value FROM account_balances WHERE account_id = 'xyz'"

      assert Local.query_sql(conn, sql, database: db) ===
               {:ok, [%{"account_id" => "xyz", "net_value" => 50.0}]}
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
      assert param_rows(conn, db, sql, %{"host" => "web01"}) === [{"web01", 10}]
    end

    test "integer param substitution", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE usage > $min"
      assert param_rows(conn, db, sql, %{"min" => 15}) === [{"web02", 20}]
    end

    test "atom key params without $ prefix", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE host = $host"
      assert param_rows(conn, db, sql, %{host: "web01"}) === [{"web01", 10}]
    end

    test "string key params without $ prefix", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE host = $host"
      assert param_rows(conn, db, sql, %{"host" => "web01"}) === [{"web01", 10}]
    end

    test "atom key params with multiple conditions", %{conn: conn, db: db} do
      sql = "SELECT * FROM cpu WHERE host = $host AND usage > $min"
      assert param_rows(conn, db, sql, %{host: "web02", min: 15}) === [{"web02", 20}]
    end

    test "a placeholder that prefixes another is substituted whole",
         %{conn: conn, db: db} do
      # Sequential replacement rewrote `$h` inside `$hmin`, producing
      # `'web02'min` and a parse failure.
      sql = "SELECT * FROM cpu WHERE host = $h AND usage > $hmin"
      assert param_rows(conn, db, sql, %{h: "web02", hmin: 15}) === [{"web02", 20}]
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

      assert param_rows(conn, db, sql, params) === [{"$min", 20}]
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

      assert direct === expected
      assert stream_rows === expected
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
                     "Schema error: No field named nosuch. Valid fields are cpu.time, cpu.v.",
                   fn -> Enum.to_list(stream) end
    end

    test "raises StreamError with :unsupported when the profile lacks streaming" do
      {:ok, v2_conn} = Local.start(profile: :v2, databases: ["v2_db"])

      stream = Local.query_sql_stream(v2_conn, "SELECT * FROM cpu")

      error = assert_raise InfluxElixir.StreamError, fn -> Enum.to_list(stream) end
      assert %InfluxElixir.StreamError{kind: :unsupported, reason: :unsupported_operation} = error
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
      assert row["host"] === "gamma"
    end

    test "case insensitive SELECT", %{conn: conn, db: db} do
      assert hosts(conn, db, "select * from m where host = 'alpha'") === ["alpha"]
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

      assert column_values(conn, db, sql, "symbol") === ["AAPL", "GOOG"]
    end

    test "SELECT * with ISO 8601 time params", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM prices WHERE time >= $start AND time < $end ORDER BY time",
          database: db,
          params: %{
            "start" => "2026-03-17T12:00:00Z",
            "end" => "2026-03-17T12:02:00Z"
          }
        )

      assert Enum.map(rows, & &1["symbol"]) === ["AAPL", "GOOG"]
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
            "start" => "2026-03-17T12:00:00Z",
            "end" => "2026-03-17T12:02:00Z"
          }
        )

      assert rows === [
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
            "start" => "2026-03-17T12:00:00Z",
            "end" => "2026-03-17T12:05:00Z"
          }
        )

      assert rows === [
               %{"symbol" => "AAPL", "price" => 150.0, "time" => ~U[2026-03-17 12:00:00.000000Z]}
             ]
    end

    test "time WHERE excludes all points", %{conn: conn, db: db} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM prices WHERE time >= $start AND time < $end",
          database: db,
          params: %{
            "start" => "2026-03-18T00:00:00Z",
            "end" => "2026-03-18T01:00:00Z"
          }
        )

      assert rows === []
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
      assert column_values(conn, db, sql, "symbol") === ["AAPL", "GOOG", "MSFT"]

      assert {:ok, []} =
               Local.query_sql(conn, "SELECT * FROM prices WHERE time <= '2026-03-17'",
                 database: db
               )
    end

    test "bare ISO date range filters across day boundaries",
         %{conn: conn, db: db} do
      sql =
        "SELECT * FROM prices WHERE time >= '2026-03-17' AND time <= '2026-03-18' ORDER BY time"

      assert column_values(conn, db, sql, "symbol") === ["AAPL", "GOOG", "MSFT"]
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
      assert holding_tickers(conn, db, "ticker IN ('AAPL', 'MSFT')") === ["AAPL", "MSFT"]
    end

    test "IN with a single value matches one row", %{conn: conn, db: db} do
      assert holding_tickers(conn, db, "ticker IN ('GOOG')") === ["GOOG"]
    end

    test "empty IN () matches no rows", %{conn: conn, db: db} do
      assert holding_tickers(conn, db, "ticker IN ()") === []
    end

    test "IN works on field columns", %{conn: conn, db: db} do
      assert holding_tickers(conn, db, "shares IN (10, 20)") === ["AAPL", "MSFT"]
    end

    test "NOT IN excludes listed values", %{conn: conn, db: db} do
      assert holding_tickers(conn, db, "ticker NOT IN ('AAPL', 'GOOG')") === ["MSFT"]
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
          params: %{"t0" => "AAPL", "t1" => "MSFT"}
        )

      assert Enum.map(rows, & &1["ticker"]) === ["AAPL", "MSFT"]
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

      assert rows |> Enum.sort_by(& &1["sym"]) === [
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
  # query_sql/3 — coverage for error/edge branches
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — error and edge branches" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "edge_db")
      {:ok, db: "edge_db"}
    end

    test "WHERE time with a DateTime param renders as the ISO string Jason sends",
         %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m val=1i 5000\nm val=2i 6000", database: db)

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM m WHERE time >= $t",
          database: db,
          params: %{"t" => ~U[1970-01-01 00:00:00.000006Z]}
        )

      assert rows === [%{"val" => 2, "time" => ~U[1970-01-01 00:00:00.000006Z]}]
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

      assert rows === []
    end

    test "float param in SQL literal", %{conn: conn, db: db} do
      {:ok, :written} = Local.write(conn, "m val=3.14 #{@ts}", database: db)

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM m WHERE val > $v",
          database: db,
          params: %{"v" => 3.0}
        )

      assert rows === [%{"time" => iq_time(0), "val" => 3.14}]
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
      assert column_values(conn, db, sql, "device") === ["alpha", "beta"]
    end

    test "WHERE with float boundary excludes low values", %{conn: conn, db: db} do
      sql = "SELECT * FROM sensors WHERE temp > 50.0 ORDER BY time"
      assert column_values(conn, db, sql, "device") === ["alpha"]
    end

    test "WHERE with unparseable string value is treated as string literal",
         %{conn: conn, db: db} do
      # A value like 'alpha' matches tag values as a string
      sql = "SELECT * FROM sensors WHERE device = 'alpha'"
      assert column_values(conn, db, sql, "device") === ["alpha"]
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

  @acct_08338636 %{
    "repcode" => "08338636",
    "amount" => 500.0,
    "time" => ~U[1970-01-01 00:00:00.000001Z]
  }
  @acct_12345678 %{
    "repcode" => "12345678",
    "amount" => 5000.0,
    "time" => ~U[1970-01-01 00:00:00.000002Z]
  }

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
      assert sql_rows(conn, db, sql) === [@acct_12345678]
    end

    test "IN / NOT IN compare zero-padded literals as strings", %{conn: conn, db: db} do
      sql = "SELECT * FROM acct WHERE repcode IN ('08338636')"
      assert sql_rows(conn, db, sql) === [@acct_08338636]

      sql = "SELECT * FROM acct WHERE repcode NOT IN ('08338636')"
      assert sql_rows(conn, db, sql) === [@acct_12345678]
    end

    test "a bare numeric literal against a float field compares numerically",
         %{conn: conn, db: db} do
      sql = "SELECT * FROM acct WHERE amount >= 1000.0"
      assert sql_rows(conn, db, sql) === [@acct_12345678]
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
          "devices,id=d1 active=true #{@ts}\ndevices,id=d2 active=false #{@ts}",
          database: "bool_param_db"
        )

      {:ok, db: "bool_param_db"}
    end

    test "boolean params select by the flag", %{conn: conn, db: db} do
      for {flag, id} <- [{true, "d1"}, {false, "d2"}] do
        assert Local.query_sql(conn, "SELECT * FROM devices WHERE active = $flag",
                 database: db,
                 params: %{"flag" => flag}
               ) === {:ok, [%{"id" => id, "active" => flag, "time" => iq_time(0)}]}
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
                 params: %{"val" => nil}
               )

      assert rows === []
    end
  end

  describe "query_sql/3 — an unrecognised WHERE clause is an error, not dropped rows" do
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
end
