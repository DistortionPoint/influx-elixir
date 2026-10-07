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

  # The refusal each kind of statement ends in: the stage measured is the planning of the
  # statement, up to the engine's refusal of DML, so a statement refused earlier (a parse or a
  # schema error) cannot pass for cheap.
  @insert_refusal "Error during planning: DML not supported: Insert Into"
  @update_refusal "Error during planning: DML not supported: Update"
  @delete_refusal "Error during planning: DML not supported: Delete"

  # The reductions of a statement, the least of three runs (the first call of a function loads
  # the module it lives in, which costs reductions the later calls do not).
  defp cost(conn, sql, refusal) do
    1..3
    |> Enum.map(fn _run ->
      {:reductions, before} = Process.info(self(), :reductions)
      answer = Local.query_sql(conn, sql, database: "dml_cost_db")
      {:reductions, after_} = Process.info(self(), :reductions)
      assert answer === {:error, %{status: 400, body: refusal}}
      after_ - before
    end)
    |> Enum.min()
  end

  defp chain(term, count), do: Enum.map_join(1..count, " || ", fn _position -> term end)

  defp nest(name, count),
    do: Enum.reduce(1..count, "1", fn _position, inner -> "#{name}(#{inner}, 1)" end)

  # A statement of four times the size costs about four times as much when the work is a line
  # in the size, sixteen when it is a square. The bounds sit around four: above it a square
  # (an UPDATE of 1600 terms cost 7.3 times one of 400 when the tokenizer read each word
  # with a regex over the rest of the text), and below 2.5 a statement the double refused
  # early, which would otherwise pass for cheap.
  defp assert_linear(conn, statement, refusal, opts \\ []) do
    {small, large} = Keyword.get(opts, :sizes, {400, 1600})
    upper = Keyword.get(opts, :upper, 5.0)
    short = cost(conn, statement.(small), refusal)
    long = cost(conn, statement.(large), refusal)
    ratio = long / short
    assert ratio < upper, "#{small} cost #{short} reductions, #{large} cost #{long}"
    assert ratio > 2.5, "#{small} cost #{short} reductions, #{large} cost #{long}"
  end

  describe "a chain of ||" do
    test "in the values of an INSERT is typed once per link", %{conn: conn} do
      assert_linear(conn, &"INSERT INTO main (s) VALUES (#{chain("'a'", &1)})", @insert_refusal)
    end

    test "in an UPDATE is typed once per link", %{conn: conn} do
      assert_linear(conn, &"UPDATE main SET s = #{chain("s", &1)}", @update_refusal)
    end

    test "in the WHERE of a DELETE is typed once per link", %{conn: conn} do
      assert_linear(conn, &"DELETE FROM main WHERE (#{chain("s", &1)}) = 'a'", @delete_refusal)
    end

    test "in the select of an INSERT is typed once per link", %{conn: conn} do
      assert_linear(
        conn,
        &"INSERT INTO main (s) SELECT #{chain("s", &1)} FROM main",
        @insert_refusal
      )
    end

    test "that a number breaks is typed once per link too", %{conn: conn} do
      assert_linear(
        conn,
        &"INSERT INTO main (s) VALUES (#{chain("'a'", &1)} || 1 || 2)",
        @insert_refusal
      )
    end
  end

  describe "a nest of calls" do
    # Measured: 50 -> 200 costs about 4.3 times as much (it was 6), and each doubling
    # from 100 to 800 a little more than the last (2.0, 2.1, 2.2, 2.4; it was 2.6, 2.9, 3.3).
    # The call typed the kinds of its arguments at every level; it does so only beside no literal.
    test "in the values of an INSERT costs a line in its depth", %{conn: conn} do
      assert_linear(
        conn,
        &"INSERT INTO main (v) VALUES (#{nest("coalesce", &1)})",
        @insert_refusal,
        sizes: {50, 200},
        upper: 5.0
      )
    end
  end

  describe "a list of rows" do
    test "costs a line in the rows", %{conn: conn} do
      row = "(true, 'h', 1, 'r', 'a', 2, 1.5, 1700000000000000000)"

      statement = fn rows ->
        "INSERT INTO main (b, host, n, region, s, v, x, time) VALUES " <>
          Enum.map_join(1..rows, ", ", fn _position -> row end)
      end

      assert_linear(conn, statement, @insert_refusal, sizes: {100, 400})
    end
  end
end
