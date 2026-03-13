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
    _host = Map.fetch!(connection, :host)
    _token = Map.fetch!(connection, :token)
    _database = Map.fetch!(connection, :database)

    with {:ok, channel} <- connect(connection, opts),
         {:ok, flight_data_list} <- do_get(channel, connection, sql, timeout) do
      result = Reader.decode_flight_data(flight_data_list)
      :ok = disconnect(channel)
      result
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec connect(connection(), keyword()) :: {:ok, GRPC.Channel.t()} | {:error, term()}
  defp connect(connection, opts) do
    host = Map.fetch!(connection, :host)
    port = Map.get(connection, :port, @default_port)
    use_tls = Keyword.get(opts, :tls, port == 443)

    addr = "#{host}:#{port}"

    grpc_opts =
      if use_tls do
        [cred: GRPC.Credential.new(ssl: [])]
      else
        []
      end

    GRPC.Stub.connect(addr, grpc_opts)
  end

  @spec do_get(GRPC.Channel.t(), connection(), binary(), non_neg_integer()) ::
          {:ok, [FlightData.t()]} | {:error, term()}
  defp do_get(channel, connection, sql, timeout) do
    database = Map.fetch!(connection, :database)
    token = Map.fetch!(connection, :token)

    ticket_payload =
      Jason.encode!(%{
        "database" => database,
        "sql_query" => sql,
        "query_type" => "sql"
      })

    ticket = %Ticket{ticket: ticket_payload}

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
