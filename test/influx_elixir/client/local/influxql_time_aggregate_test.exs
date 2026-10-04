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
end
