defmodule InfluxElixir.Client.Local.SQLDmlCostTest do
  @moduledoc """
  What an `INSERT`, an `UPDATE` or a `DELETE` costs `Client.Local` to plan: the work of a
  statement must grow linearly with the length of what it holds (a chain of `||`, a nest of calls,
  a list of rows), and not with the square of it (a chain of `n` terms typed by typing every
  prefix of it). The answers themselves are pinned by the SQL contracts.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["dml_cost_db"])

    lines =
      Enum.map_join(1..5, "\n", fn i ->
        ~s|main,host=h#{i},region=r#{i} n=#{i}i,x=#{i}.5,s="s#{i}",b=true,v=#{i}i #{1_700_000_000_000_000_000 + i}|
      end)

    {:ok, :written} = Local.write(conn, lines, database: "dml_cost_db", precision: :nanosecond)
    {:ok, conn: conn}
  end

  # The reductions of a statement, the least of three runs (the first call of a function loads
  # the module it lives in, which costs reductions the later calls do not).
  defp cost(conn, sql) do
    1..3
    |> Enum.map(fn _run ->
      {:reductions, before} = Process.info(self(), :reductions)
      answer = Local.query_sql(conn, sql, database: "dml_cost_db")
      {:reductions, after_} = Process.info(self(), :reductions)
      assert {:error, %{status: 400}} = answer
      after_ - before
    end)
    |> Enum.min()
  end

  defp chain(term, count), do: Enum.map_join(1..count, " || ", fn _position -> term end)

  defp nest(name, count),
    do: Enum.reduce(1..count, "1", fn _position, inner -> "#{name}(#{inner}, 1)" end)

  # A statement of four times the length costs about four times as much when the work is a line
  # in the length, sixteen when it is a square. The bound sits between them, with room for the
  # fixed cost of the statement and for the noise of the reductions count.
  defp assert_linear(conn, statement) do
    short = cost(conn, statement.(100))
    long = cost(conn, statement.(400))
    assert long / short < 7.0, "100 terms cost #{short} reductions, 400 cost #{long}"
  end

  describe "a chain of ||" do
    test "in the values of an INSERT is typed once per link", %{conn: conn} do
      assert_linear(conn, &"INSERT INTO main (s) VALUES (#{chain("'a'", &1)})")
    end

    test "in an UPDATE is typed once per link", %{conn: conn} do
      assert_linear(conn, &"UPDATE main SET s = #{chain("s", &1)}")
    end

    test "in the WHERE of a DELETE is typed once per link", %{conn: conn} do
      assert_linear(conn, &"DELETE FROM main WHERE (#{chain("s", &1)}) = 'a'")
    end

    test "in the select of an INSERT is typed once per link", %{conn: conn} do
      assert_linear(conn, &"INSERT INTO main (s) SELECT #{chain("s", &1)} FROM main")
    end

    test "that a number breaks is typed once per link too", %{conn: conn} do
      assert_linear(conn, &"INSERT INTO main (s) VALUES (#{chain("'a'", &1)} || 1 || 2)")
    end
  end

  describe "a nest of calls" do
    test "in the values of an INSERT costs a line in its depth", %{conn: conn} do
      short = cost(conn, "INSERT INTO main (v) VALUES (#{nest("coalesce", 50)})")
      long = cost(conn, "INSERT INTO main (v) VALUES (#{nest("coalesce", 200)})")
      assert long / short < 7.0, "50 deep cost #{short} reductions, 200 deep cost #{long}"
    end
  end

  describe "a list of rows" do
    test "costs a line in the rows", %{conn: conn} do
      row = "(true, 'h', 1, 'r', 'a', 2, 1.5, 1700000000000000000)"

      statement = fn rows ->
        "INSERT INTO main (b, host, n, region, s, v, x, time) VALUES " <>
          Enum.map_join(1..rows, ", ", fn _position -> row end)
      end

      short = cost(conn, statement.(100))
      long = cost(conn, statement.(400))
      assert long / short < 6.0, "100 rows cost #{short} reductions, 400 cost #{long}"
    end
  end
end
