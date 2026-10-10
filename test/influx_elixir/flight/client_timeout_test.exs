defmodule InfluxElixir.Flight.ClientTimeoutTest do
  # A peer that accepts the connection and says nothing used to hold `Flight.Client.query/3`
  # for the gRPC library's own wait (5 s, or 60 s until the peer closed): the `:timeout` was
  # only a request header. It is now a wall-clock bound, and a connection's `:timeout`
  # reaches the Flight transport. No test measures a duration: each asserts the error.
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.HTTP
  alias InfluxElixir.Flight.Client
  alias InfluxElixir.TestServer
  alias InfluxElixir.TestSupport.Await

  # Far past any test: the timeout under test is the other one.
  @never 600_000

  defp flight_connection(port, token \\ ""),
    do: %{host: "127.0.0.1", port: port, token: token, database: "db"}

  describe "Flight.Client.query/3 :timeout" do
    test "a peer that accepts and stays silent is {:error, :timeout}" do
      port = TestServer.black_hole()

      assert Client.query(flight_connection(port), "SELECT 1",
               tls: false,
               connect_timeout: @never,
               timeout: 50
             ) === {:error, :timeout}
    end

    test "the caller is not linked to the process that ran the call" do
      Process.flag(:trap_exit, true)
      port = TestServer.black_hole()

      assert Client.query(flight_connection(port), "SELECT 1",
               tls: false,
               connect_timeout: @never,
               timeout: 50
             ) === {:error, :timeout}

      refute_received {:EXIT, _pid, _reason}
    end
  end

  describe "the connection's :timeout reaches the Flight transport" do
    defp http_connection(extra),
      do:
        [host: "127.0.0.1", token: "", database: "db", scheme: :http, finch_name: :unused] ++
          extra

    test "through Client.HTTP.query_sql/3" do
      port = TestServer.black_hole()
      conn = http_connection(timeout: 50)

      assert HTTP.query_sql(conn, "SELECT 1",
               transport: :flight,
               flight_port: port,
               tls: false,
               connect_timeout: @never
             ) === {:error, :timeout}
    end

    test "the call's :timeout wins over the connection's" do
      port = TestServer.black_hole()
      conn = http_connection(timeout: @never)

      assert HTTP.query_sql(conn, "SELECT 1",
               transport: :flight,
               flight_port: port,
               tls: false,
               connect_timeout: @never,
               timeout: 50
             ) === {:error, :timeout}
    end
  end

  # The bytes the client sends are read off the socket. The HTTP/2 request line names its
  # method (`DoGet`) and the authorization value is written out, so both can be looked for.
  describe "the authorization metadata" do
    defp listen_and_forward(test) do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listener)

      start_supervised!(
        {Task,
         fn ->
           {:ok, socket} = :gen_tcp.accept(listener)
           :ok = :inet.setopts(socket, active: true)
           forward(socket, test)
         end}
      )

      port
    end

    defp forward(socket, test) do
      receive do
        {:tcp, ^socket, data} ->
          send(test, {:bytes, data})
          forward(socket, test)

        {:tcp_closed, ^socket} ->
          :ok
      end
    end

    # Everything sent up to and including the chunk that holds the DoGet request line.
    defp bytes_through_do_get(acc \\ "") do
      if String.contains?(acc, "DoGet") do
        acc
      else
        receive do
          {:bytes, data} -> bytes_through_do_get(acc <> data)
        after
          Await.bound() -> flunk("the client never sent a DoGet request: #{inspect(acc)}")
        end
      end
    end

    defp sent_by(token) do
      port = listen_and_forward(self())

      task =
        Task.async(fn ->
          Client.query(flight_connection(port, token), "SELECT 1", tls: false, timeout: 30_000)
        end)

      bytes = bytes_through_do_get()

      # The server going away ends the call, which closes its channel; killing the call would
      # leave the channel open under the gRPC client's supervisor, which every test shares.
      :ok = stop_supervised(Task)
      assert {:error, _closed} = Task.await(task, Await.bound())
      bytes
    end

    test "a token is sent as a Bearer value" do
      assert String.contains?(sent_by("sekret"), "Bearer sekret")
    end

    test "an empty token sends no authorization at all" do
      refute String.contains?(sent_by(""), "Bearer")
    end
  end
end
