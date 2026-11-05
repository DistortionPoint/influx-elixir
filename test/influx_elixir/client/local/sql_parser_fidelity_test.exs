defmodule InfluxElixir.Client.Local.SQLParserFidelityTest do
  @moduledoc """
  What a SQL answer cannot show, and no engine can be asked. What a query
  means, and every body the engine answers with, is pinned in
  `InfluxElixir.Contract.SQLParser` and `InfluxElixir.Contract.SQLExecutor`
  against both clients; this is the one edge only the double has: a text that
  is not UTF-8 cannot be sent to the engine (JSON has no form for it), so the
  double's refusal has no engine answer to match.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  alias InfluxElixir.Client.Local.{
    InfluxQLRegex,
    SQLBind,
    SQLCompare,
    SQLCondition,
    SQLDdl,
    SQLParser,
    SQLPredicate,
    SQLPredicates,
    SQLStatement,
    SQLWhere
  }

  test "a query text that is not UTF-8 is refused by name" do
    {:ok, conn} = Local.start(databases: ["utf8_db"], profile: :v3_core)

    assert Local.query_sql(conn, <<"select ", 0xFF>>, database: "utf8_db") ===
             {:error, %{status: 400, body: "Client.Local: the SQL text is not valid UTF-8"}}
  end

  describe "InfluxQLRegex refusal and flag group edge cases" do
    test "refuses uncompilable regex patterns, backreferences, and unsupported groups" do
      assert catch_throw(InfluxQLRegex.pattern("[unclosed")) ==
               {:refused, "unsupported InfluxQL (the regular expression /[unclosed/)"}

      assert catch_throw(InfluxQLRegex.pattern("\\1")) ==
               {:refused, "unsupported InfluxQL (the regular expression escape \\1)"}

      assert catch_throw(InfluxQLRegex.pattern("(?#comment)")) ==
               {:refused, "unsupported InfluxQL (the regular expression group (?#)"}

      assert catch_throw(InfluxQLRegex.pattern("(?P=name)")) ==
               {:refused, "unsupported InfluxQL (the regular expression group (?P=)"}
    end

    test "refuses unworded flag groups and non-UTF8 bytes" do
      unworded =
        {:refused,
         "unsupported InfluxQL (a regular expression flag group the double does not word)"}

      assert catch_throw(InfluxQLRegex.pattern("(?i")) == unworded
      assert catch_throw(InfluxQLRegex.pattern("(?--i)a")) == unworded
      assert catch_throw(InfluxQLRegex.pattern("(?R)a")) == unworded
      assert catch_throw(InfluxQLRegex.pattern("(?ii)a")) == unworded

      assert catch_throw(InfluxQLRegex.pattern(<<0xFF>>)) ==
               {:refused, <<"unsupported InfluxQL (the regular expression /", 0xFF, "/)">>}
    end
  end

  describe "SQLPredicates, SQLCompare, and SQLDdl internal edge cases" do
    test "SQLPredicates.flatten handles empty negated conjunction and empty negated disjunction" do
      leaves = %{
        never: :never,
        opaque: &{:opaque, &1},
        clause: fn c, n -> [{c, n}] end
      }

      assert SQLPredicates.flatten([], true, leaves) == [:never]
      assert SQLPredicates.flatten([{:or, []}], true, leaves) == []
    end

    test "SQLCompare handles null comparisons, non-boolean negation, and text rendering" do
      assert {:query_error, %{status: 400}} = catch_throw(SQLCompare.negate(:not_a_bool))
      assert SQLCompare.compare(nil, :eq, 1) == false
      assert SQLCompare.compare(1, :eq, nil) == false
      assert SQLCompare.wide_decimal_float(1.0, {:dec, 10, 1}) == :ok
      assert SQLCompare.text({:int, 32, 42}) == "42"
      assert SQLCompare.text({:dec, 123, 2}) == "1.23"
      assert SQLCompare.text(:inf) == "inf"
      assert SQLCompare.text(:neg_inf) == "-inf"
      assert SQLCompare.text(:nan) == "NaN"
    end

    test "SQLDdl.error returns nil for non-matching statement shapes" do
      assert SQLDdl.error("DROP TABLE a; DROP TABLE b") == nil
      assert SQLDdl.error("MSCK OTHER") == nil
      assert SQLDdl.error("CREATE OR REPLACE TABLE t (x INT)") == nil
      assert SQLDdl.error("CREATE 1") == nil
      assert SQLDdl.error("CREATE VIRTUAL VIEW v") == nil
      assert SQLDdl.error("DROP MATERIALIZED TABLE t") == nil
      assert SQLDdl.error("DROP UNKNOWN_KIND x") == nil
      assert SQLDdl.error("DROP 1") == nil
      assert SQLDdl.error("DROP INDEX idx ON 1") == nil
      assert SQLDdl.error("DROP INDEX idx EXTRA") == nil
      assert SQLDdl.error("DROP INDEX a, b EXTRA") == nil
      assert SQLDdl.error("ATTACH DATABASE 1") == nil
      assert SQLDdl.error("DROP TABLE a, 1") == nil
    end

    test "refuses multi-statement INSERT when first statement cuts off inside an unmodelled cell" do
      {:ok, conn} = Local.start(databases: ["utf8_db"], profile: :v3_core)

      assert {:error, %{status: 400, body: body}} =
               Local.query_sql(
                 conn,
                 "INSERT INTO m VALUES (INTERVAL 1; SELECT 1",
                 database: "utf8_db"
               )

      assert body =~ "a statement that ends inside a value the double cannot read"
    end

    test "SQLCondition.node_value handles non-boolean predicates, null timestamps, and pattern errors" do
      point = %{
        measurement: "cpu",
        tags: %{"host" => "s1"},
        fields: %{"v" => 42},
        timestamp: 1_000
      }

      assert {:query_error, %{status: 400}} =
               catch_throw(SQLCondition.node_value(point, {:non_boolean, "v", {"v", "Int64"}}))

      assert {:query_error, %{status: 400}} =
               catch_throw(
                 SQLCondition.node_value(point, {:truthy_expr, {:expr, {:field, "v"}}, nil})
               )

      assert {:query_error, %{status: 400}} =
               catch_throw(
                 SQLCondition.node_value(
                   point,
                   {:truthy_expr, {:expr, {:cast, {:field, "v"}, :int64}}, nil}
                 )
               )

      assert {:query_error, %{status: 400}} =
               catch_throw(SQLCondition.node_value(point, {:truthy, "v", nil}))

      assert {:query_error, %{status: 400}} =
               catch_throw(SQLCondition.node_value(point, {:truthy, "host", nil}))

      assert SQLCondition.node_value(%{point | timestamp: nil}, {:eq, "time", 100}) == nil
      assert SQLCondition.node_value(%{point | timestamp: nil}, {:in, "time", [100]}) == nil

      assert {:query_error, %{status: 400}} =
               catch_throw(SQLCondition.node_value(point, {:like, "v", ~r/a/}))

      assert {:query_error, %{status: 400}} =
               catch_throw(
                 SQLCondition.node_value(point, {:regex, "v", {~r/a/, "~", %{}, :other}})
               )
    end

    test "SQLWhere, SQLPredicate, SQLBind, and SQLStatement handle malformed clauses and parameter bindings" do
      for clause <- [
            "WHERE a = 1 )",
            "WHERE a = 1 (",
            "WHERE a = 1 AND",
            "WHERE AND a = 1",
            "WHERE OR a = 1",
            "WHERE NOT",
            "WHERE )",
            "WHERE (a = 1",
            "WHERE a = 'unterminated",
            "WHERE (a = 'unterminated"
          ] do
        assert {:error, %{status: 400}} = SQLWhere.parsed(clause)
      end

      assert SQLPredicate.parse("false IS NULL") == {:ok, {:is_null, {:expr, {:lit, false}}, nil}}

      assert SQLPredicate.parse("true IS NOT NULL") ==
               {:ok, {:is_not_null, {:expr, {:lit, true}}, nil}}

      assert {:ok, query} = SQLParser.parse_select("SELECT * FROM m WHERE $1 = a")

      assert {:error, %{status: 400, body: "Client.Local: " <> _reason}} =
               SQLBind.bind(query, %{"1" => true})

      assert {:ok, bound_val} = SQLBind.bind(query, %{"1" => 42})
      assert [{:eq, "a", {:uint, 42}}] = bound_val.where

      assert {:ok, partial} = SQLBind.bind_partial(query, %{})
      assert partial.where == query.where

      assert {:ok, partial_val} = SQLBind.bind_partial(query, %{"1" => 42})
      assert [{:eq, "a", {:uint, 42}}] = partial_val.where

      assert {:error, %{status: 400, body: "Client.Local: " <> _reason}} =
               SQLBind.bind_partial(query, %{"1" => false})

      assert SQLStatement.display("RELEASE s") == {:ok, "RELEASE SAVEPOINT s"}
      assert SQLStatement.display("RELEASE SAVEPOINT s") == {:ok, "RELEASE SAVEPOINT s"}
      assert SQLStatement.display("DROP VIEW IF EXISTS v") == {:ok, "DROP VIEW IF EXISTS v"}
      assert %{status: 400} = SQLStatement.bare_error("ATTACH ;")
    end

    test "CTE columns named time with IS DISTINCT FROM, unsigned CTE outputs, and power/sqrt edge cases" do
      {:ok, conn} = Local.start(databases: ["cte_db"], profile: :v3_core)

      assert {:ok, :written} =
               Local.write(
                 conn,
                 "m,host=a u=10u,v=1.5 1704067200000000000",
                 database: "cte_db"
               )

      assert {:ok, [%{"same" => false, "diff" => true}]} =
               Local.query_sql(
                 conn,
                 "WITH t AS (SELECT '2024-01-01T00:00:00Z' AS time) " <>
                   "SELECT time IS DISTINCT FROM '2024-01-01T00:00:00Z' AS same, " <>
                   "'abc' IS DISTINCT FROM time AS diff FROM t",
                 database: "cte_db"
               )

      for cte_sql <- [
            "WITH t AS (SELECT DISTINCT u FROM m) SELECT * FROM t WHERE u < 0",
            "WITH t AS (SELECT first_value(u ORDER BY time) AS u FROM m) " <>
              "SELECT * FROM t WHERE u < 0",
            "WITH t AS (SELECT selector_first(u, time)['value'] AS u FROM m) " <>
              "SELECT * FROM t WHERE u < 0"
          ] do
        assert {:error, %{status: 400, body: body}} =
                 Local.query_sql(conn, cte_sql, database: "cte_db")

        assert body =~ "leaves a numeric column no value"
      end

      assert {:error, {:connection_error, %{reason: :closed}}} =
               Local.query_sql(conn, "SELECT power(2, 65) FROM m", database: "cte_db")

      assert {:ok, [%{"s" => nil}]} =
               Local.query_sql(conn, "SELECT sqrt(-1.0 / 0.0) AS s FROM m", database: "cte_db")

      for sql <- [
            ~s|SELECT * FROM m WHERE time BETWEEN "u" AND 1|,
            ~s|SELECT * FROM m WHERE time IN ("u", 1)|
          ] do
        assert {:error, %{status: 400, body: "Client.Local: " <> _reason}} =
                 Local.query_sql(conn, sql, database: "cte_db")
      end

      assert {:error, %{status: 400, body: in_null_body}} =
               Local.query_sql(conn, "SELECT * FROM m WHERE time IN (NULL, 1)",
                 database: "cte_db"
               )

      assert in_null_body =~
               "Can not find compatible types to compare Timestamp(ns) with [Null, Int64]"

      {:ok, ent} = Local.start(databases: ["ent_db"], profile: :v3_enterprise)

      assert {:error, %{status: 400, body: del_body}} =
               Local.execute_sql(ent, "DELETE FROM m WHERE time > 1", database: "ent_db")

      assert del_body =~
               "Cannot infer common argument type for comparison operation Timestamp(ns) > Int64"

      {:ok, v2} = Local.start(databases: ["b"], profile: :v2)

      assert {:ok, :written} =
               Local.write(v2, "m,host=a flag=true,v=10i 1704067200000000000", bucket: "b")

      assert {:ok, [%{"_value" => true}]} =
               Local.query_flux(
                 v2,
                 ~S[from(bucket: "b") |> range(start: 0) |> filter(fn: (r) => r._field == "flag" and r._value == true)],
                 org: "my-org"
               )

      assert {:ok, [%{"_value" => 10}]} =
               Local.query_flux(
                 v2,
                 ~S[from(bucket: "b") |> range(start: 0) |> filter(fn: (r) => r._field == "v" and r._value >= 10 and r._value <= 10)],
                 org: "my-org"
               )

      assert {:ok, []} =
               Local.query_flux(
                 v2,
                 ~S[from(bucket: "b") |> range(start: 0) |> filter(fn: (r) => not (r._field == "v") and r._field == "v") |> first()],
                 org: "my-org"
               )

      assert {:error, %{status: 400, body: flux_err}} =
               Local.query_flux(
                 v2,
                 ~S[from(bucket: "b") |> range(start: 0) |> filter(bad: 1)],
                 org: "my-org"
               )

      assert flux_err =~ "Client.Local: unsupported filter(): bad: 1"
    end
  end
end
