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

    write_rows(conn, 1500)
    {:ok, conn: conn}
  end

  defp write_rows(conn, count) do
    lines =
      Enum.map_join(1..count, "\n", fn i ->
        "main,host=h#{rem(i, 5)} n=#{i}i,x=#{i}.5 #{1_700_000_000_000_000_000 + i * 1_000_000_000}"
      end)

    {:ok, :written} = Local.write(conn, lines, database: "cost_db", precision: :nanosecond)
  end

  # The reductions of a grouped query whose HAVING names its select alias `count` times: the
  # least of three runs. There is no cache to fill: the first call of a function loads the
  # module it lives in, which costs reductions the later calls do not (the work of a run
  # that finds the modules loaded does not vary).
  defp having_cost(conn, count) do
    sql =
      "SELECT host, count(*) AS c FROM main GROUP BY host HAVING " <>
        Enum.join(List.duplicate("c > 0", count), " AND ") <> " ORDER BY host"

    1..3
    |> Enum.map(fn _run ->
      {reductions, {:ok, kept}} =
        reductions(fn -> Local.query_sql(conn, sql, database: "cost_db") end)

      assert length(kept) === 5
      reductions
    end)
    |> Enum.min()
  end

  # What one more reference costs: the cost of `count` references less the cost of one,
  # over the `count - 1` the first lacks. The modules a connection's first query loads
  # are loaded before anything is measured.
  defp per_reference_cost(conn, count) do
    having_cost(conn, 1)
    (having_cost(conn, count) - having_cost(conn, 1)) / (count - 1)
  end

  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    answer = fun.()
    {:reductions, after_} = Process.info(self(), :reductions)
    {after_ - before, answer}
  end

  describe "a HAVING that names a select alias" do
    # Every reference costs its own condition to evaluate, so the cost is a line in the
    # number of references and never flat. What tells a reference from a re-read of the
    # table's columns is what the line's slope depends on: a reference evaluates a
    # condition over the groups (five here, whatever the table holds), a re-read walks
    # the rows. The same query over 1500 and over 6000 rows must therefore not add more per
    # reference on the larger table (measured 0.8 times: the same condition over the same five
    # groups, and the larger table's fixed cost is not in the difference), where a re-read adds
    # about four times as much (measured 3.6 times with the columns read once more per
    # reference). The bound sits between them, with room for the noise of the reductions count.
    test "costs no more per reference over a table four times as large", %{conn: conn} do
      small = per_reference_cost(conn, 7)

      {:ok, big_conn} = Local.start(databases: ["cost_db"])
      write_rows(big_conn, 6000)
      big = per_reference_cost(big_conn, 7)
      assert small > 0

      assert big <= small * 1.5,
             "a reference costs #{small} reductions over 1500 rows and #{big} over 6000"
    end

    test "the cost is a line in the references", %{conn: conn} do
      cost = fn count -> having_cost(conn, count) end

      # Warm the caches the first query of a connection fills.
      cost.(1)

      one = cost.(1)
      seven = cost.(7)
      fourteen = cost.(14)

      # The 7 references from 7 to 14 cost no more than 1.3 times the 6 from 1 to 7
      # (measured 1.10; the 7 over 6 references alone is 1.17, so 1.3 leaves room for the
      # noise of the reductions count and for nothing else).
      assert fourteen - seven <= (seven - one) * 1.3,
             "references 1/7/14 cost #{one}/#{seven}/#{fourteen} reductions"
    end
  end

  describe "an expression of many operators" do
    test "is typed once per operator, not once per operator below it", %{conn: conn} do
      sum = fn terms ->
        Local.query_sql(conn, "select #{Enum.join(List.duplicate("1", terms), "+")} as r",
          database: "cost_db"
        )
      end

      # Run both shapes once before measuring: the first call of a function loads its module,
      # which would be counted in `short` and in nothing else.
      assert {:ok, [%{"r" => 300}]} = sum.(300)
      assert {:ok, [%{"r" => 900}]} = sum.(900)

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
