defmodule InfluxElixir.Client.Local.InfluxQLTimeAggregateTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  # Aggregates of `time` beside a field: `percentile()`, `integral()` and `mode()` word their
  # outcome at length (or by the engine's choice among equals), so the double refuses them
  # by name; the others are cases of the contract.

  setup do
    {:ok, conn} = Local.start(databases: ["t_db"], profile: :v3_core)

    lines =
      "cpu,host=a usage=1.5 1700000000000000000\ncpu,host=b usage=2.5 1700000060000000000"

    {:ok, :written} = Local.write(conn, lines, database: "t_db", precision: :nanosecond)
    {:ok, conn: conn}
  end

  for {statement, reason} <- [
        {"SELECT percentile(time, 50), max(usage) FROM cpu", "percentile() of time"},
        {"SELECT integral(time), max(usage) FROM cpu", "integral() of time"},
        {"SELECT mode(time), max(usage) FROM cpu", "mode() of values equally often there"}
      ] do
    test "#{statement} is refused by name", %{conn: conn} do
      assert {:error, %{status: 400, body: "Client.Local: " <> body}} =
               Local.query_influxql(conn, unquote(statement), database: "t_db")

      assert body =~ unquote(reason)
    end
  end

  test "a time aggregate alone answers nothing, as an aggregate of a tag does", %{conn: conn} do
    for function <- ~w(min max count first last mean sum median spread stddev mode) do
      assert {:ok, []} =
               Local.query_influxql(conn, "SELECT #{function}(time) FROM cpu", database: "t_db")
    end
  end

  test "min and max of time beside a field are the times of the points", %{conn: conn} do
    assert {:ok, [row]} =
             Local.query_influxql(conn, "SELECT max(time), min(usage) FROM cpu", database: "t_db")

    assert row["max"] == ~U[2023-11-14 22:14:20.000000Z]
    assert row["min"] == 1.5
  end
end
