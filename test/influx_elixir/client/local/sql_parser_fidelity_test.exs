defmodule InfluxElixir.Client.Local.SQLParserFidelityTest do
  @moduledoc """
  The parser's answers where InfluxDB 3 Core was asked and its text is
  pinned here (every body below was recorded from a real Core).
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.{SQLFunctions, SQLParser}

  defp parse!(sql, params \\ %{}) do
    assert {:ok, query} = sql |> SQLParser.resolve_params(params) |> SQLParser.parse_select()
    query
  end

  defp refused(sql, params \\ %{}) do
    assert {:error, error} = sql |> SQLParser.resolve_params(params) |> SQLParser.parse_select()
    error
  end

  defp coercion(message),
    do: "type_coercion\ncaused by\nError during planning: " <> message

  describe "string literals" do
    test "a doubled quote is one quote" do
      assert %{where: [{:eq, "name", "O'Brien"}]} =
               parse!("SELECT * FROM m WHERE name = 'O''Brien'")

      assert %{where: [{:like, "name", regex}]} =
               parse!("SELECT * FROM m WHERE name LIKE 'O''B%'")

      assert Regex.match?(regex, "O'Brien")
    end

    test "a bound string is data, never re-parsed" do
      hostile = "zzz' OR v > 0 OR name = 'q"

      assert %{where: [{:eq, "name", ^hostile}], limit: nil} =
               parse!("SELECT * FROM m WHERE name = $n", %{n: hostile})

      assert %{where: [{:eq, "name", "O'Brien"}]} =
               parse!("SELECT * FROM m WHERE name = $n", %{"n" => "O'Brien"})
    end

    test "a placeholder inside a literal is text" do
      assert SQLParser.resolve_params("SELECT * FROM m WHERE s = '$n' AND v = $n", %{n: 1}) ==
               "SELECT * FROM m WHERE s = '$n' AND v = 1"

      assert SQLParser.unbound_placeholder("SELECT * FROM m WHERE s = '$n'") == nil
      assert SQLParser.unbound_placeholder("SELECT * FROM m WHERE s = $n") == "$n"
    end

    test "SQL syntax inside a literal does not split anything" do
      assert %{where: [{:in, "city", ["Smith, John", "Doe"]}]} =
               parse!("SELECT * FROM m WHERE city IN ('Smith, John', 'Doe')")

      assert %{where: [{:eq, "s", "a>b"}]} = parse!("SELECT * FROM m WHERE s = 'a>b'")

      assert %{where: [{:eq, "s", "note limit 5"}], limit: nil} =
               parse!("SELECT * FROM m WHERE s = 'note limit 5'")

      assert %{where: [{:eq, "s", "x order by y"}], order_by: []} =
               parse!("SELECT * FROM m WHERE s = 'x order by y'")

      assert %{where: [{:eq, "s", "a from b"}]} = parse!("SELECT * FROM m WHERE s = 'a from b'")

      assert %{where: [{:eq, "s", "a group by b"}], group_by_columns: nil} =
               parse!("SELECT * FROM m WHERE s = 'a group by b'")

      assert %{projection_columns: [{{:lit, "a,b"}, "x"}], limit: 1} =
               parse!("SELECT 'a,b' AS x FROM m LIMIT 1")

      assert %{projection_columns: [{{:lit, "from m"}, "x"}, {"v", "v"}]} =
               parse!("SELECT 'from m' AS x, v FROM m")
    end
  end

  describe "constant predicates" do
    test "a comparison of two literals is every row or none" do
      assert %{where: []} = parse!("SELECT * FROM m WHERE 1 = 1")
      assert %{where: []} = parse!("SELECT * FROM m WHERE 1 < 2.5")
      assert %{where: []} = parse!("SELECT * FROM m WHERE 'a' = 'a'")
      assert %{where: [{:or, []}]} = parse!("SELECT * FROM m WHERE 1 = 2")
      assert %{where: [{:or, []}]} = parse!("SELECT * FROM m WHERE 'a' > 'b'")
    end

    test "TRUE and FALSE" do
      assert %{where: []} = parse!("SELECT * FROM m WHERE true")
      assert %{where: [{:or, []}]} = parse!("SELECT * FROM m WHERE false")
      assert %{where: [{:not, []}]} = parse!("SELECT * FROM m WHERE NOT true")
      assert %{where: [{:gt, "v", 1}]} = parse!("SELECT * FROM m WHERE true AND v > 1")
    end

    test "a lone literal that is not a boolean is the engine's planning error" do
      assert %{
               status: 400,
               body:
                 "Error during planning: Cannot create filter with non-boolean predicate " <>
                   "'Int64(1)' returning Int64"
             } = refused("SELECT * FROM m WHERE 1")

      assert %{body: body} = refused("SELECT * FROM m WHERE 1.5")
      assert body =~ "'Float64(1.5)' returning Float64"

      assert %{body: body} = refused("SELECT * FROM m WHERE 'a'")
      assert body =~ ~s|'Utf8("a")' returning Utf8|
    end
  end

  describe "LIKE" do
    test "_ is one character and ILIKE folds non-ASCII case" do
      assert %{where: [{:like, "s", like}]} = parse!("SELECT * FROM m WHERE s LIKE 'caf_'")
      assert Regex.match?(like, "café")
      refute Regex.match?(like, "cafe!!")

      assert %{where: [{:like, "s", ilike}]} = parse!("SELECT * FROM m WHERE s ILIKE 'éa'")
      assert Regex.match?(ilike, "Éa")
    end
  end

  describe "a bare number against time" do
    test "names the operator and the literal's type" do
      for {sql, pair} <- [
            {"time > 5", "Timestamp(ns) > Int64"},
            {"time >= -5", "Timestamp(ns) >= Int64"},
            {"time = 5", "Timestamp(ns) = Int64"},
            {"time <> 5", "Timestamp(ns) != Int64"},
            {"time <= 1.5", "Timestamp(ns) <= Float64"},
            {"5 < time", "Int64 < Timestamp(ns)"}
          ] do
        assert %{status: 400, body: body} = refused("SELECT * FROM m WHERE " <> sql)

        assert body ==
                 coercion("Cannot infer common argument type for comparison operation " <> pair),
               sql
      end
    end

    test "a non-negative integer param is UInt64, a negative one Int64" do
      assert %{body: body} = refused("SELECT * FROM m WHERE time > $t", %{t: 5})
      assert body =~ "Timestamp(ns) > UInt64"

      assert %{body: body} = refused("SELECT * FROM m WHERE time < $t", %{t: 5})
      assert body =~ "Timestamp(ns) < UInt64"

      assert %{body: body} = refused("SELECT * FROM m WHERE $t < time", %{t: 5})
      assert body =~ "UInt64 < Timestamp(ns)"

      assert %{body: body} = refused("SELECT * FROM m WHERE time > $t", %{t: -5})
      assert body =~ "Timestamp(ns) > Int64"

      assert %{body: body} = refused("SELECT * FROM m WHERE time > $t", %{t: 1.5})
      assert body =~ "Timestamp(ns) > Float64"
    end

    test "an integer param elsewhere is a plain number" do
      assert %{where: [{:gt, "v", 5}]} = parse!("SELECT * FROM m WHERE v > $t", %{t: 5})
    end

    test "IN and BETWEEN word it their own way" do
      assert %{status: 400, body: body} = refused("SELECT * FROM m WHERE time IN (1, 'a')")

      assert body ==
               coercion(
                 "Can not find compatible types to compare Timestamp(ns) with [Int64, Utf8]"
               )

      assert %{body: body} = refused("SELECT * FROM m WHERE time IN ($t)", %{t: 5})
      assert body =~ "with [UInt64]"

      assert %{status: 500, body: body} = refused("SELECT * FROM m WHERE time BETWEEN 1 AND 2")

      assert body ==
               "type_coercion\ncaused by\nInternal error: Failed to coerce types " <>
                 "Timestamp(ns) and Int64 in BETWEEN expression.\nThis issue was likely " <>
                 "caused by a bug in DataFusion's code. Please help us to resolve this by " <>
                 "filing a bug report in our issue tracker: " <>
                 "https://github.com/apache/datafusion/issues"
    end

    test "a quoted timestamp still parses" do
      assert %{where: [{:gt, "time", ns}]} =
               parse!("SELECT * FROM m WHERE time > '2023-11-14T22:13:20Z'")

      assert ns == 1_700_000_000_000_000_000
    end
  end

  describe "aggregates over time" do
    test "AVG and SUM have their own words" do
      assert %{status: 400, body: avg} = refused("SELECT AVG(time) AS a FROM m")

      assert avg ==
               "Error during planning: Execution error: Function 'avg' user-defined coercion " <>
                 "failed with \"Error during planning: Avg does not support inputs of type " <>
                 "Timestamp(ns).\" No function matches the given name and argument types " <>
                 "'avg(Timestamp(ns))'. You might need to add explicit type casts.\n" <>
                 "\tCandidate functions:\n\tavg(UserDefined)"

      assert %{body: sum} = refused("SELECT SUM(time) AS a FROM m")

      assert sum ==
               "Error during planning: Execution error: Function 'sum' user-defined coercion " <>
                 "failed with \"Execution error: Sum not supported for Timestamp(ns)\" No " <>
                 "function matches the given name and argument types 'sum(Timestamp(ns))'. " <>
                 "You might need to add explicit type casts.\n" <>
                 "\tCandidate functions:\n\tsum(UserDefined)"
    end

    test "the statistics share one wording and name themselves canonically" do
      for {call, name} <- [
            {"median", "median"},
            {"stddev", "stddev"},
            {"stddev_samp", "stddev"},
            {"stddev_pop", "stddev_pop"},
            {"var", "var"},
            {"var_samp", "var"},
            {"var_pop", "var_pop"}
          ] do
        assert %{status: 400, body: body} = refused("SELECT #{call}(time) AS a FROM m")

        assert body ==
                 "Error during planning: Function '#{name}' expects NativeType::Numeric but " <>
                   "received NativeType::Timestamp(Nanosecond, None) No function matches the " <>
                   "given name and argument types '#{name}(Timestamp(ns))'. You might need to " <>
                   "add explicit type casts.\n\tCandidate functions:\n\t#{name}(Numeric(1))",
               call
      end
    end

    test "an alias is not needed, and MIN, MAX and COUNT are fine" do
      assert %{body: "Error during planning: Execution error: Function 'avg'" <> _rest} =
               refused("SELECT AVG(time) FROM m")

      assert %{select_columns: [{:aggregate, :min, {:field, "time"}, "a"}]} =
               parse!("SELECT MIN(time) AS a FROM m")
    end
  end

  describe "SELECT DISTINCT" do
    test "ORDER BY outside the select list names the measurement" do
      assert %{
               status: 400,
               body:
                 "Error during planning: For SELECT DISTINCT, ORDER BY expressions " <>
                   "pp.price must appear in select list"
             } = refused("SELECT DISTINCT v FROM pp ORDER BY price")

      # Several are listed run together, with no separator.
      assert %{body: body} = refused("SELECT DISTINCT v FROM pp ORDER BY price, name")
      assert body =~ "expressions pp.pricepp.name must appear"

      assert %{body: body} = refused("SELECT DISTINCT v FROM pp ORDER BY price + 1")
      assert body =~ "expressions pp.price must appear"
    end

    test "ORDER BY a selected column is fine" do
      assert %{distinct_columns: ["v"], order_by: [{"v", :desc}]} =
               parse!("SELECT DISTINCT v FROM pp ORDER BY v DESC")
    end

    test "DISTINCT over no columns" do
      assert %{distinct_columns: [], measurement: "prices"} =
               parse!("SELECT DISTINCT FROM prices")

      assert %{body: "Error during planning: For SELECT DISTINCT, ORDER BY expressions" <> rest} =
               refused("SELECT DISTINCT FROM prices ORDER BY price")

      assert rest =~ "prices.price must appear in select list"
    end
  end

  describe "LIMIT and OFFSET" do
    test "a negative LIMIT or OFFSET is an optimizer error" do
      assert %{status: 400, body: body} = refused("SELECT v FROM pp LIMIT -1")

      assert body ==
               "Optimizer rule 'eliminate_limit' failed\ncaused by\n" <>
                 "Error during planning: LIMIT must be >= 0, '-1' was provided"

      assert %{body: body} = refused("SELECT v FROM pp OFFSET -1")

      assert body ==
               "Optimizer rule 'eliminate_limit' failed\ncaused by\n" <>
                 "Error during planning: OFFSET must be >=0, '-1' was provided"

      assert %{body: body} = refused("SELECT v FROM pp LIMIT 1 OFFSET -1")

      assert body ==
               "Optimizer rule 'push_down_limit' failed\ncaused by\n" <>
                 "Error during planning: OFFSET must be >=0, '-1' was provided"

      assert %{body: "Optimizer rule 'eliminate_limit' failed" <> rest} =
               refused("SELECT v FROM pp LIMIT -1 OFFSET -1")

      assert rest =~ "LIMIT must be >= 0"
    end

    test "a name is a schema error, a fraction a type error, NULL no limit" do
      assert %{status: 500, body: "Schema error: No field named abc."} =
               refused("SELECT v FROM pp LIMIT abc")

      assert %{status: 500, body: "Schema error: No field named abc."} =
               refused("SELECT v FROM pp LIMIT 1 OFFSET abc")

      assert %{status: 400, body: body} = refused("SELECT v FROM pp LIMIT 1.5")

      assert body ==
               coercion("Expected LIMIT to be an integer or null, but got Float64")

      assert %{body: body} = refused("SELECT v FROM pp LIMIT 1 OFFSET 1.5")
      assert body == coercion("Expected OFFSET to be an integer or null, but got Float64")

      assert %{limit: nil, offset: nil} = parse!("SELECT v FROM pp LIMIT NULL OFFSET NULL")
    end

    test "a column called offset is still a column" do
      assert %{where: [{:gt, "offset", 3}], limit: 2} =
               parse!("SELECT v FROM pp WHERE offset > 3 LIMIT 2")
    end
  end

  describe "FIRST and LAST" do
    test "are the engine's invalid function, with one stable suggestion" do
      assert %{
               status: 400,
               body: "Error during planning: Invalid function 'first'.\nDid you mean '" <> rest
             } =
               refused("SELECT FIRST(v) AS a FROM pp")

      assert rest =~ ~r/\A[a-z_0-9]+'\?\z/

      assert %{body: "Error during planning: Invalid function 'last'.\nDid you mean '" <> rest} =
               refused("SELECT last(v) FROM pp")

      assert rest =~ ~r/\A[a-z_0-9]+'\?\z/
    end

    test "first_value and last_value are not them" do
      assert {:ok, _query} =
               SQLParser.parse_select("SELECT first_value(v ORDER BY time) AS a FROM pp")
    end
  end

  describe "DATE_BIN" do
    test "a select-list bucket must be the GROUP BY's" do
      assert %{status: 400, body: "Client.Local: a DATE_BIN in the select list" <> _rest} =
               refused("SELECT DATE_BIN(INTERVAL '1 second', time) AS t, MAX(v) AS m FROM pp")

      assert %{status: 400, body: "Client.Local: a DATE_BIN in the select list" <> _rest} =
               refused("""
               SELECT DATE_BIN(INTERVAL '1 second', time) AS t, MAX(v) AS m FROM pp
               GROUP BY DATE_BIN(INTERVAL '2 second', time)
               """)
    end

    test "an interval is compared by value, not by spelling" do
      assert %{group_by_interval: 60_000_000_000, select_columns: [{:time_bucket, "t"}, _agg]} =
               parse!("""
               SELECT DATE_BIN(INTERVAL '60 seconds', time) AS t, MAX(v) AS m FROM pp
               GROUP BY DATE_BIN(INTERVAL '1 minute', time)
               """)
    end

    test "a position or alias in GROUP BY resolves to the select item" do
      for group <- ["1", "t"] do
        assert %{group_by_interval: 1_000_000_000} =
                 parse!(
                   "SELECT DATE_BIN(INTERVAL '1 second', time) AS t, MAX(v) AS m FROM pp " <>
                     "GROUP BY #{group}"
                 )
      end
    end

    test "an interval of zero still parses" do
      assert %{group_by_interval: 0} =
               parse!("""
               SELECT DATE_BIN(INTERVAL '0 second', time) AS t, MAX(v) AS m FROM pp
               GROUP BY DATE_BIN(INTERVAL '0 second', time)
               """)
    end
  end

  describe "round with a scale outside a double" do
    test "is refused by name, not an ArithmeticError" do
      for scale <- [309, 400, -309, -400] do
        assert {:query_error, %{status: 400, body: "Client.Local: round(x, " <> _rest}} =
                 catch_throw(SQLFunctions.call(:round, [1.0, scale])),
               "scale #{scale}"
      end

      # x * 10^scale overflows although the power itself does not.
      assert {:query_error, %{status: 400}} =
               catch_throw(SQLFunctions.call(:round, [2.5, 308]))
    end

    test "a scale that fits rounds as before" do
      assert SQLFunctions.call(:round, [1234.5678, -2]) == 1200.0
      assert SQLFunctions.call(:round, [2.345, 2]) == 2.35
      assert SQLFunctions.call(:round, [-2.5, 0]) == -3.0
      assert SQLFunctions.call(:round, [1.0, 300]) == 1.0
      assert SQLFunctions.call(:round, [1.0, -308]) == 0.0
      assert SQLFunctions.call(:round, [1.0, nil]) == nil
    end
  end
end
