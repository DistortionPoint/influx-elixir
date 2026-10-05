defmodule InfluxElixir.Client.Local.WriteBucketsV2Test do
  @moduledoc """
  InfluxDB 2 writes and buckets through `Client.Local`: shard groups, retention,
  the data a deleted bucket takes with it. Every expectation was read from
  InfluxDB 2.7.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.TestSupport.Await

  # Helpers
  # ---------------------------------------------------------------------------

  defp v2_conn(buckets) do
    {:ok, conn} = Local.start(profile: :v2)
    Enum.each(buckets, &Local.create_bucket(conn, &1))
    conn
  end

  defp error_body(result) do
    assert {:error, %{body: body}} = result
    Jason.decode!(body)
  end

  # The later of the two clocks the BEAM has: the double's own reading of "now".
  defp clock, do: max(System.os_time(:nanosecond), System.system_time(:nanosecond))

  # Returns once the clock reads later than it did, so that a second stamp
  # taken after this call cannot equal one taken before it. Fails the test,
  # rather than spinning on, if the clock never moves.
  defp let_the_clock_move do
    started = System.os_time(:nanosecond)
    Await.until(fn -> System.os_time(:nanosecond) > started end)
  end

  @minute_ns 60_000_000_000
  @hour_ns 3_600_000_000_000

  @drop_conflict "failure writing points to database: partial write: field type conflict: " <>
                   ~s|input field "v" on measurement "m" is type integer, | <>
                   "already exists as type float dropped="
  @drop_invalid "failure writing points to database: partial write: invalid field name: " <>
                  ~s|input field "time" on measurement "m" is invalid dropped=|

  defp drop_body(message), do: %{"code" => "unprocessable entity", "message" => message}

  # The message with the clock's reading and the bucket's id masked, and the
  # bounds it printed.
  defp masked_retention(conn, bucket, body) do
    assert %{"code" => "unprocessable entity", "message" => message} = body
    assert {:ok, buckets} = Local.list_buckets(conn)
    assert %{"id" => id} = Enum.find(buckets, &(&1["name"] === bucket))

    bounds =
      ~r/Lower Bound at (\d{4}-[-\d:.TZ]+)/
      |> Regex.scan(message, capture: :all_but_first)
      |> List.flatten()

    masked =
      message
      |> String.replace(~r/Lower Bound at \d{4}-[-\d:.TZ]+/, "Lower Bound at BOUND")
      |> String.replace("database: #{id} ", "database: ID ")

    {masked, bounds}
  end

  # ---------------------------------------------------------------------------
  # Writes and buckets through the double
  # ---------------------------------------------------------------------------

  describe "write/3 — InfluxDB 2 shard groups" do
    # A bucket that keeps three hours has hour-long groups, one that keeps
    # three days day-long ones. Each gets `v` as a float in the group of
    # `first`; `second` is two hours on, in the same group only for the
    # daily bucket. Every time is before now whatever the time of day: the
    # hourly pair lies in the two hours before the current one, the daily
    # pair in the day before the current one.
    setup do
      conn = v2_conn([])
      :ok = Local.create_bucket(conn, "hourly", retention: 10_800)
      :ok = Local.create_bucket(conn, "daily", retention: 259_200)

      now = System.os_time(:nanosecond)
      hour = Integer.floor_div(now, @hour_ns) * @hour_ns
      yesterday = Integer.floor_div(now, 24 * @hour_ns) * 24 * @hour_ns - 24 * @hour_ns

      times = %{
        "hourly" => {hour - 2 * @hour_ns + 5 * @minute_ns, hour - 5 * @minute_ns},
        "daily" => {yesterday + @hour_ns, yesterday + 3 * @hour_ns}
      }

      for {bucket, {first, _second}} <- times do
        assert {:ok, :written} = Local.write(conn, "m v=1.5 #{first}", database: bucket)
      end

      {:ok, conn: conn, times: times}
    end

    test "a bucket of hour-long groups reports the first group's drop, counting its own",
         %{conn: conn, times: %{"hourly" => {first, second}}} do
      payload = "m v=1i #{first}\nm time=1 #{second}"

      assert error_body(Local.write(conn, payload, database: "hourly")) ===
               drop_body(@drop_conflict <> "1")
    end

    test "a bucket of day-long groups counts both drops of the one group",
         %{conn: conn, times: %{"daily" => {first, second}}} do
      payload = "m v=1i #{first}\nm time=1 #{second}"

      assert error_body(Local.write(conn, payload, database: "daily")) ===
               drop_body(@drop_conflict <> "2")
    end

    test "the earliest hour-long group speaks whatever order the payload gives them in",
         %{conn: conn, times: %{"hourly" => {first, second}}} do
      payload = "m time=1 #{second}\nm v=1i #{first}\nm time=1 #{first}"

      assert error_body(Local.write(conn, payload, database: "hourly")) ===
               drop_body(@drop_conflict <> "2")
    end

    test "in one day-long group the first drop in the payload speaks, counting all three",
         %{conn: conn, times: %{"daily" => {first, second}}} do
      payload = "m time=1 #{second}\nm v=1i #{first}\nm time=1 #{first}"

      assert error_body(Local.write(conn, payload, database: "daily")) ===
               drop_body(@drop_invalid <> "3")
    end

    test "a payload of thousands of groups is written group by group" do
      conn = v2_conn(["weekly"])
      assert {:ok, :written} = Local.write(conn, "m v=1.5 5", database: "weekly")

      payload = Enum.map_join(0..2_999, "\n", &"m v=1i #{&1 * 604_800_000_000_000 + 7}")

      assert error_body(Local.write(conn, payload, database: "weekly")) ===
               drop_body(@drop_conflict <> "1")
    end
  end

  describe "write/3 — InfluxDB 2 retention" do
    setup do
      conn = v2_conn([])
      :ok = Local.create_bucket(conn, "short", retention: 7200)
      :ok = Local.create_bucket(conn, "forever")
      {:ok, conn: conn, now: System.os_time(:nanosecond)}
    end

    test "a bucket that keeps everything accepts a point of any age", %{conn: conn} do
      assert {:ok, :written} = Local.write(conn, "m v=1i 5", database: "forever")
    end

    test "a point older than the retention is the engine's 422, naming it", ctx do
      %{conn: conn} = ctx
      body = error_body(Local.write(conn, "m v=1i 1672790400000000000", database: "short"))

      assert {masked, _bounds} = masked_retention(conn, "short", body)

      assert masked ===
               "failure writing points to database: partial write: dropped 1 points outside " <>
                 "retention policy of duration 2h0m0s - oldest point m at 2023-01-04T00:00:00Z " <>
                 "dropped because it violates a Retention Policy Lower Bound at BOUND, " <>
                 "newest point m at 2023-01-04T00:00:00Z dropped because it violates a " <>
                 "Retention Policy Lower Bound at BOUND dropped=1 for database: ID " <>
                 "for retention policy: autogen"
    end

    test "the lower bound is the retention before now", %{conn: conn} do
      # The double's clock is the later of the two the BEAM has.
      first = clock()
      body = error_body(Local.write(conn, "m v=1i 5", database: "short"))
      last = clock()

      assert {_masked, [bound, same]} = masked_retention(conn, "short", body)
      assert bound === same

      # Printed to the microsecond at most, so it is compared as one.
      assert {:ok, bound, 0} = DateTime.from_iso8601(bound)
      printed = DateTime.to_unix(bound, :microsecond)
      assert printed >= Integer.floor_div(first - 7200 * 1_000_000_000, 1_000)
      assert printed <= Integer.floor_div(last - 7200 * 1_000_000_000, 1_000)
    end

    test "the oldest and the newest dropped point are named by series key and time",
         %{conn: conn} do
      payload =
        "m1,t=a v=1i 1672790400123456789\n" <>
          "m2,u=c,t=b v=1i 1672790400000000001\n" <>
          "m3 v=1i 1672790400123456000"

      body = error_body(Local.write(conn, payload, database: "short"))
      assert {masked, _bounds} = masked_retention(conn, "short", body)

      assert masked =~ "dropped 3 points"
      assert masked =~ "oldest point m2,t=b,u=c at 2023-01-04T00:00:00.000000001Z dropped"
      assert masked =~ "newest point m1,t=a at 2023-01-04T00:00:00.123456789Z dropped"
      assert masked =~ "dropped=3 for database"
    end

    test "on a tie the first point of the payload is both the oldest and the newest",
         %{conn: conn} do
      body =
        error_body(
          Local.write(conn, "m1 v=1i 1672790400000000000\nm2 v=1i 1672790400000000000",
            database: "short"
          )
        )

      assert {masked, _bounds} = masked_retention(conn, "short", body)
      assert masked =~ "oldest point m1 at 2023-01-04T00:00:00Z dropped"
      assert masked =~ "newest point m1 at 2023-01-04T00:00:00Z dropped"
    end

    test "a series key is escaped as line protocol escapes it", %{conn: conn} do
      payload = ~S"m\ x\,y,b\ k\=1=v\,2\ 3,a=z v=1i 1672790400000000000"
      body = error_body(Local.write(conn, payload, database: "short"))
      assert {masked, _bounds} = masked_retention(conn, "short", body)

      key = ~S"m\ x\,y,a=z,b\ k\=1=v\,2\ 3"
      assert masked =~ "oldest point #{key} at 2023-01-04T00:00:00Z dropped"
    end

    test "the duration is Go's, in hours", %{conn: conn} do
      :ok = Local.create_bucket(conn, "odd", retention: 90_061)
      body = error_body(Local.write(conn, "m v=1i 5", database: "odd"))
      assert {masked, _bounds} = masked_retention(conn, "odd", body)
      assert masked =~ "outside retention policy of duration 25h1m1s - "
    end

    test "the other points of the payload are written", %{conn: conn, now: now} do
      assert {:error, %{status: 422}} =
               Local.write(conn, "m v=1i 5\nm v=2i #{now - 60_000_000_000}", database: "short")

      assert {:ok, rows} =
               Local.query_flux(conn, ~s|from(bucket: "short") \|> range(start: -3h, stop: 1h)|)

      assert Enum.map(rows, & &1["_value"]) === [2]
    end

    test "a point older than the retention registers no field type", %{conn: conn, now: now} do
      assert {:error, %{status: 422}} = Local.write(conn, "m v=2.5 5", database: "short")
      assert {:ok, :written} = Local.write(conn, "m v=1i #{now}", database: "short")
    end

    test "a point older than the retention is dropped before its fields are judged",
         %{conn: conn} do
      body = error_body(Local.write(conn, "m time=1 5", database: "short"))
      assert {masked, _bounds} = masked_retention(conn, "short", body)
      assert masked =~ "partial write: dropped 1 points outside retention policy"
    end

    test "a group's drop is reported instead of the retention drops", %{conn: conn, now: now} do
      assert {:ok, :written} = Local.write(conn, "m v=1i #{now}", database: "short")

      payload = "m v=1i 5\nm v=2.5 #{now + 1}"

      assert error_body(Local.write(conn, payload, database: "short")) ===
               drop_body(
                 "failure writing points to database: partial write: field type conflict: " <>
                   ~s|input field "v" on measurement "m" is type float, | <>
                   "already exists as type integer dropped=1"
               )
    end
  end

  describe "delete_bucket/2 — the bucket's data goes with it" do
    test "another bucket keeps its points and its field types" do
      conn = v2_conn(["b", "other"])
      assert {:ok, :written} = Local.write(conn, "m v=1i 5", database: "other")
      assert :ok = Local.delete_bucket(conn, "b")

      assert {:error, %{status: 422}} = Local.write(conn, "m v=1.5 5", database: "other")

      # `_stop` is the clock's reading; the rest of the row is exact.
      assert {:ok, [row]} = Local.query_flux(conn, ~s|from(bucket: "other") \|> range(start: 0)|)

      assert Map.delete(row, "_stop") === %{
               "result" => "_result",
               "table" => 0,
               "_measurement" => "m",
               "_field" => "v",
               "_start" => ~U[1970-01-01 00:00:00.000000Z],
               "_time" => ~U[1970-01-01 00:00:00.000000Z],
               "_value" => 1
             }
    end

    test "the bucket holds nothing of it when it is made again under the name" do
      conn = v2_conn(["b"])
      read = ~s|from(bucket: "b") \|> range(start: 0)|

      fields = fn ->
        conn |> Local.query_flux(read) |> elem(1) |> Enum.map(&{&1["_field"], &1["_value"]})
      end

      # The same series and time twice: one merged point, the later write's value.
      assert {:ok, :written} = Local.write(conn, "m v=1i 5", database: "b")
      assert {:ok, :written} = Local.write(conn, "m v=2i 5", database: "b")
      assert fields.() === [{"v", 2}]

      assert :ok = Local.delete_bucket(conn, "b")
      assert :ok = Local.create_bucket(conn, "b")
      assert Local.query_flux(conn, read) === {:ok, []}

      # The field `v` was an integer: made again, the bucket takes it as a float. The same
      # series and time as a first write is one point with only its own fields, not merged
      # with anything the deleted bucket held.
      assert {:ok, :written} = Local.write(conn, "m v=2.5,w=3i 5", database: "b")
      assert Enum.sort(fields.()) === [{"v", 2.5}, {"w", 3}]
    end
  end

  describe "query_flux/3 — a field of another type in a later shard group" do
    test "a bucket of hour-long groups reads up to the first group of another type" do
      conn = v2_conn([])
      :ok = Local.create_bucket(conn, "hourly", retention: 10_800)
      hour = Integer.floor_div(System.os_time(:nanosecond), @hour_ns) * @hour_ns

      assert {:ok, :written} =
               Local.write(
                 conn,
                 "m v=1i #{hour - 2 * @hour_ns + 30 * @minute_ns}\n" <>
                   "m v=2.5 #{hour - @hour_ns + 30 * @minute_ns}\n" <>
                   "m v=3i #{hour}",
                 database: "hourly"
               )

      assert {:ok, rows} =
               Local.query_flux(conn, ~s|from(bucket: "hourly") \|> range(start: -3h, stop: 1h)|)

      assert Enum.map(rows, & &1["_value"]) === [1]
    end
  end

  describe "list_buckets/1" do
    test "a bucket's orgID is its org's and its id is stable across calls and connections" do
      {:ok, conn} = Local.start(profile: :v2, org: "acme")
      :ok = Local.create_bucket(conn, "one")
      :ok = Local.create_bucket(conn, "two", retention: 86_400)

      assert {:ok, [one, two]} = Local.list_buckets(conn)
      assert {:ok, [^one, ^two]} = Local.list_buckets(conn)

      assert two["orgID"] === one["orgID"]
      assert one["id"] !== two["id"]

      # Another connection to the same org lists the same ids; another org does not.
      {:ok, same} = Local.start(profile: :v2, org: "acme")
      {:ok, other} = Local.start(profile: :v2, org: "other")
      :ok = Local.create_bucket(same, "one")
      :ok = Local.create_bucket(other, "one")

      # Created on another connection, so its time differs; its identity does not.
      assert {:ok, [same_one]} = Local.list_buckets(same)
      assert Map.take(same_one, ["orgID", "id"]) === Map.take(one, ["orgID", "id"])
      assert {:ok, [other_one]} = Local.list_buckets(other)
      refute other_one["orgID"] === one["orgID"]
    end

    test "creating a bucket again keeps its creation time" do
      conn = v2_conn([])
      :ok = Local.create_bucket(conn, "one")
      {:ok, [first]} = Local.list_buckets(conn)
      let_the_clock_move()
      :ok = Local.create_bucket(conn, "one")
      assert {:ok, [^first]} = Local.list_buckets(conn)
    end
  end
end
