defmodule InfluxElixir.Client.Local.SqlAggregateTest do
  use ExUnit.Case, async: true

  import InfluxElixir.TestSupport.LocalHelpers

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    {:ok, conn: conn}
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

      assert rows === [
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

      assert rows === [
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

      assert row === %{
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
      assert row === %{"time" => ~U[1970-01-01 00:00:00.000000Z], "avg_usage" => 20.0}
    end

    test "ORDER BY the DATE_BIN time alias DESC lists the buckets newest first",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        DATE_BIN(INTERVAL '3 hours', time) AS time,
        COUNT(usage) AS cnt
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '3 hours', time)
      ORDER BY time DESC
      """

      assert {:ok, rows} = Local.query_sql(conn, sql, database: db)

      assert rows === [
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

      assert rows === [
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
      assert row["avg_usage"] === 35.0
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
      assert row["time"] === ~U[1970-01-01 00:00:00.000000Z]
      assert row["total"] === 210
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
      assert row["total"] === 210
    end

    test "scalar aggregate without GROUP BY DATE_BIN returns one row",
         %{conn: conn, db: db} do
      sql = """
      SELECT
        AVG(usage) AS avg_usage
      FROM "cpu"
      """

      assert Local.query_sql(conn, sql, database: db) === {:ok, [%{"avg_usage" => 35.0}]}
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
        assert body === "Client.Local: " <> message, sql
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Issues #16 and #17: statistical aggregates, arithmetic inside aggregates,
  # selector functions, multi-column DISTINCT, ORDER BY alias, null omission.
  # Expected values were recorded from InfluxDB 3 Core (see
  # docs/design/2026-09-14_local-sql-stats-selectors-distinct.md).
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — statistical aggregates" do
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
      assert row["sd"] === 10.0
      assert row["sd_samp"] === 10.0
      assert row["sd_pop"] === 8.16496580927726
      assert row["v"] === 100.0
      assert row["v_samp"] === 100.0
      assert row["v_pop"] === 66.66666666666667
    end

    test "sample statistics over one row are null and the column is omitted",
         %{conn: conn, db: db} do
      sql = """
      SELECT STDDEV(value) AS sd, VAR(value) AS v, VAR_POP(value) AS v_pop
      FROM "m"
      WHERE provider = 'b'
      """

      assert Local.query_sql(conn, sql, database: db) === {:ok, [%{"v_pop" => +0.0}]}
    end

    test "an empty group keeps only COUNT (0); every other aggregate is omitted",
         %{conn: conn, db: db} do
      sql = """
      SELECT COUNT(value) AS n, AVG(value) AS a, STDDEV(value) AS sd
      FROM "m"
      WHERE provider = 'none'
      """

      assert Local.query_sql(conn, sql, database: db) === {:ok, [%{"n" => 0}]}
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
      assert row["sum_sq"] === 1400.0
      assert row["half_avg"] === 10.0
      assert row["max_less_one"] === 29.0
      assert row["min_shifted"] === 40.0
    end

    test "integer operands divide as integers, like DataFusion", %{conn: conn, db: db} do
      {:ok, :written} =
        Local.write(conn, "ints n=3i 1000000000\nints n=5i 2000000000", database: db)

      sql = ~s|SELECT SUM(n / 2) AS halves, SUM(n * n) AS squares, AVG(n) AS a FROM "ints"|

      assert Local.query_sql(conn, sql, database: db) ===
               {:ok, [%{"halves" => 3, "squares" => 34, "a" => 4.0}]}
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
        assert body === "Client.Local: invalid aggregate: #{rendered} as a", sql
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

      assert rows === [
               %{"provider" => "a", "total" => 60.0},
               %{"provider" => "b", "total" => 5.0}
             ]
    end
  end

  describe "query_sql/3 — selector functions and DATE_BIN ordering" do
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
      assert row["first_v"] === 10.0
      assert row["first_t"] === ~U[1970-01-01 00:00:00.000000Z]
      assert row["last_v"] === 5.0
      assert row["last_t"] === ~U[1970-01-01 00:01:10.000000Z]
      assert row["min_v"] === 5.0
      assert row["min_t"] === ~U[1970-01-01 00:01:10.000000Z]
      assert row["max_v"] === 30.0
      assert row["max_t"] === ~U[1970-01-01 00:00:20.000000Z]
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

      assert late["bucket"] === ~U[1970-01-01 00:01:00.000000Z]
      assert late["open"] === 5.0 and late["close"] === 5.0 and late["n"] === 1

      assert early["bucket"] === ~U[1970-01-01 00:00:00.000000Z]
      assert early["open"] === 10.0
      assert early["high"] === 30.0
      assert early["low"] === 10.0
      assert early["close"] === 20.0
      assert early["n"] === 3
    end

    test "an empty selector group omits the column", %{conn: conn, db: db} do
      sql = ~s|SELECT selector_last(value, time)['value'] AS v FROM "m" WHERE symbol = 'nope'|

      assert {:ok, [row]} = Local.query_sql(conn, sql, database: db)
      assert row === %{}
    end
  end

  describe "query_sql/3 — null omission" do
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
      assert with_value["value"] === 3.0
      refute Map.has_key?(with_value, "other")
      assert with_other["other"] === 4.0
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

      assert rows === [%{"provider" => "a"}, %{"provider" => "a"}]
    end
  end

  # ---------------------------------------------------------------------------
  # Quality sweep 2026-09-14: divergences found by probing the double against
  # InfluxDB 3 Core (see docs/design/2026-09-14_local-time-filters-count-distinct.md).
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — now() time filters, IS NULL, COUNT(DISTINCT), time aggregates" do
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

    # A single `now() - INTERVAL` bound is in the contract.
    test "now() arithmetic chains intervals and is case-insensitive", %{conn: conn, db: db} do
      sql =
        ~s|SELECT price FROM "q" WHERE time >= now() - INTERVAL '1 hour' - INTERVAL '30 minutes' | <>
          ~s|AND time < NOW() + INTERVAL '1 day' ORDER BY price|

      assert column_values(conn, db, sql, "price") === [1.0, 2.0, 3.0]
    end

    # The engine answers "Error during planning: Invalid function 'foo'." with
    # a "Did you mean" suggestion that varies from run to run (verified); the
    # double refuses by name with the same status.
    test "an unknown function as a time comparand is refused by name", %{conn: conn, db: db} do
      assert Local.query_sql(conn, ~s|SELECT price FROM "q" WHERE time >= foo()|, database: db) ==
               {:error,
                %{
                  status: 400,
                  body:
                    "Client.Local: a `time` comparand must be a quoted ISO-8601 string, now() " <>
                      "+/- INTERVAL 'N unit', NULL or a $parameter: foo()"
                }}
    end
  end

  # ---------------------------------------------------------------------------
  # Issue #19: median(), CROSS JOIN, expression comparands. Expected values
  # recorded from InfluxDB 3 Core (docs/design/2026-09-15_local-median-cross-join.md).
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — median, CROSS JOIN and expression comparands" do
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
      assert Local.query_sql(conn, sql, database: db, params: params) ===
               {:ok,
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
                ]}
    end
  end
end
