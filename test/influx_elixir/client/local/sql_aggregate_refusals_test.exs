defmodule InfluxElixir.Client.Local.SqlAggregateRefusalsTest do
  @moduledoc """
  The SQL aggregates, DISTINCT forms and intervals `Client.Local` does not model
  and refuses by name. What the engine answers to the aggregates the double does
  model is pinned for the double and for the real servers by the SQL contracts in
  `test/support`.
  """

  use ExUnit.Case, async: true

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
  # query_sql/3 — DATE_BIN refusals. What DATE_BIN answers is in the contract.
  # ---------------------------------------------------------------------------

  describe "Client.Local: DATE_BIN" do
    test "an unknown interval unit is refused by name", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "cpu usage=10i 1800000000000", database: "test_db")

      sql = """
      SELECT
        DATE_BIN(INTERVAL '1 fortnight', time) AS time,
        AVG(usage) AS avg_usage
      FROM "cpu"
      GROUP BY DATE_BIN(INTERVAL '1 fortnight', time)
      ORDER BY time ASC
      """

      assert {:error, %{status: 400, body: "Client.Local: unknown interval unit: fortnight"}} =
               Local.query_sql(conn, sql, database: "test_db")
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
              %{
                status: 400,
                body:
                  "Client.Local: unsupported aggregate: avg(price, time) as avg (it goes on at ,, " <>
                    "where an operator is expected)"
              }} =
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
             "unsupported column expression: weird_func(temp) as alias (the function " <>
               "weird_func is not one the double has)"},
            {"INVALID_FUNC(temp) AS bad", "DATE_BIN(INTERVAL '1 hour', time)",
             "unsupported column expression: invalid_func(temp) as bad (the function " <>
               "invalid_func is not one the double has)"},
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

  describe "Client.Local: aggregates it does not model" do
    setup %{conn: conn} do
      {:ok, :written} =
        Local.write(conn, "m,provider=a value=10.0,other=1.0 1000000000", database: "test_db")

      {:ok, db: "test_db"}
    end

    test "VARIANCE is not a DataFusion function and is rejected", %{conn: conn, db: db} do
      assert {:error,
              %{
                status: 400,
                body:
                  "Client.Local: unsupported column: variance(value) as v (the function " <>
                    "variance is not one the double has)"
              }} =
               Local.query_sql(conn, ~s|SELECT VARIANCE(value) AS v FROM "m"|, database: db)
    end

    test "an aggregate of two arguments is refused by name", %{conn: conn, db: db} do
      sql = ~s|SELECT AVG(value, other) AS a FROM "m"|

      assert {:error, %{status: 400, body: body}} = Local.query_sql(conn, sql, database: db)

      assert body ===
               "Client.Local: unsupported aggregate: avg(value, other) as a (it goes on at ,, " <>
                 "where an operator is expected)",
             sql
    end

    test "a malformed expression is the engine's parser error", %{conn: conn, db: db} do
      InfluxElixir.TestSupport.Check.each_case(
        [
          {"AVG(value +)", "Expected: an expression, found: ) at Line: 1, Column: 19"},
          {"AVG((value)", "Expected: ), found: AS at Line: 1, Column: 20"},
          {"AVG(value $ 2)", "Expected: ), found: $ at Line: 1, Column: 18"}
        ],
        fn {expression, message} ->
          sql = ~s|SELECT #{expression} AS a FROM "m"|

          assert Local.query_sql(conn, sql, database: db) ===
                   {:error, %{status: 400, body: ~s|SQL error: ParserError("#{message}")|}}
        end
      )
    end
  end

  describe "Client.Local: a time comparand it does not model" do
    setup %{conn: conn} do
      {:ok, :written} = Local.write(conn, "q price=1.0 1000000000", database: "test_db")
      {:ok, db: "test_db"}
    end

    # The engine answers "Error during planning: Invalid function 'foo'." with
    # a "Did you mean" suggestion that varies from run to run (verified); the
    # double refuses by name with the same status.
    test "an unknown function is refused by name", %{conn: conn, db: db} do
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
end
