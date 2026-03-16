defmodule InfluxElixir.Write.BatchWriterTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Write.{BatchWriter, Point}

  setup do
    {:ok, conn} = Local.start()
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  defp start_writer(conn, extra_opts \\ []) do
    defaults = [
      connection: conn,
      database: "test_db",
      batch_size: 10,
      flush_interval_ms: 100,
      jitter_ms: 0,
      max_retries: 1
    ]

    opts = Keyword.merge(defaults, extra_opts)
    start_supervised!({BatchWriter, opts})
  end

  describe "start_link/1" do
    test "starts the GenServer and returns a pid", %{conn: conn} do
      pid = start_writer(conn)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "starts with empty buffer and zeroed stats", %{conn: conn} do
      pid = start_writer(conn)
      assert {:ok, stats} = BatchWriter.stats(pid)
      assert stats.total_writes == 0
      assert stats.total_errors == 0
      assert stats.total_bytes == 0
    end
  end

  describe "write/2" do
    test "accepts a line protocol binary and returns :ok", %{conn: conn} do
      pid = start_writer(conn)
      assert :ok = BatchWriter.write(pid, "cpu value=1.0")
    end

    test "accepts a Point struct and returns :ok", %{conn: conn} do
      pid = start_writer(conn)
      point = Point.new("cpu", %{"value" => 0.64})
      assert :ok = BatchWriter.write(pid, point)
    end

    test "flushes when buffer reaches batch_size via explicit flush",
         %{conn: conn} do
      pid = start_writer(conn, batch_size: 3, flush_interval_ms: 60_000)

      Enum.each(1..3, fn i ->
        :ok = BatchWriter.write(pid, "cpu value=#{i}.0")
      end)

      # Explicitly flush to ensure all buffered data is written
      :ok = BatchWriter.flush(pid)

      {:ok, stats} = BatchWriter.stats(pid)
      assert stats.total_writes >= 1
      assert stats.total_bytes > 0
    end

    test "rejects writes when buffer is at capacity", %{conn: conn} do
      pid =
        start_writer(conn,
          batch_size: 3,
          flush_interval_ms: 60_000,
          max_retries: 0
        )

      # Set buffer_size to max_buffer (3 * 10 = 30) via state replacement
      :sys.replace_state(pid, fn state ->
        %{state | buffer_size: 30}
      end)

      assert {:error, :buffer_full} =
               BatchWriter.write(pid, "cpu value=999.0")
    end
  end

  describe "write_sync/2" do
    test "returns :ok after flush completes", %{conn: conn} do
      pid = start_writer(conn)
      assert :ok = BatchWriter.write_sync(pid, "cpu value=1.0")
    end

    test "increments total_writes after successful sync write",
         %{conn: conn} do
      pid = start_writer(conn)
      :ok = BatchWriter.write_sync(pid, "cpu value=1.0")

      {:ok, stats} = BatchWriter.stats(pid)
      assert stats.total_writes == 1
    end

    test "with no_sync: true behaves like async write", %{conn: conn} do
      pid = start_writer(conn, no_sync: true)
      assert :ok = BatchWriter.write_sync(pid, "cpu value=1.0")
    end

    test "accepts a Point struct", %{conn: conn} do
      pid = start_writer(conn)
      point = Point.new("mem", %{"free" => 512})
      assert :ok = BatchWriter.write_sync(pid, point)
    end
  end

  describe "flush/1" do
    test "returns :ok immediately on empty buffer", %{conn: conn} do
      pid = start_writer(conn)
      assert :ok = BatchWriter.flush(pid)
    end

    test "flushes buffered writes and increments total_writes",
         %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, "cpu value=1.0")
      :ok = BatchWriter.write(pid, "cpu value=2.0")
      :ok = BatchWriter.flush(pid)

      {:ok, stats} = BatchWriter.stats(pid)
      assert stats.total_writes == 1
      assert stats.total_bytes > 0
    end

    test "clears the buffer after flush", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      Enum.each(1..3, fn i -> BatchWriter.write(pid, "cpu v=#{i}.0") end)
      :ok = BatchWriter.flush(pid)

      # A second flush on empty buffer should also succeed
      assert :ok = BatchWriter.flush(pid)
    end
  end

  describe "stats/1" do
    test "returns {:ok, stats_map}", %{conn: conn} do
      pid = start_writer(conn)
      assert {:ok, stats} = BatchWriter.stats(pid)
      assert is_map(stats)
      assert Map.has_key?(stats, :total_writes)
      assert Map.has_key?(stats, :total_errors)
      assert Map.has_key?(stats, :total_bytes)
    end

    test "total_bytes accumulates correctly", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      payload = "cpu value=1.0"
      :ok = BatchWriter.write(pid, payload)
      :ok = BatchWriter.flush(pid)

      {:ok, stats} = BatchWriter.stats(pid)
      assert stats.total_bytes == byte_size(payload)
    end

    test "total_writes increments on each flush", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)

      :ok = BatchWriter.write(pid, "cpu v=1.0")
      :ok = BatchWriter.flush(pid)
      :ok = BatchWriter.write(pid, "cpu v=2.0")
      :ok = BatchWriter.flush(pid)

      {:ok, stats} = BatchWriter.stats(pid)
      assert stats.total_writes == 2
    end
  end

  describe "timer-based flush" do
    test "automatically flushes after flush_interval_ms", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 50)
      :ok = BatchWriter.write(pid, "cpu value=1.0")

      :timer.sleep(200)

      {:ok, stats} = BatchWriter.stats(pid)
      assert stats.total_writes >= 1
    end
  end

  describe "handle_continue/2" do
    test "schedules flush timer after init", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 50)

      # The timer should be set — verify by checking state
      state = :sys.get_state(pid)
      assert state.timer_ref != nil
    end
  end

  describe "terminate/2" do
    test "flushes buffered data on shutdown", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, "cpu value=42.0")

      # Stop the GenServer — terminate/2 should flush
      GenServer.stop(pid)

      # Verify the data was written to the LocalClient
      {:ok, rows} =
        Local.query_sql(conn, "SELECT * FROM cpu", database: "default")

      assert rows != []
    end
  end

  describe "GenServer lifecycle" do
    test "can be stopped cleanly", %{conn: conn} do
      pid = start_writer(conn)
      assert Process.alive?(pid)
      GenServer.stop(pid)
      refute Process.alive?(pid)
    end
  end

  describe "struct-based state" do
    test "state is a BatchWriter struct", %{conn: conn} do
      pid = start_writer(conn)
      state = :sys.get_state(pid)
      assert %BatchWriter{} = state
    end

    test "struct fields match configured options", %{conn: conn} do
      pid =
        start_writer(conn,
          batch_size: 42,
          flush_interval_ms: 500,
          max_retries: 5
        )

      state = :sys.get_state(pid)
      assert state.batch_size == 42
      assert state.flush_interval_ms == 500
      assert state.max_retries == 5
    end
  end

  describe "write_sync edge cases" do
    test "write_sync with no_sync triggers batch flush at batch_size",
         %{conn: conn} do
      pid =
        start_writer(conn,
          no_sync: true,
          batch_size: 2,
          flush_interval_ms: 60_000
        )

      :ok = BatchWriter.write_sync(pid, "cpu value=1.0")
      :ok = BatchWriter.write_sync(pid, "cpu value=2.0")

      # batch_size=2, no_sync=true → maybe_flush_on_batch triggers do_flush
      {:ok, stats} = BatchWriter.stats(pid)
      assert stats.total_writes >= 1
    end

    test "write_sync with no_sync under batch_size does not flush",
         %{conn: conn} do
      pid =
        start_writer(conn,
          no_sync: true,
          batch_size: 10,
          flush_interval_ms: 60_000
        )

      :ok = BatchWriter.write_sync(pid, "cpu value=1.0")

      {:ok, stats} = BatchWriter.stats(pid)
      assert stats.total_writes == 0

      state = :sys.get_state(pid)
      assert state.buffer_size == 1
    end

    test "write_sync rejects when buffer is full", %{conn: conn} do
      pid =
        start_writer(conn,
          batch_size: 3,
          flush_interval_ms: 60_000,
          max_retries: 0
        )

      :sys.replace_state(pid, fn state ->
        %{state | buffer_size: 30}
      end)

      assert {:error, :buffer_full} =
               BatchWriter.write_sync(pid, "cpu value=999.0")
    end
  end

  describe "jitter" do
    test "jitter_ms is applied to flush scheduling", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 50, jitter_ms: 10)

      state = :sys.get_state(pid)
      assert state.timer_ref != nil
      assert state.jitter_ms == 10
    end
  end

  describe "error paths via invalid line protocol" do
    test "flush with unparseable payload and max_retries: 0 increments errors",
         %{conn: conn} do
      pid =
        start_writer(conn,
          flush_interval_ms: 60_000,
          max_retries: 0
        )

      # Inject invalid line protocol directly into the buffer via write
      # "!!!" is not valid line protocol — Local returns {:error, %{status: 400, ...}}
      :ok = BatchWriter.write(pid, "!!!")
      :ok = BatchWriter.flush(pid)

      {:ok, stats} = BatchWriter.stats(pid)
      assert stats.total_errors == 1
      assert stats.total_writes == 0
    end

    test "flush with unparseable payload and max_retries > 0 schedules retry",
         %{conn: conn} do
      pid =
        start_writer(conn,
          flush_interval_ms: 60_000,
          max_retries: 2
        )

      :ok = BatchWriter.write(pid, "!!!")
      :ok = BatchWriter.flush(pid)

      state = :sys.get_state(pid)
      assert state.retry_attempt == 1
      assert state.retry_payload != nil
      assert state.buffer == []
      assert state.buffer_size == 0
    end

    test "retry exhausts max_retries and records error", %{conn: conn} do
      pid =
        start_writer(conn,
          flush_interval_ms: 60_000,
          max_retries: 1
        )

      :ok = BatchWriter.write(pid, "!!!")
      :ok = BatchWriter.flush(pid)

      # Wait for retry to fire and exhaust (base delay ~200ms for attempt 1)
      :timer.sleep(500)

      {:ok, stats} = BatchWriter.stats(pid)
      assert stats.total_errors == 1

      state = :sys.get_state(pid)
      assert state.retry_payload == nil
      assert state.retry_attempt == 0
    end

    test "write_sync with pending_sync gets reply on error flush",
         %{conn: conn} do
      pid =
        start_writer(conn,
          flush_interval_ms: 60_000,
          max_retries: 0
        )

      # write_sync should return the error (not hang)
      result = BatchWriter.write_sync(pid, "!!!")
      assert {:error, _reason} = result
    end
  end
end
