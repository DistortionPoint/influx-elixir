defmodule InfluxElixir.TelemetryTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Telemetry

  # ---------- Helpers ----------

  defp unique_handler_id(suffix) do
    "influx-elixir-test-#{inspect(self())}-#{suffix}"
  end

  defp attach_handler(handler_id, event) do
    test_pid = self()

    :telemetry.attach(
      handler_id,
      event,
      fn ev, measurements, metadata, _config ->
        send(test_pid, {:telemetry, ev, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # ---------- span_write/2 ----------

  describe "span_write/2" do
    test "emits :start event before the function executes" do
      handler_id = unique_handler_id("span_write_start")
      attach_handler(handler_id, [:influx_elixir, :write, :start])

      metadata = %{database: "testdb", point_count: 1, bytes: 42}

      Telemetry.span_write(metadata, fn -> :ok end)

      assert_receive {:telemetry, [:influx_elixir, :write, :start], measurements, recv_meta}
      assert is_integer(measurements.system_time)
      assert recv_meta.database == "testdb"
      assert recv_meta.point_count == 1
      assert recv_meta.bytes == 42
    end

    test "emits :stop event after the function returns" do
      handler_id = unique_handler_id("span_write_stop")
      attach_handler(handler_id, [:influx_elixir, :write, :stop])

      metadata = %{database: "testdb", point_count: 2, bytes: 100}

      result = Telemetry.span_write(metadata, fn -> {:ok, :written} end)

      assert result == {:ok, :written}
      assert_receive {:telemetry, [:influx_elixir, :write, :stop], measurements, recv_meta}
      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
      assert recv_meta.database == "testdb"
    end

    test "emits :exception event when the function raises" do
      handler_id = unique_handler_id("span_write_exception")
      attach_handler(handler_id, [:influx_elixir, :write, :exception])

      metadata = %{database: "testdb", point_count: 1, bytes: 10}

      assert_raise RuntimeError, "boom", fn ->
        Telemetry.span_write(metadata, fn -> raise "boom" end)
      end

      assert_receive {:telemetry, [:influx_elixir, :write, :exception], measurements, recv_meta}

      assert is_integer(measurements.duration)
      assert recv_meta.database == "testdb"
      assert recv_meta.kind == :error
    end

    test "does not emit :stop event when the function raises" do
      stop_handler_id = unique_handler_id("span_write_no_stop")
      attach_handler(stop_handler_id, [:influx_elixir, :write, :stop])

      metadata = %{database: "testdb", point_count: 1, bytes: 10}

      assert_raise RuntimeError, fn ->
        Telemetry.span_write(metadata, fn -> raise "oops" end)
      end

      refute_receive {:telemetry, [:influx_elixir, :write, :stop], _, _}
    end

    test "passes the function return value through unchanged" do
      handler_id = unique_handler_id("span_write_passthrough")
      attach_handler(handler_id, [:influx_elixir, :write, :stop])

      result =
        Telemetry.span_write(%{database: "db", point_count: 0, bytes: 0}, fn ->
          {:ok, %{rows: 3}}
        end)

      assert result == {:ok, %{rows: 3}}
    end
  end

  # ---------- span_query/2 ----------

  describe "span_query/2" do
    test "emits :start event before the function executes" do
      handler_id = unique_handler_id("span_query_start")
      attach_handler(handler_id, [:influx_elixir, :query, :start])

      metadata = %{database: "testdb", transport: :http}

      Telemetry.span_query(metadata, fn -> {:ok, []} end)

      assert_receive {:telemetry, [:influx_elixir, :query, :start], measurements, recv_meta}
      assert is_integer(measurements.system_time)
      assert recv_meta.database == "testdb"
      assert recv_meta.transport == :http
    end

    test "emits :stop event after the function returns" do
      handler_id = unique_handler_id("span_query_stop")
      attach_handler(handler_id, [:influx_elixir, :query, :stop])

      metadata = %{database: "testdb", transport: :flight}

      result = Telemetry.span_query(metadata, fn -> {:ok, [%{"col" => 1}]} end)

      assert result == {:ok, [%{"col" => 1}]}
      assert_receive {:telemetry, [:influx_elixir, :query, :stop], measurements, recv_meta}
      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
      assert recv_meta.transport == :flight
    end

    test "emits :exception event when the function raises" do
      handler_id = unique_handler_id("span_query_exception")
      attach_handler(handler_id, [:influx_elixir, :query, :exception])

      metadata = %{database: "testdb", transport: :http}

      assert_raise ArgumentError, "bad query", fn ->
        Telemetry.span_query(metadata, fn -> raise ArgumentError, "bad query" end)
      end

      assert_receive {:telemetry, [:influx_elixir, :query, :exception], measurements, recv_meta}

      assert is_integer(measurements.duration)
      assert recv_meta.database == "testdb"
      assert recv_meta.kind == :error
    end

    test "does not emit :stop event when the function raises" do
      stop_handler_id = unique_handler_id("span_query_no_stop")
      attach_handler(stop_handler_id, [:influx_elixir, :query, :stop])

      metadata = %{database: "testdb", transport: :http}

      assert_raise RuntimeError, fn ->
        Telemetry.span_query(metadata, fn -> raise "fail" end)
      end

      refute_receive {:telemetry, [:influx_elixir, :query, :stop], _, _}
    end

    test "passes the function return value through unchanged" do
      handler_id = unique_handler_id("span_query_passthrough")
      attach_handler(handler_id, [:influx_elixir, :query, :stop])

      result =
        Telemetry.span_query(%{database: "db", transport: :http}, fn ->
          {:ok, [%{"a" => 1}, %{"a" => 2}]}
        end)

      assert result == {:ok, [%{"a" => 1}, %{"a" => 2}]}
    end
  end

  # ---------- Manual write events ----------

  describe "write_start/1" do
    test "emits the event with system_time measurement" do
      handler_id = unique_handler_id("write_start")
      attach_handler(handler_id, [:influx_elixir, :write, :start])

      meta = %{database: "mydb", point_count: 5, bytes: 200}
      Telemetry.write_start(meta)

      assert_receive {:telemetry, [:influx_elixir, :write, :start], measurements, recv_meta}
      assert is_integer(measurements.system_time)
      assert recv_meta == meta
    end
  end

  describe "write_stop/2" do
    test "emits the event with duration measurement" do
      handler_id = unique_handler_id("write_stop")
      attach_handler(handler_id, [:influx_elixir, :write, :stop])

      meta = %{database: "mydb", point_count: 5, bytes: 200, compressed_bytes: 120}
      Telemetry.write_stop(12_345, meta)

      assert_receive {:telemetry, [:influx_elixir, :write, :stop], measurements, recv_meta}
      assert measurements.duration == 12_345
      assert recv_meta == meta
    end
  end

  describe "write_exception/2" do
    test "emits the event with duration measurement" do
      handler_id = unique_handler_id("write_exception")
      attach_handler(handler_id, [:influx_elixir, :write, :exception])

      meta = %{database: "mydb", kind: :error, reason: :timeout, stacktrace: []}
      Telemetry.write_exception(99_999, meta)

      assert_receive {:telemetry, [:influx_elixir, :write, :exception], measurements, recv_meta}

      assert measurements.duration == 99_999
      assert recv_meta == meta
    end
  end

  # ---------- Manual query events ----------

  describe "query_start/1" do
    test "emits the event with system_time measurement" do
      handler_id = unique_handler_id("query_start")
      attach_handler(handler_id, [:influx_elixir, :query, :start])

      meta = %{database: "mydb", transport: :http}
      Telemetry.query_start(meta)

      assert_receive {:telemetry, [:influx_elixir, :query, :start], measurements, recv_meta}
      assert is_integer(measurements.system_time)
      assert recv_meta == meta
    end
  end

  describe "query_stop/2" do
    test "emits the event with duration measurement" do
      handler_id = unique_handler_id("query_stop")
      attach_handler(handler_id, [:influx_elixir, :query, :stop])

      meta = %{database: "mydb", transport: :flight, row_count: 100}
      Telemetry.query_stop(55_000, meta)

      assert_receive {:telemetry, [:influx_elixir, :query, :stop], measurements, recv_meta}
      assert measurements.duration == 55_000
      assert recv_meta == meta
    end
  end

  describe "query_exception/2" do
    test "emits the event with duration measurement" do
      handler_id = unique_handler_id("query_exception")
      attach_handler(handler_id, [:influx_elixir, :query, :exception])

      meta = %{
        database: "mydb",
        transport: :http,
        kind: :error,
        reason: :network_error,
        stacktrace: []
      }

      Telemetry.query_exception(77_777, meta)

      assert_receive {:telemetry, [:influx_elixir, :query, :exception], measurements, recv_meta}

      assert measurements.duration == 77_777
      assert recv_meta == meta
    end
  end
end
