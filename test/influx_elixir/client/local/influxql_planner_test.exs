defmodule InfluxElixir.Client.Local.InfluxQLPlannerTest do
  @moduledoc """
  Unit tests for the InfluxQL planner modules of `Client.Local`: what the
  double refuses by name where the engine's answer cannot be told from its
  neighbours, and the pure helpers (`InfluxQLArithmetic`, `InfluxQLTime`,
  `InfluxQLNames`, `InfluxQLLiteral`). What the double answers as the engine
  does is in `InfluxElixir.Contract.InfluxQLFluxLP`, run against both.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  alias InfluxElixir.Client.Local.{
    InfluxQLArithmetic,
    InfluxQLLiteral,
    InfluxQLNames,
    InfluxQLTime
  }

  setup do
    {:ok, conn} = Local.start(databases: ["planner"], profile: :v3_core)

    lines = [
      "m,k=a i=1i,j=5i,u=3u,f=1.5 1000",
      "m,k=b i=2i,j=-5i,u=18446744073709551615u,f=-2.5 2000"
    ]

    assert {:ok, :written} = Local.write(conn, Enum.join(lines, "\n"), database: "planner")
    {:ok, conn: conn}
  end

  defp refused(conn, statement) do
    assert {:error, %{status: 400, body: body}} =
             Local.query_influxql(conn, statement, database: "planner")

    body
  end

  describe "refused by name" do
    test "select items that end up with the same name", %{conn: conn} do
      for statement <- [
            "SELECT i AS time, j AS time FROM m",
            "SELECT first(i) AS time, last(i) AS time FROM m"
          ] do
        assert refused(conn, statement) ===
                 "Client.Local: unsupported InfluxQL " <>
                   "(select items that end up with the same name): #{statement}"
      end
    end

    test "* beside other items, a renamed time beside an aggregate", %{conn: conn} do
      statement = "SELECT *, i FROM m"

      assert refused(conn, statement) ===
               "Client.Local: unsupported InfluxQL (* beside other select items): #{statement}"

      statement = "SELECT max(i), time AS x FROM m"

      assert refused(conn, statement) ===
               "Client.Local: unsupported InfluxQL " <>
                 "(a renamed time column beside an aggregate): #{statement}"
    end

    test "a tag called time in GROUP BY", %{conn: conn} do
      for group <- ["\"time\"", "time::tag", "k, \"time\""] do
        statement = "SELECT i FROM m GROUP BY #{group}"

        assert refused(conn, statement) ===
                 "Client.Local: unsupported InfluxQL (GROUP BY a tag named time): #{statement}"
      end
    end

    test "a quoted time in a form the double cannot tell from the engine's", %{conn: conn} do
      for content <- [" 1970-01-01", "1970-1-1", "1970-01-01 00:00:00 UTC", "-0001-01-01"] do
        assert refused(conn, "SELECT i FROM m WHERE time >= '#{content}'") ===
                 "Client.Local: unsupported InfluxQL " <>
                   "(the time '#{content}' in a form the double does not read)"
      end
    end

    test "a time before what the SQL engine reads", %{conn: conn} do
      for where <- [
            "time >= -9223372036854775808",
            "time <= '1677-09-21T00:12:43.145224192Z'"
          ] do
        assert refused(conn, "SELECT i FROM m WHERE #{where}") ===
                 "Client.Local: unsupported InfluxQL (a time before 1677-09-21T00:12:44)"
      end
    end

    test "an unsigned arithmetic comparison inside OR", %{conn: conn} do
      assert refused(conn, "SELECT i FROM m WHERE u * 2 > 4 OR i = 1") ===
               "Client.Local: unsupported InfluxQL " <>
                 "(an unsigned arithmetic comparison inside OR)"
    end

    test "a bare time in a condition of a shape the double has not seen", %{conn: conn} do
      for where <- ["(time) AND (time)", "(time) AND i > 1 AND k = 'a'"] do
        assert refused(conn, "SELECT i FROM m WHERE #{where}") ===
                 "Client.Local: unsupported InfluxQL " <>
                   "(a bare time inside a condition of that shape)"
      end
    end

    test "a constant the double cannot name as the engine does", %{conn: conn} do
      for {constant, why} <- [
            {"100000000000000000000.5", "a float constant of that size"},
            {"0.00001", "a float constant of that size"},
            {"'a\\nb'", "a string constant with escapes"},
            {"9223372036854775808", "an integer constant beyond 64 bits"}
          ] do
        statement = "SELECT mean(#{constant}) FROM m"

        assert refused(conn, statement) ===
                 "Client.Local: unsupported InfluxQL (#{why}): #{statement}"
      end

      statement = "SELECT mean(-i) FROM m"

      assert refused(conn, statement) ===
               "Client.Local: unsupported select item: mean(-i): #{statement}"
    end
  end

  describe "InfluxQLLiteral.debug/1" do
    test "a constant as the engine's parser holds it" do
      for {text, debug} <- [
            {"true", "Boolean(true)"},
            {"FALSE", "Boolean(false)"},
            {"007", "Integer(7)"},
            {"-5", "Integer(-5)"},
            {"+5", "Integer(5)"},
            {"1.5", "Float(1.5)"},
            {".5", "Float(0.5)"},
            {"+.5", "Float(0.5)"},
            {"-0.5", "Float(-0.5)"},
            {"0.0", "Float(0.0)"},
            {"0.0001", "Float(0.0001)"},
            {"100000000000000.0", "Float(100000000000000.0)"},
            {"15000000000.0", "Float(15000000000.0)"},
            {"123456789012345.6", "Float(123456789012345.6)"},
            {"5s", "Duration(Duration(5000000000))"},
            {"2w", "Duration(Duration(1209600000000000))"},
            {"'a'", "String(\"a\")"},
            {"'a\\'b'", "String(\"a'b\")"},
            {"'a\"b'", "String(\"a\\\"b\")"}
          ] do
        assert InfluxQLLiteral.debug(text) === {:ok, debug}, text
      end

      assert InfluxQLLiteral.debug("x") === :none
      assert InfluxQLLiteral.debug("5x") === :none
    end

    test "check_items/1 names the first constant" do
      items = [{:column, "i", "i"}, {:aggregate, "mean", {:literal, "Integer(1)"}, nil}]

      assert {:error, {:engine, body}} = InfluxQLLiteral.check_items(items)

      assert body ===
               "rewriting statement\ncaused by\ngather information about select statement\n" <>
                 "caused by\nError during planning: " <>
                 "expected field argument in mean(), got Literal(Integer(1))"

      assert InfluxQLLiteral.check_items([{:column, "i", "i"}]) === :ok
      assert InfluxQLLiteral.literal_item?({:literal, "1"})
      refute InfluxQLLiteral.literal_item?({:column, "i", "i"})
    end
  end

  describe "InfluxQLNames.resolve/1" do
    test "numbers a name taken twice, skipping those taken" do
      items = [{:column, "i", "i_1"}, {:column, "i", "i"}, {:column, "i", "i"}]

      assert InfluxQLNames.resolve(items) ===
               {:ok, [{:column, "i", "i_1"}, {:column, "i", "i"}, {:column, "i", "i_2"}]}
    end

    test "an item called time is time_1 unless a time column is selected" do
      assert InfluxQLNames.resolve([{:column, "i", "time"}]) === {:ok, [{:column, "i", "time_1"}]}

      assert InfluxQLNames.resolve([{:aggregate, "mean", "i", "time"}]) ===
               {:ok, [{:aggregate, "mean", "i", "time_1"}]}

      assert InfluxQLNames.resolve([{:column, "time", "time"}, {:column, "i", "time"}]) ===
               {:ok, [{:column, "time", "time"}, {:column, "i", "time_1"}]}

      assert InfluxQLNames.time_name([{:column, "TIME", "x"}, {:column, "i", "i"}]) === "x"
      assert InfluxQLNames.time_name([{:column, "i", "i"}]) === "time"
    end

    test "a list with a constant in it is left to the planner's error" do
      items = [{:literal, "1"}, :star, {:column, "i", "i"}]
      assert InfluxQLNames.resolve(items) === {:ok, items}
    end
  end

  describe "InfluxQLTime.classify/1" do
    test "reads the forms the planner reads, to nanoseconds" do
      for {content, ns} <- [
            {"1970-01-01", 0},
            {"1970-01-01T00:00:01Z", 1_000_000_000},
            {"1970-01-01t00:00:01z", 1_000_000_000},
            {"1970-01-01 00:00:01", 1_000_000_000},
            {"1970-01-01T01:00:00+01:00", 0},
            {"1970-01-01T00:00:00.000002Z", 2000},
            {"1970-01-01T00:00:60Z", 60_000_000_000},
            {"2262-04-11T23:47:16.854775807Z", 9_223_372_036_854_775_807}
          ] do
        assert InfluxQLTime.classify(content) === {:ok, ns}, content
      end
    end

    test "an instant past 64-bit nanoseconds is out of range, shown as the engine shows it" do
      assert InfluxQLTime.classify("2262-04-12") ===
               {:out_of_range, "2262-04-12 00:00:00 +00:00"}

      assert InfluxQLTime.classify("1677-09-21T00:12:43.145224191Z") ===
               {:out_of_range, "1677-09-21 00:12:43.145224191 +00:00"}

      assert InfluxQLTime.classify("2262-04-12T00:00:00.5Z") === :unknown

      assert InfluxQLTime.classify("2262-04-12T00:00:00+00:30") ===
               {:ok, 9_223_371_000_000_000_000}
    end

    test "structures the planner refuses are invalid" do
      for content <- [
            "",
            "a",
            "1970-01",
            "1970-01-01T00:00:00",
            "1970-01-01 00:00",
            "1970-02-29",
            "1970-01-01T24:00:00Z",
            "1970-01-01T00:00:00Z ",
            "10000-01-01"
          ] do
        assert InfluxQLTime.classify(content) === :invalid, content
      end
    end

    test "forms it cannot tell from the engine's are unknown" do
      for content <- [" 1970-01-01", "1970-1-1", "1970-01-01 00:00:00 UTC", "a'b", "-0001-01-01"] do
        assert InfluxQLTime.classify(content) === :unknown, content
      end
    end
  end

  describe "InfluxQLArithmetic" do
    test "fold/3 wraps a sum at the range of its type" do
      assert InfluxQLArithmetic.fold("sum", [9_223_372_036_854_775_807, 1], :integer) ===
               -9_223_372_036_854_775_808

      assert InfluxQLArithmetic.fold("sum", [18_446_744_073_709_551_615, 2], :unsigned) === 1
      assert InfluxQLArithmetic.fold("sum", [1, 2], nil) === 3
      assert InfluxQLArithmetic.fold("sum", [1.5, 2.5], nil) === 4.0
      assert InfluxQLArithmetic.fold("sum", [1.0e308, 1.0e308], :float) === nil
    end

    test "fold/3 takes the mean of the exact sum, and null for a float one that overflows" do
      assert InfluxQLArithmetic.fold("mean", [1, 2], :integer) === 1.5
      assert InfluxQLArithmetic.fold("mean", [1.0e308, 1.0e308], :float) === nil
      assert InfluxQLArithmetic.fold("mean", [1.0, 2.0], :float) === 1.5
    end

    test "compile/2 takes a comparison of numbers with an unsigned field in it" do
      types = %{"u" => :unsigned, "j" => :integer, "f" => :float, "s" => :string}
      u = {:ident, "u"}

      assert {:ok, {:check, "<", {:op, "*", {:field, "u", :uint}, {:lit, {:int, -1}}}, _zero}} =
               InfluxQLArithmetic.compile(
                 [u, {:raw, "*"}, {:raw, "-"}, {:number, "1"}, {:op, "<"}, {:number, "0"}],
                 types
               )

      for tokens <- [
            [{:ident, "j"}, {:op, ">"}, {:number, "1"}],
            [u, {:op, "=~"}, {:regex, "a"}],
            [u, {:op, ">"}, {:str, "a"}],
            [u, {:op, ">"}, {:ident, "s"}],
            [u, {:op, ">"}, {:number, "1"}, {:op, "<"}, {:number, "3"}],
            [u, {:raw, "("}, {:op, ">"}, {:number, "1"}],
            [u, {:op, ">"}, {:number, "18446744073709551616"}]
          ] do
        assert InfluxQLArithmetic.compile(tokens, types) === :unsupported, inspect(tokens)
      end
    end

    test "keep?/2 follows the engine's casts" do
      types = %{"u" => :unsigned, "j" => :integer, "f" => :float}
      check = fn tokens -> elem(InfluxQLArithmetic.compile(tokens, types), 1) end
      u = {:ident, "u"}
      j = {:ident, "j"}

      # u * -1 = 2 holds for 2^64 - 1: -1 is cast to 2^64 - 2
      times = check.([u, {:raw, "*"}, {:raw, "-"}, {:number, "1"}, {:op, "="}, {:number, "2"}])
      assert InfluxQLArithmetic.keep?([times], %{"u" => 18_446_744_073_709_551_615})
      refute InfluxQLArithmetic.keep?([times], %{"u" => 3})
      refute InfluxQLArithmetic.keep?([times], %{})

      # an integer field is cast to unsigned: -1 is 2^64 - 2
      compared = check.([j, {:op, "="}, u])
      assert InfluxQLArithmetic.keep?([compared], %{"j" => -1, "u" => 18_446_744_073_709_551_614})
      refute InfluxQLArithmetic.keep?([compared], %{"j" => -9_223_372_036_854_775_808, "u" => 0})

      # a float next to an unsigned makes both floats, a division by zero is null
      floats = check.([u, {:raw, "+"}, {:ident, "f"}, {:op, ">"}, {:number, "4"}])
      assert InfluxQLArithmetic.keep?([floats], %{"u" => 3, "f" => 1.5})
      refute InfluxQLArithmetic.keep?([floats], %{"u" => 3, "f" => 0.5})

      divided = check.([u, {:raw, "/"}, {:number, "0"}, {:op, ">"}, {:number, "1"}])
      refute InfluxQLArithmetic.keep?([divided], %{"u" => 3})
      divided_float = check.([u, {:raw, "/"}, {:number, "0.0"}, {:op, ">"}, {:number, "1"}])
      refute InfluxQLArithmetic.keep?([divided_float], %{"u" => 3})

      huge = check.([{:ident, "f"}, {:raw, "*"}, {:ident, "f"}, {:op, ">"}, u])
      refute InfluxQLArithmetic.keep?([huge], %{"u" => 3, "f" => 1.0e200})
    end
  end
end
