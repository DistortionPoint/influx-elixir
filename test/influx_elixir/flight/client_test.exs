defmodule InfluxElixir.Flight.ClientTest do
  use ExUnit.Case, async: true

  doctest InfluxElixir.Flight.Client, only: [build_ticket_payload: 2, build_ticket: 2]

  alias InfluxElixir.Flight.Client
  alias InfluxElixir.Flight.Proto.{FlightData, Ticket}
  alias InfluxElixir.TestSupport.{Await, ClosedPort}

  describe "build_ticket_payload/2" do
    test "is the JSON InfluxDB 3 reads: the database, the statement as given, sql" do
      sql = "SELECT time, value FROM cpu WHERE host = $host ORDER BY time DESC LIMIT 100"

      assert "metrics_prod" |> Client.build_ticket_payload(sql) |> Jason.decode!() ===
               %{"database" => "metrics_prod", "sql_query" => sql, "query_type" => "sql"}
    end
  end

  describe "build_ticket/2" do
    test "is a Ticket carrying that JSON, unchanged through protobuf encoding" do
      ticket = Client.build_ticket("sensors", "SELECT * FROM temp")

      assert ticket === %Ticket{
               ticket: Client.build_ticket_payload("sensors", "SELECT * FROM temp")
             }

      assert ticket |> Protobuf.encode() |> Protobuf.decode(Ticket) === ticket
    end
  end

  describe "query/3 — connection validation" do
    test "raises KeyError when host is missing" do
      conn = %{token: "tok", database: "db"}

      assert_raise KeyError, fn ->
        Client.query(conn, "SELECT 1")
      end
    end

    test "raises KeyError when token is missing" do
      conn = %{host: "localhost", database: "db"}

      assert_raise KeyError, fn ->
        Client.query(conn, "SELECT 1")
      end
    end

    # The gRPC client cannot connect to an IPv6 address (verified against Core, which answers
    # on [::1] over HTTP): a clear error before any connection, where it raised or said
    # :no_addresses.
    test "an IPv6 host is an error that names it, before any connection" do
      for host <- ["[::1]", "[fe80::1]", "::1"] do
        conn = %{host: host, port: 8181, token: "tok", database: "db"}
        assert Client.query(conn, "SELECT 1", tls: false) === {:error, {:ipv6_unsupported, host}}
      end
    end

    test "a host that is not a host name is an error that names it, before any connection" do
      # A port belongs in `:port`: one colon is no IPv6 address.
      for host <- [
            "localhost:8181",
            "host with spaces",
            "host\nname",
            "host/path",
            "user@localhost",
            "localhost?q=1",
            "localhost#frag",
            nil,
            ~c"localhost",
            "",
            1
          ] do
        conn = %{host: host, port: 8181, token: "tok", database: "db"}
        assert Client.query(conn, "SELECT 1", tls: false) === {:error, {:invalid_host, host}}
      end
    end

    test "a token that is not a string is an error, before any connection" do
      conn = %{host: "localhost", port: ClosedPort.port(), token: %{}, database: "db"}
      assert Client.query(conn, "SELECT 1", tls: false) === {:error, {:invalid_token, %{}}}
    end

    test "a statement or a database JSON cannot carry is an error, before any connection" do
      conn = %{host: "localhost", port: ClosedPort.port(), token: "tok", database: "db"}

      assert Client.query(conn, <<0xFF>>, tls: false) ===
               {:error, {:unencodable_body, "invalid byte 0xFF in <<255>>"}}

      assert {:error, {:unencodable_body, "protocol Jason.Encoder not implemented for" <> _rest}} =
               Client.query(%{conn | database: {1}}, "SELECT 1", tls: false)
    end

    test "raises KeyError when database is missing" do
      conn = %{host: "localhost", token: "tok"}

      assert_raise KeyError, fn ->
        Client.query(conn, "SELECT 1")
      end
    end

    @tag :capture_log
    test "returns {:error, :no_addresses} when nothing listens on the port" do
      conn = %{
        host: "127.0.0.1",
        token: "tok",
        database: "db",
        port: ClosedPort.port()
      }

      # The bound is not under test here; it only has to outlast a refused
      # connection on a loaded machine.
      assert Client.query(conn, "SELECT 1", tls: false, timeout: 30_000) ===
               {:error, :no_addresses}
    end

    test "a non-map connection or invalid options returns a tagged error, never a raise" do
      for bad_conn <- [[host: "localhost"], "localhost", :conn, 123] do
        assert Client.query(bad_conn, "SELECT 1") === {:error, {:invalid_connection, bad_conn}}
      end

      conn = %{host: "localhost", port: 8181, token: "tok", database: "db"}

      for bad_opts <- [
            %{},
            :bad,
            "opts",
            [:a | :b],
            [1, 2],
            [timeout: false],
            [timeout: -1],
            [timeout: "30s"],
            [connect_timeout: false],
            [connect_timeout: -1],
            [connect_timeout: "5s"],
            [tls: "false"],
            [tls: 1]
          ] do
        assert Client.query(conn, "SELECT 1", bad_opts) === {:error, {:invalid_options, bad_opts}}
      end
    end

    @tag :capture_log
    test "tls: nil uses port-based TLS default and timeout: :infinity is accepted" do
      conn = %{
        host: "127.0.0.1",
        token: "tok",
        database: "db",
        port: ClosedPort.port()
      }

      assert Client.query(conn, "SELECT 1", tls: nil, timeout: :infinity) ===
               {:error, :no_addresses}

      assert Client.query(conn, "SELECT 1", tls: true, timeout: :infinity) ===
               {:error, :no_addresses}

      assert Client.query(%{conn | host: "a" <> <<0xFF>>}, "SELECT 1", tls: false) ===
               {:error, {:invalid_host, "a" <> <<0xFF>>}}
    end

    test "an invalid port is {:error, {:invalid_port, port}}, while port: nil defaults to 443" do
      base = %{host: "localhost", token: "tok", database: "db"}

      for bad_port <- [0, -1, 65_536, "8181", false, :port, {443}] do
        assert Client.query(Map.put(base, :port, bad_port), "SELECT 1", tls: false) ===
                 {:error, {:invalid_port, bad_port}}
      end

      assert Client.query(%{base | host: ""}, "SELECT 1", tls: false) ===
               {:error, {:invalid_host, ""}}
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_connect_timeout/1 precedence. Read from the function: through `query/3` the
  # timeout chosen shows only as how long a connect that never answers takes to fail.
  # ---------------------------------------------------------------------------

  describe "resolve_connect_timeout/1" do
    test "uses :connect_timeout when set" do
      assert Client.resolve_connect_timeout(connect_timeout: 100, timeout: 5_000) ===
               100
    end

    test "falls back to :timeout when :connect_timeout is absent" do
      assert Client.resolve_connect_timeout(timeout: 5_000) === 5_000
    end

    test "falls back to 30s default when neither is set" do
      assert Client.resolve_connect_timeout([]) === 30_000
    end
  end

  # ---------------------------------------------------------------------------
  # bounded_connect/2 wall-clock guarantee
  #
  # The grpc 0.11 adapter does not expose a connect-phase timeout, so the call runs in a
  # monitored process that is killed at the bound. The bound applies regardless of what the
  # underlying gRPC stub does internally.
  # ---------------------------------------------------------------------------

  describe "bounded_connect/2" do
    test "returns the fn's result when it completes in time" do
      assert Client.bounded_connect(fn -> {:ok, :channel} end, Await.bound()) === {:ok, :channel}
    end

    test "a raise, a throw or an exit inside the fn is an error tuple, not the caller's crash" do
      for {fun, banner} <- [
            {fn -> raise "boom" end, "** (RuntimeError) boom"},
            {fn -> throw(:x) end, "** (throw) :x"},
            {fn -> exit(:boom) end, "** (exit) :boom"},
            {fn -> exit(:normal) end, "** (exit) normal"},
            {fn -> Process.exit(self(), :kill) end, "killed"}
          ] do
        assert Client.bounded_connect(fun, Await.bound()) === {:error, {:connect_failed, banner}}
      end
    end

    test "a caller that traps exits gets the same error tuple" do
      Process.flag(:trap_exit, true)

      assert Client.bounded_connect(fn -> exit(:boom) end, Await.bound()) ===
               {:error, {:connect_failed, "** (exit) :boom"}}

      refute_received {:EXIT, _pid, _reason}
    end

    test "propagates the fn's error tuple" do
      assert Client.bounded_connect(fn -> {:error, :nxdomain} end, Await.bound()) ===
               {:error, :nxdomain}
    end

    test "returns {:error, :connect_timeout} when fn exceeds the bound, and leaves nothing" do
      assert Client.bounded_connect(fn -> Process.sleep(:infinity) end, 50) ===
               {:error, :connect_timeout}

      assert Client.bounded_connect(fn -> {:ok, :late} end, 0) ===
               {:error, :connect_timeout}

      # The process is gone and the caller's mailbox holds nothing of it.
      assert Process.info(self(), :messages) === {:messages, []}
    end
  end

  describe "normalize_error/1 and collect_stream/1" do
    test "maps gRPC status codes to HTTP equivalents and deadline exceeded to :timeout" do
      assert Client.normalize_error({:error, %GRPC.RPCError{status: 4, message: "deadline"}}) ===
               {:error, :timeout}

      for {grpc_status, http_status} <- [
            {3, 400},
            {5, 404},
            {6, 409},
            {7, 403},
            {8, 429},
            {12, 501},
            {13, 500},
            {14, 503},
            {16, 401},
            {2, 500}
          ] do
        err = %GRPC.RPCError{status: grpc_status, message: "msg-#{grpc_status}"}

        assert Client.normalize_error({:error, err}) ===
                 {:error, %{status: http_status, body: "msg-#{grpc_status}"}}
      end

      assert Client.normalize_error({:ok, []}) === {:ok, []}
      assert Client.normalize_error({:error, :timeout}) === {:error, :timeout}
    end

    test "collect_stream/1 accumulates FlightData chunks in order and halts on error" do
      fd1 = %FlightData{data_header: "h1", data_body: "b1"}
      fd2 = %FlightData{data_header: "h2", data_body: "b2"}

      assert Client.collect_stream([{:ok, fd1}, {:ok, fd2}]) === {:ok, [fd1, fd2]}
      assert Client.collect_stream([]) === {:ok, []}

      assert Client.collect_stream([{:ok, fd1}, {:error, :stream_failed}, {:ok, fd2}]) ===
               {:error, :stream_failed}
    end
  end
end
