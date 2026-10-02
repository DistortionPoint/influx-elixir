defmodule InfluxElixir.Client.HTTPTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.HTTP
  alias InfluxElixir.StreamError

  # ---------------------------------------------------------------------------
  # init_connection — :database resolution parity with Client.Local
  #
  # Regression coverage for issue #2: both impls must resolve the same default
  # database for the same config so a config is a drop-in replacement.
  # ---------------------------------------------------------------------------

  describe "init_connection/1 — :database resolution" do
    test "passes :database through unchanged" do
      {:ok, conn} = HTTP.init_connection(host: "h", token: "t", database: "primary")
      assert Keyword.get(conn, :database) == "primary"
    end

    test "defaults :database to first of :databases when singular missing" do
      {:ok, conn} =
        HTTP.init_connection(host: "h", token: "t", databases: ["a", "b"])

      assert Keyword.get(conn, :database) == "a"
    end

    test "preserves :database when both keys are given" do
      {:ok, conn} =
        HTTP.init_connection(
          host: "h",
          token: "t",
          database: "primary",
          databases: ["a", "b"]
        )

      assert Keyword.get(conn, :database) == "primary"
    end

    test "leaves :database absent when neither key is given" do
      {:ok, conn} = HTTP.init_connection(host: "h", token: "t")
      assert Keyword.get(conn, :database) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Timeouts (issues #8 and #14)
  #
  # The HTTP transport once dropped :timeout on the floor. opts > connection >
  # default, for the receive timeout and for the pool checkout alike. A server
  # that accepts a connection and never answers makes the precedence show: the
  # request returns when the timeout that won runs out, or not at all.
  # ---------------------------------------------------------------------------

  @timed_out {:error, {:connection_error, %Mint.TransportError{reason: :timeout}}}

  # The port of a listener that accepts connections and says nothing; the
  # test process is told (`:held`) each time it has taken one.
  defp black_hole do
    owner = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, backlog: 128])
    {:ok, port} = :inet.port(listener)
    spawn(fn -> accept_and_hold(listener, owner, []) end)
    port
  end

  defp accept_and_hold(listener, owner, sockets) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        send(owner, :held)
        accept_and_hold(listener, owner, [socket | sockets])

      {:error, _closed} ->
        :ok
    end
  end

  # A pool of one connection, so a second request has to wait for the first.
  defp connection(port, extra) do
    finch = :"http_test_finch_#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: finch, pools: %{default: [size: 1]}}, id: finch)

    [host: "127.0.0.1", port: port, scheme: :http, token: "t", database: "db", finch_name: finch] ++
      extra
  end

  # The request's answer, or `:hung` when it is still waiting after `wait` ms.
  # Each wait is well below the timeout a wrong precedence would apply (30 s
  # or more for the receive timeout; Finch's 5 s for the pool checkout), and
  # far above the one under test, so a loaded machine cannot flip the result.
  defp answer_within(wait, fun) do
    task = Task.async(fun)

    case Task.yield(task, wait) || Task.shutdown(task, :brutal_kill) do
      {:ok, answer} -> answer
      _no_answer -> :hung
    end
  end

  # The first request holds the pool's only connection while the black hole
  # keeps it waiting for an answer.
  defp hold_the_connection(conn) do
    task = Task.async(fn -> HTTP.query_sql(conn, "SELECT 1", timeout: 5_000) end)
    assert_receive :held, 2_000
    task
  end

  describe "the receive timeout" do
    test "the option wins over the connection's" do
      conn = connection(black_hole(), timeout: 60_000)

      assert answer_within(20_000, fn -> HTTP.query_sql(conn, "SELECT 1", timeout: 150) end) ==
               @timed_out
    end

    test "the connection's applies when the option is absent" do
      conn = connection(black_hole(), timeout: 150)
      assert answer_within(20_000, fn -> HTTP.query_sql(conn, "SELECT 1") end) == @timed_out
    end

    test "a nil option falls through to the connection's" do
      conn = connection(black_hole(), timeout: 150)

      assert answer_within(20_000, fn -> HTTP.query_sql(conn, "SELECT 1", timeout: nil) end) ==
               @timed_out
    end

    test "every query function reads it" do
      conn = connection(black_hole(), timeout: 150)

      for call <- [
            fn -> HTTP.query_sql(conn, "SELECT 1") end,
            fn -> HTTP.execute_sql(conn, "SELECT 1") end,
            fn -> HTTP.query_influxql(conn, "SELECT 1") end
          ] do
        assert {:error, {:connection_error, %Mint.TransportError{reason: :timeout}}} =
                 answer_within(20_000, call)
      end
    end

    test "falls back to 30 seconds when neither names one" do
      # A wait that long is not worth a test: the default is read directly.
      assert HTTP.resolve_timeout([], host: "h") == 30_000
    end
  end

  describe "the pool checkout timeout" do
    test "the option wins over the connection's" do
      conn = connection(black_hole(), pool_timeout: 60_000)
      holder = hold_the_connection(conn)

      assert answer_within(3_000, fn -> HTTP.query_sql(conn, "SELECT 1", pool_timeout: 100) end) ==
               {:error, {:connection_error, :pool_timeout}}

      Task.shutdown(holder, :brutal_kill)
    end

    test "the connection's applies when the option is absent, and is independent of :timeout" do
      conn = connection(black_hole(), pool_timeout: 100, timeout: 180_000)
      holder = hold_the_connection(conn)

      assert answer_within(3_000, fn -> HTTP.query_sql(conn, "SELECT 1") end) ==
               {:error, {:connection_error, :pool_timeout}}

      Task.shutdown(holder, :brutal_kill)
    end

    test "falls back to Finch's 5 seconds when neither names one" do
      assert HTTP.resolve_pool_timeout([], []) == 5_000
      assert HTTP.resolve_pool_timeout([timeout: 180_000], timeout: 180_000) == 5_000
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql_stream/3 — error surfacing (issue #10)
  #
  # The stream must never swallow errors as "zero rows". Each error class is
  # raised as an InfluxElixir.StreamError when the stream is enumerated. These
  # tests use a real Finch pool (no mocking) — the transport case points at a
  # closed port so the failure is a genuine connection error.
  # ---------------------------------------------------------------------------

  describe "query_sql_stream/3 — error surfacing" do
    test "raises :no_database when no database can be resolved" do
      conn = [host: "h", token: "t", finch_name: :unused_finch]
      stream = HTTP.query_sql_stream(conn, "SELECT 1")

      for _enumeration <- 1..2 do
        error = assert_raise StreamError, fn -> Enum.to_list(stream) end
        assert %StreamError{kind: :no_database, status: nil, body: nil, reason: nil} = error
      end
    end

    test "raises :transport on a connection failure rather than yielding []" do
      conn = connection(1, [])
      stream = HTTP.query_sql_stream(conn, "SELECT 1")

      # Port 1 is not listening — Finch will fail to connect.
      error = assert_raise StreamError, fn -> Enum.to_list(stream) end

      assert %StreamError{
               kind: :transport,
               status: nil,
               body: nil,
               reason: %Mint.TransportError{reason: :econnrefused}
             } = error
    end
  end

  # ---------------------------------------------------------------------------
  # What a query carries — parameters the engine cannot be sent
  #
  # The body of a request is pinned against the engine in the SQL contract
  # (`InfluxElixir.Contract.SQLParser`); here is what is refused before any
  # request is made, and that `params: nil` is not one of them.
  # ---------------------------------------------------------------------------

  describe "a parameter that cannot be sent" do
    @closed {:error, {:connection_error, %Mint.TransportError{reason: :econnrefused}}}

    test "is refused by every query function before anything is sent" do
      conn = [host: "localhost", port: 1, scheme: "http", token: "t", database: "db"]

      for {params, error} <- [
            {%{p: Decimal.new("NaN")}, {:invalid_param, "p", :non_finite_decimal}},
            {%{p: Decimal.new("-Infinity")}, {:invalid_param, "p", :non_finite_decimal}},
            {%{p: {1, 2}}, {:invalid_param, "p", :unsupported_type}},
            {%{{1, 2} => 1}, {:invalid_param, "{1, 2}", :unsupported_key}},
            {5, {:invalid_param, "5", :unsupported_params}}
          ] do
        opts = [params: params]

        assert HTTP.query_sql(conn, "select 1", opts) == {:error, error}
        assert HTTP.execute_sql(conn, "select 1", opts) == {:error, error}

        stream_error =
          assert_raise StreamError, fn ->
            conn |> HTTP.query_sql_stream("select 1", opts) |> Enum.to_list()
          end

        assert %StreamError{kind: :transport, status: nil, body: nil, reason: ^error} =
                 stream_error
      end
    end

    test "does not include nil, an empty list or a keyword list" do
      conn = connection(1, [])

      for params <- [nil, [], [p: 1], %{}, %{p: Decimal.new("1000.00")}] do
        assert HTTP.query_sql(conn, "select 1", params: params) == @closed, inspect(params)
        assert HTTP.execute_sql(conn, "select 1", params: params) == @closed, inspect(params)
      end
    end
  end
end
