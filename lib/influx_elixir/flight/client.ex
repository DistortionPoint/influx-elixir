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

  ## Example

      conn = %{host: "us-east-1.influxdb.io", token: "my-token",
               database: "mydb", port: 443}

      {:ok, rows} = InfluxElixir.Flight.Client.query(conn, "SELECT * FROM cpu LIMIT 10")

  ## Options

    * `:timeout` — per-call timeout in milliseconds (default: `30_000`)
    * `:connect_timeout` — bound on the gRPC channel establishment phase
      (default: same value as `:timeout`). Without this bound, a stuck TLS
      handshake against an unresponsive host can hang far longer than
      the in-stream `:timeout` would suggest.
    * `:tls` — `true` to use TLS (default: `true` when port is 443)
  """

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

    * `:timeout` — milliseconds to wait for the full stream (default: `30_000`)
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

  A connection without `:host`, `:token` or `:database` raises `KeyError`: that is a
  programming error, not an answer.
    * `{:error, term()}` — gRPC or decode error

  ## Example

      conn = %{host: "cloud2.influxdata.com", token: "my-tok", database: "sensors"}
      {:ok, rows} = InfluxElixir.Flight.Client.query(conn, "SELECT * FROM cpu LIMIT 5")
  """
  @spec query(connection(), binary(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def query(connection, sql, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Validate required keys eagerly before attempting any network calls.
    # Map.fetch!/2 raises KeyError with a clear message if a key is missing.
    host = Map.fetch!(connection, :host)
    token = Map.fetch!(connection, :token)
    database = Map.fetch!(connection, :database)

    # The channel is closed on every path after connect, a raise included;
    # a failed DoGet used to leak it.
    with :ok <- check_host(host),
         :ok <- check_token(token),
         {:ok, _payload} <- ticket_payload(database, sql),
         {:ok, channel} <- open_channel(host, connection, opts) do
      try do
        with {:ok, flight_data_list} <- do_get(channel, connection, sql, timeout) do
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

  defp check_host(host) when is_binary(host) and host != "" do
    case length(:binary.matches(host, ":")) do
      0 -> if String.valid?(host), do: :ok, else: {:error, {:invalid_host, host}}
      1 -> {:error, {:invalid_host, host}}
      _ipv6 -> {:error, {:ipv6_unsupported, host}}
    end
  end

  defp check_host(host), do: {:error, {:invalid_host, host}}

  @spec check_token(term()) :: :ok | {:error, {:invalid_token, term()}}
  defp check_token(token) when is_binary(token), do: :ok
  defp check_token(token), do: {:error, {:invalid_token, token}}

  # The ticket is JSON: a database or a statement JSON cannot carry (text that is not UTF-8,
  # a tuple) is the caller's error before any connection, as over HTTP.
  @spec ticket_payload(term(), term()) ::
          {:ok, binary()} | {:error, {:unencodable_body, binary()}}
  defp ticket_payload(database, sql) do
    case Jason.encode(%{"database" => database, "sql_query" => sql, "query_type" => "sql"}) do
      {:ok, payload} -> {:ok, payload}
      {:error, error} -> {:error, {:unencodable_body, Exception.message(error)}}
    end
  rescue
    error in [FunctionClauseError, Protocol.UndefinedError, Jason.EncodeError] ->
      {:error, {:unencodable_body, Exception.message(error)}}
  end

  @spec open_channel(binary(), connection(), keyword()) ::
          {:ok, GRPC.Channel.t()} | {:error, term()}
  defp open_channel(host, connection, opts) do
    port = Map.get(connection, :port, @default_port)
    use_tls = Keyword.get(opts, :tls, port == 443)
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

  @doc false
  # Resolves the connect-phase timeout: :connect_timeout → :timeout → default.
  @spec resolve_connect_timeout(keyword()) :: non_neg_integer()
  def resolve_connect_timeout(opts) do
    Keyword.get(opts, :connect_timeout) ||
      Keyword.get(opts, :timeout) ||
      @default_timeout
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
  @spec bounded_connect((-> result), non_neg_integer()) ::
          result | {:error, :connect_timeout | {:connect_failed, binary()}}
        when result: term()
  def bounded_connect(fun, timeout) when is_function(fun, 0) do
    caller = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            fun.()
          catch
            kind, reason -> {:error, {:connect_failed, Exception.format_banner(kind, reason)}}
          end

        send(caller, {tag, result})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:connect_failed, Exception.format_exit(reason)}}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        # A result sent just before the kill is dropped with the rest.
        receive do
          {^tag, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, :connect_timeout}
    end
  end

  @spec do_get(GRPC.Channel.t(), connection(), binary(), non_neg_integer()) ::
          {:ok, [FlightData.t()]} | {:error, term()}
  defp do_get(channel, connection, sql, timeout) do
    database = Map.fetch!(connection, :database)
    token = Map.fetch!(connection, :token)

    ticket = build_ticket(database, sql)

    metadata = [{"authorization", "Bearer #{token}"}]
    call_opts = [timeout: timeout, metadata: metadata]

    case FlightService.Stub.do_get(channel, ticket, call_opts) do
      {:ok, stream} -> collect_stream(stream)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec collect_stream(Enumerable.t()) :: {:ok, [FlightData.t()]} | {:error, term()}
  defp collect_stream(stream) do
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

  Exposed for testing and introspection purposes.

  ## Parameters

    * `database` — target InfluxDB database name
    * `sql` — SQL query string

  ## Example

      iex> payload = InfluxElixir.Flight.Client.build_ticket_payload("mydb", "SELECT 1")
      iex> Jason.decode!(payload)
      %{"database" => "mydb", "sql_query" => "SELECT 1", "query_type" => "sql"}
  """
  @spec build_ticket_payload(binary(), binary()) :: binary()
  def build_ticket_payload(database, sql) do
    Jason.encode!(%{
      "database" => database,
      "sql_query" => sql,
      "query_type" => "sql"
    })
  end

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
