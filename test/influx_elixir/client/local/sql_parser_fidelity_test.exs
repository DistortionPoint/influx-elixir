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
    SQLCompare,
    SQLCondition,
    SQLDdl,
    SQLPredicates
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
  end
end
