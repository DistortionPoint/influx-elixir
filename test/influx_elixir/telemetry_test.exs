defmodule InfluxElixir.TelemetryTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Telemetry
  alias InfluxElixir.TestSupport.Telemetry, as: Forward

  # A span's function that takes a moment (so that a duration of nothing would be seen) and
  # reports how long it ran, by the monotonic clock read inside it: the span's duration spans
  # the function, so it can never be less than that.
  defp timed(fun) do
    parent = self()

    fn ->
      started = System.monotonic_time()

      try do
        Process.sleep(1)
        fun.()
      after
        send(parent, {:inner_elapsed, System.monotonic_time() - started})
      end
    end
  end

  defp assert_spans_function(duration) do
    assert_received {:inner_elapsed, inner_elapsed}
    assert duration >= inner_elapsed
  end

  # Runs `emit` and returns the readings of a clock taken before and after it,
  # so that a time the event carries can be bracketed exactly.
  defp bracketed(clock, emit) do
    before = clock.()
    emit.()
    {before, clock.()}
  end

  describe "span_write/2" do
    test "emits :start event before the function executes" do
      Forward.attach([[:influx_elixir, :write, :start]])
      metadata = %{database: "testdb", point_count: 1, bytes: 42}

      {before, later} =
        bracketed(&System.system_time/0, fn ->
          Telemetry.span_write(metadata, fn -> :ok end)
        end)

      assert_receive {:telemetry, [:influx_elixir, :write, :start], measurements, recv_meta}
      assert measurements.system_time >= before and measurements.system_time <= later
      assert recv_meta.database === "testdb"
      assert recv_meta.point_count === 1
      assert recv_meta.bytes === 42
    end

    test "emits :stop event after the function returns" do
      Forward.attach([[:influx_elixir, :write, :stop]])
      metadata = %{database: "testdb", point_count: 2, bytes: 100}

      assert Telemetry.span_write(metadata, timed(fn -> {:ok, :written} end)) === {:ok, :written}

      assert_receive {:telemetry, [:influx_elixir, :write, :stop], measurements, recv_meta}
      assert_spans_function(measurements.duration)
      assert recv_meta.database === "testdb"
    end

    test "emits :exception event when the function raises" do
      Forward.attach([[:influx_elixir, :write, :exception]])
      metadata = %{database: "testdb", point_count: 1, bytes: 10}

      assert_raise RuntimeError, "boom", fn ->
        Telemetry.span_write(metadata, timed(fn -> raise "boom" end))
      end

      assert_receive {:telemetry, [:influx_elixir, :write, :exception], measurements, recv_meta}

      assert_spans_function(measurements.duration)
      assert recv_meta.database === "testdb"
      assert recv_meta.kind === :error
    end

    test "does not emit :stop event when the function raises" do
      Forward.attach([[:influx_elixir, :write, :stop]])
      metadata = %{database: "testdb", point_count: 1, bytes: 10}

      assert_raise RuntimeError, fn ->
        Telemetry.span_write(metadata, fn -> raise "oops" end)
      end

      # Handlers run in the caller, so the event would already be in the mailbox.
      refute_received {:telemetry, [:influx_elixir, :write, :stop], _, _}
    end
  end

  describe "span_query/2" do
    test "emits :start event before the function executes" do
      Forward.attach([[:influx_elixir, :query, :start]])
      metadata = %{database: "testdb", transport: :http}

      {before, later} =
        bracketed(&System.system_time/0, fn ->
          Telemetry.span_query(metadata, fn -> {:ok, []} end)
        end)

      assert_receive {:telemetry, [:influx_elixir, :query, :start], measurements, recv_meta}
      assert measurements.system_time >= before and measurements.system_time <= later
      assert recv_meta.database === "testdb"
      assert recv_meta.transport === :http
    end

    test "emits :stop event after the function returns" do
      Forward.attach([[:influx_elixir, :query, :stop]])
      metadata = %{database: "testdb", transport: :flight}

      assert Telemetry.span_query(metadata, timed(fn -> {:ok, [%{"col" => 1}]} end)) ===
               {:ok, [%{"col" => 1}]}

      assert_receive {:telemetry, [:influx_elixir, :query, :stop], measurements, recv_meta}
      assert_spans_function(measurements.duration)
      assert recv_meta.transport === :flight
    end

    test "emits :exception event when the function raises" do
      Forward.attach([[:influx_elixir, :query, :exception]])
      metadata = %{database: "testdb", transport: :http}

      assert_raise ArgumentError, "bad query", fn ->
        Telemetry.span_query(metadata, timed(fn -> raise ArgumentError, "bad query" end))
      end

      assert_receive {:telemetry, [:influx_elixir, :query, :exception], measurements, recv_meta}

      assert_spans_function(measurements.duration)
      assert recv_meta.database === "testdb"
      assert recv_meta.kind === :error
    end

    test "does not emit :stop event when the function raises" do
      Forward.attach([[:influx_elixir, :query, :stop]])
      metadata = %{database: "testdb", transport: :http}

      assert_raise RuntimeError, fn ->
        Telemetry.span_query(metadata, fn -> raise "fail" end)
      end

      # Handlers run in the caller, so the event would already be in the mailbox.
      refute_received {:telemetry, [:influx_elixir, :query, :stop], _, _}
    end
  end

  # `system_time` is wall-clock time and `monotonic_time` the monotonic
  # clock's, in native units: each lies between the readings taken around
  # the emit, which an arbitrary offset or the wrong clock would fail.
  defp assert_start_times(emit) do
    before = {System.system_time(), System.monotonic_time()}
    emit.()
    {before, {System.system_time(), System.monotonic_time()}}
  end

  describe "write_start/1" do
    test "emits the event with system_time measurement" do
      Forward.attach([[:influx_elixir, :write, :start]])
      meta = %{database: "mydb", point_count: 5, bytes: 200}

      {{from_system, from_mono}, {to_system, to_mono}} =
        assert_start_times(fn -> Telemetry.write_start(meta) end)

      assert_receive {:telemetry, [:influx_elixir, :write, :start], measurements, recv_meta}
      assert measurements.system_time >= from_system and measurements.system_time <= to_system
      assert measurements.monotonic_time >= from_mono and measurements.monotonic_time <= to_mono
      assert recv_meta === meta
    end
  end

  describe "write_stop/2" do
    test "emits the event with duration measurement" do
      Forward.attach([[:influx_elixir, :write, :stop]])
      meta = %{database: "mydb", point_count: 5, bytes: 200}

      {before, later} =
        bracketed(&System.monotonic_time/0, fn -> Telemetry.write_stop(12_345, meta) end)

      assert_receive {:telemetry, [:influx_elixir, :write, :stop], measurements, recv_meta}
      assert measurements.duration === 12_345
      assert measurements.monotonic_time >= before and measurements.monotonic_time <= later
      assert recv_meta === meta
    end
  end

  describe "write_exception/2" do
    test "emits the event with duration measurement" do
      Forward.attach([[:influx_elixir, :write, :exception]])
      meta = %{database: "mydb", kind: :error, reason: :timeout, stacktrace: []}

      {before, later} =
        bracketed(&System.monotonic_time/0, fn -> Telemetry.write_exception(99_999, meta) end)

      assert_receive {:telemetry, [:influx_elixir, :write, :exception], measurements, recv_meta}

      assert measurements.duration === 99_999
      assert measurements.monotonic_time >= before and measurements.monotonic_time <= later
      assert recv_meta === meta
    end
  end

  describe "query_start/1" do
    test "emits the event with system_time measurement" do
      Forward.attach([[:influx_elixir, :query, :start]])
      meta = %{database: "mydb", transport: :http}

      {{from_system, from_mono}, {to_system, to_mono}} =
        assert_start_times(fn -> Telemetry.query_start(meta) end)

      assert_receive {:telemetry, [:influx_elixir, :query, :start], measurements, recv_meta}
      assert measurements.system_time >= from_system and measurements.system_time <= to_system
      assert measurements.monotonic_time >= from_mono and measurements.monotonic_time <= to_mono
      assert recv_meta === meta
    end
  end

  describe "query_stop/2" do
    test "emits the event with duration measurement" do
      Forward.attach([[:influx_elixir, :query, :stop]])
      meta = %{database: "mydb", transport: :flight, row_count: 100}

      {before, later} =
        bracketed(&System.monotonic_time/0, fn -> Telemetry.query_stop(55_000, meta) end)

      assert_receive {:telemetry, [:influx_elixir, :query, :stop], measurements, recv_meta}
      assert measurements.duration === 55_000
      assert measurements.monotonic_time >= before and measurements.monotonic_time <= later
      assert recv_meta === meta
    end
  end

  describe "query_exception/2" do
    test "emits the event with duration measurement" do
      Forward.attach([[:influx_elixir, :query, :exception]])

      meta = %{
        database: "mydb",
        transport: :http,
        kind: :error,
        reason: :network_error,
        stacktrace: []
      }

      {before, later} =
        bracketed(&System.monotonic_time/0, fn -> Telemetry.query_exception(77_777, meta) end)

      assert_receive {:telemetry, [:influx_elixir, :query, :exception], measurements, recv_meta}

      assert measurements.duration === 77_777
      assert measurements.monotonic_time >= before and measurements.monotonic_time <= later
      assert recv_meta === meta
    end
  end
end
