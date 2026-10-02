defmodule InfluxElixir.Write.BatchWriterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  # The writer logs every discarded batch and retry; the error-path tests
  # below trigger those deliberately, so keep the output out of the run.
  @moduletag capture_log: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Write.{BatchWriter, Point}

  setup do
    {:ok, conn} = Local.start()
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

      # No timestamp was written, so `time` is the clock's.
      assert conn |> Local.query_sql("SELECT * FROM cpu", database: "target_db") |> no_clock() ===
               {:ok, [%{"value" => 7.0}]}

      assert Local.list_databases(conn) ===
               {:ok, [%{"name" => "_internal"}, %{"name" => "target_db"}]}
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

  # A row written at 1 or 2 ns, which reads back as the epoch.
  defp epoch_row(value), do: %{"time" => ~U[1970-01-01 00:00:00.000000Z], "value" => value}

  # A query result without the `time` the clock assigned to a write that
  # carried none; the rest is compared whole.
  defp no_clock({:ok, rows}), do: {:ok, Enum.map(rows, &Map.delete(&1, "time"))}

  describe "write/3" do
    test "buffers lines and Points until a flush stores them", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, "cpu value=1.0 1")
      :ok = BatchWriter.write(pid, Point.new("cpu", %{"value" => 0.64}, timestamp: 2))

      assert stored(conn, "cpu") == []
      :ok = BatchWriter.flush(pid)
      assert stored(conn, "cpu") === [epoch_row(1.0), epoch_row(0.64)]
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
      assert stored(conn, "cpu") === [epoch_row(1.0), epoch_row(2.0)]
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

      assert row["value"] === 1.0

      assert Local.list_databases(conn) ===
               {:ok, [%{"name" => "_internal"}, %{"name" => "metrics"}]}
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

      assert BatchWriter.stats(pid) ===
               {:ok, %{total_writes: 2, total_bytes: 19, total_errors: 0}}
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
        assert row["value"] === 1.0
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
      assert rows |> Enum.map(& &1["value"]) |> Enum.sort() === [1.0, 2.0, 3.0]
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

      assert conn |> Local.query_sql("SELECT * FROM cpu", database: "test_db") |> no_clock() ===
               {:ok, [%{"value" => 42.0}]}
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

      assert stored(conn, "cpu") === [%{"time" => ~U[2026-09-28 12:00:00.123000Z], "v" => 1}]
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

      assert conn |> Local.query_sql("SELECT * FROM cpu", database: "test_db") |> no_clock() ===
               {:ok, [%{"value" => 1.0}]}
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

      assert Local.query_sql(conn, "SELECT value FROM cpu", database: "test_db") ===
               {:ok, [%{"value" => 1.0}]}
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

  # A listener the test controls, run under the test's supervisor. Each
  # request is announced to the test as `{:request, handler, body}`; the
  # connection is answered, and closed, when the test sends the handler
  # `{:respond, status}`. Requests are served one at a time, which is how the
  # single writer process issues them.
  defp controlled_server do
    owner = self()
    ref = make_ref()

    start_supervised!(
      Supervisor.child_spec(
        {Task,
         fn ->
           {:ok, listener} =
             :gen_tcp.listen(0, [
               :binary,
               packet: :http_bin,
               active: false,
               reuseaddr: true,
               backlog: 128
             ])

           {:ok, port} = :inet.port(listener)
           send(owner, {ref, port})
           serve_requests(listener, owner)
         end},
        id: ref
      )
    )

    receive do
      {^ref, port} -> port
    after
      5_000 -> flunk("the controlled server did not start listening")
    end
  end

  defp serve_requests(listener, owner) do
    {:ok, socket} = :gen_tcp.accept(listener)
    {:ok, {:http_request, _method, _path, _version}} = :gen_tcp.recv(socket, 0)

    length =
      socket |> request_headers(%{}) |> Map.get("content-length", "0") |> String.to_integer()

    :ok = :inet.setopts(socket, packet: :raw)
    {:ok, body} = if length == 0, do: {:ok, ""}, else: :gen_tcp.recv(socket, length)

    send(owner, {:request, self(), body})

    receive do
      {:respond, status} ->
        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} X\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
          )

        :ok = :gen_tcp.close(socket)
    end

    serve_requests(listener, owner)
  end

  defp request_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_header, _position, name, _reserved, value}} ->
        request_headers(socket, Map.put(acc, name |> to_string() |> String.downcase(), value))

      {:ok, :http_eoh} ->
        acc
    end
  end

  # Chain 1's retry gets a 400, which ends it; chain 2's requests get 503
  # until then. Returns the first chain 2 request that arrives afterwards,
  # unanswered, so the writer stays blocked on it. Whichever chain's timer
  # fires first, the outcome is the same.
  defp answer_until_chain_two_is_held(chain_one_ended?) do
    receive do
      {:request, handler, "cpu value=1.0"} ->
        send(handler, {:respond, 400})
        answer_until_chain_two_is_held(true)

      {:request, handler, "cpu value=2.0"} when chain_one_ended? ->
        handler

      {:request, handler, "cpu value=2.0"} ->
        send(handler, {:respond, 503})
        answer_until_chain_two_is_held(false)
    after
      5_000 -> flunk("no request arrived from the writer")
    end
  end

  # Waits for a task's reply, answering any request the writer makes meanwhile
  # with a success.
  defp await_serving(%Task{ref: ref} = task) do
    receive do
      {:request, handler, _body} ->
        send(handler, {:respond, 204})
        await_serving(task)

      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply
    after
      5_000 -> flunk("the call was never answered")
    end
  end

  defp settled_stats(pid) do
    case await_serving(Task.async(fn -> BatchWriter.stats(pid) end)) do
      {:ok, %{total_writes: 2}} = settled -> settled
      {:ok, _unsettled} -> settled_stats(pid)
    end
  end

  # How many calls of `kind` sit unread in the writer's mailbox.
  defp queued_calls(pid, kind) do
    {:messages, messages} = Process.info(pid, :messages)

    Enum.count(messages, fn
      {:"$gen_call", _from, {^kind, _payload}} -> true
      {:"$gen_call", _from, ^kind} -> true
      _other -> false
    end)
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

      # The held buffer is flushed once more at shutdown, and that fails too.
      assert capture_log(fn -> :ok = stop_supervised!(BatchWriter) end) =~
               "Final flush failed"
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
      # The test is the server: it answers every request itself, so the order
      # of events is its to decide and no clock is involved. Chain 1 ends on a
      # 400 while chain 2 is mid-retry (its request held, the writer blocked
      # on it); the writes queued meanwhile must then meet the bound.
      conn = Keyword.put(conn, :port, controlled_server())

      pid =
        start_writer(conn,
          client: InfluxElixir.Client.HTTP,
          batch_size: 1,
          flush_interval_ms: 60_000,
          max_retries: 3,
          base_retry_delay_ms: 1
        )

      # Chain 1's first attempt: held while the writer is blocked on it, so
      # the next two calls are queued behind it in a known order.
      first = Task.async(fn -> BatchWriter.write(pid, "cpu value=1.0") end)
      assert_receive {:request, held, "cpu value=1.0"}, 5_000

      second = Task.async(fn -> BatchWriter.write(pid, "cpu value=2.0") end)
      wait_until(fn -> queued_calls(pid, :write) == 1 end)
      flush = Task.async(fn -> BatchWriter.flush(pid) end)
      wait_until(fn -> queued_calls(pid, :flush) == 1 end)

      send(held, {:respond, 503})
      assert :ok = Task.await(first)

      # Chain 2's first attempt, started by the queued flush before any retry.
      assert_receive {:request, chain_two, "cpu value=2.0"}, 5_000
      send(chain_two, {:respond, 503})
      assert :ok = Task.await(second)
      assert :ok = Task.await(flush)

      held_retry = answer_until_chain_two_is_held(false)

      writes =
        for i <- 1..11 do
          Task.async(fn -> BatchWriter.write(pid, "cpu value=#{i}.5") end)
        end

      wait_until(fn -> queued_calls(pid, :write) == 11 end)

      # Chain 2 stays in flight when its held attempt fails; everything the
      # writer takes next sees that chain, and the end of chain 1 must not
      # have forgotten it. The server accepts every request from here on.
      send(held_retry, {:respond, 503})

      replies = Enum.map(writes, &await_serving/1)
      assert Enum.frequencies(replies) === %{:ok => 10, {:error, :buffer_full} => 1}

      # Chain 2 then succeeds and the ten buffered lines go out in one write.
      # Wait for that so the writer has nothing left to send when it stops.
      assert {:ok, %{total_errors: 1, total_writes: 2}} = settled_stats(pid)
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
