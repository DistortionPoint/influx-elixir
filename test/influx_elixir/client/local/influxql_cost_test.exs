defmodule InfluxElixir.Client.Local.InfluxQLCostTest do
  @moduledoc """
  What an InfluxQL statement costs `Client.Local` to answer: the work must grow linearly with
  the length of its condition, and not with the square of it. The answers themselves are
  pinned by the InfluxQL contracts.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["iql_cost_db"])
    {:ok, :written} = Local.write(conn, "untagged v=1i 1", database: "iql_cost_db")
    {:ok, conn: conn}
  end

  # The reductions of a statement, the least of three runs (the first call of a function loads
  # the module it lives in, which costs reductions the later calls do not).
  defp cost(conn, statement, answer) do
    1..3
    |> Enum.map(fn _run ->
      {:reductions, before} = Process.info(self(), :reductions)
      answered = Local.query_influxql(conn, statement, database: "iql_cost_db")
      {:reductions, after_} = Process.info(self(), :reductions)
      assert answered === answer
      after_ - before
    end)
    |> Enum.min()
  end

  describe "SHOW TAG KEYS WHERE over a measurement with no tag" do
    # Every `time` was checked against its neighbours by indexing the list of tokens, a walk
    # of the list for each `time`. A condition four times as long costs about four times as
    # much when the work is a line in its length, sixteen when it is a square; the bounds sit
    # around four. The chain stays under the depth the double refuses (8020 units, 14 a link).
    test "costs a line in the length of its condition", %{conn: conn} do
      statement = fn count ->
        "SHOW TAG KEYS FROM untagged WHERE " <>
          Enum.map_join(1..count, " AND ", fn _position -> "time > 0" end)
      end

      # The engine's answer to a SHOW TAG KEYS whose measurement has no tag.
      answer =
        {:error,
         %{
           status: 400,
           body:
             "Error during planning: Aggregate requires at least one grouping or aggregate " <>
               "expression. Aggregate without grouping expressions nor aggregate expressions " <>
               "is logically equivalent to, but less efficient than, VALUES producing single " <>
               "row. Please use VALUES instead."
         }}

      short = cost(conn, statement.(125), answer)
      long = cost(conn, statement.(500), answer)
      ratio = long / short
      assert ratio < 5.0, "125 links cost #{short} reductions, 500 cost #{long}"
      assert ratio > 2.5, "125 links cost #{short} reductions, 500 cost #{long}"
    end
  end
end
