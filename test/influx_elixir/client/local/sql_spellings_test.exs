defmodule InfluxElixir.Client.Local.SQLSpellingsTest do
  @moduledoc """
  The spellings the engine reads as others (`InfluxElixir.Client.Local.SQLRewrite`),
  the types of aggregates (`InfluxElixir.Client.Local.SQLAggType`) and the place a
  call with no argument stands in (`InfluxElixir.Client.Local.SQLConstantCall`), at
  the edges the contract tables do not reach.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.{SQLAggType, SQLConstantCall, SQLRewrite, SQLSyntax}
  alias InfluxElixir.TestSupport.Check

  describe "SQLRewrite.apply/1" do
    test "writes each spelling as the one the double reads" do
      Check.each_case(
        [
          {"SELECT n FROM m WHERE n == 1 AND s = 'a==b'",
           "SELECT n FROM m WHERE n = 1 AND s = 'a==b'"},
          {"SELECT `n`, `a``b`, `x\"y` FROM `m`", ~s|SELECT "n", "a`b", "x""y" FROM "m"|},
          {"SELECT ALL n FROM m", "SELECT  n FROM m"},
          {"SELECT DISTINCT ALL n FROM m", "SELECT DISTINCT ALL n FROM m"},
          {"SELECT n FROM (m)", "SELECT n FROM m"},
          {"SELECT n FROM ((m)) AS t", "SELECT n FROM m AS t"},
          {"SELECT n FROM ( a.\"b\" ) t", ~s|SELECT n FROM  a."b" t|},
          {"SELECT n FROM (SELECT 1) t", "SELECT n FROM (SELECT 1) t"},
          {"SELECT n FROM (a, b)", "SELECT n FROM (a, b)"},
          {"SELECT n FROM a, b", "SELECT n FROM a CROSS JOIN b"},
          {"SELECT n FROM a x, (b) y, c", "SELECT n FROM a x CROSS JOIN b y CROSS JOIN c"},
          {"SELECT f(a, b) FROM a, b WHERE n IN (1, 2)",
           "SELECT f(a, b) FROM a CROSS JOIN b WHERE n IN (1, 2)"},
          {"SELECT n FROM (SELECT n FROM a, b) q, c",
           "SELECT n FROM (SELECT n FROM a CROSS JOIN b) q CROSS JOIN c"},
          {"SELECT n FROM a ORDER BY n IS NOT DISTINCT FROM 1, n",
           "SELECT n FROM a ORDER BY n IS NOT DISTINCT FROM 1, n"},
          {"SELECT n FROM a LIMIT 1 FETCH FIRST 2 ROWS ONLY", "SELECT n FROM a LIMIT 1 "},
          {"SELECT n FROM a FETCH NEXT 2 ROW WITH TIES", "SELECT n FROM a "},
          {"SELECT n FROM a FETCH FIRST ROWS ONLY", "SELECT n FROM a "},
          {"SELECT n FROM a FETCH 50 PERCENT ROWS", "SELECT n FROM a "},
          {"SELECT n FROM a FETCH FIRST $1 ROWS ONLY", "SELECT n FROM a "},
          {"SELECT n FROM a FETCH FIRST 'x' ROWS ONLY", "SELECT n FROM a "},
          {"SELECT n FROM a FETCH FIRST TRUE ROW ONLY", "SELECT n FROM a "},
          {"SELECT fetch FROM a", "SELECT fetch FROM a"},
          {"SELECT n FROM a OFFSET 2 ROWS", "SELECT n FROM a OFFSET 2"},
          {"SELECT n FROM a OFFSET $1 ROW", "SELECT n FROM a OFFSET $1"},
          {"SELECT n FROM a OFFSET n ROWS", "SELECT n FROM a OFFSET n ROWS"},
          {"SELECT 'unterminated", "SELECT 'unterminated"},
          {"SELECT é FROM ünï, b", "SELECT é FROM ünï CROSS JOIN b"}
        ],
        fn {sql, rewritten} -> assert SQLRewrite.apply(sql) == rewritten end
      )
    end
  end

  describe "SQLAggType.types/2" do
    test "gives each aggregate the type of its result, and none the engine rejects" do
      columns = %{
        "n" => "Int64",
        "x" => "Float64",
        "u" => "UInt64",
        "i" => "Int32",
        "h" => "Dictionary(Int32, Utf8)",
        "b" => "Boolean",
        "d" => "Decimal128(?)"
      }

      aggs = [
        {"a0", {:count_star, "c"}},
        {"a1", {:count_distinct, "n", "c"}},
        {"a2", {:aggregate, :count, {:field, "h"}, "c"}},
        {"a3", {:aggregate, :sum, {:field, "n"}, "s"}},
        {"a4", {:aggregate, :sum, {:field, "u"}, "s"}},
        {"a5", {:aggregate, :sum, {:field, "x"}, "s"}},
        {"a6", {:aggregate, :sum, {:field, "i"}, "s"}},
        {"a7", {:aggregate, :sum, {:field, "d"}, "s"}},
        {"a8", {:aggregate, :sum, {:field, "b"}, "s"}},
        {"a9", {:aggregate, :avg, {:field, "n"}, "s"}},
        {"b0", {:aggregate, :stddev, {:field, "u"}, "s"}},
        {"b1", {:aggregate, :min, {:field, "h"}, "s"}},
        {"b2", {:aggregate, :max, {:field, "b"}, "s"}},
        {"b3", {:aggregate, :median, {:field, "u"}, "s"}},
        {"b4", {:aggregate, :median, {:field, "h"}, "s"}},
        {"b5", {:aggregate, :sum, {:field, "nosuch"}, "s"}},
        {"b6", {:ordered_aggregate, :first, "h", "time", "f"}},
        {"b7", {:selector, :first, "x", "time", :value, "f"}},
        {"b8", {:selector, :first, "x", "time", :time, "f"}},
        {"b9", {:selector, :first, "x", "time", :struct, "f"}},
        {"c0", {:constant, 1, "k"}}
      ]

      assert SQLAggType.types(aggs, columns) == %{
               "a0" => "Int64",
               "a1" => "Int64",
               "a2" => "Int64",
               "a3" => "Int64",
               "a4" => "UInt64",
               "a5" => "Float64",
               "a6" => "Int64",
               "a9" => "Float64",
               "b0" => "Float64",
               "b1" => "Utf8",
               "b2" => "Boolean",
               "b3" => "UInt64",
               "b6" => "Dictionary(Int32, Utf8)",
               "b7" => "Float64",
               "b8" => "Timestamp(ns)"
             }
    end

    test "names the columns the aggregates read" do
      aggs = [
        {"a0", {:count_distinct, "n", "c"}},
        {"a1", {:aggregate, :sum, {:op, :+, {:field, "x"}, {:lit, 1}}, "s"}},
        {"a2", {:ordered_aggregate, :last, "s", "time", "l"}},
        {"a3", {:selector, :min, "v", "time", :value, "m"}},
        {"a4", {:count_star, "c"}}
      ]

      assert Enum.sort(SQLAggType.fields(aggs)) == ["n", "s", "v", "x"]
    end
  end

  describe "SQLConstantCall.phase/2" do
    test "says which pass reports a call with no argument" do
      Check.each_case(
        [
          {[], :select, :planner},
          {[:cast], :select, :planner},
          {[:isnull], :select, :optimizer},
          {[:cast, :isnull], :where, :optimizer},
          {[:other, :isnull], :select, :coercion},
          {[:deferred, :other], :select, :coercion},
          {[:other], :where, :coercion},
          {[:cast], :where, :bare},
          {[], :order_by, :bare},
          {[:neg], :order_by, :bare},
          {[:cast], :order_by, :bare},
          {[:other], :order_by, :coercion}
        ],
        fn {ancestors, clause, phase} ->
          assert SQLConstantCall.phase(ancestors, clause) == phase
        end
      )
    end
  end

  describe "SQLSyntax.check_statements/1" do
    test "reads each statement at its place in the whole text" do
      Check.each_case(
        [
          {"SELECT 1;\nSELECT 2 x y",
           ~s|SQL error: ParserError("Expected: end of statement, found: y at Line: 2, Column: 12")|},
          {"SELECT $$a\nb$$ x y",
           ~s|SQL error: ParserError("Expected: end of statement, found: y at Line: 2, Column: 7")|},
          {"SELECT E'a\\nb' x y",
           ~s|SQL error: ParserError("Expected: end of statement, found: y at Line: 1, Column: 18")|},
          {"SELECT 1 E'a' z",
           ~s|SQL error: ParserError("Expected: end of statement, found: E'a' at Line: 1, Column: 10")|},
          {"SELECT 1 0x1F z",
           ~s|SQL error: ParserError("Expected: end of statement, found: X'1F' at Line: 1, Column: 10")|},
          {"SELECT 1; garbage",
           ~s|SQL error: ParserError("Expected: an SQL statement, found: garbage at Line: 1, Column: 11")|},
          {"SELECT n FROM m WHERE; SELECT 1",
           ~s|SQL error: ParserError("Expected: an expression, found: ; at Line: 1, Column: 22")|},
          {"SELECT /* ; */ 1 -- ;\n; 'a;b' x y",
           ~s|SQL error: ParserError("Expected: an SQL statement, found: 'a;b' at Line: 2, Column: 3")|},
          {"SELECT \"a;b\" x y",
           ~s|SQL error: ParserError("Expected: end of statement, found: y at Line: 1, Column: 16")|},
          {"SELECT $t$;$t$ x y",
           ~s|SQL error: ParserError("Expected: end of statement, found: y at Line: 1, Column: 18")|},
          {"SELECT n FROM m FETCH FIRST ONLY",
           ~s|SQL error: ParserError("Expected: a concrete value, found: ONLY at Line: 1, Column: 29")|},
          {"SELECT n FROM m FETCH FIRST -1 ROWS",
           ~s|SQL error: ParserError("Expected: a value, found: - at Line: 1, Column: 29")|},
          {"SELECT TOP n FROM m",
           ~s|SQL error: ParserError("Expected: literal int, found: n at Line: 1, Column: 12")|},
          {"SELECT ALL DISTINCT n",
           ~s|SQL error: ParserError("Cannot specify both ALL and DISTINCT at Line: 1, Column: 8")|},
          {"SELECT n FROM (SELECT n x y FROM m)",
           ~s|SQL error: ParserError("Expected: ), found: x at Line: 1, Column: 25")|},
          {"SELECT n FROM m WHERE n IN (SELECT n FROM m WHERE",
           ~s|SQL error: ParserError("Expected: ), found: n at Line: 1, Column: 36")|},
          {"(SELECT n FROM m", ~s|SQL error: ParserError("Expected: ), found: EOF")|},
          {"WITH t SELECT 1",
           ~s|SQL error: ParserError("Expected: AS, found: SELECT at Line: 1, Column: 8")|},
          {"WITH", ~s|SQL error: ParserError("Expected: identifier, found: EOF")|}
        ],
        fn {sql, body} ->
          assert {:error, %{status: 400, body: ^body}} = SQLSyntax.check_statements(sql)
        end
      )
    end

    test "reads what the engine reads and the double refuses by name or answers elsewhere" do
      Check.each_case(
        [
          {"SELECT n FROM m ORDER BY time FETCH FIRST 2 ROWS ONLY", :ok},
          {"SELECT * EXCEPT (n) FROM m", {400, "Client.Local: a wildcard option"}},
          {"SELECT t.* ILIKE 'a%' FROM m t", {400, "Client.Local: a wildcard option"}},
          {"SELECT TOP 3 n FROM m", {405, "This feature is not implemented: TOP"}},
          {"SELECT n FROM m WHERE n <=> 1", {400, "Client.Local: the null-safe"}},
          {"SELECT 0x10", {400, "Client.Local: a hexadecimal number"}},
          {"SELECT n FROM (m CROSS JOIN m)", {400, "Client.Local: a parenthesised"}},
          {"SELECT n FROM ((m))", :ok},
          {"SELECT n FROM (WITH t AS (SELECT 1) SELECT * FROM t) q", :ok},
          {"WITH RECURSIVE t AS (SELECT 1) SELECT 1", :ok},
          {"DELETE FROM m", :ok}
        ],
        fn
          {sql, :ok} ->
            assert SQLSyntax.check_statements(sql) == :ok

          {sql, {status, prefix}} ->
            assert {:error, %{status: ^status, body: body}} = SQLSyntax.check_statements(sql)
            assert String.starts_with?(body, prefix)
        end
      )
    end
  end
end
