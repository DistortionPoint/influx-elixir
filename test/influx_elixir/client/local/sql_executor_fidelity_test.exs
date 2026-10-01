defmodule InfluxElixir.Client.Local.SQLExecutorFidelityTest do
  @moduledoc """
  Where `Client.Local`'s SQL executor must answer exactly as InfluxDB 3 Core
  does (every body and row here was read from a real Core): null in
  `IN`/`BETWEEN`, aggregate and arithmetic type errors at plan time,
  `DATE_BIN` edges, ordered aggregates over nulls, CTE schemas, division by
  zero, floats compared as text, and the wording of the planner's errors.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Client.Local.{Format, SQLExecutor}

  @closed {:error, {:connection_error, %Mint.TransportError{reason: :closed}}}

  setup do
    {:ok, conn} = Local.start(databases: ["fidelity"], profile: :v3_core)
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  defp write!(conn, lines) do
    assert {:ok, :written} = Local.write(conn, Enum.join(lines, "\n"), database: "fidelity")
    :ok
  end

  defp query(conn, sql, opts \\ []),
    do: Local.query_sql(conn, sql, Keyword.put(opts, :database, "fidelity"))

  defp rows!(conn, sql) do
    assert {:ok, rows} = query(conn, sql)
    rows
  end

  defp error!(conn, sql) do
    assert {:error, %{status: status, body: body}} = query(conn, sql)
    {status, body}
  end

  defp seed_mixed(conn) do
    write!(conn, [
      ~s|t1,k=a v=1i,s="b",b=false,f=1.5 1000000000|,
      ~s|t1,k=b v=2i,s="a",b=true,f=2.5 2000000000|,
      "t1,k=c v=3i,b=true,f=500.0 3000000000"
    ])
  end

  describe "NULL in IN and BETWEEN" do
    test "a null in the list makes a miss unknown", %{conn: conn} do
      seed_mixed(conn)

      assert rows!(conn, "SELECT v FROM t1 WHERE v NOT IN (1, NULL)") == []
      assert rows!(conn, "SELECT v FROM t1 WHERE v NOT IN (NULL)") == []
      assert rows!(conn, "SELECT v FROM t1 WHERE v IN (NULL)") == []
      assert rows!(conn, "SELECT v FROM t1 WHERE v IN (1, NULL)") == [%{"v" => 1}]
      assert rows!(conn, "SELECT v FROM t1 WHERE s IN ('a', NULL)") == [%{"v" => 2}]
      assert rows!(conn, "SELECT v FROM t1 WHERE s NOT IN ('zz', NULL)") == []
    end

    test "a null parameter in the list is a null", %{conn: conn} do
      seed_mixed(conn)

      assert {:ok, []} =
               query(conn, "SELECT v FROM t1 WHERE v NOT IN (1, $x)", params: %{"x" => nil})
    end

    test "a null bound makes BETWEEN unknown, with three-valued AND", %{conn: conn} do
      seed_mixed(conn)

      assert rows!(conn, "SELECT v FROM t1 WHERE v BETWEEN NULL AND 5") == []
    end

    test "the executor evaluates a null bound in three-valued logic" do
      point = fn v -> %{measurement: "m", tags: %{}, fields: %{"v" => v}, timestamp: 1} end
      matches? = fn node, v -> SQLExecutor.matches_all?(point.(v), [node]) end

      refute matches?.({:between, "v", {nil, 5}}, 3)
      refute matches?.({:between, "v", {1, nil}}, 3)
      refute matches?.({:between, "v", {nil, nil}}, 3)
      refute matches?.({:not_between, "v", {nil, 2}}, 2)
      assert matches?.({:not_between, "v", {nil, 2}}, 3)
      refute matches?.({:not_between, "v", {1, nil}}, 3)
      assert matches?.({:not_between, "v", {1, nil}}, 0)
      refute matches?.({:not_between, "v", {nil, nil}}, 3)
    end
  end

  describe "aggregates over non-numeric columns are planning errors" do
    setup %{conn: conn} do
      seed_mixed(conn)
    end

    test "sum and avg", %{conn: conn} do
      assert error!(conn, "SELECT sum(s) AS x FROM t1") ==
               {400,
                "Error during planning: Execution error: Function 'sum' user-defined " <>
                  "coercion failed with \"Execution error: Sum not supported for Utf8\" " <>
                  "No function matches the given name and argument types 'sum(Utf8)'. " <>
                  "You might need to add explicit type casts.\n\tCandidate functions:\n" <>
                  "\tsum(UserDefined)"}

      assert error!(conn, "SELECT avg(b) AS x FROM t1") ==
               {400,
                "Error during planning: Execution error: Function 'avg' user-defined " <>
                  "coercion failed with \"Error during planning: Avg does not support " <>
                  "inputs of type Boolean.\" No function matches the given name and " <>
                  "argument types 'avg(Boolean)'. You might need to add explicit type " <>
                  "casts.\n\tCandidate functions:\n\tavg(UserDefined)"}
    end

    test "a tag is named by its dictionary type, and by its value type inside", %{conn: conn} do
      assert error!(conn, "SELECT sum(k) AS x FROM t1") ==
               {400,
                "Error during planning: Execution error: Function 'sum' user-defined " <>
                  "coercion failed with \"Execution error: Sum not supported for Utf8\" " <>
                  "No function matches the given name and argument types " <>
                  "'sum(Dictionary(Int32, Utf8))'. You might need to add explicit type " <>
                  "casts.\n\tCandidate functions:\n\tsum(UserDefined)"}
    end

    test "median, stddev and the variances want a numeric", %{conn: conn} do
      assert error!(conn, "SELECT median(s) AS x FROM t1") ==
               {400,
                "Error during planning: Function 'median' expects NativeType::Numeric but " <>
                  "received NativeType::String No function matches the given name and " <>
                  "argument types 'median(Utf8)'. You might need to add explicit type " <>
                  "casts.\n\tCandidate functions:\n\tmedian(Numeric(1))"}

      assert error!(conn, "SELECT stddev(k) AS x FROM t1") ==
               {400,
                "Error during planning: Function 'stddev' expects NativeType::Numeric but " <>
                  "received NativeType::String No function matches the given name and " <>
                  "argument types 'stddev(Dictionary(Int32, Utf8))'. You might need to add " <>
                  "explicit type casts.\n\tCandidate functions:\n\tstddev(Numeric(1))"}

      assert {400,
              "Error during planning: Function 'var' expects NativeType::Numeric but " <> _rest} =
               error!(conn, "SELECT var_samp(s) AS x FROM t1")

      assert {400, "Error during planning: Function 'var_pop' expects" <> _rest} =
               error!(conn, "SELECT var_pop(b) AS x FROM t1")

      assert {400, "Error during planning: Function 'stddev_pop' expects" <> _rest} =
               error!(conn, "SELECT stddev_pop(s) AS x FROM t1")
    end

    test "they are raised before any row is looked at", %{conn: conn} do
      assert {400, "Error during planning: Function 'median' expects" <> _rest} =
               error!(conn, "SELECT median(s) AS x FROM t1 WHERE v > 100")
    end

    test "min, max and count take any type", %{conn: conn} do
      assert rows!(conn, "SELECT min(b) AS lo, max(b) AS hi, count(b) AS n FROM t1") ==
               [%{"lo" => false, "hi" => true, "n" => 3}]

      assert rows!(conn, "SELECT min(s) AS lo, max(s) AS hi, count(s) AS n FROM t1") ==
               [%{"lo" => "a", "hi" => "b", "n" => 2}]

      assert rows!(conn, "SELECT min(k) AS lo, max(k) AS hi FROM t1") ==
               [%{"lo" => "a", "hi" => "c"}]
    end

    test "numbers aggregate", %{conn: conn} do
      assert rows!(conn, "SELECT sum(v) AS s, avg(f) AS a, median(v) AS m FROM t1") ==
               [%{"s" => 6, "a" => 168.0, "m" => 2}]
    end
  end

  describe "DATE_BIN" do
    test "an interval of zero closes the connection on the first row", %{conn: conn} do
      seed_mixed(conn)

      assert query(
               conn,
               "SELECT DATE_BIN(INTERVAL '0 seconds', time) AS t, count(*) AS n " <>
                 "FROM t1 GROUP BY 1"
             ) == @closed

      assert {:ok, []} =
               query(
                 conn,
                 "SELECT DATE_BIN(INTERVAL '0 seconds', time) AS t, count(*) AS n " <>
                   "FROM t1 WHERE v > 100 GROUP BY 1"
               )
    end

    test "a time before the epoch is in the bucket that starts before it", %{conn: conn} do
      write!(conn, ["neg v=1i -5", "neg v=2i -15"])

      assert rows!(
               conn,
               "SELECT DATE_BIN(INTERVAL '10 seconds', time) AS t, count(*) AS n " <>
                 "FROM neg GROUP BY 1"
             ) == [%{"t" => ~U[1969-12-31 23:59:50.000000Z], "n" => 2}]
    end
  end

  describe "grouping by time" do
    test "is a row per distinct time", %{conn: conn} do
      seed_mixed(conn)

      assert conn
             |> rows!("SELECT time, count(*) AS n FROM t1 GROUP BY time")
             |> Enum.sort_by(& &1["time"], DateTime) ==
               [
                 %{"time" => ~U[1970-01-01 00:00:01.000000Z], "n" => 1},
                 %{"time" => ~U[1970-01-01 00:00:02.000000Z], "n" => 1},
                 %{"time" => ~U[1970-01-01 00:00:03.000000Z], "n" => 1}
               ]
    end

    test "a boolean column groups by its value, false included", %{conn: conn} do
      seed_mixed(conn)

      assert conn
             |> rows!("SELECT b, count(*) AS n FROM t1 GROUP BY b")
             |> Enum.sort_by(& &1["b"]) ==
               [%{"b" => false, "n" => 1}, %{"b" => true, "n" => 2}]
    end
  end

  describe "ordered aggregates" do
    test "a first value of false is false, not missing", %{conn: conn} do
      seed_mixed(conn)

      assert rows!(
               conn,
               "SELECT first_value(b ORDER BY time) AS a, last_value(b ORDER BY time) AS z FROM t1"
             ) == [%{"a" => false, "z" => true}]
    end

    test "a null ordering value sorts last ascending and first descending", %{conn: conn} do
      seed_mixed(conn)

      assert rows!(
               conn,
               "SELECT first_value(v ORDER BY s) AS a, first_value(v ORDER BY s DESC) AS b, " <>
                 "last_value(v ORDER BY s) AS c, last_value(v ORDER BY s DESC) AS d FROM t1"
             ) == [%{"a" => 2, "b" => 3, "c" => 3, "d" => 2}]
    end
  end

  describe "arithmetic over text" do
    setup %{conn: conn} do
      seed_mixed(conn)
    end

    test "in the select list is a planning error naming the types", %{conn: conn} do
      assert error!(conn, "SELECT s + 1 AS x FROM t1") ==
               {400,
                "Error during planning: Cannot coerce arithmetic expression " <>
                  "Utf8 + Int64 to valid types"}

      assert error!(conn, "SELECT 1 + s AS x FROM t1") ==
               {400,
                "Error during planning: Cannot coerce arithmetic expression " <>
                  "Int64 + Utf8 to valid types"}

      assert error!(conn, "SELECT b * 2 AS x FROM t1") ==
               {400,
                "Error during planning: Cannot coerce arithmetic expression " <>
                  "Boolean * Int64 to valid types"}

      assert error!(conn, "SELECT k + 1 AS x FROM t1 WHERE v > 100") ==
               {400,
                "Error during planning: Cannot coerce arithmetic expression " <>
                  "Dictionary(Int32, Utf8) + Int64 to valid types"}
    end

    test "in WHERE and ORDER BY carries the type_coercion wrapper", %{conn: conn} do
      expected =
        "type_coercion\ncaused by\nError during planning: Cannot coerce arithmetic " <>
          "expression Utf8 + Int64 to valid types"

      assert error!(conn, "SELECT v FROM t1 WHERE s + 1 > 3") == {400, expected}
      assert error!(conn, "SELECT v FROM t1 ORDER BY s + 1") == {400, expected}
    end

    test "inside an aggregate", %{conn: conn} do
      assert error!(conn, "SELECT sum(s + 1) AS x FROM t1") ==
               {400,
                "Error during planning: Cannot coerce arithmetic expression " <>
                  "Utf8 + Int64 to valid types"}
    end

    test "the planner reports the first term it meets", %{conn: conn} do
      assert {400, "Error during planning: Function 'abs' expects" <> _rest} =
               error!(conn, "SELECT abs(s) AS a, s + 1 AS b FROM t1")

      assert {400, "Error during planning: Cannot coerce" <> _rest} =
               error!(conn, "SELECT s + 1 AS a, abs(s) AS b FROM t1")
    end

    test "numbers still add", %{conn: conn} do
      assert conn |> rows!("SELECT v + f AS x FROM t1 ORDER BY time") |> Enum.map(& &1["x"]) ==
               [2.5, 4.5, 503.0]
    end
  end

  describe "casting a boolean" do
    test "to text and to numbers", %{conn: conn} do
      seed_mixed(conn)

      assert rows!(
               conn,
               "SELECT CAST(b AS VARCHAR) AS t, CAST(b AS INTEGER) AS i, " <>
                 "CAST(b AS DOUBLE) AS d FROM t1 ORDER BY time"
             ) == [
               %{"t" => "false", "i" => 0, "d" => 0.0},
               %{"t" => "true", "i" => 1, "d" => 1.0},
               %{"t" => "true", "i" => 1, "d" => 1.0}
             ]
    end

    test "a float to text is written as the engine writes it", %{conn: conn} do
      write!(conn, [
        "fl amount=5000.0 1000000000",
        "fl amount=1e16 2000000000",
        "fl amount=1e-5 3000000000",
        "fl amount=1.5e-7 4000000000"
      ])

      assert conn
             |> rows!("SELECT CAST(amount AS VARCHAR) AS x FROM fl ORDER BY time")
             |> Enum.map(& &1["x"]) == ["5000.0", "1e16", "0.00001", "1.5e-7"]
    end
  end

  describe "a CTE" do
    test "keeps a time column that is not a timestamp", %{conn: conn} do
      seed_mixed(conn)

      assert conn
             |> rows!("WITH c AS (SELECT s AS time FROM t1) SELECT * FROM c")
             |> Enum.sort_by(&Map.get(&1, "time", "~")) == [
               %{"time" => "a"},
               %{"time" => "b"},
               %{}
             ]

      assert rows!(
               conn,
               "WITH c AS (SELECT s AS time FROM t1) SELECT time FROM c ORDER BY time"
             ) == [%{"time" => "a"}, %{"time" => "b"}, %{}]
    end

    test "keeps a column that is null in every row in its schema", %{conn: conn} do
      seed_mixed(conn)

      assert rows!(conn, "WITH c AS (SELECT k, s FROM t1 WHERE k = 'c') SELECT s FROM c") == [%{}]

      assert rows!(
               conn,
               "WITH c AS (SELECT k, s FROM t1 WHERE k = 'c') " <>
                 "SELECT count(s) AS n, count(*) AS m FROM c"
             ) == [%{"n" => 0, "m" => 1}]

      assert rows!(conn, "WITH c AS (SELECT * FROM t1 WHERE k = 'c') SELECT s FROM c") == [%{}]

      assert {500, "Schema error: No field named zz." <> _rest} =
               error!(conn, "WITH c AS (SELECT k, s FROM t1 WHERE k = 'c') SELECT zz FROM c")
    end

    test "keeps a timestamp time", %{conn: conn} do
      seed_mixed(conn)

      assert rows!(conn, "WITH c AS (SELECT time, v FROM t1) SELECT max(time) AS t FROM c") ==
               [%{"t" => ~U[1970-01-01 00:00:03.000000Z]}]
    end
  end

  describe "division by zero" do
    setup %{conn: conn} do
      seed_mixed(conn)
    end

    test "of an integer by the integer zero closes the connection", %{conn: conn} do
      assert query(conn, "SELECT v / 0 AS x FROM t1") == @closed
      assert query(conn, "SELECT v % 0 AS x FROM t1") == @closed
      assert query(conn, "SELECT sum(v / 0) AS x FROM t1") == @closed
      assert query(conn, "SELECT v FROM t1 WHERE v / 0 > 1") == @closed
      assert {:ok, []} = query(conn, "SELECT v / 0 AS x FROM t1 WHERE v > 100")
    end

    # Infinity or NaN on the engine, which compares as a number; the double
    # cannot hold it and refuses by name rather than answer null.
    test "involving a float is refused by name", %{conn: conn} do
      refusal =
        {:error,
         %{
           status: 400,
           body:
             "Client.Local: a float divided by zero is IEEE infinity or NaN on the " <>
               "engine, which the double cannot hold"
         }}

      for sql <- [
            "SELECT v / 0.0 AS x FROM t1",
            "SELECT 1.5 / 0 AS y FROM t1",
            "SELECT f % 0 AS z FROM t1",
            "SELECT v FROM t1 WHERE v / 0.0 > 1"
          ] do
        assert Local.query_sql(conn, sql, database: "fidelity") == refusal, sql
      end
    end
  end

  describe "a float compared with a string literal" do
    setup %{conn: conn} do
      write!(conn, [
        "fl,k=a amount=5000.0 1000000000",
        "fl,k=b amount=500.0 2000000000",
        "fl,k=c amount=12000.0 3000000000",
        "fl,k=d amount=1e16 4000000000",
        "fl,k=e amount=1e-5 5000000000",
        "fl,k=f amount=123456789.5 6000000000",
        "fl,k=g amount=1.5e-7 7000000000",
        "fl,k=h amount=-2.5 8000000000",
        "fl,k=i amount=1e15 9000000000"
      ])
    end

    defp keys(conn, where) do
      conn
      |> rows!("SELECT k FROM fl WHERE #{where} ORDER BY time")
      |> Enum.map(& &1["k"])
    end

    test "is compared as the text the engine renders", %{conn: conn} do
      assert keys(conn, "amount = '5000.0'") == ["a"]
      assert keys(conn, "amount >= '1000.00'") == ["a", "b", "c", "d", "f", "i"]
      assert keys(conn, "amount > '2e3'") == ["a", "b"]
      assert keys(conn, "amount = '1e16'") == ["d"]
      assert keys(conn, "amount = '1.0e16'") == []
      assert keys(conn, "amount = '0.00001'") == ["e"]
      assert keys(conn, "amount = '1e-5'") == []
      assert keys(conn, "amount = '1.5e-7'") == ["g"]
      assert keys(conn, "amount = '1000000000000000.0'") == ["i"]
      assert keys(conn, "amount = '-2.5'") == ["h"]
    end
  end

  describe "LIKE over a number" do
    setup %{conn: conn} do
      seed_mixed(conn)
    end

    test "names the column's real type, with the type_coercion wrapper", %{conn: conn} do
      prefix = "type_coercion\ncaused by\nError during planning: There isn't a common type to"

      assert error!(conn, "SELECT * FROM t1 WHERE f LIKE '1%'") ==
               {400, prefix <> " coerce Float64 and Utf8 in LIKE expression"}

      assert error!(conn, "SELECT * FROM t1 WHERE v LIKE '1%'") ==
               {400, prefix <> " coerce Int64 and Utf8 in LIKE expression"}

      assert error!(conn, "SELECT * FROM t1 WHERE b NOT LIKE 't%'") ==
               {400, prefix <> " coerce Boolean and Utf8 in LIKE expression"}
    end

    test "is a planning error even when an earlier conjunct is false for every row", %{conn: conn} do
      assert {400, "type_coercion\ncaused by\n" <> _rest} =
               error!(conn, "SELECT * FROM t1 WHERE f LIKE '1%' AND k = 'zz'")
    end
  end

  describe "CROSS JOIN" do
    setup %{conn: conn} do
      write!(conn, [
        "px,symbol=AAA,exch=X price=10.5,qty=3i 1000000000",
        "px,symbol=BBB,exch=Y price=20.5,qty=4i 2000000000",
        "ref,symbol=AAA price=1.0 1000000000",
        "ref2,zz=1 only2=5i 1000000000"
      ])
    end

    test "an ambiguous reference is the engine's error without a suffix", %{conn: conn} do
      assert error!(conn, "SELECT price, symbol FROM px CROSS JOIN ref") ==
               {500, "Schema error: Ambiguous reference to unqualified field price"}

      assert error!(conn, "SELECT qty FROM px CROSS JOIN ref WHERE symbol = 'a'") ==
               {500, "Schema error: Ambiguous reference to unqualified field symbol"}

      assert error!(conn, "SELECT qty, time FROM px CROSS JOIN ref WHERE price > 1") ==
               {500, "Schema error: Ambiguous reference to unqualified field price"}
    end

    test "columns that are not shared join", %{conn: conn} do
      assert conn
             |> rows!("SELECT qty, only2 FROM px CROSS JOIN ref2 ORDER BY qty")
             |> Enum.map(&{&1["qty"], &1["only2"]}) == [{3, 5}, {4, 5}]
    end
  end

  describe "an ungrouped column" do
    setup %{conn: conn} do
      write!(conn, ["px,symbol=AAA,exch=X price=10.5,qty=3i 1000000000"])
    end

    test "without GROUP BY", %{conn: conn} do
      assert error!(conn, "SELECT symbol, price, count(*) AS n FROM px") ==
               {400, ungrouped("px.symbol", "count(Int64(1))")}
    end

    test "names the first one, then the group and the aggregates", %{conn: conn} do
      assert error!(conn, "SELECT symbol, price, qty, count(*) AS n FROM px GROUP BY symbol") ==
               {400, ungrouped("px.price", "px.symbol, count(Int64(1))")}

      assert error!(conn, "SELECT exch, price, count(*) AS n FROM px GROUP BY symbol, exch") ==
               {400, ungrouped("px.price", "px.symbol, px.exch, count(Int64(1))")}

      assert error!(
               conn,
               "SELECT exch, count(*) AS a, sum(price) AS b, avg(qty) AS c, min(price) AS d FROM px GROUP BY symbol"
             ) ==
               {400,
                ungrouped(
                  "px.exch",
                  "px.symbol, count(Int64(1)), sum(px.price), avg(px.qty), min(px.price)"
                )}
    end

    test "prints expressions and distinct counts as the planner does", %{conn: conn} do
      assert error!(
               conn,
               "SELECT exch, sum(price * 2.5) AS a, count(DISTINCT qty) AS b, " <>
                 "sum(abs(price) - 1) AS c FROM px GROUP BY symbol"
             ) ==
               {400,
                ungrouped(
                  "px.exch",
                  "px.symbol, sum(px.price * Float64(2.5)), count(DISTINCT px.qty), " <>
                    "sum(abs(px.price) - Int64(1))"
                )}
    end

    test "prints a DATE_BIN by its interval in nanoseconds", %{conn: conn} do
      assert error!(
               conn,
               "SELECT price, DATE_BIN(INTERVAL '10 seconds', time) AS t, count(*) AS n " <>
                 "FROM px GROUP BY 2"
             ) ==
               {400,
                ungrouped(
                  "px.price",
                  ~s|date_bin(IntervalMonthDayNano("IntervalMonthDayNano { months: 0, | <>
                    ~s|days: 0, nanoseconds: 10000000000 }"),px.time), count(Int64(1))|
                )}
    end

    defp ungrouped(column, satisfying) do
      "Error during planning: Column in SELECT must be in GROUP BY or an aggregate " <>
        "function: While expanding wildcard, column \"#{column}\" must appear in the " <>
        "GROUP BY clause or must be part of an aggregate function, currently only " <>
        "\"#{satisfying}\" appears in the SELECT clause satisfies this requirement"
    end
  end

  describe "an unknown format" do
    test "ends with the position in the request body Client.HTTP sends", %{conn: conn} do
      assert {:error, %{status: 400, body: body}} =
               Local.query_sql(conn, "SELECT 1", database: "fidelity", format: :xml)

      prefix =
        "serde json error: unknown variant `xml`, expected one of `parquet`, `csv`, " <>
          "`pretty`, `json`, `json_lines`, `jsonl` at line 1 column "

      assert String.starts_with?(body, prefix)
      assert String.replace_prefix(body, prefix, "") =~ ~r/\A\d+\z/
    end

    test "Format counts the bytes of the database name and of the format" do
      for {database, format, column} <- [
            {"fix_exec", "xml", 31},
            {"nodb", "xml", 27},
            {"a", :yaml, 25}
          ] do
        assert {:error, %{body: body}} = Format.answer(format, fn -> {:ok, []} end, database)
        assert String.ends_with?(body, " at line 1 column #{column}")
      end
    end
  end

  describe "Format.render_decimal/1" do
    test "prints a float as the planner prints a Float64 literal" do
      assert Format.render_decimal(1.0) == "1"
      assert Format.render_decimal(2.5) == "2.5"
      assert Format.render_decimal(0.1) == "0.1"
      assert Format.render_decimal(1.0e20) == "100000000000000000000"
      assert Format.render_decimal(1.0e-7) == "0.0000001"
      assert Format.render_decimal(100_000.0) == "100000"
      assert Format.render_decimal(-1.5) == "-1.5"
    end
  end

  describe "a scalar call over many points" do
    test "is still checked against the columns' types", %{conn: conn} do
      lines = for i <- 1..2000, do: "bulk,k=a v=#{i}i,s=\"x\" #{i * 1_000_000_000}"
      write!(conn, lines)

      assert {400, "Error during planning: Function 'abs' expects" <> _rest} =
               error!(conn, "SELECT abs(s) AS x FROM bulk")

      assert [%{"x" => 1}] = rows!(conn, "SELECT abs(v) AS x FROM bulk LIMIT 1")
    end
  end
end
