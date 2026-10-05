defmodule InfluxElixir.Client.Local.SQLScalarRefusalsTest do
  @moduledoc """
  The SQL expressions, functions and `SHOW` statements `Client.Local` refuses by
  name instead of answering as the engine does, with the exact words of a few of them.
  What the engine answers to the rest is pinned for the double and for the real servers by
  `InfluxElixir.Contract.SQLScalar`; its `*_refusable` tables pin the exact reason of
  every refusal in `InfluxElixir.Contract.SQLScalarRefusals`, so that a refusal cannot
  change its words, or turn into another refusal, unnoticed.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.TestSupport.Check

  setup do
    {:ok, conn} = Local.start(databases: ["refusals"])

    lines =
      Enum.join(
        [
          ~s|m,host=h0 n=1i,x=2.5,s="s0",b=true 1700000000000000000|,
          ~s|m,host=h1 n=2i,x=3.5,s="s1",b=false 1700000030000000000|
        ],
        "\n"
      )

    {:ok, :written} = Local.write(conn, lines, database: "refusals")
    {:ok, conn: conn}
  end

  describe "an expression the double cannot answer as the engine does" do
    test "is refused by name", %{conn: conn} do
      Check.each_case(
        [
          {"SELECT substr(s) FROM m",
           "Client.Local: substr with one argument: the engine's error quotes the argument's " <>
             "position in the query, which is not modelled"},
          {"SELECT length(time) FROM m",
           "Client.Local: length of a timestamp: the engine writes its nanoseconds as text, " <>
             "which the double keeps only to the microsecond"},
          {"SELECT time || 'x' FROM m",
           "Client.Local: a timestamp concatenated as text: the engine writes its " <>
             "nanoseconds, which the double keeps only to the microsecond"},
          {"SELECT coalesce(n, s) FROM m",
           "Client.Local: COALESCE of an integer with text: the engine casts the text to the " <>
             "number when it runs the plan (and closes the connection when a value does not " <>
             "cast), which is not modelled"},
          {"SELECT nullif(n, s) FROM m",
           "Client.Local: NULLIF of an integer with text: the engine casts the text to the " <>
             "number when it runs the plan (and closes the connection when a value does not " <>
             "cast), which is not modelled"},
          {"SELECT nosuch(a => 1) AS r",
           "Client.Local: a call to nosuch, a function the double does not know, beside a call " <>
             "with a named argument: which of the two errors the engine gives first is not modelled"},
          {"SELECT greatest(n, b) FROM m",
           "Client.Local: greatest of arguments with no common type the double models"},
          {"SELECT CASE WHEN n THEN 1 END FROM m",
           "Client.Local: a CASE condition that is not a boolean: the engine casts it"},
          {"SELECT CASE WHEN b THEN time ELSE 1 END FROM m",
           "Client.Local: a CASE whose results have no common type the double models"},
          {"SELECT pow(1e300 * 1e300, 2.0) FROM m",
           "Client.Local: pow of an infinity or a NaN: the engine's result for it is not modelled"},
          {"SELECT s ~ 's' FROM m",
           "Client.Local: unsupported column: s ~ 's' as r (the character ~ is not one it reads)"}
        ],
        fn {sql, body} ->
          sql = String.replace(sql, ~r/ FROM m\z/, " AS r FROM m")
          assert {:error, %{status: 400, body: ^body}} = Local.query_sql(conn, sql, [])
        end
      )
    end
  end

  describe "a spelling the engine reads and the double does not" do
    test "is refused by name once the text reads", %{conn: conn} do
      Check.each_case(
        [
          {"SELECT n <=> 1 FROM m",
           "Client.Local: the null-safe equality operator <=>: write IS NOT DISTINCT FROM"},
          {"SELECT * EXCLUDE (n) FROM m",
           "Client.Local: a wildcard option (EXCLUDE, EXCEPT, REPLACE, RENAME or ILIKE) after *"},
          {"SELECT * EXCEPT n FROM m",
           "Client.Local: a wildcard option (EXCLUDE, EXCEPT, REPLACE, RENAME or ILIKE) after *"},
          {"SELECT 0x10 FROM m",
           "Client.Local: a hexadecimal number (0x...) is a binary value on the engine, " <>
             "which this double does not model"},
          {"SELECT n FROM (m CROSS JOIN m)", "Client.Local: a parenthesised table expression"},
          {"VALUES (1)", "Client.Local: a VALUES statement: the double reads no VALUES rows"},
          {"SELECT CASE time WHEN 's' THEN 1 END FROM m",
           "Client.Local: a CASE comparing time with text: the engine reads the text as a " <>
             "timestamp, which is not modelled"},
          {"SELECT log(CAST(n AS DOUBLE), n) FROM m",
           "Client.Local: log of an expression and its cast to a float: whether the engine " <>
             "folds it to 1.0 depends on the column's type"}
        ],
        fn {sql, body} ->
          assert {:error, %{status: 400, body: ^body}} = Local.query_sql(conn, sql, [])
        end
      )
    end

    test "gives way to the engine's parser error when the text does not read", %{conn: conn} do
      assert {:error, %{status: 400, body: body}} =
               Local.query_sql(conn, "SELECT n <=> 1 FROM m WHERE", [])

      assert body ===
               ~s|SQL error: ParserError("Expected: an expression, found: EOF")|
    end
  end

  describe "SHOW and the information_schema" do
    test "refuse the views and system tables the double does not model", %{conn: conn} do
      Check.each_case(
        [
          {"SHOW COLUMNS FROM information_schema.views",
           "Client.Local: information_schema.views: the double models " <>
             "information_schema.tables, information_schema.columns and " <>
             "information_schema.schemata"},
          {"SELECT * FROM information_schema.routines",
           "Client.Local: information_schema.routines: the double models " <>
             "information_schema.tables, information_schema.columns and " <>
             "information_schema.schemata"},
          {"SHOW COLUMNS FROM system.nosuch",
           "Error during planning: table 'public.system.nosuch' not found"},
          {"SELECT * FROM system.queries",
           "Client.Local: system.queries: the engine's system tables are not modelled"},
          {"SHOW SCHEMAS", "Client.Local: unsupported SQL: show schemas"},
          {"SHOW COLUMNS", "Client.Local: unsupported SQL: show columns"},
          {"SHOW TABLES FROM iox", "Client.Local: unsupported SQL: show tables from iox"}
        ],
        fn {sql, body} ->
          assert {:error, %{status: 400, body: ^body}} = Local.query_sql(conn, sql, [])
        end
      )
    end
  end

  describe "a name or a statement the engine words by a measure the double does not hold" do
    test "is refused by name", %{conn: conn} do
      close =
        "Client.Local: an ORDER BY name close to a select item: the engine suggests the item " <>
          "by a measure of closeness the double does not hold"

      Check.each_case(
        [
          {"SELECT host, count(*) AS c FROM m GROUP BY host HAVING c.c > 0",
           "Client.Local: a HAVING name c.c whose relation is a column or a select item: the " <>
             "engine reads it as a field of that column"},
          {"SELECT host AS hh FROM m ORDER BY hhh", close},
          {"SELECT host, count(*) AS c FROM m GROUP BY host ORDER BY cc", close},
          {"SELECT host AS hh, count(*) AS c FROM m GROUP BY x.host",
           "Client.Local: a GROUP BY name with a relation that is not the column's: the " <>
             "engine may suggest the column"},
          {"DESCRIBE information_schema.columns",
           "Client.Local: DESCRIBE of information_schema.columns: only tables of the iox schema"},
          {"CREATE SCHEMA",
           "Client.Local: that CREATE or DROP of a database or a schema: the engine's error " <>
             "for it is not modelled"},
          {"MERGE INTO m USING m c2 ON true WHEN MATCHED THEN DELETE",
           "Client.Local: the statement \"MERGE INTO m USING m c2 ON true WHEN MATCHED THEN " <>
             "DELETE\" is not run: the engine's wording of it (its keywords in capitals) is " <>
             "not modelled"}
        ],
        fn {sql, body} ->
          assert {:error, %{status: 400, body: ^body}} = Local.query_sql(conn, sql, [])
        end
      )
    end
  end
end
