defmodule InfluxElixir.Client.Local.InfluxQLLimitsTest do
  @moduledoc """
  Statements that are long rather than odd, run in a process whose heap is capped at five
  million words (about 40 MB): each is answered, or refused by name, and none is killed by
  the cap. The answers of the shapes the engine also answers are pinned by the planner
  contract (`InfluxElixir.Contract.InfluxQLNestedCases.deep_conditions/0`); the engine takes
  seconds to plan a list of a few thousand sources, so the refusals of those are not pinned
  against it. A condition nested or chained deeper than the engine answers is refused by name
  before anything reads it (`InfluxElixir.Client.Local.InfluxQLDepth`: past the depths measured
  on 3.10.1 the engine overflows its stack and the server dies).
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

  @sources_refusal "Client.Local: unsupported InfluxQL (more than 2500 sources in FROM)"
  @points_refusal "Client.Local: unsupported InfluxQL (a measurement named more than once in " <>
                    "FROM over more than 20000 points)"

  defp refused(body), do: {:error, %{status: 400, body: body}}

  describe "the list of sources of FROM" do
    test "a list of 2,500 sources is read, one of 2,501 is refused by name", %{conn: conn} do
      assert {:ok, rows} = capped(conn, sources("five_a", 2_500))
      assert length(rows) === 12_500

      statement = sources("five_a", 2_501)
      assert capped(conn, statement) === refused(@sources_refusal <> ": " <> statement)
    end

    test "a list of forty thousand sources is refused before anything is read", %{conn: conn} do
      statement = sources("nine", 40_000)
      assert capped(conn, statement) === refused(@sources_refusal <> ": " <> statement)
    end

    test "a statement of more than 256 KiB is refused by name, unread", %{conn: conn} do
      assert capped(conn, sources("five_a", 100_001)) ===
               refused(
                 "Client.Local: unsupported InfluxQL (a statement of more than 262144 bytes)"
               )
    end
  end

  describe "a measurement named more than once" do
    test "the points it repeats are counted over every measurement the sources stand for",
         %{conn: conn} do
      assert {:ok, rows} = capped(conn, sources("nine", 2_222))
      assert length(rows) === 19_998

      assert capped(conn, sources("nine", 2_223)) === refused(@points_refusal)

      # Three measurements of five points, each repeated 1,500 times: 7,500 points each is
      # under the bound, the 22,500 together are not.
      regex = "/^five_/"
      statement = "SELECT v FROM " <> Enum.join(List.duplicate(regex, 1_500), ", ")
      assert capped(conn, statement) === refused(@points_refusal)

      two = "SELECT v FROM " <> Enum.join(List.duplicate("five_a, five_b", 1_000), ", ")
      assert {:ok, rows} = capped(conn, two)
      assert length(rows) === 10_000
    end
  end

  describe "conditions" do
    @depth_refusal "Client.Local: unsupported InfluxQL (a condition nested or chained deeper " <>
                     "than 8020 units, where InfluxDB 3 Core 3.10.1 overflows its stack: a call " <>
                     "counts 20, a sign 6, an arithmetic operator 10, a comparison 7, AND/OR 7, " <>
                     "a parenthesis 6)"

    # The refusal of a statement, which quotes it as sent.
    defp depth_refusal(statement),
      do: {:error, %{status: 400, body: @depth_refusal <> ": " <> statement}}

    # Groups that alternate, `ok = (v > 0 AND ok = (w > 1 AND ... ok = false))`, `depth` of them.
    defp alternating(depth) do
      Enum.reduce(1..depth, "ok = false", fn level, inner ->
        if rem(level, 2) == 0,
          do: "ok = (w > 1 AND " <> inner <> ")",
          else: "ok = (v > 0 AND " <> inner <> ")"
      end)
    end

    defp calls(depth),
      do: Enum.reduce(1..depth, "v", fn _level, inner -> "abs(" <> inner <> ")" end)

    # `(ok = (ok = ... (v > 1)))`, `depth` groups of `ok =` around the comparison.
    defp compared(depth),
      do: Enum.reduce(1..depth, "(v > 1)", fn _level, inner -> "(ok = " <> inner <> ")" end)

    # Core 3.10.1 answers `ok = (v > 0 AND ok = (w > 1 AND ...))` 400 deep with the two points
    # whose `ok` is false (verified at 400, and at 2, 4, 6 and 40), and its stack overflows by
    # 412 groups: past 400 the double refuses, the 800 it answered before included.
    test "groups in parentheses nested 400 deep are answered, 401 and 800 deep are refused",
         %{conn: conn} do
      statement = "SELECT ok FROM flag WHERE " <> alternating(400)
      assert {:ok, rows} = capped(conn, statement)

      assert Enum.map(rows, &{&1["ok"], DateTime.to_unix(&1["time"])}) === [
               {false, 2},
               {false, 3}
             ]

      for depth <- [401, 450, 800] do
        statement = "SELECT ok FROM flag WHERE " <> alternating(depth)
        assert capped(conn, statement) === depth_refusal(statement)
      end
    end

    # Core answers the sum of 800 `abs(1)` with every point (verified, and the contract pins
    # it); its stack overflows by 860 terms.
    test "a sum of 800 calls is answered, one of 804 and of three thousand is refused",
         %{conn: conn} do
      sum = fn terms -> Enum.join(List.duplicate("abs(1)", terms), " + ") end
      statement = "SELECT v FROM nine WHERE " <> sum.(800) <> " > 0"
      assert {:ok, rows} = capped(conn, statement)
      assert Enum.map(rows, & &1["v"]) === Enum.to_list(1..9)

      for terms <- [804, 3_000] do
        statement = "SELECT v FROM nine WHERE " <> sum.(terms) <> " > 0"
        assert capped(conn, statement) === depth_refusal(statement)
      end
    end

    # Core answers `abs(...abs(v)...) = 5` with the point whose `v` is 5 at the depths 1, 3,
    # 10, 50, 400 and 475 (verified; it takes 12 s at 400), and does not answer at 487.
    test "a call nested 400 deep is answered, 401 and eight thousand deep are refused",
         %{conn: conn} do
      statement = "SELECT v FROM nine WHERE " <> calls(400) <> " = 5"
      assert {:ok, rows} = capped(conn, statement)
      assert Enum.map(rows, &{&1["v"], DateTime.to_unix(&1["time"])}) === [{5, 5}]

      for depth <- [401, 500, 1_000, 4_000, 8_000] do
        statement = "SELECT v FROM nine WHERE " <> calls(depth) <> " = 5"
        assert capped(conn, statement) === depth_refusal(statement)
      end
    end

    # Core answers `(ok = (ok = ... (v > 1)))` with the two points whose `ok` is false at the
    # even depths and with none at the odd ones (verified at 1 to 8, 40, 41, 614, 615, 666,
    # 667 and 700), and its stack overflows by 900.
    test "groups that alternate with a comparison are answered to 615 deep, refused past it",
         %{conn: conn} do
      statement = "SELECT v FROM flag WHERE " <> compared(614)
      assert {:ok, rows} = capped(conn, statement)
      assert Enum.map(rows, &{&1["v"], DateTime.to_unix(&1["time"])}) === [{2, 2}, {3, 3}]

      assert capped(conn, "SELECT v FROM flag WHERE " <> compared(615)) === {:ok, []}

      for depth <- [616, 668, 1_500, 3_000, 6_000] do
        statement = "SELECT v FROM flag WHERE " <> compared(depth)
        assert capped(conn, statement) === depth_refusal(statement)
      end
    end
  end

  describe "select items" do
    @item_refusal "Client.Local: unsupported InfluxQL (a select item nested or chained deeper " <>
                    "than 160100 units, where InfluxDB 3 Core 3.10.1 overflows its stack: a call " <>
                    "counts 256, a sign 100, an arithmetic operator 200, a parenthesis 100, " <>
                    "after an operator 20)"

    defp item_refusal(statement),
      do: {:error, %{status: 400, body: @item_refusal <> ": " <> statement}}

    defp nest(prefix, core, suffix, depth),
      do: String.duplicate(prefix, depth) <> core <> String.duplicate(suffix, depth)

    # Core 3.10.1 answers `abs(...abs(v)...)` in the select list 625 deep (13 s; the contract
    # pins 400) and its stack overflows by 650 (641 verified as well); the double answers to 625.
    test "calls nested 625 deep are answered, 626 and more are refused", %{conn: conn} do
      assert {:ok, rows} =
               capped(conn, "SELECT " <> nest("abs(", "v", ")", 625) <> " AS x FROM nine")

      assert Enum.map(rows, & &1["x"]) === Enum.to_list(1..9)

      for depth <- [626, 650, 1_000, 8_000] do
        statement = "SELECT " <> nest("abs(", "v", ")", depth) <> " FROM nine"
        assert capped(conn, statement) === item_refusal(statement)
      end
    end

    # Answered by Core at 1,500 and 1,604 (it overflows by 1,900); sums of 800 terms; `v + (...)`
    # 729 deep; `-(...)` 800 deep (it overflows by 850, 1,000 and 1,000).
    test "parentheses, sums and signs are answered to the depth Core answers, refused past it",
         %{conn: conn} do
      sum = fn terms -> Enum.join(List.duplicate("v", terms), " + ") end

      # `v` is 1 to 9: each item is a multiple of it (an even count of negations is `v`).
      for {item, depth, times} <- [
            {nest("(", "v", ")", 1_600), 1_600, 1},
            {sum.(800), 800, 800},
            {nest("v + (", "v", ")", 727), 727, 728},
            {nest("-(", "v", ")", 800), 800, 1}
          ] do
        assert {:ok, rows} = capped(conn, "SELECT " <> item <> " AS x FROM nine"), "#{depth}"
        assert Enum.map(rows, & &1["x"]) === Enum.map(1..9, &(&1 * times)), "#{depth}"
      end

      for item <- [
            nest("(", "v", ")", 1_700),
            nest("(", "v", ")", 3_000),
            sum.(802),
            sum.(900),
            nest("v + (", "v", ")", 730),
            nest("v + (", "v", ")", 1_000),
            nest("-(", "v", ")", 803),
            nest("-(", "v", ")", 1_200)
          ] do
        statement = "SELECT " <> item <> " FROM nine"
        assert capped(conn, statement) === item_refusal(statement)
      end
    end

    # Each item has the budget on its own, and an alias does not hide the next item.
    test "a deep item is refused whichever it is, with an alias or after another item",
         %{conn: conn} do
      deep = nest("abs(", "v", ")", 700)

      for statement <- [
            "SELECT v, " <> deep <> " FROM nine",
            "SELECT " <> deep <> " AS x, v FROM nine",
            "SELECT v AS a, v + 1 AS b, " <> deep <> " AS c FROM nine"
          ] do
        assert capped(conn, statement) === item_refusal(statement)
      end
    end

    # Any expression in `time()` is refused by name, a group in as many parentheses as written
    # (the engine answers `time(((1m)))` and 1,500 parentheses; it overflows by 2,500).
    test "the interval of GROUP BY time() in parentheses is refused by name, deep or not",
         %{conn: conn} do
      for depth <- [2, 3, 10, 1_500, 3_000] do
        statement =
          "SELECT count(v) FROM nine WHERE time >= 0 AND time < 100s GROUP BY time(" <>
            nest("(", "1m", ")", depth) <> ")"

        assert {:error, %{status: 400, body: body}} = capped(conn, statement)

        assert body ===
                 "Client.Local: unsupported InfluxQL (GROUP BY time() of an expression): " <>
                   statement
      end
    end
  end
end
