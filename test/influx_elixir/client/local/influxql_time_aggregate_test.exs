defmodule InfluxElixir.Client.Local.InfluxQLTimeAggregateTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Client.Local.InfluxQLBuckets

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
        {"SELECT percentile(time, 50), max(usage) FROM cpu",
         "percentile() of time beside a field"},
        {"SELECT integral(time), max(usage) FROM cpu", "integral() of time beside a field"},
        {"SELECT mode(time), max(usage) FROM cpu", "mode() of values equally often there"}
      ] do
    test "#{statement} is refused by name", %{conn: conn} do
      assert Local.query_influxql(conn, unquote(statement), database: "t_db") ===
               {:error,
                %{status: 400, body: "Client.Local: unsupported InfluxQL (#{unquote(reason)})"}}
    end
  end

  test "InfluxQLBuckets.max_rows/0 falls back to 2_000_000 for non-positive or non-integer config" do
    try do
      for invalid <- [nil, 0, -10, :invalid, "2000000"] do
        Application.put_env(:influx_elixir, :local_influxql_max_rows, invalid)
        assert InfluxQLBuckets.max_rows() == 2_000_000
      end

      Application.put_env(:influx_elixir, :local_influxql_max_rows, 2_500_000)
      assert InfluxQLBuckets.max_rows() == 2_500_000
    after
      Application.delete_env(:influx_elixir, :local_influxql_max_rows)
    end
  end
end
