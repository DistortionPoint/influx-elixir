defmodule InfluxElixir.Client.Local.SQLParserFidelityTest do
  @moduledoc """
  What the parser makes of a `$name` and what `SQLParser.bind/2` makes of the
  nodes, as whole query shapes: a SQL answer cannot show them. What a query
  means, and every body the engine answers with, is pinned in
  `InfluxElixir.Contract.SQLParser` against both clients.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.{SQLLexer, SQLParser}

  @query %{
    measurement: "m",
    where: [],
    order_by: [],
    limit: nil,
    offset: nil,
    group_by_interval: nil,
    group_by_columns: nil,
    select_columns: nil,
    distinct_columns: nil,
    distinct_on: nil,
    projection_columns: nil,
    ctes: [],
    cross_join: nil
  }

  defp query(fields), do: Map.merge(@query, Map.new(fields))

  defp parse!(sql) do
    assert {:ok, parsed} = SQLParser.parse_select(sql)
    parsed
  end

  defp bound!(sql, params) do
    assert {:ok, bound} = sql |> parse!() |> SQLParser.bind(params)
    bound
  end

  describe "a placeholder in a parsed query" do
    test "is a node where a comparand, a list item, a bound or a limit stands" do
      assert parse!(
               "SELECT * FROM m WHERE v > $a AND s IN ($b, 'x') AND w BETWEEN $c AND 3 " <>
                 "LIMIT $n OFFSET $o"
             ) ==
               query(
                 where: [
                   {:gt, "v", {:param, "a"}},
                   {:in, "s", [{:param, "b"}, "x"]},
                   {:between, "w", {{:param, "c"}, 3}}
                 ],
                 limit: {:param, "n"},
                 offset: {:param, "o"}
               )
    end

    test "keeps the side it stood on against time" do
      assert parse!(
               "SELECT * FROM m WHERE time > $a AND $b < time AND " <>
                 "time BETWEEN $c AND '2024-01-01' AND time IN ($d, '2024-01-02')"
             ) ==
               query(
                 where: [
                   {:gt, "time", {:param, "a"}},
                   {:gt, "time", {:param, "b", :left}},
                   {:between, "time", {{:param, "c"}, 1_704_067_200_000_000_000}},
                   {:in, "time", [{:param, "d"}, 1_704_153_600_000_000_000]}
                 ]
               )
    end

    test "is a pattern to compile where a LIKE or a regex takes it" do
      assert parse!("SELECT * FROM m WHERE s LIKE $a AND s NOT ILIKE $b AND s ~* $c") ==
               query(
                 where: [
                   {:like, "s", {:like_param, "a", false}},
                   {:not_like, "s", {:like_param, "b", true}},
                   {:regex, "s", {:regex_param, "c", "~*"}}
                 ]
               )
    end

    test "is an operand of an expression and a constant of the select list" do
      assert parse!("SELECT $p AS x, v + $q AS y FROM m") ==
               query(
                 projection_columns: [
                   {{:param, "p"}, "x"},
                   {{:op, :+, {:field, "v"}, {:param, "q"}}, "y"}
                 ]
               )

      assert parse!("SELECT $p AS x, count(*) AS n FROM m") ==
               query(select_columns: [{:constant, {:param, "p"}, "x"}, {:count_star, "n"}])
    end

    test "is not read inside a literal or a comment" do
      assert parse!("SELECT * FROM m WHERE s = '$a' /* $b */ -- $c") ==
               query(where: [{:eq, "s", "$a"}])
    end
  end

  describe "bind/2" do
    test "gives a non-negative integer the engine's UInt64 and the other values their own" do
      params = %{"a" => 5, "b" => "x", "c" => 1.5, "d" => nil, "e" => -1, "f" => true}

      assert bound!(
               "SELECT * FROM m WHERE v > $a AND s = $b AND f < $c AND g = $d AND " <>
                 "h IN ($e, $f) AND w BETWEEN $a AND $e",
               params
             ) ==
               query(
                 where: [
                   {:gt, "v", {:uint, 5}},
                   {:eq, "s", "x"},
                   {:lt, "f", 1.5},
                   {:eq, "g", nil},
                   {:in, "h", [-1, true]},
                   {:between, "w", {{:uint, 5}, -1}}
                 ]
               )
    end

    test "types an operand of an expression and a constant" do
      assert bound!("SELECT $a AS x, v + $b AS y, v - $c AS z FROM m", %{
               "a" => "s",
               "b" => 2,
               "c" => -2
             }) ==
               query(
                 projection_columns: [
                   {{:lit, "s"}, "x"},
                   {{:op, :+, {:field, "v"}, {:uint, 2}}, "y"},
                   {{:op, :-, {:field, "v"}, {:lit, -2}}, "z"}
                 ]
               )

      assert bound!("SELECT $p AS x, count(*) AS n FROM m", %{"p" => 7}) ==
               query(select_columns: [{:constant, 7, "x"}, {:count_star, "n"}])
    end

    test "reads a time parameter as an instant and keeps now() as it is" do
      assert bound!("SELECT * FROM m WHERE time > $a AND $b < time AND time < now()", %{
               "a" => "2023-11-14T22:13:20Z",
               "b" => "2023-11-14"
             }) ==
               query(
                 where: [
                   {:gt, "time", 1_700_000_000_000_000_000},
                   {:gt, "time", 1_699_920_000_000_000_000},
                   {:lt, "time", {:now, 0}}
                 ]
               )
    end

    test "compiles a pattern parameter" do
      assert %{where: [{:like, "s", like}, {:regex, "s", {regex, "~"}}]} =
               bound!("SELECT * FROM m WHERE s LIKE $a AND s ~ $b", %{"a" => "a%", "b" => "^b"})

      assert Regex.match?(like, "abc")
      refute Regex.match?(like, "bac")
      assert Regex.match?(regex, "bcd")
    end

    test "binds LIMIT and OFFSET to integers, and NULL to none" do
      assert %{limit: 2, offset: 1} =
               bound!("SELECT * FROM m LIMIT $n OFFSET $o", %{"n" => 2, "o" => 1})

      assert %{limit: nil, offset: nil} =
               bound!("SELECT * FROM m LIMIT $n OFFSET $o", %{"n" => nil, "o" => nil})
    end

    test "returns a query without placeholders as it is, and leaves its CTEs to the executor" do
      plain = parse!("SELECT * FROM m WHERE v > 1")
      assert SQLParser.bind(plain, %{"a" => 1}) == {:ok, plain}

      with_cte = parse!("WITH c AS (SELECT * FROM m WHERE v > $a) SELECT * FROM c")

      assert with_cte.ctes == [
               {"c", query(where: [{:gt, "v", {:param, "a"}}])}
             ]

      assert SQLParser.bind(with_cte, %{}) == {:ok, with_cte}
    end

    test "names the first placeholder with no value, or whose value is not a scalar" do
      sql = "SELECT * FROM m WHERE v > $a AND s = $b"

      assert sql |> parse!() |> SQLParser.bind(%{"a" => 1}) ==
               {:error,
                %{
                  status: 400,
                  body: "Error during planning: No value found for placeholder with name $b"
                }}

      assert sql |> parse!() |> SQLParser.bind(%{"a" => 1, "b" => %{"x" => 1}}) ==
               {:error,
                %{status: 400, body: "Client.Local: the parameter $b is a JSON object or array"}}
    end
  end

  describe "parse_where/1 — a statement that binds nothing" do
    test "is the engine's unbound placeholder error for a $name" do
      assert SQLParser.parse_where(" WHERE v > $a") ==
               {:error,
                %{
                  status: 400,
                  body: "Error during planning: No value found for placeholder with name $a"
                }}
    end

    test "reads its text as the tokenizer does" do
      assert SQLParser.parse_where(" WHERE s = 'a") ==
               {:error,
                %{
                  status: 400,
                  body:
                    ~s|SQL error: TokenizerError("Unterminated string literal at Line: 1, | <>
                      ~s|Column: 12")|
                }}

      assert SQLParser.parse_where(" WHERE s = 'a;b' -- c") == {:ok, [{:eq, "s", "a;b"}]}
      assert SQLParser.parse_where("   ") == {:ok, []}
    end
  end

  describe "SQLLexer.scrub/1" do
    test "removes the comments, the semicolons and the dollar quotes, nothing else" do
      assert SQLLexer.scrub("select 'a -- b' /* c /* d */ */ , \"x;y\" from t -- e\n ; ;") ==
               {:ok, "select 'a -- b'   , \"x;y\" from t"}

      assert SQLLexer.scrub("select $$it's$$, $t$ $$ $t$, $1, $é") ==
               {:ok, "select 'it''s', ' $$ ', $1, $é"}
    end

    test "refuses a text that is not UTF-8" do
      assert SQLLexer.scrub(<<"select ", 0xFF>>) ==
               {:error, %{status: 400, body: "Client.Local: the SQL text is not valid UTF-8"}}
    end
  end
end
