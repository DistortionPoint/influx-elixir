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

  test "multi-column top(time, N) and bottom(time, N) order DateTime values chronologically" do
    {:ok, conn} = Local.start(databases: ["t_db"], profile: :v3_core)

    # 2024-01-25 has day=25 while 2024-02-01 has day=1; structural map comparison on DateTime
    # compares :day before :month and would rank 2024-01-25 ahead of 2024-02-01.
    t1 = DateTime.to_unix(~U[2024-01-25 00:00:00Z], :nanosecond)
    t2 = DateTime.to_unix(~U[2024-02-01 00:00:00Z], :nanosecond)
    t3 = DateTime.to_unix(~U[2024-03-10 00:00:00Z], :nanosecond)

    lines =
      Enum.join(
        [
          "events,host=a v=10 #{t1}",
          "events,host=a v=20 #{t2}",
          "events,host=b v=30 #{t3}"
        ],
        "\n"
      )

    assert {:ok, :written} = Local.write(conn, lines, database: "t_db", precision: :nanosecond)

    assert {:ok, top_rows} =
             Local.query_influxql(conn, "SELECT top(time, 2), v FROM events", database: "t_db")

    assert Enum.map(top_rows, & &1["v"]) == [20.0, 30.0]

    assert {:ok, bottom_rows} =
             Local.query_influxql(conn, "SELECT bottom(time, 2), v FROM events", database: "t_db")

    assert Enum.map(bottom_rows, & &1["v"]) == [10.0, 20.0]

    assert {:ok, top_by_host} =
             Local.query_influxql(conn, "SELECT top(time, host, 2), v FROM events",
               database: "t_db"
             )

    assert Enum.map(top_by_host, &{&1["host"], &1["v"]}) == [{"a", 20.0}, {"b", 30.0}]

    assert {:ok, bottom_by_host} =
             Local.query_influxql(conn, "SELECT bottom(time, host, 2), v FROM events",
               database: "t_db"
             )

    assert Enum.map(bottom_by_host, &{&1["host"], &1["v"]}) == [{"a", 10.0}, {"b", 30.0}]
  end

  test "wildcard function expansion handles field names containing quotes or backslashes" do
    {:ok, conn} = Local.start(databases: ["t_db"], profile: :v3_core)

    lp = ~s(weird,host=a q"f=-2.5,b\\\\f=-4.0 1700000000000000000)
    assert {:ok, :written} = Local.write(conn, lp, database: "t_db", precision: :nanosecond)

    assert {:ok, [row]} =
             Local.query_influxql(conn, "SELECT abs(*) FROM weird", database: "t_db")

    assert row["abs_b\\f"] == 4.0
    assert row["abs_q\"f"] == 2.5
  end
end
