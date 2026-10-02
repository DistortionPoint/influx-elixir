defmodule InfluxElixir.Integration.ContractV3CoreTest do
  @moduledoc """
  Contract tests against real InfluxDB v3 Core on port 8181.

  Run with: `mix test --include v3_core`

  These are the SAME assertions that run against LocalClient in
  `ContractLocalV3CoreTest`. If both pass, LocalClient is proven
  faithful to real InfluxDB v3 Core.
  """

  use ExUnit.Case, async: false

  @moduletag :v3_core
  @moduletag :integration

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core

  use InfluxElixir.Contract.SQLParser, client: InfluxElixir.Client.HTTP, profile: :v3_core
  use InfluxElixir.Contract.SQLExecutor, client: InfluxElixir.Client.HTTP, profile: :v3_core
  use InfluxElixir.Contract.InfluxQLFluxLP, client: InfluxElixir.Client.HTTP, profile: :v3_core

  alias InfluxElixir.Client.HTTP
  alias InfluxElixir.IntegrationHelper, as: H

  setup_all do
    H.start_finch()
    conn = H.v3_core_conn()

    if H.reachable?(conn) do
      {:ok, base_conn: conn}
    else
      {:ok, skip: true, base_conn: conn}
    end
  end

  setup %{base_conn: base_conn} = ctx do
    if ctx[:skip] do
      flunk("InfluxDB v3 Core not reachable on port 8181")
    end

    db = H.unique_name("contract_v3core")

    case HTTP.create_database(base_conn, db) do
      :ok ->
        on_exit(fn -> HTTP.delete_database(base_conn, db) end)
        {:ok, conn: base_conn, database: db, query_delay: 500, time_slack: 60}

      {:error, reason} ->
        flunk("Failed to create test database: #{inspect(reason)}")
    end
  end

  # A streaming query holds its pool connection in a producer process. The
  # producer used to be killed when the consumer stopped early, and to wait
  # forever when the consumer itself was killed. A pool drops the connection
  # of a checkout owner that dies, without serving the requests already
  # queued for it (verified), so a request waiting on the pool timed out.
  # The producer now halts its request, which checks the connection back in.
  describe "query_sql_stream/3 releases its pool connection" do
    setup ctx do
      finch = :"stream_release_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch, pools: %{default: [size: 1]}})
      conn = Keyword.put(ctx.conn, :finch_name, finch)
      m = "stream_release_#{System.unique_integer([:positive])}"

      # Enough rows that the response arrives in many chunks.
      lp = Enum.map_join(1..20_000, "\n", &"#{m},k=k#{rem(&1, 50)} v=#{&1}i #{&1}")
      {:ok, :written} = HTTP.write(conn, lp, database: ctx.database)
      InfluxElixir.ClientContract.settle(ctx)

      count = fn ->
        HTTP.query_sql(conn, "SELECT count(*) AS n FROM #{m}",
          database: ctx.database,
          pool_timeout: 5_000
        )
      end

      {:ok, conn: conn, m: m, count: count}
    end

    test "when the consumer stops early, a request waiting on the pool is served", ctx do
      test_pid = self()

      rows =
        ctx.conn
        |> HTTP.query_sql_stream("SELECT * FROM #{ctx.m}", database: ctx.database)
        |> Stream.with_index()
        |> Stream.each(fn
          {_row, 0} -> send(test_pid, {:waiter, queue_waiter(ctx.count)})
          _later -> :ok
        end)
        |> Enum.take(3)

      assert length(rows) == 3

      # The stream ran in this process: nothing of it is left in the mailbox.
      refute_received {_ref, {:data, _chunk}}
      refute_received {_ref, :done}

      assert_received {:waiter, waiter}
      assert {:ok, [%{"n" => 20_000}]} = Task.await(waiter, 10_000)
    end

    test "when the consumer is killed, a request waiting on the pool is served", ctx do
      test_pid = self()

      consumer =
        spawn(fn ->
          ctx.conn
          |> HTTP.query_sql_stream("SELECT * FROM #{ctx.m}", database: ctx.database)
          |> Enum.each(fn _row ->
            send(test_pid, :streaming)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :streaming, 10_000
      waiter = queue_waiter(ctx.count)
      Process.exit(consumer, :kill)

      assert {:ok, [%{"n" => 20_000}]} = Task.await(waiter, 10_000)
    end
  end

  # A request for the pool's only connection, queued behind the stream:
  # returns once the waiting process is blocked on its checkout.
  defp queue_waiter(count) do
    waiter = Task.async(count)
    wait_until(fn -> Process.info(waiter.pid, :status) == {:status, :waiting} end)
    waiter
  end

  # Proves :pool_timeout reaches Finch (#14). A pool of size 1 is held by a
  # streaming request that sleeps inside its chunk callback; a second request
  # must then wait on checkout, and its :pool_timeout decides its fate
  # regardless of how generous :timeout is.
  describe "query_sql/3 with :pool_timeout" do
    setup ctx do
      finch = :"pool_timeout_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch, pools: %{default: [size: 1]}})
      conn = Keyword.put(ctx.conn, :finch_name, finch)

      holder =
        Task.async(fn ->
          request =
            Finch.build(
              :post,
              "http://#{conn[:host]}:#{conn[:port]}/api/v3/query_sql",
              [{"content-type", "application/json"}],
              Jason.encode!(%{"db" => ctx.database, "q" => "SELECT 1", "format" => "json"})
            )

          Finch.stream(request, finch, nil, fn _chunk, acc ->
            Process.sleep(1_500)
            acc
          end)
        end)

      # Give the holder time to check the only connection out.
      Process.sleep(200)
      {:ok, conn: conn, holder: holder}
    end

    test "a short :pool_timeout fails at checkout even with a long :timeout", ctx do
      started = System.monotonic_time(:millisecond)

      # Finch raises on checkout timeout; the client maps it to a tuple.
      assert {:error, {:connection_error, :pool_timeout}} =
               HTTP.query_sql(ctx.conn, "SELECT 1",
                 database: ctx.database,
                 timeout: 180_000,
                 pool_timeout: 100
               )

      assert System.monotonic_time(:millisecond) - started < 1_000

      # The streaming path reports the same failure as a StreamError.
      error =
        assert_raise InfluxElixir.StreamError, fn ->
          ctx.conn
          |> HTTP.query_sql_stream("SELECT 1", database: ctx.database, pool_timeout: 100)
          |> Enum.to_list()
        end

      assert error.kind == :transport
      assert error.reason == :pool_timeout

      Task.await(ctx.holder, 10_000)
    end

    test "a generous :pool_timeout waits for the connection and succeeds", ctx do
      assert {:ok, [%{"one" => 1}]} =
               HTTP.query_sql(ctx.conn, "SELECT 1 AS one",
                 database: ctx.database,
                 pool_timeout: 10_000
               )

      Task.await(ctx.holder, 10_000)
    end
  end

  # Arrow Flight is HTTP-client only (Local is in-memory), so it lives
  # outside the shared contract. InfluxDB 3 Core serves Flight gRPC on the
  # same port as HTTP, without TLS.
  describe "query_sql/3 with transport: :flight" do
    test "returns the same rows as the HTTP transport", ctx do
      {:ok, :written} =
        HTTP.write(
          ctx.conn,
          "flight_probe,host=a value=1.5,count=2i 1700000000000000000",
          database: ctx.database
        )

      InfluxElixir.ClientContract.settle(ctx)
      sql = "SELECT time, host, value, count FROM flight_probe"

      assert {:ok, [http_row]} = HTTP.query_sql(ctx.conn, sql, database: ctx.database)

      assert {:ok, [flight_row]} =
               HTTP.query_sql(ctx.conn, sql,
                 database: ctx.database,
                 transport: :flight,
                 flight_port: ctx.conn[:port],
                 tls: false
               )

      # Same rows on both transports, including `time` as a DateTime.
      assert flight_row == http_row
      assert %{"host" => "a", "value" => 1.5, "count" => 2} = flight_row
      assert flight_row["time"] == ~U[2023-11-14 22:13:20.000000Z]
    end

    test "a null column is absent from the row, as over HTTP, for every field type", ctx do
      # A second series with no `region` tag and no `s`, `b`, `u` fields:
      # its row must not carry those keys at all, over either transport.
      lp = """
      flight_nulls,host=a,region=r1 v=1.5,c=1i,u=7u,s="x",b=true 1700000000000000000
      flight_nulls,host=b v=2.5,c=2i 1700000000000000001
      """

      {:ok, :written} = HTTP.write(ctx.conn, String.trim(lp), database: ctx.database)
      InfluxElixir.ClientContract.settle(ctx)
      sql = "SELECT * FROM flight_nulls ORDER BY time"

      assert {:ok, http_rows} = HTTP.query_sql(ctx.conn, sql, database: ctx.database)

      assert {:ok, flight_rows} =
               HTTP.query_sql(ctx.conn, sql,
                 database: ctx.database,
                 transport: :flight,
                 flight_port: ctx.conn[:port],
                 tls: false
               )

      assert flight_rows == http_rows
      assert [_full, sparse] = flight_rows
      assert Enum.sort(Map.keys(sparse)) == ["c", "host", "time", "v"]
    end

    test "structs, lists, durations and Utf8View strings are the same over Flight", ctx do
      m = "flight_types_#{System.unique_integer([:positive])}"

      lp = """
      #{m},host=a v=1.5,s="x" 1700000000000000000
      #{m},host=b v=2.5 1700000060000000000
      """

      {:ok, :written} = HTTP.write(ctx.conn, String.trim(lp), database: ctx.database)
      InfluxElixir.ClientContract.settle(ctx)

      for sql <- [
            "SELECT selector_last(v, time) AS sl, array_agg(host ORDER BY host) AS hosts FROM #{m}",
            "SELECT time - LAG(time) OVER (ORDER BY time) AS gap FROM #{m} ORDER BY time",
            "SELECT concat(host, '-', s) AS hs, CAST(time AS DATE) AS d, CAST(v AS DECIMAL(10,2)) AS dec FROM #{m} ORDER BY time"
          ] do
        assert {:ok, http_rows} = HTTP.query_sql(ctx.conn, sql, database: ctx.database)

        assert {:ok, ^http_rows} =
                 HTTP.query_sql(ctx.conn, sql,
                   database: ctx.database,
                   transport: :flight,
                   flight_port: ctx.conn[:port],
                   tls: false
                 ),
               sql
      end
    end

    test "rejects params over Flight instead of dropping them", ctx do
      assert {:error, :params_unsupported_over_flight} =
               HTTP.query_sql(ctx.conn, "SELECT 1",
                 database: ctx.database,
                 transport: :flight,
                 params: %{x: 1}
               )
    end
  end

  # A retry chain end to end: a pool of size 1 is held by a streaming request,
  # so the writer's first flush fails at checkout (a transport error, retried);
  # by the time the backoff fires the holder has released the connection and
  # the retry reaches the server. No fake server is involved.
  describe "BatchWriter retry against the server" do
    setup ctx do
      finch = :"bw_int_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch, pools: %{default: [size: 1]}})
      conn = Keyword.put(ctx.conn, :finch_name, finch)

      holder =
        Task.async(fn ->
          request =
            Finch.build(
              :post,
              "http://#{conn[:host]}:#{conn[:port]}/api/v3/query_sql",
              [{"content-type", "application/json"}],
              Jason.encode!(%{"db" => ctx.database, "q" => "SELECT 1", "format" => "json"})
            )

          Finch.stream(request, finch, nil, fn _chunk, acc ->
            Process.sleep(1_000)
            acc
          end)
        end)

      Process.sleep(200)
      {:ok, conn: conn, holder: holder}
    end

    test "a transport error is retried and the retry succeeds", ctx do
      pid =
        start_supervised!(
          {InfluxElixir.Write.BatchWriter,
           connection: ctx.conn,
           client: HTTP,
           database: ctx.database,
           batch_size: 1,
           flush_interval_ms: 60_000,
           max_retries: 3,
           base_retry_delay_ms: 1_000,
           write_opts: [pool_timeout: 100]}
        )

      # batch_size 1 flushes at once; checkout times out; chain starts.
      :ok = InfluxElixir.Write.BatchWriter.write(pid, "bw_retry value=1.0")

      assert {:ok, %{total_writes: 0, total_errors: 0}} =
               InfluxElixir.Write.BatchWriter.stats(pid)

      wait_until(fn ->
        {:ok, stats} = InfluxElixir.Write.BatchWriter.stats(pid)
        stats.total_writes == 1
      end)

      InfluxElixir.ClientContract.settle(ctx)

      assert {:ok, [%{"value" => 1.0}]} =
               HTTP.query_sql(ctx.conn, "SELECT value FROM bw_retry", database: ctx.database)

      Task.await(ctx.holder, 10_000)
    end

    test "a 4xx answered on retry discards the batch instead of retrying again", ctx do
      pid =
        start_supervised!(
          {InfluxElixir.Write.BatchWriter,
           connection: ctx.conn,
           client: HTTP,
           database: ctx.database,
           batch_size: 1,
           flush_interval_ms: 60_000,
           max_retries: 3,
           base_retry_delay_ms: 1_000,
           write_opts: [pool_timeout: 100]}
        )

      :ok = InfluxElixir.Write.BatchWriter.write(pid, "not line protocol!!!")

      wait_until(fn ->
        {:ok, stats} = InfluxElixir.Write.BatchWriter.stats(pid)
        stats.total_errors == 1
      end)

      # The chain is over: a valid batch goes straight through.
      assert :ok = InfluxElixir.Write.BatchWriter.write_sync(pid, "bw_retry value=2.0")

      assert {:ok, %{total_errors: 1, total_writes: 1}} =
               InfluxElixir.Write.BatchWriter.stats(pid)
    end
  end

  # Polls `fun` with a hard deadline instead of a fixed sleep.
  defp wait_until(fun, deadline_ms \\ 10_000) do
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
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end
end
