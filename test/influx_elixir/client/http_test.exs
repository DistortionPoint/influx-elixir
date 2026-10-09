defmodule InfluxElixir.Client.HTTPTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.HTTP
  alias InfluxElixir.{StreamError, TestServer}
  alias InfluxElixir.TestSupport.{Await, Check, ClosedPort}

  # ---------------------------------------------------------------------------
  # init_connection — :database resolution parity with Client.Local
  #
  # Regression coverage for issue #2: both impls must resolve the same default
  # database for the same config so a config is a drop-in replacement.
  # ---------------------------------------------------------------------------

  describe "init_connection/1 — :database resolution" do
    test "passes :database through unchanged" do
      {:ok, conn} = HTTP.init_connection(host: "h", token: "t", database: "primary")
      assert Keyword.get(conn, :database) === "primary"
    end

    test "defaults :database to first of :databases when singular missing" do
      {:ok, conn} =
        HTTP.init_connection(host: "h", token: "t", databases: ["a", "b"])

      assert Keyword.get(conn, :database) === "a"
    end

    test "preserves :database when both keys are given" do
      {:ok, conn} =
        HTTP.init_connection(
          host: "h",
          token: "t",
          database: "primary",
          databases: ["a", "b"]
        )

      assert Keyword.get(conn, :database) === "primary"
    end

    test "leaves :database absent when neither key is given" do
      {:ok, conn} = HTTP.init_connection(host: "h", token: "t")
      assert Keyword.get(conn, :database) === nil
    end
  end

  # ---------------------------------------------------------------------------
  # Timeouts (issues #8 and #14)
  #
  # The HTTP transport once dropped :timeout on the floor. opts > connection >
  # default, for the receive timeout and for the pool checkout alike.
  #
  # Two kinds of test, because the defaults (30 s receive, 5 s checkout) cannot be
  # waited for or told apart from a short value that ran out:
  #
  #   * "the option wins" runs a request against a server that never answers. The
  #     option is short (40 ms) and the value that must lose is far above the failure
  #     bound (600 s), so the request answers at once when the option applied and is
  #     still waiting at the bound when the wrong value did. The bound only ends a
  #     failing run; a passing one never depends on it.
  #   * "the connection's applies" and "the defaults" read the resolvers, which the
  #     requests call (public only for this), so nothing waits for a default to expire.
  # ---------------------------------------------------------------------------

  @timed_out {:error, {:connection_error, %Mint.TransportError{reason: :timeout}}}

  # Longer than any failure bound: a request that waits this long has used the wrong value.
  @never 600_000

  # A pool of one connection, so a second request has to wait for the first.
  # The pool for the port is started with Finch, so no request has to start one
  # (a call that times out under load).
  defp connection(port, extra) do
    finch = :"http_test_finch_#{System.unique_integer([:positive])}"
    pools = %{"http://127.0.0.1:#{port}" => [size: 1]}
    start_supervised!({Finch, name: finch, pools: pools}, id: finch)

    [
      host: "127.0.0.1",
      port: port,
      scheme: :http,
      token: "t",
      database: "db",
      finch_name: finch
    ] ++ extra
  end

  # The request's answer, or `:hung` when it is still waiting at the failure bound.
  defp answer(fun) do
    task = Task.async(fun)

    case Task.yield(task, Await.bound()) || Task.shutdown(task, :brutal_kill) do
      {:ok, answer} -> answer
      _no_answer -> :hung
    end
  end

  # The first request holds the pool's only connection while the black hole
  # keeps it waiting for an answer.
  #
  # The holder names its own :pool_timeout: the connection's may be short, and under
  # load the holder would then fail at checkout and never connect. It relies on Finch
  # connecting lazily, inside the checkout of its request: the pool starts without a
  # connection, so the black hole's `:held` is sent exactly when the holder's request
  # has taken the pool's only connection, and every later request must wait for it.
  defp hold_the_connection(conn) do
    task =
      Task.async(fn ->
        HTTP.query_sql(conn, "SELECT 1", timeout: @never, pool_timeout: @never)
      end)

    receive do
      :held -> task
    after
      Await.bound() -> flunk("the holder never connected: #{inspect(Task.yield(task, 0))}")
    end
  end

  describe "the receive timeout" do
    test "the option wins over the connection's" do
      conn = connection(TestServer.black_hole(), timeout: @never)

      assert answer(fn -> HTTP.query_sql(conn, "SELECT 1", timeout: 40) end) === @timed_out
    end

    test "every query function reads the option" do
      conn = connection(TestServer.black_hole(), timeout: @never)

      # Concurrent, so the three timeouts run their course in one wait.
      answers =
        [
          fn -> HTTP.query_sql(conn, "SELECT 1", timeout: 40) end,
          fn -> HTTP.execute_sql(conn, "SELECT 1", timeout: 40) end,
          fn -> HTTP.query_influxql(conn, "SELECT 1", timeout: 40) end
        ]
        |> Enum.map(&Task.async(fn -> answer(&1) end))
        |> Enum.map(&Task.await(&1, 2 * Await.bound()))

      assert answers === [@timed_out, @timed_out, @timed_out]
    end

    test "the connection's applies when the option is absent or nil" do
      assert HTTP.resolve_timeout([], timeout: 40) === 40
      assert HTTP.resolve_timeout([timeout: nil], timeout: 40) === 40
      assert HTTP.resolve_timeout([timeout: 40], timeout: @never) === 40
    end
  end

  describe "the pool checkout timeout" do
    # The holder waits for a connection (up to the bound) and the request after it for an
    # answer (up to the bound again): a hang fails at the second, not at ExUnit's default.
    @describetag timeout: 3 * Await.bound()

    test "the option wins over the connection's" do
      conn = connection(TestServer.black_hole(notify: self()), pool_timeout: @never)
      holder = hold_the_connection(conn)

      query = fn -> HTTP.query_sql(conn, "SELECT 1", pool_timeout: 40) end
      assert answer(query) === {:error, {:connection_error, :pool_timeout}}

      Task.shutdown(holder, :brutal_kill)
    end

    test "the connection's applies when the option is absent, and is independent of :timeout" do
      assert HTTP.resolve_pool_timeout([], pool_timeout: 40, timeout: 180_000) === 40
      assert HTTP.resolve_pool_timeout([pool_timeout: nil], pool_timeout: 40) === 40
      assert HTTP.resolve_pool_timeout([pool_timeout: 40], pool_timeout: @never) === 40
    end
  end

  describe "the timeout defaults" do
    test "are 30 seconds to receive and 5 to check out when nothing names one" do
      assert HTTP.resolve_timeout([], host: "h") === 30_000
      assert HTTP.resolve_pool_timeout([], []) === 5_000
      assert HTTP.resolve_pool_timeout([timeout: 180_000], timeout: 180_000) === 5_000
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql_stream/3 — error surfacing (issue #10)
  #
  # The stream must never swallow errors as "zero rows". Each error class is
  # raised as an InfluxElixir.StreamError when the stream is enumerated. These
  # tests use a real Finch pool (no mocking) — the transport case points at a
  # closed port (`ClosedPort`) so the failure is a genuine connection error.
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
      conn = connection(ClosedPort.port(), [])
      stream = HTTP.query_sql_stream(conn, "SELECT 1")

      # Nothing listens on the port (see ClosedPort): the connection is refused.
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

  describe "text that is not UTF-8" do
    # A request body is JSON, which holds only UTF-8 text; nothing is sent.
    test "is an error from every function that sends it, never a raise" do
      conn = connection(ClosedPort.port(), [])
      bad = <<0xFF>>
      sql = "SELECT '" <> bad <> "'"

      unencodable = fn text ->
        {:error, {:unencodable_body, "invalid byte 0xFF in #{inspect(text)}"}}
      end

      assert HTTP.query_sql(conn, sql) === unencodable.(sql)
      assert HTTP.query_sql(conn, "SELECT 1", database: "d" <> bad) === unencodable.("d" <> bad)
      assert HTTP.execute_sql(conn, sql) === unencodable.(sql)
      assert HTTP.query_influxql(conn, sql) === unencodable.(sql)
      assert HTTP.query_flux(conn, "x" <> bad) === unencodable.("x" <> bad)
      assert HTTP.create_database(conn, "x" <> bad) === unencodable.("x" <> bad)
      assert HTTP.create_token(conn, "t" <> bad) === unencodable.("t" <> bad)

      assert %StreamError{kind: :transport, reason: {:unencodable_body, _message}} =
               assert_raise(StreamError, fn ->
                 conn |> HTTP.query_sql_stream(sql) |> Enum.to_list()
               end)
    end

    test "a value JSON has no form for (a tuple, a pid) is the same error, never a raise" do
      conn = connection(ClosedPort.port(), [])

      # An improper list and a map key JSON has no form for make Jason raise, not return.
      for value <- [{1}, self(), fn -> :x end, [1 | 2], %{{1} => 2}] do
        assert {:error, {:unencodable_body, _message}} = HTTP.query_sql(conn, value)

        assert {:error, {:unencodable_body, _message}} =
                 HTTP.query_sql(conn, "SELECT 1", database: value)

        assert %StreamError{reason: {:unencodable_body, _message}} =
                 assert_raise(StreamError, fn ->
                   conn |> HTTP.query_sql_stream("SELECT 1", database: value) |> Enum.to_list()
                 end)
      end
    end
  end

  describe "a parameter that cannot be sent" do
    @closed {:error, {:connection_error, %Mint.TransportError{reason: :econnrefused}}}

    test "is refused by every query function before anything is sent" do
      conn = [
        host: "localhost",
        port: ClosedPort.port(),
        scheme: "http",
        token: "t",
        database: "db"
      ]

      for {params, error} <- [
            {%{p: Decimal.new("NaN")}, {:invalid_param, "p", :non_finite_decimal}},
            {%{p: Decimal.new("-Infinity")}, {:invalid_param, "p", :non_finite_decimal}},
            {%{p: {1, 2}}, {:invalid_param, "p", :unsupported_type}},
            {%{{1, 2} => 1}, {:invalid_param, "{1, 2}", :unsupported_key}},
            {5, {:invalid_param, "5", :unsupported_params}}
          ] do
        opts = [params: params]

        assert HTTP.query_sql(conn, "select 1", opts) === {:error, error}
        assert HTTP.execute_sql(conn, "select 1", opts) === {:error, error}

        stream_error =
          assert_raise StreamError, fn ->
            conn |> HTTP.query_sql_stream("select 1", opts) |> Enum.to_list()
          end

        assert %StreamError{kind: :transport, status: nil, body: nil, reason: ^error} =
                 stream_error
      end
    end

    test "nil, an empty list, a keyword list, an empty map and a finite Decimal are all sent" do
      conn = connection(ClosedPort.port(), [])

      for params <- [nil, [], [p: 1], %{}, %{p: Decimal.new("1000.00")}] do
        assert HTTP.query_sql(conn, "select 1", params: params) === @closed, inspect(params)
        assert HTTP.execute_sql(conn, "select 1", params: params) === @closed, inspect(params)
      end
    end
  end

  # Every function that takes options also works without them: each default
  # reaches the transport, which here refuses the connection.
  describe "calls without options" do
    test "write, query_flux, create_database, create_bucket and create_token reach the transport" do
      conn = connection(ClosedPort.port(), org: "org")

      calls = [
        write: fn -> HTTP.write(conn, "m v=1i 1") end,
        query_flux: fn -> HTTP.query_flux(conn, "from(bucket: \"b\")") end,
        create_database: fn -> HTTP.create_database(conn, "db") end,
        create_bucket: fn -> HTTP.create_bucket(conn, "b") end,
        create_token: fn -> HTTP.create_token(conn, "t") end
      ]

      Check.check_cases(calls, fn {_name, call} ->
        case call.() do
          @closed -> :ok
          other -> {:mismatch, other}
        end
      end)
    end
  end
end
