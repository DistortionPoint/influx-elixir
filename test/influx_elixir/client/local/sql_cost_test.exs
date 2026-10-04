defmodule InfluxElixir.Client.Local.SqlCostTest do
  @moduledoc """
  What a SQL text costs `Client.Local` to read, and what it never does to a text it cannot:
  the work of a query must not grow with the number of times a name is written in it
  (a `HAVING` alias), nor faster than linearly with the length of an expression it nests (a long
  sum), and a name or a pattern too long for the regular expressions the double matches with is a
  refusal by name, not an exception. The answers themselves are pinned by the SQL contracts.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["cost_db"])

    lines =
      Enum.map_join(1..1500, "\n", fn i ->
        "main,host=h#{rem(i, 5)} n=#{i}i,x=#{i}.5 #{1_700_000_000_000_000_000 + i * 1_000_000_000}"
      end)

    {:ok, :written} = Local.write(conn, lines, database: "cost_db", precision: :nanosecond)
    {:ok, conn: conn}
  end

  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    answer = fun.()
    {:reductions, after_} = Process.info(self(), :reductions)
    {after_ - before, answer}
  end

  describe "a HAVING that names a select alias" do
    test "costs the table's columns once, however many times it names it", %{conn: conn} do
      having = fn count ->
        "SELECT host, count(*) AS c FROM main GROUP BY host HAVING " <>
          Enum.join(List.duplicate("c > 0", count), " AND ") <> " ORDER BY host"
      end

      {_warm, {:ok, rows}} =
        reductions(fn -> Local.query_sql(conn, having.(1), database: "cost_db") end)

      assert length(rows) === 5

      {one, _answer} =
        reductions(fn -> Local.query_sql(conn, having.(1), database: "cost_db") end)

      {seven, {:ok, kept}} =
        reductions(fn -> Local.query_sql(conn, having.(7), database: "cost_db") end)

      assert length(kept) === 5
      assert seven < one * 1.5, "7 references cost #{seven} reductions, 1 cost #{one}"
    end
  end

  describe "an expression of many operators" do
    test "is typed once per operator, not once per operator below it", %{conn: conn} do
      sum = fn terms ->
        Local.query_sql(conn, "select #{Enum.join(List.duplicate("1", terms), "+")} as r",
          database: "cost_db"
        )
      end

      {short, {:ok, [%{"r" => 300}]}} = reductions(fn -> sum.(300) end)
      {long, answer} = reductions(fn -> sum.(900) end)

      assert answer === {:ok, [%{"r" => 900}]}
      # Three times the terms: about three times the work when each operator is
      # typed once, about nine times when every subtree is typed again.
      assert long < short * 5, "900 terms cost #{long} reductions, 300 cost #{short}"
    end
  end

  describe "a name or a pattern past the size of the regular expression that matches it" do
    test "a table name is a refusal by name", %{conn: conn} do
      name = String.duplicate("a", 4100)

      for sql <- [
            "SELECT 1 FROM #{name}",
            ~s(SELECT 1 FROM "#{name}"),
            "SELECT #{name}.n FROM #{name}"
          ] do
        assert {:error, %{status: 400, body: "Client.Local: " <> _reason}} =
                 Local.query_sql(conn, sql, database: "cost_db")
      end
    end

    test "a LIKE pattern is a refusal by name", %{conn: conn} do
      pattern = String.duplicate("a", 70_000)

      for sql <- [
            "SELECT v FROM main WHERE host LIKE '#{pattern}'",
            "SELECT host LIKE '#{pattern}' AS r FROM main"
          ] do
        assert {:error, %{status: 400, body: "Client.Local: " <> _reason}} =
                 Local.query_sql(conn, sql, database: "cost_db")
      end
    end

    test "a LIKE pattern bound as a parameter is a refusal by name", %{conn: conn} do
      assert {:error, %{status: 400, body: "Client.Local: " <> _reason}} =
               Local.query_sql(conn, "SELECT n FROM main WHERE host LIKE $p",
                 database: "cost_db",
                 params: %{"p" => String.duplicate("a", 70_000)}
               )
    end
  end
end
