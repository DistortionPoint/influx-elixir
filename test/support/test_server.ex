defmodule InfluxElixir.TestServer do
  @moduledoc """
  A real TCP listener a test controls, for the HTTP client's behaviour that
  no healthy server shows: a request that is never answered, a failure on
  demand, an exact count of the requests made.

  Each server is a task under the test's own supervisor, so it owns the
  listener and every socket it takes and all of them close when the test
  ends. Servers listen on `127.0.0.1` only, on a port the system picks.

    * `black_hole/1` accepts connections and says nothing.
    * `controlled/1` announces each request to the test as
      `{:request, handler, body}` and answers it, and closes the
      connection, when the test calls `respond/3`. Requests are served one
      at a time, which is how a single writer process issues them.
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @listen_options [
    :binary,
    ip: {127, 0, 0, 1},
    active: false,
    reuseaddr: true,
    backlog: 128
  ]

  @doc """
  Starts a listener that accepts connections and never answers; returns its
  port. With `notify: pid`, `pid` is sent `:held` each time a connection has
  been taken.
  """
  @spec black_hole(keyword()) :: :inet.port_number()
  def black_hole(opts \\ []) do
    notify = Keyword.get(opts, :notify)
    start_listener(@listen_options, &accept_and_hold(&1, notify, []))
  end

  @doc """
  Starts a listener whose answers the test decides; returns its port.

  The owner receives `{:request, handler, body}` per request, and the
  request waits until `respond(handler, status)`. The owner is the calling
  process unless `owner: pid` names another, for a test that must answer
  while it is itself blocked (stopping a writer that makes a final write).
  With `request_line: true` the message is `{:request, handler, {method, path, body}}`,
  for a test that checks where a request went.
  """
  @spec controlled(keyword()) :: :inet.port_number()
  def controlled(opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    line? = Keyword.get(opts, :request_line, false)
    start_listener([{:packet, :http_bin} | @listen_options], &serve_requests(&1, owner, line?))
  end

  @doc """
  Answers the request `handler` announced with a response of `status`.

  `body` is the whole body (empty by default), or `{:chunks, parts}`: a chunked response
  whose every part is written to the socket on its own, as a streaming server sends it.
  """
  @spec respond(pid(), pos_integer(), binary() | {:chunks, [binary()]}) ::
          {:respond, pos_integer(), binary() | {:chunks, [binary()]}}
  def respond(handler, status, body \\ "") when is_pid(handler),
    do: send(handler, {:respond, status, body})

  @spec start_listener(list(), (port() -> term())) :: :inet.port_number()
  defp start_listener(options, serve) do
    owner = self()
    ref = make_ref()

    start_supervised!(
      Supervisor.child_spec(
        {Task,
         fn ->
           {:ok, listener} = :gen_tcp.listen(0, options)
           {:ok, port} = :inet.port(listener)
           send(owner, {ref, port})
           serve.(listener)
         end},
        id: ref
      )
    )

    receive do
      {^ref, port} -> port
    after
      30_000 -> flunk("the test server did not start listening")
    end
  end

  @spec accept_and_hold(port(), pid() | nil, [port()]) :: :ok
  defp accept_and_hold(listener, notify, sockets) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        if notify, do: send(notify, :held)
        accept_and_hold(listener, notify, [socket | sockets])

      {:error, _closed} ->
        :ok
    end
  end

  # A client that closes before it has sent a whole request (a probe, a
  # timed-out request) is dropped; the listener keeps serving the next one.
  @spec serve_requests(port(), pid(), boolean()) :: no_return()
  defp serve_requests(listener, owner, line?) do
    {:ok, socket} = :gen_tcp.accept(listener)

    case read_request(socket) do
      {:ok, method, path, body} ->
        answer(socket, owner, if(line?, do: {method, path, body}, else: body))

      {:error, _closed} ->
        :ok = :gen_tcp.close(socket)
    end

    serve_requests(listener, owner, line?)
  end

  @spec read_request(port()) :: {:ok, atom() | binary(), term(), binary()} | {:error, term()}
  defp read_request(socket) do
    with {:ok, {:http_request, method, {:abs_path, path}, _version}} <- :gen_tcp.recv(socket, 0),
         {:ok, headers} <- request_headers(socket, %{}) do
      length = headers |> Map.get("content-length", "0") |> String.to_integer()
      :ok = :inet.setopts(socket, packet: :raw)

      with {:ok, body} <- if(length == 0, do: {:ok, ""}, else: :gen_tcp.recv(socket, length)),
           do: {:ok, method, path, body}
    end
  end

  @spec answer(port(), pid(), term()) :: :ok
  defp answer(socket, owner, body) do
    send(owner, {:request, self(), body})

    receive do
      {:respond, status, body} ->
        # The client may have gone while the test decided; nothing to answer then.
        Enum.each(response(status, body), &:gen_tcp.send(socket, &1))
        :ok = :gen_tcp.close(socket)
    end
  end

  # The response as the writes that send it: one for a whole body, one per chunk otherwise.
  @spec response(pos_integer(), binary() | {:chunks, [binary()]}) :: [iodata()]
  defp response(status, {:chunks, parts}) do
    head = "HTTP/1.1 #{status} X\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"
    chunks = Enum.map(parts, &[Integer.to_string(byte_size(&1), 16), "\r\n", &1, "\r\n"])
    [head | chunks] ++ ["0\r\n\r\n"]
  end

  defp response(status, body) do
    [
      "HTTP/1.1 #{status} X\r\ncontent-length: #{byte_size(body)}\r\n" <>
        "connection: close\r\n\r\n" <> body
    ]
  end

  @spec request_headers(port(), %{String.t() => String.t()}) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  defp request_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_header, _position, name, _reserved, value}} ->
        request_headers(socket, Map.put(acc, name |> to_string() |> String.downcase(), value))

      {:ok, :http_eoh} ->
        {:ok, acc}

      {:error, _reason} = error ->
        error
    end
  end
end
