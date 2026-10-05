defmodule InfluxElixir.Client.Local.RetentionVisibilityTest do
  @moduledoc """
  Which points a database with a retention shows: `Retention.visible/3` against the
  definition (a chunk is shown for as long as its newest point is), the markers the
  store keeps so that a read with nothing expired does not look at the points, and the
  answers a query gives either way.

  `Retention.visible/3` is tested directly because it is a pure function of its clock: the
  public calls read the real one, and the definition is checked against many fixed clocks
  and chunk edges that no real clock could be made to stand at.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Client.Local.Retention

  @second 1_000_000_000
  @chunk 600 * @second
  @now 1_000_000 * @second

  defp point(measurement, seconds_ago),
    do: %{measurement: measurement, timestamp: @now - seconds_ago * @second, tags: %{}}

  # The rule as stated: the newest point of each chunk decides.
  defp reference(points, seconds) do
    cutoff = @now - seconds * @second
    chunk = fn p -> {p.measurement, Integer.floor_div(p.timestamp, @chunk)} end

    newest =
      Enum.reduce(points, %{}, fn p, acc ->
        Map.update(acc, chunk.(p), p.timestamp, &max(&1, p.timestamp))
      end)

    Enum.filter(points, &(Map.fetch!(newest, chunk.(&1)) >= cutoff))
  end

  describe "visible/3" do
    test "a database without a retention shows every point" do
      points = [point("m", 5), point("m", 99_999)]
      assert Retention.visible(points, nil, @now) === points
    end

    test "points none of which is older than the cut-off are returned as they are" do
      points = [point("m", 5), point("m", 50), point("n", 59)]
      assert Retention.visible(points, 60, @now) === points
    end

    test "an expired point shares the fate of the newest point of its chunk" do
      # chunk of the cut-off: 999_000 s .. 999_600 s holds the cut-off 999_940 s
      # when the retention is 60 s
      kept = point("m", 30)
      old_in_chunk = %{kept | timestamp: kept.timestamp - 100 * @second}
      old_elsewhere = point("m", 5_000)
      other_measurement = %{old_in_chunk | measurement: "n"}

      points = [old_in_chunk, kept, old_elsewhere, other_measurement]

      assert Retention.visible(points, 60, @now) === reference(points, 60)
      assert Retention.visible(points, 60, @now) === [old_in_chunk, kept]
    end

    test "a retention of zero shows only the chunks that hold a point at or after now" do
      now_point = point("m", 0)
      same_chunk = %{now_point | timestamp: now_point.timestamp - 1}
      older_chunk = point("m", 3_000)

      assert Retention.visible([older_chunk, same_chunk, now_point], 0, @now) ===
               [same_chunk, now_point]
    end

    test "agrees with the rule on points scattered over many chunks and measurements" do
      :rand.seed(:exsss, {7, 11, 13})

      for retention <- [0, 1, 59, 60, 600, 1_000, 5_000, 100_000] do
        points =
          for _index <- 1..300 do
            point(Enum.random(["a", "b", "c"]), :rand.uniform(20_000) - 1_000)
          end

        assert Retention.visible(points, retention, @now) === reference(points, retention),
               "retention #{retention}"
      end
    end
  end

  describe "chunks/1 and oldest_chunk/1" do
    test "lists each chunk of each measurement once" do
      points = [point("m", 1), point("m", 2), point("m", 700), point("n", 1)]

      assert points |> Retention.chunks() |> Enum.sort() ===
               Enum.sort([
                 {"m", Integer.floor_div(@now - @second, @chunk)},
                 {"m", Integer.floor_div(@now - 700 * @second, @chunk)},
                 {"n", Integer.floor_div(@now - @second, @chunk)}
               ])
    end

    test "the oldest chunk is the one the cut-off falls in" do
      cutoff = Retention.cutoff(60, @now)
      assert Retention.oldest_chunk(cutoff) === Integer.floor_div(cutoff, @chunk)
    end
  end

  describe "a query through the store" do
    setup do
      {:ok, conn} = Local.start(profile: :v3_core)
      :ok = Local.create_database(conn, "kept", retention: "1h")
      :ok = Local.create_database(conn, "plain")
      {:ok, conn: conn}
    end

    defp write(conn, database, lines),
      do: {:ok, :written} = Local.write(conn, Enum.join(lines, "\n"), database: database)

    defp count(conn, database) do
      {:ok, [row]} = Local.query_sql(conn, "SELECT count(*) AS n FROM m", database: database)
      row["n"]
    end

    test "points that are all current are all shown", %{conn: conn} do
      now = System.os_time(:nanosecond)
      lines = for i <- 1..50, do: "m,k=a v=#{i} #{now - i * @second}"

      write(conn, "kept", lines)
      write(conn, "plain", lines)

      assert count(conn, "kept") === 50
      assert count(conn, "kept") === count(conn, "plain")
    end

    test "points written long ago are hidden, those of a chunk with a current point are not",
         %{conn: conn} do
      now = System.os_time(:nanosecond)
      long_ago = now - 7_200 * @second

      # The retention puts the cut-off in the middle of a chunk, five minutes from either
      # end, whatever the time of day: the query reads the clock a little later than this test
      # does, and a cut-off at the end of a chunk could move into the next one by then.
      chunk_start = div(now - 3_600 * @second, @chunk) * @chunk
      retention = div(now - (chunk_start + div(@chunk, 2)), @second)
      :ok = Local.create_database(conn, "middle", retention: "#{retention}s")

      # The chunk the cut-off falls in: its first nanosecond is older than the
      # cut-off, its last is not.
      write(conn, "middle", [
        "m,k=a v=1 #{long_ago}",
        "m,k=a v=2 #{long_ago + @second}",
        "m,k=b v=3 #{chunk_start + 1}",
        "m,k=b v=4 #{chunk_start + @chunk - 1}",
        "m,k=b v=5 #{now}"
      ])

      assert {:ok, rows} = Local.query_sql(conn, "SELECT v FROM m ORDER BY v", database: "middle")
      assert Enum.map(rows, & &1["v"]) === [3.0, 4.0, 5.0]
    end

    test "points written later, into a chunk that was current, change nothing that is shown",
         %{conn: conn} do
      now = System.os_time(:nanosecond)
      write(conn, "kept", ["m,k=a v=1 #{now}"])
      assert count(conn, "kept") === 1

      write(conn, "kept", ["m,k=a v=2 #{now - 7_200 * @second}"])
      assert count(conn, "kept") === 1
    end
  end
end
