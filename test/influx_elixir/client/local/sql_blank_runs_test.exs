defmodule InfluxElixir.Client.Local.SQLBlankRunsTest do
  @moduledoc """
  A long run of blanks inside a clause is read in work that grows with its length. The patterns
  that cut a statement into its clauses (`... (.+?)\\s+FROM`, `WHERE\\s+(.+?)(?:\\s+GROUP ...)`,
  `(.+?)\\s+AS ...`) tried every blank of the run as the start of the match and each time read the
  rest of the run: a run four times as long cost sixteen times as much (64,000 blanks took
  seventeen seconds).

  The work is counted in reductions, not time, so a slow or busy machine does not change it: a
  run four times as long costs about four times as much (measured 3.89 to 4.01), sixteen when it
  is a square. Each statement still answers its rows.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  @database "blanks_db"

  setup do
    {:ok, conn} = Local.start(databases: [@database])

    lines =
      for i <- 1..4, do: "main,host=h#{rem(i, 2)} n=#{i}i,v=#{i * 10}i #{i * 1_000_000_000}"

    {:ok, :written} =
      Local.write(conn, Enum.join(lines, "\n"), database: @database, precision: :nanosecond)

    {:ok, conn: conn}
  end

  # `@@` is where the run of blanks stands.
  for {name, sql, rows} <- [
        {"a select item without FROM", "SELECT 1@@+ 1 AS x", [%{"x" => 2}]},
        {"a select item", "SELECT n@@+ 1 AS x FROM main",
         [%{"x" => 2}, %{"x" => 3}, %{"x" => 4}, %{"x" => 5}]},
        {"a WHERE comparison", "SELECT n FROM main WHERE n@@> 1",
         [%{"n" => 2}, %{"n" => 3}, %{"n" => 4}]},
        {"a WHERE IN list", "SELECT n FROM main WHERE n@@IN (1, 2)", [%{"n" => 1}, %{"n" => 2}]},
        {"a WHERE BETWEEN", "SELECT n FROM main WHERE n@@BETWEEN 1 AND 2",
         [%{"n" => 1}, %{"n" => 2}]},
        {"an ORDER BY", "SELECT n FROM main ORDER BY n@@DESC",
         [%{"n" => 4}, %{"n" => 3}, %{"n" => 2}, %{"n" => 1}]},
        {"a GROUP BY", "SELECT count(*) AS c FROM main GROUP BY host@@ORDER BY c",
         [%{"c" => 2}, %{"c" => 2}]}
      ] do
    test "a run of blanks in #{name} costs a line in its length", %{conn: conn} do
      sql = fn blanks -> String.replace(unquote(sql), "@@", String.duplicate(" ", blanks)) end

      short = cost(conn, sql.(16_000), unquote(Macro.escape(rows)))
      long = cost(conn, sql.(64_000), unquote(Macro.escape(rows)))
      ratio = long / short

      assert ratio < 6.0, "16,000 blanks cost #{short} reductions, 64,000 cost #{long}"
      assert ratio > 2.5, "16,000 blanks cost #{short} reductions, 64,000 cost #{long}"
    end
  end

  # The reductions of a query, the least of three runs (the first call of a function loads the
  # module it lives in, which costs reductions the later calls do not), asserting its rows.
  defp cost(conn, sql, rows) do
    1..3
    |> Enum.map(fn _run ->
      {:reductions, before} = Process.info(self(), :reductions)
      answer = Local.query_sql(conn, sql, database: @database)
      {:reductions, after_} = Process.info(self(), :reductions)
      assert answer === {:ok, rows}
      after_ - before
    end)
    |> Enum.min()
  end
end
