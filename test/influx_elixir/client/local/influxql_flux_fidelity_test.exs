defmodule InfluxElixir.Client.Local.InfluxQLFluxFidelityTest do
  @moduledoc """
  What `Client.Local` answers to InfluxQL and Flux where it refuses by name or
  models more than the shared contract reaches. Every expectation was read from
  InfluxDB 3 Core or InfluxDB 2.7.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Client.Local.Store

  # Helpers
  # ---------------------------------------------------------------------------

  # A connection's store dies with the test process, so nothing is stopped.
  defp v3_conn(databases \\ ["db"]) do
    {:ok, conn} = Local.start(databases: databases, profile: :v3_core)
    conn
  end

  defp v2_conn(buckets \\ ["b"]) do
    {:ok, conn} = Local.start(profile: :v2)
    Enum.each(buckets, &Local.create_bucket(conn, &1))
    conn
  end

  defp error_body(result) do
    assert {:error, %{body: body}} = result
    Jason.decode!(body)
  end

  defp iql(conn, statement), do: Local.query_influxql(conn, statement, database: "db")

  defp flux_all(conn, tail),
    do: Local.query_flux(conn, ~s|from(bucket: "b") \|> range(start: 0) | <> tail)

  defp flux_range(conn, args),
    do: Local.query_flux(conn, ~s|from(bucket: "b") \|> range(#{args})|)

  defp wrap64(value) do
    wrapped = Bitwise.band(value, 0xFFFFFFFFFFFFFFFF)
    if wrapped >= 0x8000000000000000, do: wrapped - 0x10000000000000000, else: wrapped
  end

  @empty_range %{
    "code" => "invalid",
    "message" => "error in building plan while starting program: cannot query an empty range"
  }

  @hour_ns 3_600_000_000_000

  # ---------------------------------------------------------------------------
  # InfluxQL through the double
  # ---------------------------------------------------------------------------

  describe "query_influxql/3 — what the double refuses by name" do
    setup do
      conn = v3_conn()
      {:ok, :written} = Local.write(conn, "o,k=a v=1,w=10 1000", database: "db")
      {:ok, conn: conn}
    end

    test "a WHERE it does not model", %{conn: conn} do
      for {where, message} <- [
            {"time > 0.5", "Client.Local: unsupported InfluxQL (non-integer time 0.5)"},
            {"time >= 2 OR k = 'a'",
             "Client.Local: unsupported InfluxQL (a time comparison inside OR)"},
            {"k = 'a' OR (k = 'b' AND time >= 2)",
             "Client.Local: unsupported InfluxQL (a time comparison inside OR)"},
            {"time > 1 * 2",
             "Client.Local: unsupported InfluxQL (a time compared with an expression)"}
          ] do
        assert iql(conn, "SELECT v FROM o WHERE #{where}") ===
                 {:error, %{status: 400, body: message}},
               where
      end
    end

    test "a clause it does not model, outside a literal", %{conn: conn} do
      for {statement, name} <- [
            {"SELECT v INTO x FROM o", "INTO"},
            {"SELECT v FROM (SELECT v FROM o)", "subqueries"},
            {"SELECT mean(v) FROM o GROUP BY time(1)", "GROUP BY time() with an integer interval"}
          ] do
        assert iql(conn, statement) ===
                 {:error,
                  %{
                    status: 400,
                    body: "Client.Local: unsupported InfluxQL (#{name}): #{statement}"
                  }},
               statement
      end
    end

    test "a keyword inside a literal is no keyword, however long the literal", %{conn: conn} do
      long = String.duplicate("x", 5_000)

      for literal <- [
            "into",
            "fill(",
            "group by time(1m)",
            "slimit 1",
            "tz(x)",
            "it\\'s into",
            long
          ] do
        assert {:ok, []} = iql(conn, "SELECT v FROM o WHERE k = '#{literal}'"), literal
      end

      assert {:ok, []} = iql(conn, "SELECT v FROM o WHERE k =~ /fill\\(/")

      assert iql(conn, "SELECT v FROM o WHERE k = 'a' LIMIT 5") ===
               {:ok,
                [
                  %{
                    "iox::measurement" => "o",
                    "time" => ~U[1970-01-01 00:00:00.000001Z],
                    "v" => 1.0
                  }
                ]}
    end
  end

  describe "query_influxql/3 — answers the contract does not reach" do
    setup do
      conn = v3_conn()

      lp = """
      o,k=a v=1,w=10 1000
      o,k=b v=2,w=20 2000
      o,k=a v=3,w=30 3000
      o,k=into v=4,w=40 4000
      o,k=c x=7i 5000
      """

      {:ok, :written} = Local.write(conn, String.trim(lp), database: "db")
      {:ok, conn: conn}
    end

    test "a bound taken from now() is stamped on the aggregate", %{conn: conn} do
      assert {:ok, []} = iql(conn, "SELECT mean(v) FROM o WHERE time > now() - 1h")

      assert {:ok, :written} =
               Local.write(conn, "fresh v=1 #{System.os_time(:nanosecond)}", database: "db")

      # `time > x` starts one nanosecond after x, and the row carries whole
      # microseconds: the stamp lies between the bounds of a bracket of the
      # call, whatever the clock reads in it.
      first = Store.now_ns()
      answer = iql(conn, "SELECT mean(v) FROM fresh WHERE time > now() - 1h")
      last = Store.now_ns()

      assert {:ok, [%{"time" => time} = row]} = answer
      assert Map.delete(row, "time") === %{"iox::measurement" => "fresh", "mean" => 1.0}
      stamp = DateTime.to_unix(time, :microsecond)
      assert stamp >= Integer.floor_div(first - @hour_ns + 1, 1_000)
      assert stamp <= Integer.floor_div(last - @hour_ns + 1, 1_000)
    end

    test "a tag equal to '' finds the points that lack the tag", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "o v=9,w=90 6000", database: "db")

      assert {:ok, rows} = iql(conn, "SELECT v FROM o WHERE k = ''")
      assert Enum.map(rows, & &1["v"]) === [9.0]
    end

    test "a tag not equal to a value finds the points that lack the tag", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "o v=9,w=90 6000", database: "db")

      assert {:ok, rows} = iql(conn, "SELECT v FROM o WHERE k != 'a'")
      assert Enum.map(rows, & &1["v"]) === [2.0, 4.0, 9.0]
    end

    test "a row without the tag has no key for it, not an empty string", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "o v=9,w=90 6000", database: "db")

      assert {:ok, [row]} = iql(conn, "SELECT * FROM o WHERE k = ''")
      refute Map.has_key?(row, "k")

      assert {:ok, rows} = iql(conn, "SELECT * FROM o")
      assert length(rows) === 6
      refute Enum.any?(rows, &(&1["k"] === ""))
    end

    test "SHOW MEASUREMENTS lists the measurements by name", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "zz v=1 1\naa v=1 1\nmm v=1 1", database: "db")
      assert {:ok, rows} = iql(conn, "SHOW MEASUREMENTS")
      assert Enum.map(rows, & &1["name"]) === ["aa", "mm", "o", "zz"]
    end
  end

  # ---------------------------------------------------------------------------
  # Flux through the double
  # ---------------------------------------------------------------------------

  describe "query_flux/3 — range" do
    test "an integer second count that does not fit wraps in 64-bit nanoseconds" do
      conn = v2_conn()
      assert {:ok, :written} = Local.write(conn, "m v=1 5", database: "b")

      assert {:ok, [row]} = flux_range(conn, "start: 0, stop: 99999999999999")
      assert row["_start"] === ~U[1970-01-01 00:00:00.000000Z]
      assert row["_stop"] === ~U[1976-05-08 04:06:59.520689Z]

      assert {:ok, [row]} = flux_range(conn, "start: 0, stop: 9223372036")
      assert row["_stop"] === ~U[2262-04-11 23:47:16.000000Z]

      # The stop wraps below the start, but a range is judged on the seconds.
      assert {:ok, []} = flux_range(conn, "start: 0, stop: 18446744073")
    end

    test "a negative duration reaches back from now, a positive one forward" do
      conn = v2_conn()
      now = System.os_time(:nanosecond)
      later = now + 86_400_000_000_000

      assert {:ok, :written} = Local.write(conn, "m v=1 #{now}\nm v=2 #{later}", database: "b")

      assert {:ok, [row]} = flux_range(conn, "start: -1h, stop: now()")
      assert {row["_value"], DateTime.diff(row["_stop"], row["_start"], :second)} === {1.0, 3_600}

      assert {:ok, [row]} = flux_range(conn, "start: now(), stop: 1w")

      assert {row["_value"], DateTime.diff(row["_stop"], row["_start"], :second)} ===
               {2.0, 604_800}
    end

    test "a duration that does not fit wraps to the engine's value" do
      conn = v2_conn()
      assert {:ok, :written} = Local.write(conn, "m v=1 5", database: "b")

      assert {:ok, [row]} = flux_range(conn, "start: -99999999999w, stop: now()")

      stop_ns = DateTime.to_unix(row["_stop"], :nanosecond)
      week = 604_800_000_000_000

      # `now` carries nanoseconds a row's time does not, which can move the
      # microsecond of the wrapped start by one.
      candidates =
        for extra <- [0, 999],
            do: DateTime.from_unix!(wrap64(stop_ns + extra - 99_999_999_999 * week), :nanosecond)

      assert Enum.any?(candidates, &(DateTime.truncate(&1, :microsecond) === row["_start"]))
      assert row["_start"].year === 1810
    end

    test "an RFC3339 time that does not fit wraps" do
      conn = v2_conn()
      assert {:ok, :written} = Local.write(conn, "m v=1 5", database: "b")
      assert {:ok, rows} = flux_range(conn, "start: 0001-01-01T00:00:00Z, stop: now()")

      assert Enum.map(rows, & &1["_start"]) === [~U[1754-08-30 22:43:41.128654Z]]
    end

    test "a range with no time in it is the engine's plan error" do
      conn = v2_conn()

      for args <- [
            "start: 5, stop: 3",
            "start: 0, stop: 0",
            "start: 0, stop: -1",
            "start: -1h, stop: -2h",
            "start: now()",
            "start: 1970-01-01T00:00:10Z, stop: 1970-01-01T00:00:05Z",
            "start: 3000000000, stop: 1",
            "start: 0, stop: 9223372036854775807",
            "start: 0, stop: 2262-04-12T00:00:00Z",
            "start: 18446744073, stop: 18446744070"
          ] do
        assert error_body(flux_range(conn, args)) === @empty_range, args
      end

      # Judged on the seconds as Go counts them, these have a range.
      for args <- [
            "start: 0, stop: 18446744073",
            "start: 9223372037, stop: 9223372038",
            "start: 18446744073, stop: 18446744075"
          ] do
        assert {:ok, []} = flux_range(conn, args), args
      end
    end
  end

  describe "query_flux/3 — stages" do
    test "rows of a table are in the stored nanosecond order: first, last, limit and the rows" do
      conn = v2_conn()

      assert {:ok, :written} =
               Local.write(conn, "m,t=a v=1i 1001\nm,t=a v=2i 1000", database: "b")

      assert {:ok, rows} = flux_all(conn, "")
      assert Enum.map(rows, & &1["_value"]) === [2, 1]

      for {stage, value} <- [{"first()", 2}, {"last()", 1}, {"limit(n: 1)", 2}] do
        assert {:ok, [row]} = flux_all(conn, "|> " <> stage)
        assert row["_value"] === value, stage
      end

      assert {:ok, [row]} = flux_all(conn, "|> limit(n: 1, offset: 1)")
      assert row["_value"] === 1
    end

    test "sort and group are refused by name" do
      conn = v2_conn()

      for stage <- ["sort()", "group()"] do
        assert error_body(flux_all(conn, "|> " <> stage)) === %{
                 "code" => "invalid",
                 "message" => "Client.Local: unsupported Flux function: #{stage}"
               }
      end
    end

    test "a filter on _measurement reads only those measurements" do
      conn = v2_conn()
      assert {:ok, :written} = Local.write(conn, "a v=1 1\nb v=2 2\nc v=3 3", database: "b")

      reads = fn filter ->
        assert {:ok, rows} = flux_all(conn, "|> filter(fn: (r) => #{filter})")
        Enum.map(rows, &{&1["_measurement"], &1["_value"]})
      end

      assert reads.(~s|r._measurement == "a"|) === [{"a", 1.0}]

      assert reads.(~s|r._measurement == "a" or r._measurement == "c"|) === [
               {"a", 1.0},
               {"c", 3.0}
             ]

      assert reads.(~s|r._measurement == "a" and r._measurement == "b"|) === []
      assert reads.(~s|r._measurement != "a"|) === [{"b", 2.0}, {"c", 3.0}]
      assert reads.(~s|not (r._measurement == "a")|) === [{"b", 2.0}, {"c", 3.0}]

      assert reads.(~s|r._measurement == "a" or r._field == "v"|) === [
               {"a", 1.0},
               {"b", 2.0},
               {"c", 3.0}
             ]

      assert reads.(~s|r._measurement == "nope"|) === []
    end

    test "a measurement InfluxDB 2 accepts and never returns is not returned" do
      conn = v2_conn()

      assert {:ok, :written} =
               Local.write(conn, ~S"gone\\,x v=1i 1" <> "\n" <> ~S"here\,x v=2i 2", database: "b")

      assert {:ok, rows} = flux_all(conn, "")
      assert Enum.map(rows, &{&1["_measurement"], &1["_value"]}) === [{"here,x", 2}]
    end
  end
end
