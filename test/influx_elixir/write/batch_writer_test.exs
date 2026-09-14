defmodule InfluxElixir.Write.BatchWriterTest do
  use ExUnit.Case, async: true

  # The writer logs every discarded batch and retry; the error-path tests
  # below trigger those deliberately, so keep the output out of the run.
  @moduletag capture_log: true

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

    test "the :database option is the write target for every flush", %{conn: conn} do
      # Regression: :database was stored but never forwarded, so flushes
      # landed in the connection default ("default") instead.
      pid = start_writer(conn, database: "target_db")

      :ok = BatchWriter.write_sync(pid, "cpu value=7.0")

      assert {:ok, [%{"value" => 7.0}]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: "target_db")

      assert {:error, %{status: 400}} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: "default")
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

    test "flush/2 accepts an explicit timeout", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, "cpu value=1.0")

      # Generous timeout — verifies the new arity accepts and forwards it.
      assert :ok = BatchWriter.flush(pid, 10_000)
    end

    test "write/3 accepts an explicit timeout", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      assert :ok = BatchWriter.write(pid, "cpu value=1.0", 10_000)
    end

    test "write_sync/3 accepts an explicit timeout", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      assert :ok = BatchWriter.write_sync(pid, "cpu value=1.0", 10_000)
    end

    test "GenServer.call timeout fires when the wait bound is exceeded",
         %{conn: conn} do
      # Spawn a writer with a queue of writes that the call-side cannot
      # process before a 1ms timeout — verifies the bound is honoured
      # rather than being capped by a hardcoded value.
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, "cpu value=1.0")

      # GenServer.call with timeout: 0 will exit with :timeout if the
      # handler doesn't reply within 0ms. We trap exits and verify.
      Process.flag(:trap_exit, true)
      caller = self()

      spawn_link(fn ->
        result =
          try do
            BatchWriter.flush(pid, 0)
          catch
            :exit, reason -> {:exit, reason}
          end

        send(caller, {:done, result})
      end)

      assert_receive {:done, {:exit, {:timeout, _}}}, 1_000
    end

    test "forwards :write_opts to Writer.write/3 on flush" do
      # Use a conn with two databases. Without :write_opts, Local would
      # fall back to the conn-level default ("default"). With
      # write_opts: [database: "metrics"], the flush must land there.
      {:ok, conn} = Local.start(databases: ["metrics"])
      on_exit(fn -> Local.stop(conn) end)

      pid =
        start_supervised!(
          {BatchWriter,
           connection: conn,
           database: "ignored",
           batch_size: 10,
           flush_interval_ms: 60_000,
           jitter_ms: 0,
           max_retries: 0,
           write_opts: [database: "metrics"]}
        )

      :ok = BatchWriter.write_sync(pid, "cpu value=1.0")

      # Data should be in "metrics", not "default"
      assert {:ok, [row]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: "metrics")

      assert row["value"] == 1.0

      assert {:error,
              %{status: 400, body: "Error during planning: table 'public.iox.cpu' not found"}} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: "default")
    end
  end

  describe "backoff_delay/3" do
    test "base_retry_delay_ms controls the backoff scale" do
      # base=100, attempt=1, no jitter → 100 * 2 = 200
      assert BatchWriter.backoff_delay(1, 0, 100) == 200

      # base=10, attempt=1, no jitter → 10 * 2 = 20
      assert BatchWriter.backoff_delay(1, 0, 10) == 20

      # base=100, attempt=3, no jitter → 100 * 8 = 800
      assert BatchWriter.backoff_delay(3, 0, 100) == 800
    end

    test "jitter adds randomness within the bound" do
      # base=100, attempt=1, jitter=50 → between 200 and 250
      delay = BatchWriter.backoff_delay(1, 50, 100)
      assert delay >= 200
      assert delay <= 250
    end
  end

  describe "stats/1" do
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

  # Poll a public-API predicate until it holds, with a hard deadline. This
  # replaces fixed sleeps: it never waits longer than needed and never
  # passes by luck on a slow machine.
  defp wait_until(fun, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within deadline")

      true ->
        Process.sleep(5)
        do_wait_until(fun, deadline)
    end
  end

  describe "timer-based flush" do
    test "automatically flushes after flush_interval_ms", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 10)
      :ok = BatchWriter.write(pid, "cpu value=1.0")

      wait_until(fn ->
        {:ok, stats} = BatchWriter.stats(pid)
        stats.total_writes >= 1
      end)

      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM cpu", database: "test_db")
      assert row["value"] == 1.0
    end
  end

  describe "terminate/2" do
    test "flushes buffered data on shutdown", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, "cpu value=42.0")

      # Stop the GenServer — terminate/2 should flush
      GenServer.stop(pid)

      # Verify the data was written to the writer's configured database
      assert {:ok, [%{"value" => 42.0}]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: "test_db")
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

      # The line is buffered, not dropped: an explicit flush lands it.
      :ok = BatchWriter.flush(pid)
      assert {:ok, %{total_writes: 1}} = BatchWriter.stats(pid)

      assert {:ok, [%{"value" => 1.0}]} =
               Local.query_sql(conn, "SELECT value FROM cpu", database: "test_db")
    end
  end

  describe "jitter" do
    test "the timer still flushes when jitter is configured", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 10, jitter_ms: 20)
      :ok = BatchWriter.write(pid, "cpu value=3.0")

      wait_until(fn ->
        {:ok, stats} = BatchWriter.stats(pid)
        stats.total_writes >= 1
      end)

      assert {:ok, [%{"value" => 3.0}]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: "test_db")
    end
  end

  describe "4xx responses" do
    test "invalid line protocol is discarded on the first flush even with retries left",
         %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000, max_retries: 2)

      :ok = BatchWriter.write(pid, "!!!")
      :ok = BatchWriter.flush(pid)

      {:ok, stats} = BatchWriter.stats(pid)
      assert stats.total_errors == 1
      assert stats.total_writes == 0

      # Nothing is pending: the next valid batch goes straight through.
      :ok = BatchWriter.write_sync(pid, "cpu value=1.0")
      assert {:ok, %{total_errors: 1, total_writes: 1}} = BatchWriter.stats(pid)
    end

    test "with max_retries: 0 the error is recorded immediately", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000, max_retries: 0)

      :ok = BatchWriter.write(pid, "!!!")
      :ok = BatchWriter.flush(pid)

      {:ok, stats} = BatchWriter.stats(pid)
      assert stats.total_errors == 1
      assert stats.total_writes == 0
    end
  end

  # Transport errors come from a real HTTP client pointed at a closed port
  # (nothing listens on 127.0.0.1:1) — no mocking. The :client option lets
  # one writer use Client.HTTP while the suite's configured client is Local.
  describe "retry path — transport errors" do
    setup do
      finch = :"bw_retry_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch, pools: %{default: [size: 1]}})

      conn = [host: "127.0.0.1", port: 1, scheme: :http, token: "t", finch_name: finch]
      {:ok, http_conn: conn}
    end

    test "a transport error starts a retry chain: nothing is counted yet and writes keep buffering",
         %{http_conn: conn} do
      pid =
        start_writer(conn,
          client: InfluxElixir.Client.HTTP,
          batch_size: 1,
          flush_interval_ms: 60_000,
          max_retries: 2,
          base_retry_delay_ms: 60_000
        )

      # batch_size 1: the write flushes at once, fails, and is now retrying.
      :ok = BatchWriter.write(pid, "cpu value=1.0")
      assert {:ok, %{total_errors: 0, total_writes: 0}} = BatchWriter.stats(pid)

      # Further writes are accepted and held (not flushed into a second
      # chain) while the first chain is in flight.
      :ok = BatchWriter.write(pid, "cpu value=2.0")
      assert {:ok, %{total_errors: 0, total_writes: 0}} = BatchWriter.stats(pid)
    end

    test "backpressure: the buffer is bounded at 10 x batch_size while a chain is in flight",
         %{http_conn: conn} do
      pid =
        start_writer(conn,
          client: InfluxElixir.Client.HTTP,
          batch_size: 1,
          flush_interval_ms: 60_000,
          max_retries: 2,
          base_retry_delay_ms: 60_000
        )

      :ok = BatchWriter.write(pid, "cpu value=0.0")

      for i <- 1..10 do
        assert :ok = BatchWriter.write(pid, "cpu value=#{i}.0")
      end

      assert {:error, :buffer_full} = BatchWriter.write(pid, "cpu value=11.0")
      assert {:error, :buffer_full} = BatchWriter.write_sync(pid, "cpu value=11.0")
    end

    test "retries exhaust max_retries and record one error", %{http_conn: conn} do
      pid =
        start_writer(conn,
          client: InfluxElixir.Client.HTTP,
          flush_interval_ms: 60_000,
          max_retries: 1,
          base_retry_delay_ms: 1
        )

      :ok = BatchWriter.write(pid, "cpu value=1.0")
      :ok = BatchWriter.flush(pid)

      wait_until(fn ->
        {:ok, stats} = BatchWriter.stats(pid)
        stats.total_errors == 1
      end)
    end

    test "the buffer deferred during a chain is flushed when the chain ends", %{http_conn: conn} do
      pid =
        start_writer(conn,
          client: InfluxElixir.Client.HTTP,
          batch_size: 1,
          flush_interval_ms: 60_000,
          max_retries: 1,
          base_retry_delay_ms: 1
        )

      :ok = BatchWriter.write(pid, "cpu value=1.0")
      :ok = BatchWriter.write(pid, "cpu value=2.0")

      # Chain 1 exhausts (error 1); the deferred line then flushes into
      # chain 2, which exhausts too (error 2).
      wait_until(fn ->
        {:ok, stats} = BatchWriter.stats(pid)
        stats.total_errors == 2
      end)
    end

    test "write_sync is answered with its own chain's final result", %{http_conn: conn} do
      pid =
        start_writer(conn,
          client: InfluxElixir.Client.HTTP,
          flush_interval_ms: 60_000,
          max_retries: 1,
          base_retry_delay_ms: 1
        )

      assert {:error, {:connection_error, _reason}} =
               BatchWriter.write_sync(pid, "cpu value=1.0")

      assert {:ok, %{total_errors: 1}} = BatchWriter.stats(pid)
    end
  end

  describe "error paths via invalid line protocol" do
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
