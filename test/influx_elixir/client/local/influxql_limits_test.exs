defmodule InfluxElixir.Client.Local.InfluxQLLimitsTest do
  @moduledoc """
  Statements that are long rather than odd, run in a process whose heap is capped at five
  million words (about 40 MB): each is answered, or refused by name, and none is killed by
  the cap. The answers of the shapes the engine also answers are pinned by the planner
  contract (`InfluxElixir.Contract.InfluxQLNestedCases.deep_conditions/0`); the engine takes
  seconds to plan a list of a few thousand sources and stops answering past a few thousand
  calls, so the refusals below are not pinned against it.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  @database "limits_db"

  setup do
    {:ok, conn} = Local.start(databases: [@database])

    lines =
      for(i <- 1..9, do: "nine v=#{i}i #{i * 1_000_000_000}") ++
        for(i <- 1..5, do: "five_a v=#{i}i #{i * 1_000_000_000}") ++
        for(i <- 1..5, do: "five_b v=#{i}i #{i * 1_000_000_000}") ++
        for(i <- 1..5, do: "five_c v=#{i}i #{i * 1_000_000_000}") ++
        [
          "flag ok=true,v=1i 1000000000",
          "flag ok=false,v=2i 2000000000",
          "flag ok=false,v=3i 3000000000"
        ]

    {:ok, :written} = Local.write(conn, Enum.join(lines, "\n"), database: @database)
    {:ok, conn: conn}
  end

  # The answer of a statement in a process capped at five million words: `{:killed, reason}`
  # when the cap kills it.
  defp capped(conn, statement) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: 5_000_000, kill: true, error_logger: false})
        send(parent, {ref, Local.query_influxql(conn, statement, database: @database)})
      end)

    receive do
      {^ref, answer} ->
        Process.demonitor(monitor, [:flush])
        answer

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:killed, reason}
    end
  end

  defp sources(name, count), do: "SELECT v FROM " <> Enum.join(List.duplicate(name, count), ", ")

  describe "the list of sources of FROM" do
    test "a list of 2,500 sources is read, one of 2,501 is refused by name", %{conn: conn} do
      assert {:ok, rows} = capped(conn, sources("five_a", 2_500))
      assert length(rows) === 12_500

      assert {:error, %{status: 400, body: body}} = capped(conn, sources("five_a", 2_501))
      assert body =~ "Client.Local: unsupported InfluxQL (more than 2500 sources in FROM)"
    end

    test "a list of forty thousand sources is refused before anything is read", %{conn: conn} do
      assert {:error, %{status: 400, body: body}} = capped(conn, sources("nine", 40_000))
      assert body =~ "more than 2500 sources in FROM"
    end

    test "a statement of more than 256 KiB is refused by name, unread", %{conn: conn} do
      assert {:error, %{status: 400, body: body}} = capped(conn, sources("five_a", 100_001))
      assert body =~ "Client.Local: unsupported InfluxQL (a statement of more than 262144 bytes)"
    end
  end

  describe "a measurement named more than once" do
    test "the points it repeats are counted over every measurement the sources stand for",
         %{conn: conn} do
      assert {:ok, rows} = capped(conn, sources("nine", 2_222))
      assert length(rows) === 19_998

      assert {:error, %{status: 400, body: body}} = capped(conn, sources("nine", 2_223))
      assert body =~ "over more than 20000 points"

      # Three measurements of five points, each repeated 1,500 times: 7,500 points each is
      # under the bound, the 22,500 together are not.
      regex = "/^five_/"
      statement = "SELECT v FROM " <> Enum.join(List.duplicate(regex, 1_500), ", ")
      assert {:error, %{status: 400, body: body}} = capped(conn, statement)
      assert body =~ "over more than 20000 points"

      two = "SELECT v FROM " <> Enum.join(List.duplicate("five_a, five_b", 1_000), ", ")
      assert {:ok, rows} = capped(conn, two)
      assert length(rows) === 10_000
    end
  end

  describe "conditions" do
    test "a condition in parentheses nested 800 deep is answered", %{conn: conn} do
      nested =
        Enum.reduce(1..800, "ok = false", fn level, inner ->
          if rem(level, 2) == 0,
            do: "ok = (w > 1 AND " <> inner <> ")",
            else: "ok = (v > 0 AND " <> inner <> ")"
        end)

      # Every even depth answers as depth 2 does on the engine (verified at depths 2, 4, 6
      # and 40): the two points whose `ok` is false.
      assert {:ok, rows} = capped(conn, "SELECT ok FROM flag WHERE " <> nested)

      assert Enum.map(rows, &{&1["ok"], DateTime.to_unix(&1["time"])}) === [
               {false, 2},
               {false, 3}
             ]
    end

    test "a sum of three thousand calls is answered", %{conn: conn} do
      calls = Enum.join(List.duplicate("abs(1)", 3_000), " + ")
      assert {:ok, rows} = capped(conn, "SELECT v FROM nine WHERE " <> calls <> " > 0")
      assert length(rows) === 9
    end
  end
end
