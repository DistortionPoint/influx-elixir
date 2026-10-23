defmodule InfluxElixir.Flight.Client do
  @moduledoc """
  Arrow Flight gRPC client for high-throughput query transport.

  Connects to an InfluxDB v3 Flight endpoint, encodes SQL queries as
  JSON-bearing `Ticket` messages, streams back `FlightData` chunks via
  the `DoGet` RPC, and delegates binary decoding to `InfluxElixir.Flight.Reader`.

  ## Transport

  InfluxDB v3 exposes its Flight service on the same host as the HTTP API,
  typically port 443 (TLS). The `host` in the connection map must be the plain
  hostname (no scheme); TLS is configured via the `:tls` option.

  ## Authentication

  Bearer-token auth is passed as gRPC metadata on every call:

      Authorization: Bearer <token>

  An empty token (`""`, a server started without auth) sends no `authorization` metadata,
  as the HTTP transport sends no header.

  ## Example

      conn = %{host: "us-east-1.influxdb.io", token: "my-token",
               database: "mydb", port: 443}

      {:ok, rows} = InfluxElixir.Flight.Client.query(conn, "SELECT * FROM cpu LIMIT 10")

  ## Options

    * `:timeout` — wall-clock bound in milliseconds on the call and the streaming of its
      whole result (default: `30_000`; through `InfluxElixir.query_sql/3` the call's, then
      the connection's `:timeout`). A server that accepts the connection and stays silent,
      or that stops sending, is `{:error, :timeout}` when it is spent.
    * `:connect_timeout` — bound on the gRPC channel establishment phase
      (default: same value as `:timeout`). Without this bound, a stuck TLS
      handshake against an unresponsive host can hang far longer than
      the in-stream `:timeout` would suggest.
    * `:tls` — `true` to use TLS (default: `true` when port is 443)
  """

  alias InfluxElixir.Client.Options
  alias InfluxElixir.Config
  alias InfluxElixir.Flight.Proto.{FlightData, FlightService, Ticket}
  alias InfluxElixir.Flight.Reader

  @default_timeout 30_000
  @default_port 443

  @typedoc """
  A connection map with the keys used by this client.

    * `:host` — hostname of the InfluxDB Flight endpoint (required)
    * `:token` — bearer token for authentication (required)
    * `:database` — InfluxDB database / bucket name (required)
    * `:port` — gRPC port (default: `443`)
  """
  @type connection :: %{
          required(:host) => binary(),
          required(:token) => binary(),
          required(:database) => binary(),
          optional(:port) => non_neg_integer()
        }

  @doc """
  Executes a SQL query against InfluxDB v3 via Arrow Flight `DoGet`.

  Builds a `Ticket` with a JSON payload understood by InfluxDB v3, opens a
  gRPC channel, streams `FlightData` messages, and decodes them into a list
  of row maps.

  ## Parameters

    * `connection` — map with `:host`, `:token`, `:database`, and optional `:port`
    * `sql` — SQL query string
    * `opts` — keyword options

  ## Options

    * `:timeout` — milliseconds the call and its whole stream may take (default: `30_000`);
      the call runs in a monitored process that is killed at the bound
    * `:connect_timeout` — milliseconds to establish the channel (default: `:timeout`)
    * `:tls` — force TLS on/off; inferred from port when omitted

  ## Returns

    * `{:ok, [map()]}` — list of row maps (column name → value)
    * `{:error, {:ipv6_unsupported, host}}` — the host is an IPv6 address: the gRPC
      client cannot connect to one (verified against InfluxDB 3 Core, which answers on
      `[::1]` over HTTP); use the HTTP transport for it
    * `{:error, {:invalid_host, host}}` — the host is not a host name (a port belongs in
      `:port`, not `"host:8181"`)
    * `{:error, {:invalid_token, token}}` — the token is not a string
    * `{:error, {:unencodable_body, message}}` — the database or the statement is not
      what JSON can carry (text that is not UTF-8, a tuple)

    * `{:error, :timeout}` — the call and its stream were not finished in `:timeout`
      milliseconds, or the server's own deadline expired (gRPC status 4)
    * `{:error, :connect_timeout}` — the channel was not open in `:connect_timeout`
    * `{:error, %{status: http_status, body: message}}` — the server refused the query, in
      the shape the HTTP transport gives. The gRPC status becomes the nearest HTTP one:
      3 (`INVALID_ARGUMENT`) 400, 16 (`UNAUTHENTICATED`) 401, 7 (`PERMISSION_DENIED`) 403,
      5 (`NOT_FOUND`) 404, 6 409, 8 429, 12 501, 14 503, any other 500. The statuses 3 and
      13 were checked against InfluxDB 3 Core 3.10.1 with the same failing statements over
      both transports; the others are the standard mapping, not observed.
      The statuses do not always agree with HTTP's (a schema error, `select nosuch from
      m`, is 500 over HTTP and 400 here; a database that does not exist is 404 over HTTP
      and 500 here, as Flight answers it `INTERNAL`), and the Flight message keeps the
      engine's prefix (`Error while logically planning query: ...`).
    * `{:error, term()}` — any other transport or decode error

  A connection without `:host`, `:token` or `:database` raises `KeyError`: that is a
  programming error, not an answer.

  ## Example

      conn = %{host: "cloud2.influxdata.com", token: "my-tok", database: "sensors"}
      {:ok, rows} = InfluxElixir.Flight.Client.query(conn, "SELECT * FROM cpu LIMIT 5")
  """
  @spec query(connection(), binary(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def query(connection, sql, opts \\ [])

  def query(connection, _sql, _opts) when not is_map(connection),
    do: {:error, {:invalid_connection, connection}}

  def query(connection, sql, opts) do
    if Options.keyword?(opts) and valid_options?(opts) do
      query_with_opts(connection, sql, opts)
    else
      {:error, {:invalid_options, opts}}
    end
  end

  @spec valid_options?(keyword()) :: boolean()
  defp valid_options?(opts) do
    valid_timeout_opt?(Keyword.get(opts, :timeout)) and
      valid_timeout_opt?(Keyword.get(opts, :connect_timeout)) and
      valid_tls_opt?(Keyword.get(opts, :tls))
  end

  @spec valid_timeout_opt?(term()) :: boolean()
  defp valid_timeout_opt?(nil), do: true
  defp valid_timeout_opt?(:infinity), do: true
  defp valid_timeout_opt?(timeout), do: is_integer(timeout) and timeout >= 0

  @spec valid_tls_opt?(term()) :: boolean()
  defp valid_tls_opt?(nil), do: true
  defp valid_tls_opt?(tls), do: is_boolean(tls)

  @spec query_with_opts(connection(), term(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defp query_with_opts(connection, sql, opts) do
    timeout = resolve_timeout(opts)

    # Validate required keys eagerly before attempting any network calls.
    # Map.fetch!/2 raises KeyError with a clear message if a key is missing.
    host = Map.fetch!(connection, :host)
    token = Map.fetch!(connection, :token)
    database = Map.fetch!(connection, :database)

    # The channel is closed on every path after connect, a raise included;
    # a failed DoGet used to leak it.
    with :ok <- check_host(host),
         {:ok, port} <- check_port(Map.get(connection, :port)),
         :ok <- check_token(token),
         {:ok, payload} <- ticket_payload(database, sql),
         {:ok, channel} <- open_channel(host, port, opts) do
      try do
        with {:ok, flight_data_list} <- fetch(channel, token, payload, timeout) do
          Reader.decode_flight_data(flight_data_list)
        end
      after
        :ok = disconnect(channel)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # An IPv6 address, bracketed (`[::1]`, as `Config` takes it) or bare (`::1`), has two
  # colons or more; one colon is a port written into the host, which `:port` carries.
  @spec check_host(term()) :: :ok | {:error, term()}
  defp check_host("[" <> _address = host), do: {:error, {:ipv6_unsupported, host}}

  defp check_host(host) when is_binary(host) do
    if length(:binary.matches(host, ":")) >= 2 do
      {:error, {:ipv6_unsupported, host}}
    else
      case Config.host(host) do
        {:ok, _host} -> :ok
        {:error, _reason} -> {:error, {:invalid_host, host}}
      end
    end
  end

  defp check_host(host), do: {:error, {:invalid_host, host}}

  @spec check_port(term()) :: {:ok, pos_integer()} | {:error, {:invalid_port, term()}}
  defp check_port(nil), do: {:ok, @default_port}
  defp check_port(port) when is_integer(port) and port in 1..65_535, do: {:ok, port}
  defp check_port(port), do: {:error, {:invalid_port, port}}

  @spec check_token(term()) :: :ok | {:error, {:invalid_token, term()}}
  defp check_token(token) when is_binary(token), do: :ok
  defp check_token(token), do: {:error, {:invalid_token, token}}

  # The ticket is JSON: a database or a statement JSON cannot carry (text that is not UTF-8,
  # a tuple) is the caller's error before any connection, as over HTTP.
  @spec ticket_payload(term(), term()) ::
          {:ok, binary()} | {:error, {:unencodable_body, binary()}}
  defp ticket_payload(database, sql) do
    case Jason.encode(ticket(database, sql)) do
      {:ok, payload} -> {:ok, payload}
      {:error, error} -> {:error, {:unencodable_body, Exception.message(error)}}
    end
  rescue
    error in [FunctionClauseError, Protocol.UndefinedError, Jason.EncodeError, ArgumentError] ->
      {:error, {:unencodable_body, Exception.message(error)}}
  end

  @spec open_channel(binary(), pos_integer(), keyword()) ::
          {:ok, GRPC.Channel.t()} | {:error, term()}
  defp open_channel(host, port, opts) do
    use_tls =
      case Keyword.get(opts, :tls) do
        nil -> port == 443
        tls -> tls
      end

    connect_timeout = resolve_connect_timeout(opts)

    addr = "#{host}:#{port}"

    # Default to the Mint adapter so we don't depend on `:gun`. Mint is a hard
    # dep in `grpc 0.11` and reaches us transitively via `finch` on `grpc 1.0`
    # (where the Gun adapter became optional and isn't pulled in by default).
    base_opts = [adapter: GRPC.Client.Adapters.Mint]

    grpc_opts =
      if use_tls do
        [{:cred, GRPC.Credential.new(ssl: [])} | base_opts]
      else
        base_opts
      end

    bounded_connect(fn -> GRPC.Stub.connect(addr, grpc_opts) end, connect_timeout)
  end

  @spec resolve_timeout(keyword()) :: timeout()
  defp resolve_timeout(opts) do
    case Keyword.get(opts, :timeout) do
      nil -> @default_timeout
      timeout -> timeout
    end
  end

  @doc false
  # Resolves the connect-phase timeout: :connect_timeout → :timeout → default.
  @spec resolve_connect_timeout(keyword()) :: timeout()
  def resolve_connect_timeout(opts) do
    case Keyword.get(opts, :connect_timeout) do
      nil -> resolve_timeout(opts)
      connect_timeout -> connect_timeout
    end
  end

  @doc false
  # Bounds the wall-clock duration of `fun`. Returns whatever `fun` returns
  # if it completes in time, or `{:error, :connect_timeout}` if not. Runs it
  # in a monitored process so the bound is library-version-agnostic — it does
  # not rely on the underlying gRPC adapter exposing a connect-timeout
  # knob (which `grpc 0.11` does not).
  #
  # The process is monitored, never linked: a raise, a throw or an exit inside `fun` (the
  # gRPC client raises on an address it cannot read) is the caller's
  # `{:error, {:connect_failed, message}}`, never its crash, whether or not it traps exits.
  @spec bounded_connect((-> result), timeout()) ::
          result | {:error, :connect_timeout | {:connect_failed, binary()}}
        when result: term()
  def bounded_connect(fun, timeout) when is_function(fun, 0),
    do: bounded(fun, timeout, {:error, :connect_timeout}, :connect_failed, &release_channel/1)

  # A channel opened just as the bound ran out is closed, never left open with no owner.
  @spec release_channel(term()) :: :ok
  defp release_channel({:ok, %GRPC.Channel{} = channel}), do: disconnect(channel)
  defp release_channel(_result), do: :ok

  # Runs `fun` in a monitored process for at most `timeout` ms: its result, `on_timeout` past
  # the bound, or `{:error, {failure, message}}` when it raises, throws or exits. A result
  # that comes too late is handed to `release` and dropped.
  @spec bounded((-> result), timeout(), term(), atom(), (result -> :ok)) ::
          result | term()
        when result: term()
  defp bounded(fun, timeout, on_timeout, failure, release) do
    caller = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            fun.()
          catch
            kind, reason -> {:error, {failure, Exception.format_banner(kind, reason)}}
          end

        send(caller, {tag, result})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {failure, Exception.format_exit(reason)}}
    after
      timeout ->
        Process.exit(pid, :kill)

        # The :DOWN comes after every message the process sent, so a result sent just before
        # the kill is in the mailbox by then: released, never left in the caller's mailbox.
        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end

        receive do
          {^tag, late} -> release.(late)
        after
          0 -> :ok
        end

        on_timeout
    end
  end

  # The call and the collecting of its stream run in one monitored process (the adapter
  # delivers the stream to the process that made the call), bounded by wall-clock time: the
  # gRPC deadline is only a request header and a silent peer never answers it. Past the
  # bound the process is killed and the answer is `{:error, :timeout}`; the caller closes the
  # channel.
  @spec fetch(GRPC.Channel.t(), binary(), binary(), timeout()) ::
          {:ok, [FlightData.t()]} | {:error, term()}
  defp fetch(channel, token, payload, timeout) do
    fn -> do_get(channel, token, payload, timeout) end
    |> bounded(timeout, {:error, :timeout}, :flight_failed, fn _rows -> :ok end)
    |> normalize_error()
  end

  @spec do_get(GRPC.Channel.t(), binary(), binary(), timeout()) ::
          {:ok, [FlightData.t()]} | {:error, term()}
  defp do_get(channel, token, payload, timeout) do
    call_opts = [timeout: timeout, metadata: auth_metadata(token)]

    case FlightService.Stub.do_get(channel, %Ticket{ticket: payload}, call_opts) do
      {:ok, stream} -> collect_stream(stream)
      {:error, reason} -> {:error, reason}
    end
  end

  # `Authorization: Bearer <token>` as over HTTP, and none for an empty token (a server
  # without auth) rather than a header with nothing after `Bearer`.
  @spec auth_metadata(binary()) :: [{binary(), binary()}]
  defp auth_metadata(""), do: []
  defp auth_metadata(token), do: [{"authorization", "Bearer " <> token}]

  @doc false
  # A failed call is the shape the HTTP transport gives: `%{status: http_status, body: message}`.
  # The gRPC status becomes the nearest HTTP one (listed in `query/3`'s doc); an expired
  # deadline is `:timeout`.
  @spec normalize_error(term()) :: term()
  def normalize_error({:error, %GRPC.RPCError{status: 4}}), do: {:error, :timeout}

  def normalize_error({:error, %GRPC.RPCError{status: status, message: message}}),
    do: {:error, %{status: http_status(status), body: message}}

  def normalize_error(other), do: other

  @spec http_status(integer()) :: pos_integer()
  defp http_status(3), do: 400
  defp http_status(16), do: 401
  defp http_status(7), do: 403
  defp http_status(5), do: 404
  defp http_status(6), do: 409
  defp http_status(8), do: 429
  defp http_status(12), do: 501
  defp http_status(14), do: 503
  defp http_status(_other), do: 500

  @doc false
  @spec collect_stream(Enumerable.t()) :: {:ok, [FlightData.t()]} | {:error, term()}
  def collect_stream(stream) do
    result =
      Enum.reduce_while(stream, {:ok, []}, fn
        {:ok, %FlightData{} = fd}, {:ok, acc} ->
          {:cont, {:ok, [fd | acc]}}

        {:error, reason}, _acc ->
          {:halt, {:error, reason}}
      end)

    case result do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  @spec disconnect(GRPC.Channel.t()) :: :ok
  defp disconnect(channel) do
    GRPC.Stub.disconnect(channel)
    :ok
  end

  @doc """
  Builds the JSON-encoded ticket payload for an InfluxDB v3 SQL query.

  Exposed for testing and introspection purposes. Text JSON cannot carry (a string
  that is not UTF-8) raises `Jason.EncodeError`; `query/3` answers it as an error.

  ## Parameters

    * `database` — target InfluxDB database name
    * `sql` — SQL query string

  ## Example

      iex> payload = InfluxElixir.Flight.Client.build_ticket_payload("mydb", "SELECT 1")
      iex> Jason.decode!(payload)
      %{"database" => "mydb", "sql_query" => "SELECT 1", "query_type" => "sql"}
  """
  @spec build_ticket_payload(binary(), binary()) :: binary()
  def build_ticket_payload(database, sql), do: Jason.encode!(ticket(database, sql))

  # The JSON InfluxDB 3 reads from a ticket.
  @spec ticket(term(), term()) :: map()
  defp ticket(database, sql),
    do: %{"database" => database, "sql_query" => sql, "query_type" => "sql"}

  @doc """
  Builds a `Ticket` struct for the given database and SQL query.

  Useful for constructing tickets before calling `do_get` directly or for
  inspecting the wire format in tests.

  ## Parameters

    * `database` — target InfluxDB database name
    * `sql` — SQL query string

  ## Example

      iex> t = InfluxElixir.Flight.Client.build_ticket("mydb", "SELECT 1")
      iex> t.ticket |> Jason.decode!() |> Map.fetch!("database")
      "mydb"
  """
  @spec build_ticket(binary(), binary()) :: Ticket.t()
  def build_ticket(database, sql) do
    %Ticket{ticket: build_ticket_payload(database, sql)}
  end
end
