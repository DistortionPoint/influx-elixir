defmodule InfluxElixir.Write.BatchWriterTest do
  use ExUnit.Case, async: true

  # The writer logs every discarded batch and retry; the error-path tests
  # below trigger those deliberately, so keep the output out of the run.
  @moduletag capture_log: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.TestServer
  alias InfluxElixir.TestSupport.Await
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

  # The line protocol of a `cpu` point written `us` microseconds after the
  # epoch, and the row it reads back as. Distinct times keep the rows in a
  # known order, and every row is compared whole.
  defp line(value, us), do: "cpu value=#{value} #{us * 1_000}"
  defp row(value, us), do: %{"time" => DateTime.from_unix!(us, :microsecond), "value" => value}

  # The rows of `measurement` in the writer's database, in time order.
  defp stored(conn, measurement) do
    sql = "SELECT * FROM #{measurement} ORDER BY time"

    case Local.query_sql(conn, sql, database: "test_db") do
      {:ok, rows} -> rows
      {:error, _no_table_yet} -> []
    end
  end

  # The stats a writer reports once it has flushed `writes` batches of
  # `bytes` in all, with `errors` failed.
  defp stats(writes, errors, bytes),
    do: {:ok, %{total_writes: writes, total_errors: errors, total_bytes: bytes}}

  describe "start_link/1" do
    test "the :database option is the write target for every flush", %{conn: conn} do
      # Regression: :database was stored but never forwarded, so flushes
      # landed in the connection's default database instead.
      pid = start_writer(conn, database: "target_db")

      :ok = BatchWriter.write_sync(pid, line(7.0, 1))

      assert Local.query_sql(conn, "SELECT * FROM cpu", database: "target_db") ===
               {:ok, [row(7.0, 1)]}

      assert Local.list_databases(conn) ===
               {:ok, [%{"name" => "_internal"}, %{"name" => "target_db"}]}
    end

    test "a new writer reports zeroed stats", %{conn: conn} do
      pid = start_writer(conn)
      assert BatchWriter.stats(pid) === stats(0, 0, 0)
    end
  end

  describe "write/3" do
    test "buffers lines and Points until a flush stores them", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, line(1.0, 1))
      :ok = BatchWriter.write(pid, Point.new("cpu", %{"value" => 0.64}, timestamp: 2_000))

      assert stored(conn, "cpu") === []
      :ok = BatchWriter.flush(pid)
      assert stored(conn, "cpu") === [row(1.0, 1), row(0.64, 2)]
    end

    test "flushes on its own when the buffer reaches batch_size", %{conn: conn} do
      pid = start_writer(conn, batch_size: 3, flush_interval_ms: 60_000)
      lines = [line(1.0, 1), line(2.0, 2), line(3.0, 3)]

      :ok = BatchWriter.write(pid, Enum.at(lines, 0))
      :ok = BatchWriter.write(pid, Enum.at(lines, 1))
      assert stored(conn, "cpu") === []

      :ok = BatchWriter.write(pid, Enum.at(lines, 2))
      assert stored(conn, "cpu") === [row(1.0, 1), row(2.0, 2), row(3.0, 3)]
      assert BatchWriter.stats(pid) === stats(1, 0, byte_size(Enum.join(lines, "\n")))
    end
  end

  describe "write_sync/3" do
    test "returns once its line, and everything buffered before it, is stored",
         %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, line(1.0, 1))

      assert :ok =
               BatchWriter.write_sync(pid, Point.new("cpu", %{"value" => 2.0}, timestamp: 2_000))

      assert stored(conn, "cpu") === [row(1.0, 1), row(2.0, 2)]

      bytes = byte_size(line(1.0, 1) <> "\n" <> "cpu value=2.0 2000")
      assert BatchWriter.stats(pid) === stats(1, 0, bytes)
    end
  end

  describe "flush/2" do
    test "an empty buffer writes nothing", %{conn: conn} do
      pid = start_writer(conn)
      assert :ok = BatchWriter.flush(pid)
      assert BatchWriter.stats(pid) === stats(0, 0, 0)
    end

    test "writes the buffer as one request and empties it", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, line(1.0, 1))
      :ok = BatchWriter.write(pid, line(2.0, 2))
      :ok = BatchWriter.flush(pid)
      :ok = BatchWriter.flush(pid)

      assert stored(conn, "cpu") === [row(1.0, 1), row(2.0, 2)]

      assert BatchWriter.stats(pid) ===
               stats(1, 0, byte_size(line(1.0, 1) <> "\n" <> line(2.0, 2)))
    end

    test "the timeout arities write and flush as the defaults do", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, line(1.0, 1), 10_000)
      :ok = BatchWriter.flush(pid, 10_000)
      :ok = BatchWriter.write_sync(pid, line(2.0, 2), 10_000)
      assert stored(conn, "cpu") === [row(1.0, 1), row(2.0, 2)]
    end

    test "the timeout arities bound the wait for the reply", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)

      # A suspended writer cannot reply, so each call must give up after
      # exactly the timeout it was handed (the exit names it: 1 ms).
      :ok = :sys.suspend(pid)

      try do
        assert {:timeout, {GenServer, :call, [^pid, {:write, "cpu value=1.0 1"}, 1]}} =
                 catch_exit(BatchWriter.write(pid, "cpu value=1.0 1", 1))

        assert {:timeout, {GenServer, :call, [^pid, :flush, 1]}} =
                 catch_exit(BatchWriter.flush(pid, 1))

        assert {:timeout, {GenServer, :call, [^pid, {:write_sync, "cpu value=2.0 2"}, 1]}} =
                 catch_exit(BatchWriter.write_sync(pid, "cpu value=2.0 2", 1))
      after
        :ok = :sys.resume(pid)
      end
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

      :ok = BatchWriter.write_sync(pid, line(1.0, 1))

      assert Local.query_sql(conn, "SELECT * FROM cpu", database: "metrics") ===
               {:ok, [row(1.0, 1)]}

      assert Local.list_databases(conn) ===
               {:ok, [%{"name" => "_internal"}, %{"name" => "metrics"}]}
    end
  end

  describe "backoff_delay/3" do
    test "base_retry_delay_ms controls the backoff scale" do
      # base=100, attempt=1, no jitter → 100 * 2 = 200
      assert BatchWriter.backoff_delay(1, 0, 100) === 200

      # base=10, attempt=1, no jitter → 10 * 2 = 20
      assert BatchWriter.backoff_delay(1, 0, 10) === 20

      # base=100, attempt=3, no jitter → 100 * 8 = 800
      assert BatchWriter.backoff_delay(3, 0, 100) === 800
    end

    test "jitter adds 1..jitter_ms to the delay and is not constant" do
      # base=7000, attempt=1, jitter=20 → between 14_001 and 14_020
      delays = for _draw <- 1..30, do: BatchWriter.backoff_delay(1, 20, 7_000)

      assert Enum.all?(delays, &(&1 in 14_001..14_020))
      # 30 draws from 20 values are all equal with probability 20^-29.
      assert length(Enum.uniq(delays)) > 1
    end
  end

  describe "stats/1" do
    test "total_writes and total_bytes accumulate across flushes", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)

      :ok = BatchWriter.write(pid, "cpu v=1.0")
      :ok = BatchWriter.flush(pid)
      :ok = BatchWriter.write(pid, "cpu v=22.0")
      :ok = BatchWriter.flush(pid)

      assert BatchWriter.stats(pid) === stats(2, 0, 19)
    end
  end

  # The flush timer is the one thing here with no message to wait for, so
  # the tests poll the writer's public stats, with a deadline that fails
  # loudly: nothing waits longer than needed or passes by luck.
  defp await_writes(pid, writes) do
    Await.until(fn -> match?({:ok, %{total_writes: ^writes}}, BatchWriter.stats(pid)) end)
  end

  describe "timer-based flush" do
    for jitter_ms <- [0, 20] do
      test "the timer flushes the buffer by itself (jitter_ms: #{jitter_ms})",
           %{conn: conn} do
        pid = start_writer(conn, flush_interval_ms: 10, jitter_ms: unquote(jitter_ms))
        :ok = BatchWriter.write(pid, line(1.0, 1))

        await_writes(pid, 1)

        assert Local.query_sql(conn, "SELECT * FROM cpu", database: "test_db") ===
                 {:ok, [row(1.0, 1)]}

        assert BatchWriter.stats(pid) === stats(1, 0, byte_size(line(1.0, 1)))
      end
    end

    # Regression: do_flush/1 cancelled the timer and only the timer's own
    # handler re-armed it, so after a size-triggered flush the interval flush
    # never fired again and the next write stayed buffered.
    test "the timer keeps flushing after a size-triggered flush", %{conn: conn} do
      # The interval is far longer than the test: the timer message is sent
      # by hand, where the real one would fire, so no clock decides the order.
      pid = start_writer(conn, batch_size: 2, flush_interval_ms: 600_000)
      first = line(1.0, 1) <> "\n" <> line(2.0, 2)

      :ok = BatchWriter.write(pid, line(1.0, 1))
      :ok = BatchWriter.write(pid, line(2.0, 2))
      assert BatchWriter.stats(pid) === stats(1, 0, byte_size(first))

      :ok = BatchWriter.write(pid, line(3.0, 3))
      send(pid, :flush)
      assert BatchWriter.stats(pid) === stats(2, 0, byte_size(first) + byte_size(line(3.0, 3)))
      assert stored(conn, "cpu") === [row(1.0, 1), row(2.0, 2), row(3.0, 3)]
    end
  end

  # Every timer the writer sets goes through `:erlang.send_after`, and every one
  # it drops through `:erlang.cancel_timer`. The delay of the first is the one
  # thing that tells jitter (or a backoff base) from its absence, and it is
  # random or buried in a timer wheel. A trace session on the writer hands the
  # test each call's arguments as a message, so the delays and the order of the
  # calls are read exactly and no clock is involved. The session belongs to this
  # test: it traces only the writer under test, and is destroyed when the test
  # ends, so no trace pattern outlives it.
  defp trace_timers(pid) do
    session = :trace.session_create(:batch_writer_timers, self(), [])
    on_exit(fn -> :trace.session_destroy(session) end)

    1 = :trace.process(session, pid, true, [:call])
    2 = :trace.function(session, {:erlang, :send_after, :_}, true, [:global])
    2 = :trace.function(session, {:erlang, :cancel_timer, :_}, true, [:global])
    :ok
  end

  # The timer calls the writer makes, in order, up to and including the next
  # `send_after` of `kind`: `[:cancel_timer, {:send_after, delay}]`.
  defp timer_calls(pid, kind) do
    receive do
      {:trace, ^pid, :call, {:erlang, :cancel_timer, _args}} ->
        [:cancel_timer | timer_calls(pid, kind)]

      {:trace, ^pid, :call, {:erlang, :send_after, [delay, _dest, message | _opts]}} ->
        if kind_of(message) === kind,
          do: [{:send_after, delay}],
          else: [{:send_after, delay} | timer_calls(pid, kind)]
    after
      5_000 -> flunk("the writer set no #{kind} timer")
    end
  end

  defp kind_of(:flush), do: :flush
  defp kind_of({:retry, _chain, _attempt}), do: :retry
  defp kind_of(_message), do: :other

  defp next_retry_delay(pid) do
    pid |> timer_calls(:retry) |> List.last() |> elem(1)
  end

  # Every flush restarts the interval (the moduledoc's promise): the pending
  # timer is cancelled and a new one is set. Intervals here are far longer than
  # the test, so no timer fires and no clock is read.
  defp assert_restarts_timer(pid, trigger) do
    :ok = trace_timers(pid)
    trigger.()

    assert [:cancel_timer, {:send_after, 600_000}] = timer_calls(pid, :flush)
  end

  describe "the flush interval restarts on every flush" do
    test "after a size-triggered flush", %{conn: conn} do
      pid = start_writer(conn, batch_size: 2, flush_interval_ms: 600_000)
      :ok = BatchWriter.write(pid, line(1.0, 1))

      assert_restarts_timer(pid, fn -> :ok = BatchWriter.write(pid, line(2.0, 2)) end)
      assert stored(conn, "cpu") === [row(1.0, 1), row(2.0, 2)]
    end

    test "after an explicit flush/2", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 600_000)
      :ok = BatchWriter.write(pid, line(1.0, 1))

      assert_restarts_timer(pid, fn -> :ok = BatchWriter.flush(pid) end)
      assert stored(conn, "cpu") === [row(1.0, 1)]
    end

    test "after a write_sync/3", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 600_000)

      assert_restarts_timer(pid, fn -> :ok = BatchWriter.write_sync(pid, line(1.0, 1)) end)
      assert stored(conn, "cpu") === [row(1.0, 1)]
    end

    test "after the timer's own flush", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 600_000)
      :ok = BatchWriter.write(pid, line(1.0, 1))

      assert_restarts_timer(pid, fn ->
        send(pid, :flush)
        assert BatchWriter.stats(pid) === stats(1, 0, byte_size(line(1.0, 1)))
      end)
    end
  end

  describe "jitter_ms on the flush timer" do
    test "adds 1..jitter_ms to every interval", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 600_000, jitter_ms: 20)
      :ok = trace_timers(pid)

      delays =
        for i <- 1..30 do
          :ok = BatchWriter.write(pid, line(i, i))
          :ok = BatchWriter.flush(pid)
          next_flush_delay_after_cancel(pid)
        end

      assert Enum.all?(delays, &(&1 in 600_001..600_020))
      # 30 draws from 20 values are all equal with probability 20^-29.
      assert length(Enum.uniq(delays)) > 1
    end

    test "is nothing without jitter_ms", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 600_000, jitter_ms: 0)
      :ok = trace_timers(pid)

      :ok = BatchWriter.write(pid, line(1.0, 1))
      :ok = BatchWriter.flush(pid)

      assert next_flush_delay_after_cancel(pid) === 600_000
    end
  end

  # The delay of the flush timer set by the flush the test just made, which
  # first cancels the pending one.
  defp next_flush_delay_after_cancel(pid) do
    assert [:cancel_timer, {:send_after, delay}] = timer_calls(pid, :flush)
    delay
  end

  describe "retry timers" do
    setup do
      finch = :"bw_timer_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch, pools: %{default: [size: 1]}})
      {:ok, finch: finch}
    end

    test "base_retry_delay_ms sets the first retry's delay to base * 2", %{finch: finch} do
      pid =
        start_http_writer(finch, TestServer.controlled(owner: answering_owner(503)),
          batch_size: 1,
          max_retries: 2,
          base_retry_delay_ms: 7_000
        )

      :ok = trace_timers(pid)
      :ok = BatchWriter.write(pid, "cpu value=1.0")

      assert next_retry_delay(pid) === 14_000
      :ok = stop_supervised!(BatchWriter)
    end
  end

  describe "unexpected messages" do
    test "a stray message and a linked process's exit leave the writer and buffer intact",
         %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 600_000)
      :ok = BatchWriter.write(pid, line(1.0, 1))

      send(pid, :stray)
      send(pid, {:EXIT, self(), :boom})

      # The writer traps exits, so a linked process ending is a message.
      {linked, monitor} =
        spawn_monitor(fn ->
          Process.link(pid)
          Process.exit(self(), :kill)
        end)

      assert_receive {:DOWN, ^monitor, :process, ^linked, :killed}, 5_000

      assert BatchWriter.stats(pid) === stats(0, 0, 0)
      assert Process.alive?(pid)
      :ok = BatchWriter.flush(pid)
      assert stored(conn, "cpu") === [row(1.0, 1)]
    end
  end

  describe "shutdown" do
    # A supervisor stops a child with an exit signal, which kills a process
    # that does not trap exits before terminate/2 can run: the buffer was
    # lost on every application shutdown and remove_connection/1.
    # (GenServer.stop runs terminate/2 either way, so it never showed.)
    test "a supervisor stopping the writer flushes the buffer", %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000)
      :ok = BatchWriter.write(pid, line(42.0, 1))

      :ok = stop_supervised!(BatchWriter)

      assert Local.query_sql(conn, "SELECT * FROM cpu", database: "test_db") ===
               {:ok, [row(42.0, 1)]}
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
      :ok = BatchWriter.write(pid, line(1.0, 1))

      # Encoding used to run inside the writer: encode! raised there and
      # the crash lost every caller's buffered lines.
      assert {:error, :empty_fields} = BatchWriter.write(pid, Point.new("cpu", %{}))
      assert {:error, :empty_fields} = BatchWriter.write_sync(pid, Point.new("cpu", %{}))

      :ok = BatchWriter.flush(pid)

      assert stored(conn, "cpu") === [row(1.0, 1)]
    end
  end

  describe "write_sync edge cases" do
    test "write_sync with no_sync triggers batch flush at batch_size", %{conn: conn} do
      pid = start_writer(conn, no_sync: true, batch_size: 2, flush_interval_ms: 60_000)

      :ok = BatchWriter.write_sync(pid, line(1.0, 1))
      assert stored(conn, "cpu") === []
      :ok = BatchWriter.write_sync(pid, line(2.0, 2))

      assert BatchWriter.stats(pid) ===
               stats(1, 0, byte_size(line(1.0, 1) <> "\n" <> line(2.0, 2)))

      assert stored(conn, "cpu") === [row(1.0, 1), row(2.0, 2)]
    end

    test "write_sync with no_sync under batch_size does not flush", %{conn: conn} do
      pid = start_writer(conn, no_sync: true, batch_size: 10, flush_interval_ms: 60_000)

      :ok = BatchWriter.write_sync(pid, line(1.0, 1))
      assert BatchWriter.stats(pid) === stats(0, 0, 0)

      # The line is buffered, not dropped: an explicit flush lands it.
      :ok = BatchWriter.flush(pid)
      assert BatchWriter.stats(pid) === stats(1, 0, byte_size(line(1.0, 1)))
      assert stored(conn, "cpu") === [row(1.0, 1)]
    end
  end

  describe "4xx responses" do
    test "invalid line protocol is discarded on the first flush even with retries left",
         %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000, max_retries: 2)

      :ok = BatchWriter.write(pid, "!!!")
      :ok = BatchWriter.flush(pid)

      assert BatchWriter.stats(pid) === stats(0, 1, 0)

      # Nothing is pending: the next valid batch goes straight through.
      :ok = BatchWriter.write_sync(pid, line(1.0, 1))
      assert BatchWriter.stats(pid) === stats(1, 1, byte_size(line(1.0, 1)))
    end

    test "a write_sync caller is told the engine's 400, and the batch is counted as an error",
         %{conn: conn} do
      pid = start_writer(conn, flush_interval_ms: 60_000, max_retries: 0)

      assert {:error, %{status: 400}} = BatchWriter.write_sync(pid, "!!!")
      assert BatchWriter.stats(pid) === stats(0, 1, 0)
    end
  end

  # ---------------------------------------------------------------------------
  # Retries, against a server the test controls
  #
  # Every request the writer makes is announced to the test, which answers it,
  # so the order of events is the test's and no clock is involved: no backoff
  # is waited out and no stats are read while a retry could race them.
  # ---------------------------------------------------------------------------

  # How many calls of `kind` sit unread in the writer's mailbox.
  defp queued_calls(pid, kind) do
    {:messages, messages} = Process.info(pid, :messages)

    Enum.count(messages, fn
      {:"$gen_call", _from, {^kind, _payload}} -> true
      {:"$gen_call", _from, ^kind} -> true
      _other -> false
    end)
  end

  # Waits for the writer's next request, which must carry `body`, and answers
  # it with `status`. A stats call is queued behind the request first, so it
  # is the writer's very next message: the stats returned are exactly those
  # after this answer was handled and before any retry timer could be.
  defp answer_with_stats(pid, body, status) do
    assert_receive {:request, handler, ^body}, 5_000
    reader = Task.async(fn -> BatchWriter.stats(pid) end)
    Await.until(fn -> queued_calls(pid, :stats) == 1 end)
    TestServer.respond(handler, status)
    Task.await(reader)
  end

  # An owner for a server that answers every request itself with `status`
  # and tells the test each body, for the tests that stop the writer, whose
  # final writes are made while the test process is blocked on the stop.
  defp answering_owner(status) do
    test = self()

    start_supervised!(
      Supervisor.child_spec(
        {Task, fn -> answer_forever(test, status) end},
        id: :answering_owner
      )
    )
  end

  defp answer_forever(test, status) do
    receive do
      {:request, handler, body} ->
        TestServer.respond(handler, status)
        send(test, {:seen, body})
        answer_forever(test, status)
    end
  end

  # The bodies of every request an answering owner has reported so far.
  defp seen_bodies(acc \\ []) do
    receive do
      {:seen, body} -> seen_bodies([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp http_conn(finch, port),
    do: [host: "127.0.0.1", port: port, scheme: :http, token: "t", finch_name: finch]

  defp start_http_writer(finch, port, opts) do
    defaults = [client: InfluxElixir.Client.HTTP, flush_interval_ms: 60_000]
    start_writer(http_conn(finch, port), Keyword.merge(defaults, opts))
  end

  describe "retry path — server errors" do
    setup do
      finch = :"bw_retry_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch, pools: %{default: [size: 1]}})
      {:ok, finch: finch}
    end

    test "a 503 is retried max_retries times, and the error is counted once the last fails",
         %{finch: finch} do
      pid =
        start_http_writer(finch, TestServer.controlled(),
          batch_size: 1,
          max_retries: 2,
          base_retry_delay_ms: 1
        )

      # batch_size 1: the write flushes at once and its first attempt fails.
      writer = Task.async(fn -> BatchWriter.write(pid, "cpu value=1.0") end)

      assert answer_with_stats(pid, "cpu value=1.0", 503) === stats(0, 0, 0)
      assert :ok = Task.await(writer)
      assert answer_with_stats(pid, "cpu value=1.0", 503) === stats(0, 0, 0)
      assert answer_with_stats(pid, "cpu value=1.0", 503) === stats(0, 1, 0)

      # 1 + max_retries requests were made, and no chain is left to make more.
      refute_received {:request, _handler, _body}
    end

    test "a retry that succeeds ends the chain without an error", %{finch: finch} do
      pid =
        start_http_writer(finch, TestServer.controlled(),
          batch_size: 1,
          max_retries: 2,
          base_retry_delay_ms: 1
        )

      writer = Task.async(fn -> BatchWriter.write(pid, "cpu value=1.0") end)

      assert answer_with_stats(pid, "cpu value=1.0", 503) === stats(0, 0, 0)
      assert :ok = Task.await(writer)
      assert answer_with_stats(pid, "cpu value=1.0", 204) === stats(1, 0, 13)
    end

    test "backpressure: the buffer is bounded at 10 x batch_size while a chain is in flight",
         %{finch: finch} do
      pid =
        start_http_writer(finch, TestServer.controlled(owner: answering_owner(503)),
          batch_size: 1,
          max_retries: 2,
          base_retry_delay_ms: 60_000
        )

      :ok = BatchWriter.write(pid, "cpu value=0.0")

      for i <- 1..10 do
        assert :ok = BatchWriter.write(pid, "cpu value=#{i}.0")
      end

      assert {:error, :buffer_full} = BatchWriter.write(pid, "cpu value=11.0")
      assert {:error, :buffer_full} = BatchWriter.write_sync(pid, "cpu value=11.0")

      # The held batch and then the buffer are written once more at shutdown,
      # oldest first, and those writes fail here too.
      :ok = stop_supervised!(BatchWriter)

      assert seen_bodies() === [
               "cpu value=0.0",
               "cpu value=0.0",
               Enum.map_join(1..10, "\n", &"cpu value=#{&1}.0")
             ]
    end

    test "the buffer deferred during a chain is flushed when the chain ends", %{finch: finch} do
      pid =
        start_http_writer(finch, TestServer.controlled(),
          batch_size: 1,
          max_retries: 1,
          base_retry_delay_ms: 1
        )

      first = Task.async(fn -> BatchWriter.write(pid, "cpu value=1.0") end)
      assert_receive {:request, held, "cpu value=1.0"}, 5_000

      # Queued behind the held attempt, so it is the writer's next message.
      second = Task.async(fn -> BatchWriter.write(pid, "cpu value=2.0") end)
      Await.until(fn -> queued_calls(pid, :write) == 1 end)

      TestServer.respond(held, 503)
      assert :ok = Task.await(first)
      assert :ok = Task.await(second)

      # Chain 1's one retry fails and ends it (error 1); the deferred line then
      # flushes into chain 2, which succeeds.
      assert_receive {:request, retry, "cpu value=1.0"}, 5_000
      TestServer.respond(retry, 503)
      assert_receive {:request, deferred, "cpu value=2.0"}, 5_000
      TestServer.respond(deferred, 204)

      assert BatchWriter.stats(pid) === stats(1, 1, 13)
    end

    test "errors are counted per chain, and write_sync is answered with its chain's final result",
         %{finch: finch} do
      pid =
        start_http_writer(finch, TestServer.controlled(),
          max_retries: 2,
          base_retry_delay_ms: 1
        )

      caller = Task.async(fn -> BatchWriter.write_sync(pid, "cpu value=1.0") end)

      # First attempt plus two retries all fail; the chain records one error,
      # and the caller is not answered before the last.
      assert answer_with_stats(pid, "cpu value=1.0", 503) === stats(0, 0, 0)
      assert answer_with_stats(pid, "cpu value=1.0", 503) === stats(0, 0, 0)
      assert answer_with_stats(pid, "cpu value=1.0", 503) === stats(0, 1, 0)

      assert {:error, %{status: 503}} = Task.await(caller)
      refute_received {:request, _handler, _body}
      assert Process.alive?(pid)
    end

    test "a write_sync caller during another chain gets its own chain's result",
         %{finch: finch} do
      pid =
        start_http_writer(finch, TestServer.controlled(),
          max_retries: 3,
          base_retry_delay_ms: 1
        )

      one = Task.async(fn -> BatchWriter.write_sync(pid, "cpu value=1.0") end)
      assert_receive {:request, held, "cpu value=1.0"}, 5_000
      TestServer.respond(held, 503)

      # Chain 1 is now retrying; the second caller starts a chain of its own.
      two = Task.async(fn -> BatchWriter.write_sync(pid, "cpu value=2.0") end)

      # Whichever of chain 1's retry and the second call the writer takes
      # first, chain 1 ends on a 400 and chain 2 on a 204.
      for _request <- 1..2 do
        assert_receive {:request, handler, body}, 5_000
        TestServer.respond(handler, if(body == "cpu value=1.0", do: 400, else: 204))
      end

      assert {:error, %{status: 400}} = Task.await(one)
      assert :ok = Task.await(two)
      assert BatchWriter.stats(pid) === stats(1, 1, 13)
    end

    test "backpressure holds while any chain is in flight, not just the first",
         %{finch: finch} do
      # The test is the server: it answers every request itself, so the order
      # of events is its to decide and no clock is involved. Chain 1 ends on a
      # 400 while chain 2 is mid-retry (its request held, the writer blocked
      # on it); the writes queued meanwhile must then meet the bound.
      pid =
        start_http_writer(finch, TestServer.controlled(),
          batch_size: 1,
          max_retries: 3,
          base_retry_delay_ms: 1
        )

      # Chain 1's first attempt: held while the writer is blocked on it, so
      # the next two calls are queued behind it in a known order.
      first = Task.async(fn -> BatchWriter.write(pid, "cpu value=1.0") end)
      assert_receive {:request, held, "cpu value=1.0"}, 5_000

      second = Task.async(fn -> BatchWriter.write(pid, "cpu value=2.0") end)
      Await.until(fn -> queued_calls(pid, :write) == 1 end)
      flush = Task.async(fn -> BatchWriter.flush(pid) end)
      Await.until(fn -> queued_calls(pid, :flush) == 1 end)

      TestServer.respond(held, 503)
      assert :ok = Task.await(first)

      # Chain 2's first attempt, started by the queued flush before any retry.
      assert_receive {:request, chain_two, "cpu value=2.0"}, 5_000
      TestServer.respond(chain_two, 503)
      assert :ok = Task.await(second)
      assert :ok = Task.await(flush)

      held_retry = answer_until_chain_two_is_held(false)

      # Queued one at a time, so the order the writer takes them in is known.
      writes =
        for i <- 1..11 do
          task = Task.async(fn -> BatchWriter.write(pid, "cpu value=#{i}.5") end)
          Await.until(fn -> queued_calls(pid, :write) == i end)
          task
        end

      # The interval timer firing while chain 2 is held: it must wait for the
      # chain, not flush the buffer into a server that is failing.
      send(pid, :flush)

      # Chain 2 stays in flight when its held attempt fails; everything the
      # writer takes next sees that chain, and the end of chain 1 must not
      # have forgotten it.
      TestServer.respond(held_retry, 503)

      assert Enum.map(writes, &Task.await/1) ===
               List.duplicate(:ok, 10) ++ [{:error, :buffer_full}]

      # The next request is chain 2's retry, not a flush of the ten lines; it
      # succeeds, and only then do the ten buffered lines go out in one write.
      assert_receive {:request, retry, "cpu value=2.0"}, 5_000
      TestServer.respond(retry, 204)

      accepted = Enum.map_join(1..10, "\n", &"cpu value=#{&1}.5")
      assert_receive {:request, buffered, ^accepted}, 5_000
      TestServer.respond(buffered, 204)

      assert BatchWriter.stats(pid) === stats(2, 1, 13 + byte_size(accepted))
    end

    test "a write_sync caller waiting on a chain is answered at shutdown, in order",
         %{finch: finch} do
      pid =
        start_http_writer(finch, TestServer.controlled(owner: answering_owner(503)),
          max_retries: 3,
          base_retry_delay_ms: 60_000
        )

      caller = Task.async(fn -> BatchWriter.write_sync(pid, "cpu value=1.0") end)

      # The first attempt reached the server, so the writer has taken the
      # call; the write below is queued behind it and lands in the buffer
      # while the chain waits to retry.
      assert_receive {:seen, "cpu value=1.0"}, 5_000
      :ok = BatchWriter.write(pid, "cpu value=2.0")

      :ok = stop_supervised!(BatchWriter)

      # terminate/2 writes the chain's batch once more, answering its caller
      # with that result, and then the buffer.
      assert {:error, %{status: 503}} = Task.await(caller)
      assert seen_bodies() === ["cpu value=1.0", "cpu value=2.0"]
    end

    test "with max_retries: 0 a server error is recorded on the first flush",
         %{finch: finch} do
      pid = start_http_writer(finch, TestServer.controlled(), max_retries: 0)

      caller = Task.async(fn -> BatchWriter.write_sync(pid, "cpu value=1.0") end)
      assert_receive {:request, handler, "cpu value=1.0"}, 5_000
      TestServer.respond(handler, 503)

      assert {:error, %{status: 503}} = Task.await(caller)
      assert BatchWriter.stats(pid) === stats(0, 1, 0)
      refute_received {:request, _handler, _body}
    end
  end

  # Chain 1's retry gets a 400, which ends it; chain 2's requests get 503
  # until then. Returns the first chain 2 request that arrives afterwards,
  # unanswered, so the writer stays blocked on it. Whichever chain's timer
  # fires first, the outcome is the same.
  defp answer_until_chain_two_is_held(chain_one_ended?) do
    receive do
      {:request, handler, "cpu value=1.0"} ->
        TestServer.respond(handler, 400)
        answer_until_chain_two_is_held(true)

      {:request, handler, "cpu value=2.0"} when chain_one_ended? ->
        handler

      {:request, handler, "cpu value=2.0"} ->
        TestServer.respond(handler, 503)
        answer_until_chain_two_is_held(false)
    after
      5_000 -> flunk("no request arrived from the writer")
    end
  end
end
