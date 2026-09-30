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
    test "the :database option is the write target for every flush", %{conn: conn} do
      # Regression: :database was stored but never forwarded, so flushes
      # landed in the connection's default database instead.
      pid = start_writer(conn, database: "target_db")

      :ok = BatchWriter.write_sync(pid, "cpu value=7.0")

      assert {:ok, [%{"value" => 7.0}]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: "target_db")

      assert {:ok, [%{"name" => "_internal"}, %{"name" => "target_db"}]} =
               Local.list_databases(conn)
    end

    test "starts with empty buffer and zeroed stats", %{conn: conn} do
      pid = start_writer(conn)
      assert {:ok, stats} = BatchWriter.stats(pid)
      assert stats.total_writes == 0
      assert stats.total_errors == 0
      assert stats.total_bytes == 0
    end
  end

  # The rows of `measurement` in the writer's database, in time order.
  defp stored(conn, measurement) do
    case Local.query_sql(conn, "SELECT * FROM #{measurement} ORDER BY time", database: "test_db") do
      {:ok, rows} -> rows
      {:error, _no_table_yet} -> []
    end
  end

  describe "write/3" do
    test "buffers lines and Points until a flush stores them", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, "cpu value=1.0 1")
      :ok = BatchWriter.write(pid, Point.new("cpu", %{"value" => 0.64}, timestamp: 2))

      assert stored(conn, "cpu") == []
      :ok = BatchWriter.flush(pid)
      assert [%{"value" => 1.0}, %{"value" => 0.64}] = stored(conn, "cpu")
    end

    test "flushes on its own when the buffer reaches batch_size", %{conn: conn} do
      pid = start_writer(conn, batch_size: 3, flush_interval_ms: 60_000)

      :ok = BatchWriter.write(pid, "cpu value=1.0 1")
      :ok = BatchWriter.write(pid, "cpu value=2.0 2")
      assert stored(conn, "cpu") == []

      :ok = BatchWriter.write(pid, "cpu value=3.0 3")
      assert length(stored(conn, "cpu")) == 3
      assert {:ok, %{total_writes: 1}} = BatchWriter.stats(pid)
    end
  end

  describe "write_sync/3" do
    test "returns once its line, and everything buffered before it, is stored",
         %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, "cpu value=1.0 1")

      assert :ok = BatchWriter.write_sync(pid, Point.new("cpu", %{"value" => 2.0}, timestamp: 2))
      assert [%{"value" => 1.0}, %{"value" => 2.0}] = stored(conn, "cpu")
      assert {:ok, %{total_writes: 1}} = BatchWriter.stats(pid)
    end
  end

  describe "flush/2" do
    test "an empty buffer writes nothing", %{conn: conn} do
      pid = start_writer(conn)
      assert :ok = BatchWriter.flush(pid)
      assert {:ok, %{total_writes: 0, total_bytes: 0}} = BatchWriter.stats(pid)
    end

    test "writes the buffer as one request and empties it", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, "cpu value=1.0 1")
      :ok = BatchWriter.write(pid, "cpu value=2.0 2")
      :ok = BatchWriter.flush(pid)
      :ok = BatchWriter.flush(pid)

      assert length(stored(conn, "cpu")) == 2
      payload = "cpu value=1.0 1\ncpu value=2.0 2"
      assert {:ok, %{total_writes: 1, total_bytes: bytes}} = BatchWriter.stats(pid)
      assert bytes == byte_size(payload)
    end

    test "the timeout arities write and flush as the defaults do", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, "cpu value=1.0 1", 10_000)
      :ok = BatchWriter.flush(pid, 10_000)
      :ok = BatchWriter.write_sync(pid, "cpu value=2.0 2", 10_000)
      assert length(stored(conn, "cpu")) == 2
    end

    test "the timeout arities bound the wait for the reply", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)

      # A suspended writer cannot reply, so each call must give up after
      # exactly the timeout it was handed.
      :ok = :sys.suspend(pid)

      assert {:timeout, _reason} = catch_exit(BatchWriter.write(pid, "cpu value=1.0 1", 20))
      assert {:timeout, _reason} = catch_exit(BatchWriter.flush(pid, 20))
      assert {:timeout, _reason} = catch_exit(BatchWriter.write_sync(pid, "cpu value=2.0 2", 20))

      :ok = :sys.resume(pid)
    end

    test "forwards :write_opts to Writer.write/3 on flush" do
      # write_opts' :database wins over the writer's :database.
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

      assert {:ok, [row]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: "metrics")

      assert row["value"] == 1.0

      assert {:ok, [%{"name" => "_internal"}, %{"name" => "metrics"}]} =
               Local.list_databases(conn)
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
    test "total_writes and total_bytes accumulate across flushes", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)

      :ok = BatchWriter.write(pid, "cpu v=1.0")
      :ok = BatchWriter.flush(pid)
      :ok = BatchWriter.write(pid, "cpu v=22.0")
      :ok = BatchWriter.flush(pid)

      assert {:ok, %{total_writes: 2, total_bytes: 19, total_errors: 0}} =
               BatchWriter.stats(pid)
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
    for jitter_ms <- [0, 20] do
      test "automatically flushes after flush_interval_ms with jitter_ms: #{jitter_ms}",
           %{conn: conn} do
        pid = start_writer(conn, flush_interval_ms: 10, jitter_ms: unquote(jitter_ms))
        :ok = BatchWriter.write(pid, "cpu value=1.0")

        wait_until(fn -> match?({:ok, %{total_writes: 1}}, BatchWriter.stats(pid)) end)

        assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM cpu", database: "test_db")
        assert row["value"] == 1.0
      end
    end

    # Regression: do_flush/1 cancelled the timer and only the timer's own
    # handler re-armed it, so after a size-triggered flush the interval flush
    # never fired again and the next write stayed buffered.
    test "the timer keeps flushing after a size-triggered flush", %{conn: conn} do
      pid = start_writer(conn, batch_size: 2, flush_interval_ms: 50)

      :ok = BatchWriter.write(pid, "cpu value=1.0 1")
      :ok = BatchWriter.write(pid, "cpu value=2.0 2")
      assert {:ok, %{total_writes: 1}} = BatchWriter.stats(pid)

      :ok = BatchWriter.write(pid, "cpu value=3.0 3")
      wait_until(fn -> match?({:ok, %{total_writes: 2}}, BatchWriter.stats(pid)) end)

      bytes = byte_size("cpu value=1.0 1\ncpu value=2.0 2") + byte_size("cpu value=3.0 3")

      assert {:ok, %{total_writes: 2, total_errors: 0, total_bytes: ^bytes}} =
               BatchWriter.stats(pid)

      assert {:ok, rows} = Local.query_sql(conn, "SELECT value FROM cpu", database: "test_db")
      assert rows |> Enum.map(& &1["value"]) |> Enum.sort() == [1.0, 2.0, 3.0]
    end

    test "the timer keeps flushing after an explicit flush/2", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 50)

      :ok = BatchWriter.write(pid, "cpu value=1.0 1")
      :ok = BatchWriter.flush(pid)
      assert {:ok, %{total_writes: 1}} = BatchWriter.stats(pid)

      :ok = BatchWriter.write(pid, "cpu value=2.0 2")
      wait_until(fn -> match?({:ok, %{total_writes: 2}}, BatchWriter.stats(pid)) end)

      bytes = byte_size("cpu value=1.0 1") + byte_size("cpu value=2.0 2")

      assert {:ok, %{total_writes: 2, total_errors: 0, total_bytes: ^bytes}} =
               BatchWriter.stats(pid)
    end

    test "the timer keeps flushing after a write_sync/3", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 50)

      :ok = BatchWriter.write_sync(pid, "cpu value=1.0 1")
      :ok = BatchWriter.write(pid, "cpu value=2.0 2")
      wait_until(fn -> match?({:ok, %{total_writes: 2}}, BatchWriter.stats(pid)) end)

      assert {:ok, %{total_writes: 2, total_errors: 0}} = BatchWriter.stats(pid)
    end
  end

  describe "shutdown" do
    # A supervisor stops a child with an exit signal, which kills a process
    # that does not trap exits before terminate/2 can run: the buffer was
    # lost on every application shutdown and remove_connection/1.
    # (GenServer.stop runs terminate/2 either way, so it never showed.)
    test "a supervisor stopping the writer flushes the buffer", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, "cpu value=42.0")

      :ok = stop_supervised!(BatchWriter)

      assert {:ok, [%{"value" => 42.0}]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: "test_db")
    end

    test ":shutdown sets how long the supervisor waits for the final flush" do
      assert %{shutdown: 5_000} = BatchWriter.child_spec([])
      assert %{shutdown: 30_000} = BatchWriter.child_spec(shutdown: 30_000)
    end
  end

  describe "start_link/1 option validation" do
    # Each of these used to start: `batch_size: 0` then refused every write
    # as :buffer_full, a misspelt key was ignored for its default, and a
    # string batch size crashed the writer on its first write.
    test "a misconfiguration is refused before the writer starts", %{conn: conn} do
      for {bad, key} <- [
            {[batch_size: 0], :batch_size},
            {[batch_size: "10"], :batch_size},
            {[flush_interval_ms: 0], :flush_interval_ms},
            {[max_retries: -1], :max_retries},
            {[shutdown: :later], :shutdown},
            {[flush_interval: 50], [:flush_interval]}
          ] do
        assert {:error, %NimbleOptions.ValidationError{key: ^key}} =
                 BatchWriter.start_link([connection: conn, database: "test_db"] ++ bad),
               inspect(bad)
      end

      assert {:error, %NimbleOptions.ValidationError{key: :connection}} =
               BatchWriter.start_link(database: "test_db")
    end
  end

  describe "precision" do
    test "a Point's DateTime is written in the flushes' :precision", %{conn: conn} do
      # It was always nanoseconds: with `precision: :second` the server
      # refused it as out of range (verified), and the double stored a time
      # its queries could not render.
      pid = start_writer(conn, flush_interval_ms: 60_000, write_opts: [precision: :millisecond])
      dt = ~U[2026-09-28 12:00:00.123456Z]

      :ok = BatchWriter.write_sync(pid, Point.new("cpu", %{"v" => 1}, timestamp: dt))

      assert [%{"time" => ~U[2026-09-28 12:00:00.123000Z]}] = stored(conn, "cpu")
    end
  end

  describe "invalid points" do
    test "are the caller's error and leave the writer and its buffer intact", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, "cpu value=1.0")

      # Encoding used to run inside the writer: encode! raised there and
      # the crash lost every caller's buffered lines.
      assert {:error, :empty_fields} = BatchWriter.write(pid, Point.new("cpu", %{}))
      assert {:error, :empty_fields} = BatchWriter.write_sync(pid, Point.new("cpu", %{}))

      :ok = BatchWriter.flush(pid)

      assert {:ok, [%{"value" => 1.0}]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: "test_db")
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

      :ok = BatchWriter.write_sync(pid, "cpu value=1.0 1")
      assert stored(conn, "cpu") == []
      :ok = BatchWriter.write_sync(pid, "cpu value=2.0 2")

      assert {:ok, %{total_writes: 1}} = BatchWriter.stats(pid)
      assert length(stored(conn, "cpu")) == 2
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

    # That later writes are held while the chain is in flight is the
    # backpressure tests' subject, below.
    test "a transport error is retried, and counted once, when its chain gives up",
         %{http_conn: conn} do
      pid =
        start_writer(conn,
          client: InfluxElixir.Client.HTTP,
          batch_size: 1,
          flush_interval_ms: 60_000,
          max_retries: 2,
          base_retry_delay_ms: 20
        )

      # batch_size 1: the write flushes at once and fails; the retries
      # (20 ms, then 40 ms) fail too, and only then is the error counted.
      :ok = BatchWriter.write(pid, "cpu value=1.0")
      assert {:ok, %{total_errors: 0, total_writes: 0}} = BatchWriter.stats(pid)

      wait_until(fn -> match?({:ok, %{total_errors: 1}}, BatchWriter.stats(pid)) end)
      assert {:ok, %{total_errors: 1, total_writes: 0, total_bytes: 0}} = BatchWriter.stats(pid)
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

      assert {:ok, %{total_errors: 1, total_writes: 0}} = BatchWriter.stats(pid)
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

      assert {:ok, %{total_errors: 2, total_writes: 0}} = BatchWriter.stats(pid)
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

    test "errors are counted per chain, not per attempt", %{http_conn: conn} do
      pid =
        start_writer(conn,
          client: InfluxElixir.Client.HTTP,
          flush_interval_ms: 60_000,
          max_retries: 2,
          base_retry_delay_ms: 1
        )

      # First attempt plus two retries all fail; the chain records one error.
      assert {:error, {:connection_error, _reason}} =
               BatchWriter.write_sync(pid, "cpu value=1.0")

      assert {:ok, %{total_errors: 1, total_writes: 0}} = BatchWriter.stats(pid)
      assert Process.alive?(pid)
    end

    test "backpressure holds while any chain is in flight, not just the first",
         %{http_conn: conn} do
      # With max_retries: 1 a chain lasts 2 * base_retry_delay_ms. Chain 1
      # ends 3s after it starts; chain 2 starts 1.2s later, so it is still
      # retrying for 1.2s after chain 1 ends. Every margin is over a second.
      pid =
        start_writer(conn,
          client: InfluxElixir.Client.HTTP,
          batch_size: 1,
          flush_interval_ms: 60_000,
          max_retries: 1,
          base_retry_delay_ms: 1_500
        )

      :ok = BatchWriter.write(pid, "cpu value=1.0")
      Process.sleep(1_200)
      :ok = BatchWriter.write(pid, "cpu value=2.0")
      :ok = BatchWriter.flush(pid)

      wait_until(fn -> match?({:ok, %{total_errors: 1}}, BatchWriter.stats(pid)) end, 10_000)

      # Chain 2 is still retrying. The end of chain 1 used to clear the
      # single in-flight marker, so these flushed into new chains instead
      # of being held to the backpressure bound.
      for i <- 1..10, do: assert(:ok = BatchWriter.write(pid, "cpu value=#{i}.5"))
      assert {:error, :buffer_full} = BatchWriter.write(pid, "cpu value=11.5")
      assert {:ok, %{total_errors: 1}} = BatchWriter.stats(pid)
    end

    test "a write_sync caller waiting on a chain is answered at shutdown", %{http_conn: conn} do
      pid =
        start_writer(conn,
          client: InfluxElixir.Client.HTTP,
          flush_interval_ms: 60_000,
          max_retries: 3,
          base_retry_delay_ms: 60_000
        )

      caller = Task.async(fn -> BatchWriter.write_sync(pid, "cpu value=1.0") end)

      # The caller is blocked on its reply and the writer has nothing
      # queued: the first attempt has failed, the chain waits to retry.
      wait_until(fn ->
        Process.info(caller.pid, :status) == {:status, :waiting} and
          Process.info(pid, :message_queue_len) == {:message_queue_len, 0}
      end)

      :ok = stop_supervised!(BatchWriter)

      # terminate/2 writes the chain's batch once more and answers with that.
      assert {:error, {:connection_error, _reason}} = Task.await(caller)
    end

    test "with max_retries: 0 a transport error is recorded on the first flush",
         %{http_conn: conn} do
      pid =
        start_writer(conn,
          client: InfluxElixir.Client.HTTP,
          flush_interval_ms: 60_000,
          max_retries: 0
        )

      assert {:error, {:connection_error, _reason}} =
               BatchWriter.write_sync(pid, "cpu value=1.0")

      assert {:ok, %{total_errors: 1, total_writes: 0}} = BatchWriter.stats(pid)
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

      # The caller gets the engine's 400, and the batch is counted as an error.
      assert {:error, %{status: 400}} = BatchWriter.write_sync(pid, "!!!")
      assert {:ok, %{total_errors: 1, total_writes: 0}} = BatchWriter.stats(pid)
    end
  end
end
