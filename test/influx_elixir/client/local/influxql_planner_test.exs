defmodule InfluxElixir.Client.Local.InfluxQLPlannerTest do
  @moduledoc """
  What the InfluxQL planner of `Client.Local` refuses by name, through the
  public `query_influxql/3`.

  These are the questions where the double cannot tell the engine's answer
  from its neighbours and so refuses with its own wording
  (`Client.Local: unsupported InfluxQL ...`). The engine has no such answer, so
  the contract in `InfluxElixir.Contract.InfluxQLFluxLP`, which runs against both
  the engine and the double, cannot pin it: this is the one place that does.

  The helpers behind the planner (`InfluxQLArithmetic`, `InfluxQLTime`,
  `InfluxQLNames`, `InfluxQLLiteral`) are not tested here: every one of them is
  reached by a query, so the contract pins what they answer, as the engine does,
  and a test of them directly would only restate it and break on a refactor.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

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
    test "aggregates that end up with the same name", %{conn: conn} do
      # The engine words each aggregate as its plan prints it, which the double does not.
      for statement <- [
            "SELECT first(i) AS time, last(i) AS time FROM m",
            "SELECT mean(i) AS k_1, mean(j) AS k FROM m GROUP BY k"
          ] do
        assert refused(conn, statement) ===
                 "Client.Local: unsupported InfluxQL " <>
                   "(select items that end up with the same name)"
      end
    end

    test "columns that end up with the same name are the engine's planning error",
         %{conn: conn} do
      assert refused(conn, "SELECT i AS time, j AS time FROM m") ===
               ~s|Error during planning: Projections require unique expression names but the | <>
                 ~s|expression "m.i AS time_1" at position 1 and "m.j AS time_1" at | <>
                 ~s|position 2 have the same name. Consider aliasing ("AS") one of them.|
    end

    test "* beside other items, a renamed time beside an aggregate", %{conn: conn} do
      # `* , i` is answered (the wildcard is written out, `i` and `i_1`); beside an aggregate
      # the double does not tell the engine's answer from its neighbours.
      statement = "SELECT *, max(i) FROM m"

      assert refused(conn, statement) ===
               "Client.Local: unsupported InfluxQL (* beside other select items): #{statement}"

      statement = "SELECT max(i), time AS x FROM m"

      assert refused(conn, statement) ===
               "Client.Local: unsupported InfluxQL " <>
                 "(a renamed time column beside an aggregate): #{statement}"
    end

    test "a tag called time in GROUP BY, once there are points to group", %{conn: conn} do
      for group <- ["\"time\"", "time::tag", "k, \"time\""] do
        statement = "SELECT i FROM m GROUP BY #{group}"

        assert refused(conn, statement) ===
                 "Client.Local: unsupported InfluxQL (GROUP BY a tag named time)"
      end
    end

    test "a quoted time in a form the double cannot tell from the engine's", %{conn: conn} do
      for content <- [" 1970-01-01", "1970-1-1", "24-01-01T00:00:00 +0000", "-0001-01-01"] do
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

    test "a time compared with an expression of a shape the double does not fold", %{conn: conn} do
      for {where, why} <- [
            {"time > '2024-01-01T00:00:00Z' - '2023-01-01T00:00:00Z' * 2",
             "a time compared with an expression"},
            {"time > 5s - '2024-01-01T00:00:00Z'", "an instant and a length combined that way"},
            {"time > 1 + now()", "an integer added to now()"},
            {"time > '2024-01-01T00:00:00Z' + 'x'",
             "a quoted time in an expression that the double cannot read"}
          ] do
        assert refused(conn, "SELECT i FROM m WHERE #{where}") ===
                 "Client.Local: unsupported InfluxQL (#{why})"
      end
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

      why = "unsupported InfluxQL (a signed argument that is no number): mean(-i)"
      assert refused(conn, statement) === "Client.Local: " <> why <> ": " <> statement
    end

    test "a bind parameter in a condition, bound or not", %{conn: conn} do
      # The engine plans `$name` as an operand and says the first one has no value (or binds
      # it); its planning errors before and after that are not verified, so the double
      # refuses, `params:` or not. A parse error anywhere in the statement still comes first.
      for where <- ["i > $1", "i >$a", "k = $h", "i > 1 AND $n", "abs($a) > 1", "i > $\"a b\""] do
        for opts <- [[database: "planner"], [database: "planner", params: %{"a" => 1}]] do
          assert {:error, %{status: 400, body: body}} =
                   Local.query_influxql(conn, "SELECT i FROM m WHERE " <> where, opts)

          assert body === "Client.Local: unsupported InfluxQL (a bind parameter in a condition)"
        end
      end

      assert refused(conn, "SELECT i FROM m WHERE i > $a.b") ===
               "error in InfluxQL statement: parsing error: invalid InfluxQL statement at " <>
                 ~s|pos 28. Parsing Error: Nom(".b", Tag)|
    end

    test "a sign that ends a condition after a closing parenthesis", %{conn: conn} do
      for where <- ["(i > 1) +", "i > ((1 + 2) +"] do
        assert refused(conn, "SELECT i FROM m WHERE " <> where) ===
                 "Client.Local: unsupported InfluxQL WHERE: +"
      end
    end

    test "a carriage return before the parenthesis of fill or tz inside a condition",
         %{conn: conn} do
      for where <- ["i > 1 tz\r('UTC')", "i > fill\r(null)"] do
        statement = "SELECT i FROM m WHERE " <> where

        assert refused(conn, statement) ===
                 "Client.Local: unsupported InfluxQL " <>
                   "(a carriage return after fill, tz or a fill() option): #{statement}"
      end
    end
  end
end
