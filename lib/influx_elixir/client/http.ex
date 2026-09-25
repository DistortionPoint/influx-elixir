defmodule InfluxElixir.Client.HTTP do
  @moduledoc """
  Production InfluxDB client implementation using Finch.

  Communicates with real InfluxDB v3 (and v2) instances over HTTP.
  Uses Finch connection pools for efficient HTTP/1.1 and HTTP/2.

  ## Connection

  The `connection` parameter is a keyword list containing at minimum
  `:host`, `:token`, `:scheme`, `:port`, and a `:name` atom used to
  resolve the Finch pool. These are typically produced by
  `InfluxElixir.Config.validate!/1`.

  ## InfluxDB v3 API Endpoints (`api_version: :v3`, the default)

    * Write: `POST /api/v3/write_lp?db=DATABASE&precision=PRECISION`
    * SQL Query: `POST /api/v3/query_sql` (JSON body)
    * InfluxQL: `POST /api/v3/query_influxql` (JSON body)
    * Databases: `GET/POST/DELETE /api/v3/configure/database`
    * Tokens: `POST/DELETE /api/v3/configure/token`
    * Health: `GET /health`

  ## InfluxDB v2 (`api_version: :v2`)

  Set `api_version: :v2` on the connection. A v2 server answers `200` to the
  v3 write path **without storing anything**, so the version must be explicit.

    * Write: `POST /api/v2/write?org=ORG&bucket=DATABASE&precision=ns|us|ms|s`
      (the connection's `:org` and the `:database` opt name the bucket)
    * Flux: `POST /api/v2/query` (JSON body, `#datatype`-annotated CSV back)
    * Buckets: `GET/POST/DELETE /api/v2/buckets`. `create_bucket/3` resolves
      the org ID from the connection's `:org` name (override with `org_id:`);
      `delete_bucket/2` accepts a bucket name or a 16-hex bucket ID.

  ## Request Timeout

  Every request uses `Finch`'s `:receive_timeout` option. The value is
  resolved with this precedence on each call:

    1. `opts[:timeout]` (per-call override)
    2. `connection[:timeout]` (connection-level default)
    3. `30_000` ms (module default, matching `InfluxElixir.Flight.Client`)

  Finch's own default of 15s is bypassed — most production InfluxDB v3
  queries need longer. To use the Finch default, pass `timeout: 15_000`
  explicitly. Admin callbacks that don't accept opts (`list_databases`,
  `delete_database`, `health`, etc.) use the connection-level default
  or fall back to 30s.

  ## Pool Checkout Timeout

  Finch also bounds how long a request waits to check a connection out of
  the pool (`pool_timeout`, Finch default 5 s). That bound applies before
  `receive_timeout` and is independent of it, so against a slow or
  multi-node endpoint a request can fail with a transport `:timeout` after
  5 s no matter how large `:timeout` is. It resolves the same way:

    1. `opts[:pool_timeout]` (per-call override)
    2. `connection[:pool_timeout]` (connection-level default)
    3. `5_000` ms (Finch's default)

  A checkout that times out is reported as
  `{:error, {:connection_error, :pool_timeout}}` (Finch itself raises in
  that case). The streaming query uses both timeouts as well and raises an
  `InfluxElixir.StreamError` with `reason: :pool_timeout`.
  """

  @behaviour InfluxElixir.Client

  alias InfluxElixir.Query.ResponseParser

  # Default `Finch.request/3` receive timeout, mirroring
  # `InfluxElixir.Flight.Client`'s default so HTTP and Flight transports
  # have parity. Finch's own default is 15s, which is too short for many
  # production queries. Override with the `:timeout` opt on a per-call
  # basis, or via a `:timeout` key on the connection config.
  @default_timeout 30_000

  # Finch's own default for waiting on a pool checkout. Kept as the default
  # so behaviour is unchanged unless configured; see `:pool_timeout`.
  @default_pool_timeout 5_000

  # ---------------------------------------------------------------------------
  # Connection lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  @spec init_connection(keyword()) :: {:ok, keyword()}
  def init_connection(config) do
    # Mirror Client.Local: when :database (singular) is absent but
    # :databases (list) is provided, default the connection-level
    # database to the first item so resolve_database/2 picks it up.
    case Keyword.get(config, :database) do
      nil ->
        case Keyword.get(config, :databases) do
          [first | _rest] when is_binary(first) ->
            {:ok, Keyword.put(config, :database, first)}

          _other ->
            {:ok, config}
        end

      _existing ->
        {:ok, config}
    end
  end

  @impl true
  @spec shutdown_connection(keyword()) :: :ok
  def shutdown_connection(_connection), do: :ok

  # ---------------------------------------------------------------------------
  # Write
  # ---------------------------------------------------------------------------

  @impl true
  @spec write(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.write_result()
  def write(connection, line_protocol, opts \\ []) do
    with {:ok, database} <- resolve_database(opts, connection) do
      precision = Keyword.get(opts, :precision, "nanosecond")
      url = write_url(connection, database, precision)

      headers =
        if Keyword.get(opts, :gzip, false) do
          [{"content-encoding", "gzip"} | auth_headers(connection)]
        else
          auth_headers(connection)
        end

      with {:ok, _response} <-
             request(:post, url, headers, line_protocol, connection, opts, [200, 204]) do
        {:ok, :written}
      end
    end
  end

  # v3 writes go to /api/v3/write_lp. v2 only has /api/v2/write, which is
  # org/bucket scoped and spells precision as ns/us/ms/s. A v2 server
  # answers 200 to the v3 path without storing anything, so the version has
  # to be declared on the connection rather than sniffed.
  @spec write_url(keyword(), binary(), atom() | binary()) :: binary()
  defp write_url(connection, database, precision) do
    case api_version(connection) do
      :v2 ->
        org = conn_val(connection, :org, "")

        base_url(connection) <>
          "/api/v2/write?org=#{URI.encode(org)}&bucket=#{URI.encode(database)}" <>
          "&precision=#{v2_precision(precision)}"

      :v3 ->
        base_url(connection) <>
          "/api/v3/write_lp?db=#{URI.encode(database)}&precision=#{precision}"
    end
  end

  @spec api_version(keyword()) :: :v2 | :v3
  defp api_version(connection), do: conn_val(connection, :api_version, :v3)

  @spec v2_precision(atom() | binary()) :: binary()
  defp v2_precision(p) when p in [:nanosecond, "nanosecond", :ns, "ns"], do: "ns"
  defp v2_precision(p) when p in [:microsecond, "microsecond", :us, "us"], do: "us"
  defp v2_precision(p) when p in [:millisecond, "millisecond", :ms, "ms"], do: "ms"
  defp v2_precision(p) when p in [:second, "second", :s, "s"], do: "s"
  defp v2_precision(other), do: to_string(other)

  # ---------------------------------------------------------------------------
  # Query — v3 SQL
  # ---------------------------------------------------------------------------

  @impl true
  @spec query_sql(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  def query_sql(connection, sql, opts \\ []) do
    case Keyword.get(opts, :transport, :http) do
      :flight -> flight_query_sql(connection, sql, opts)
      :http -> http_query_sql(connection, sql, opts)
      other -> {:error, {:unknown_transport, other}}
    end
  end

  # `transport: :flight` runs the query over Arrow Flight gRPC. The Flight
  # endpoint shares the host and token; its port comes from
  # `opts[:flight_port]`, then the connection's `:flight_port`, then 443.
  # Params are not supported by the Flight ticket, so they are rejected
  # rather than silently dropped.
  @spec flight_query_sql(keyword(), binary(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  defp flight_query_sql(connection, sql, opts) do
    with {:ok, database} <- resolve_database(opts, connection),
         :ok <- reject_flight_params(opts) do
      flight_conn = %{
        host: conn_val(connection, :host),
        token: conn_val(connection, :token, ""),
        database: database,
        port: Keyword.get(opts, :flight_port, conn_val(connection, :flight_port, 443))
      }

      InfluxElixir.Flight.Client.query(
        flight_conn,
        sql,
        Keyword.take(opts, [:timeout, :connect_timeout, :tls])
      )
    end
  end

  @spec reject_flight_params(keyword()) :: :ok | {:error, :params_unsupported_over_flight}
  defp reject_flight_params(opts) do
    if map_size(query_params(opts)) == 0 do
      :ok
    else
      {:error, :params_unsupported_over_flight}
    end
  end

  # `params:` may be a map or a keyword list. Jason cannot encode the tuples
  # of a keyword list, so a keyword list used to raise here while
  # `Client.Local` accepted it — a query could pass tests and crash in
  # production. Both shapes are accepted by both clients.
  @spec query_params(keyword()) :: map()
  defp query_params(opts), do: opts |> Keyword.get(:params, %{}) |> Map.new()

  @spec http_query_sql(keyword(), binary(), keyword()) :: InfluxElixir.Client.query_result()
  defp http_query_sql(connection, sql, opts) do
    with {:ok, database} <- resolve_database(opts, connection) do
      params = query_params(opts)
      format = Keyword.get(opts, :format, :json)

      body =
        Jason.encode!(%{
          "db" => database,
          "q" => sql,
          "params" => params,
          "format" => to_string(format)
        })

      url = base_url(connection) <> "/api/v3/query_sql"
      headers = json_headers(connection)

      with {:ok, %Finch.Response{body: resp_body}} <-
             request(:post, url, headers, body, connection, opts, [200]) do
        ResponseParser.parse(resp_body, format)
      end
    end
  end

  @impl true
  @spec query_sql_stream(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: Enumerable.t()
  def query_sql_stream(connection, sql, opts \\ []) do
    case resolve_database(opts, connection) do
      {:ok, database} ->
        params = query_params(opts)

        body =
          Jason.encode!(%{
            "db" => database,
            "q" => sql,
            "params" => params,
            "format" => "jsonl"
          })

        url = base_url(connection) <> "/api/v3/query_sql"
        headers = json_headers(connection)
        finch_name = resolve_finch(connection)
        finch_opts = finch_opts(opts, connection)

        Stream.resource(
          fn -> start_stream(finch_name, url, headers, body, finch_opts) end,
          &stream_next/1,
          &stream_cleanup/1
        )

      {:error, :no_database_specified} ->
        # The return type is Enumerable.t(), so we cannot return an error
        # tuple. Surface the failure by raising when the stream is enumerated
        # rather than yielding an empty list that looks like "zero rows".
        raise_stream(kind: :no_database)
    end
  end

  @impl true
  @spec execute_sql(InfluxElixir.Client.connection(), binary(), keyword()) ::
          {:ok, map() | [map()]} | {:error, term()}
  def execute_sql(connection, sql, opts \\ []) do
    with {:ok, database} <- resolve_database(opts, connection) do
      body = Jason.encode!(%{"db" => database, "q" => sql})

      url = base_url(connection) <> "/api/v3/query_sql"
      headers = json_headers(connection)

      # A SELECT answers rows, typed like `query_sql/3` rows (they were raw
      # JSON with string timestamps); a summary map passes through.
      with {:ok, %Finch.Response{body: resp_body}} <-
             request(:post, url, headers, body, connection, opts, [200]),
           {:ok, decoded} <- Jason.decode(resp_body) do
        if is_list(decoded),
          do: {:ok, Enum.map(decoded, &ResponseParser.coerce_types/1)},
          else: {:ok, decoded}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Query — v3 InfluxQL
  # ---------------------------------------------------------------------------

  @impl true
  @spec query_influxql(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  def query_influxql(connection, influxql, opts \\ []) do
    database =
      case resolve_database(opts, connection) do
        {:ok, db} -> db
        {:error, :no_database_specified} -> ""
      end

    format = Keyword.get(opts, :format, :json)

    body_map = %{"q" => influxql, "format" => to_string(format)}

    body_map =
      if database != "" do
        Map.put(body_map, "db", database)
      else
        body_map
      end

    body = Jason.encode!(body_map)

    url = base_url(connection) <> "/api/v3/query_influxql"
    headers = json_headers(connection)

    with {:ok, %Finch.Response{body: resp_body}} <-
           request(:post, url, headers, body, connection, opts, [200]) do
      ResponseParser.parse(resp_body, format)
    end
  end

  # ---------------------------------------------------------------------------
  # Query — v2 Flux (compat)
  # ---------------------------------------------------------------------------

  @impl true
  @spec query_flux(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  def query_flux(connection, flux, opts \\ []) do
    org = Keyword.get(opts, :org, conn_val(connection, :org, ""))

    # The `#datatype` annotation lets ResponseParser type each column
    # (double/long/boolean/RFC3339) instead of returning every cell as text.
    body =
      Jason.encode!(%{
        "query" => flux,
        "type" => "flux",
        "dialect" => %{"annotations" => ["datatype"], "header" => true, "delimiter" => ","}
      })

    url = base_url(connection) <> "/api/v2/query?org=#{URI.encode(org)}"
    headers = json_headers(connection)

    with {:ok, %Finch.Response{body: resp_body}} <-
           request(:post, url, headers, body, connection, opts, [200]) do
      ResponseParser.parse(resp_body, :csv)
    end
  end

  # ---------------------------------------------------------------------------
  # Admin — v3 databases
  # ---------------------------------------------------------------------------

  @impl true
  @spec create_database(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_database(connection, name, opts \\ []) do
    body_map = %{"db" => name}

    body_map =
      case Keyword.get(opts, :retention) do
        nil -> body_map
        retention -> Map.put(body_map, "retention_period", retention)
      end

    body = Jason.encode!(body_map)

    url = base_url(connection) <> "/api/v3/configure/database"
    headers = json_headers(connection)

    # 409 = already exists, which is success for an idempotent create.
    with {:ok, _response} <-
           request(:post, url, headers, body, connection, opts, [200, 201, 409]) do
      :ok
    end
  end

  @impl true
  @spec list_databases(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_databases(connection) do
    url = base_url(connection) <> "/api/v3/configure/database?format=json"
    headers = auth_headers(connection)

    with {:ok, %Finch.Response{body: resp_body}} <-
           request(:get, url, headers, nil, connection, [], [200]),
         {:ok, rows} <- Jason.decode(resp_body) do
      {:ok, Enum.map(rows, fn row -> %{"name" => row["iox::database"]} end)}
    end
  end

  @impl true
  @spec delete_database(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_database(connection, name) do
    url =
      base_url(connection) <>
        "/api/v3/configure/database?db=#{URI.encode(name)}"

    headers = auth_headers(connection)

    with {:ok, _response} <-
           request(:delete, url, headers, nil, connection, [], [200, 204]) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Admin — v2 buckets (compat)
  # ---------------------------------------------------------------------------

  @impl true
  @spec create_bucket(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_bucket(connection, name, opts \\ []) do
    retention = Keyword.get(opts, :retention, 0)

    with {:ok, org_id} <- resolve_org_id(connection, opts) do
      body =
        Jason.encode!(%{
          "name" => name,
          "orgID" => org_id,
          "retentionRules" => [%{"everySeconds" => retention}]
        })

      url = base_url(connection) <> "/api/v2/buckets"
      headers = json_headers(connection)

      case request(:post, url, headers, body, connection, opts, [200, 201]) do
        {:ok, _response} ->
          :ok

        # Creating a bucket that already exists is idempotent, matching
        # Client.Local and the 409 handling in create_database/3.
        {:error, %{status: 422, body: resp_body}} = error ->
          if String.contains?(to_string(resp_body), "already exists"), do: :ok, else: error

        error ->
          error
      end
    end
  end

  # v2 buckets belong to an org by ID, not name. `opts[:org_id]` wins;
  # otherwise the ID is looked up from the connection's `:org` name.
  @spec resolve_org_id(keyword(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp resolve_org_id(connection, opts) do
    case Keyword.get(opts, :org_id) do
      nil -> lookup_org_id(connection, conn_val(connection, :org, ""))
      org_id -> {:ok, org_id}
    end
  end

  @spec lookup_org_id(keyword(), binary()) :: {:ok, binary()} | {:error, term()}
  defp lookup_org_id(connection, org) do
    url = base_url(connection) <> "/api/v2/orgs?org=#{URI.encode(org)}"

    with {:ok, %Finch.Response{body: body}} <-
           request(:get, url, auth_headers(connection), nil, connection, [], [200]),
         {:ok, %{"orgs" => [%{"id" => id} | _rest]}} <- Jason.decode(body) do
      {:ok, id}
    else
      {:ok, _no_orgs} -> {:error, {:org_not_found, org}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  @spec list_buckets(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_buckets(connection) do
    url = base_url(connection) <> "/api/v2/buckets"
    headers = auth_headers(connection)

    with {:ok, %Finch.Response{body: resp_body}} <-
           request(:get, url, headers, nil, connection, [], [200]),
         {:ok, decoded} <- Jason.decode(resp_body) do
      case decoded do
        %{"buckets" => buckets} -> {:ok, buckets}
        other -> {:ok, List.wrap(other)}
      end
    end
  end

  @impl true
  @spec delete_bucket(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_bucket(connection, bucket) do
    with {:ok, bucket_id} <- resolve_bucket_id(connection, bucket) do
      url = base_url(connection) <> "/api/v2/buckets/#{URI.encode(bucket_id)}"
      headers = auth_headers(connection)

      with {:ok, _response} <-
             request(:delete, url, headers, nil, connection, [], [200, 204]) do
        :ok
      end
    end
  end

  # The v2 API deletes by 16-hex bucket ID, while Client.Local deletes by
  # name. Accept either so callers can pass the name against both clients.
  @spec resolve_bucket_id(keyword(), binary()) :: {:ok, binary()} | {:error, term()}
  defp resolve_bucket_id(connection, bucket) do
    if String.match?(bucket, ~r/^[0-9a-f]{16}$/) do
      {:ok, bucket}
    else
      lookup_bucket_id(connection, bucket)
    end
  end

  @spec lookup_bucket_id_error(binary()) :: {:error, term()}
  defp lookup_bucket_id_error(name),
    do: {:error, %{status: 404, body: "bucket not found: #{name}"}}

  @spec lookup_bucket_id(keyword(), binary()) :: {:ok, binary()} | {:error, term()}
  defp lookup_bucket_id(connection, name) do
    url = base_url(connection) <> "/api/v2/buckets?name=#{URI.encode(name)}"

    with {:ok, %Finch.Response{body: body}} <-
           request(:get, url, auth_headers(connection), nil, connection, [], [200]),
         {:ok, %{"buckets" => [%{"id" => id} | _rest]}} <- Jason.decode(body) do
      {:ok, id}
    else
      {:ok, _no_buckets} -> lookup_bucket_id_error(name)
      {:error, _reason} = error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Admin — v3 tokens
  # ---------------------------------------------------------------------------

  @impl true
  @spec create_token(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def create_token(connection, description, opts \\ []) do
    permissions = Keyword.get(opts, :permissions, [])

    body =
      Jason.encode!(%{
        "description" => description,
        "permissions" => permissions
      })

    url = base_url(connection) <> "/api/v3/configure/token"
    headers = json_headers(connection)

    with {:ok, %Finch.Response{body: resp_body}} <-
           request(:post, url, headers, body, connection, opts, [200, 201]) do
      Jason.decode(resp_body)
    end
  end

  @impl true
  @spec delete_token(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_token(connection, token_id) do
    url =
      base_url(connection) <>
        "/api/v3/configure/token/#{URI.encode(token_id)}"

    headers = auth_headers(connection)

    with {:ok, _response} <-
           request(:delete, url, headers, nil, connection, [], [200, 204]) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Health
  # ---------------------------------------------------------------------------

  @impl true
  @spec health(InfluxElixir.Client.connection()) ::
          {:ok, map()} | {:error, term()}
  def health(connection) do
    url = base_url(connection) <> "/health"
    headers = auth_headers(connection)

    with {:ok, %Finch.Response{body: resp_body}} <-
           request(:get, url, headers, nil, connection, [], [200]) do
      # A 200 with a non-JSON body (older builds answer plain text) is
      # still a passing health check.
      case Jason.decode(resp_body) do
        {:ok, map} -> {:ok, map}
        {:error, _json_err} -> {:ok, %{"status" => "pass"}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private: HTTP helpers
  # ---------------------------------------------------------------------------

  # Runs a request and normalises the outcome: `{:ok, response}` when the
  # status is one of `ok_statuses`, `{:error, %{status, body}}` for any other
  # status, and `{:error, {:connection_error, reason}}` for a transport
  # failure. Every public function used to repeat this three-clause case.
  @spec request(
          :get | :post | :delete,
          binary(),
          [{binary(), binary()}],
          binary() | nil,
          keyword(),
          keyword(),
          [non_neg_integer()]
        ) :: {:ok, Finch.Response.t()} | {:error, term()}
  defp request(method, url, headers, body, connection, opts, ok_statuses) do
    case do_request(method, url, headers, body, connection, opts) do
      {:ok, %Finch.Response{status: status} = response} ->
        if status in ok_statuses do
          {:ok, response}
        else
          {:error, %{status: status, body: response.body}}
        end

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @spec do_request(
          :get | :post | :delete,
          binary(),
          [{binary(), binary()}],
          binary() | nil,
          keyword(),
          keyword()
        ) :: {:ok, Finch.Response.t()} | {:error, term()}
  defp do_request(method, url, headers, body, connection, opts) do
    finch_name = resolve_finch(connection)
    request = Finch.build(method, url, headers, body)
    Finch.request(request, finch_name, finch_opts(opts, connection))
  rescue
    # Finch does not return an error tuple when no connection can be checked
    # out within :pool_timeout — it converts NimblePool's exit into a
    # RuntimeError. Map it back into the library's tagged-tuple contract.
    error in RuntimeError -> {:error, classify_finch_error(error)}
  end

  @pool_timeout_message "Finch was unable to provide a connection within the timeout"

  @spec classify_finch_error(Exception.t()) :: :pool_timeout | Exception.t()
  defp classify_finch_error(%RuntimeError{message: @pool_timeout_message <> _rest}),
    do: :pool_timeout

  defp classify_finch_error(error), do: error

  # Both Finch timeouts, resolved with the same precedence. Without an
  # explicit `pool_timeout` Finch waits at most 5 s to check a connection out
  # of the pool, regardless of how generous `receive_timeout` is (#14).
  @spec finch_opts(keyword(), keyword()) :: keyword()
  defp finch_opts(opts, connection) do
    [
      receive_timeout: resolve_timeout(opts, connection),
      pool_timeout: resolve_pool_timeout(opts, connection)
    ]
  end

  @doc false
  # Resolves the receive timeout in milliseconds. Precedence:
  #   opts[:timeout] → connection[:timeout] → @default_timeout
  # Exposed (with @doc false) so the precedence logic is unit-testable
  # without spinning up a network fixture.
  @spec resolve_timeout(keyword(), keyword()) :: non_neg_integer()
  def resolve_timeout(opts, connection) do
    Keyword.get(opts, :timeout) ||
      Keyword.get(connection, :timeout) ||
      @default_timeout
  end

  @doc false
  # Resolves the pool checkout timeout in milliseconds. Precedence:
  #   opts[:pool_timeout] → connection[:pool_timeout] → @default_pool_timeout
  @spec resolve_pool_timeout(keyword(), keyword()) :: non_neg_integer()
  def resolve_pool_timeout(opts, connection) do
    Keyword.get(opts, :pool_timeout) ||
      Keyword.get(connection, :pool_timeout) ||
      @default_pool_timeout
  end

  @spec resolve_finch(keyword()) :: atom()
  defp resolve_finch(connection) do
    case Keyword.get(connection, :finch_name) do
      nil ->
        name = Keyword.fetch!(connection, :name)
        InfluxElixir.ConnectionSupervisor.finch_name(name)

      finch_name ->
        finch_name
    end
  end

  @spec base_url(keyword()) :: binary()
  defp base_url(connection) do
    scheme = conn_val(connection, :scheme, :https)
    host = conn_val(connection, :host)
    port = conn_val(connection, :port, 8086)
    "#{scheme}://#{host}:#{port}"
  end

  @spec auth_headers(keyword()) :: [{binary(), binary()}]
  defp auth_headers(connection) do
    case conn_val(connection, :token) do
      nil -> []
      "" -> []
      token -> [{"authorization", "Bearer #{token}"}]
    end
  end

  @spec json_headers(keyword()) :: [{binary(), binary()}]
  defp json_headers(connection) do
    [{"content-type", "application/json"} | auth_headers(connection)]
  end

  @spec conn_val(keyword(), atom(), term()) :: term()
  defp conn_val(connection, key, default \\ nil) do
    Keyword.get(connection, key, default)
  end

  @spec resolve_database(keyword(), keyword()) ::
          {:ok, binary()} | {:error, :no_database_specified}
  defp resolve_database(opts, connection) do
    case Keyword.get(opts, :database, conn_val(connection, :database)) do
      nil -> {:error, :no_database_specified}
      db -> {:ok, db}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: streaming helpers
  #
  # True incremental streaming with constant memory. `Finch.stream/5` is
  # push-based (it invokes a callback as chunks arrive), while `Stream.resource`
  # is pull-based. We bridge the two with a producer process: the producer runs
  # `Finch.stream/5` and, for each status/data chunk, sends a message to the
  # consumer and blocks until the consumer acks. Because the callback blocks
  # inside the HTTP receive loop, this gives real back-pressure — a chunk is
  # only pulled off the socket when the downstream consumer asks for the next
  # element. JSONL is decoded line-by-line as bytes arrive; only one chunk plus
  # a partial-line buffer is ever held in memory.
  #
  # Errors are never swallowed: a non-2xx status or a transport error raises an
  # `InfluxElixir.StreamError` when the stream is consumed, mirroring the
  # `{:error, reason}` contract of `query_sql/3`.
  # ---------------------------------------------------------------------------

  @typep stream_state :: %{
           producer: pid(),
           ref: reference(),
           monitor: reference(),
           status: non_neg_integer() | nil,
           buffer: binary(),
           error_body: iodata(),
           phase: :streaming | :halt
         }

  @spec start_stream(atom(), binary(), list(), binary(), keyword()) ::
          stream_state()
  defp start_stream(finch_name, url, headers, body, finch_opts) do
    parent = self()
    ref = make_ref()

    producer =
      spawn(fn ->
        run_producer(parent, ref, finch_name, url, headers, body, finch_opts)
      end)

    monitor = Process.monitor(producer)

    %{
      producer: producer,
      ref: ref,
      monitor: monitor,
      status: nil,
      buffer: "",
      error_body: [],
      phase: :streaming
    }
  end

  # Producer process body. Runs the blocking Finch stream, forwarding each
  # chunk to the consumer with back-pressure, then signalling completion.
  @spec run_producer(pid(), reference(), atom(), binary(), list(), binary(), keyword()) ::
          :ok
  defp run_producer(parent, ref, finch_name, url, headers, body, finch_opts) do
    request = Finch.build(:post, url, headers, body)

    outcome =
      Finch.stream(
        request,
        finch_name,
        :ok,
        fn
          {:status, status}, acc ->
            emit_and_wait(parent, ref, {:status, status})
            acc

          {:headers, _headers}, acc ->
            acc

          {:data, data}, acc ->
            emit_and_wait(parent, ref, {:data, data})
            acc

          {:trailers, _trailers}, acc ->
            acc
        end,
        finch_opts
      )

    case outcome do
      {:ok, _acc} -> send(parent, {ref, :done})
      {:error, reason, _acc} -> send(parent, {ref, {:transport_error, reason}})
    end

    :ok
  end

  # Send a chunk to the consumer and block until it acks. If the consumer has
  # abandoned the stream it is killed by `stream_cleanup/1`, which unblocks this
  # receive by terminating the process.
  @spec emit_and_wait(pid(), reference(), term()) :: :ok
  defp emit_and_wait(parent, ref, msg) do
    send(parent, {ref, msg})

    receive do
      {:ack, ^ref} -> :ok
    end
  end

  @spec stream_next(stream_state()) :: {[map()], stream_state()} | {:halt, stream_state()}
  defp stream_next(%{phase: :halt} = state), do: {:halt, state}

  defp stream_next(%{ref: ref, producer: producer, monitor: monitor} = state) do
    receive do
      {^ref, {:status, status}} ->
        ack(producer, ref)
        {[], %{state | status: status}}

      {^ref, {:data, data}} ->
        ack(producer, ref)
        handle_data(state, data)

      {^ref, :done} ->
        finish(state)

      {^ref, {:transport_error, reason}} ->
        raise InfluxElixir.StreamError, kind: :transport, reason: reason

      {:DOWN, ^monitor, :process, ^producer, :normal} ->
        {:halt, %{state | phase: :halt}}

      # The producer crashed. A pool checkout timeout surfaces here because
      # Finch raises inside the producer; report it by name.
      {:DOWN, ^monitor, :process, ^producer, {%RuntimeError{} = error, _stack}} ->
        raise InfluxElixir.StreamError, kind: :transport, reason: classify_finch_error(error)

      {:DOWN, ^monitor, :process, ^producer, reason} ->
        raise InfluxElixir.StreamError, kind: :transport, reason: reason
    end
  end

  # Decode a data chunk. On a 200 response, complete JSONL lines are decoded
  # and emitted while the trailing partial line is buffered. On a non-2xx
  # response, the body is accumulated so it can be reported when the stream ends.
  @spec handle_data(stream_state(), binary()) :: {[map()], stream_state()}
  defp handle_data(%{status: 200, buffer: buffer} = state, data) do
    {lines, rest} = split_lines(buffer <> data)
    {Enum.map(lines, &decode_line/1), %{state | buffer: rest}}
  end

  defp handle_data(%{error_body: acc} = state, data) do
    {[], %{state | error_body: [acc, data]}}
  end

  # Producer signalled a clean end-of-response.
  @spec finish(stream_state()) :: {[map()], stream_state()}
  defp finish(%{status: 200, buffer: buffer} = state) do
    rows =
      case String.trim(buffer) do
        "" -> []
        line -> [decode_line(line)]
      end

    {rows, %{state | buffer: "", phase: :halt}}
  end

  defp finish(%{status: status, error_body: acc}) do
    raise InfluxElixir.StreamError,
      kind: :http_status,
      status: status,
      body: IO.iodata_to_binary(acc)
  end

  # Split accumulated bytes into complete lines plus a trailing remainder that
  # has not yet been terminated by a newline. Blank lines are dropped.
  @spec split_lines(binary()) :: {[binary()], binary()}
  defp split_lines(data) do
    parts = String.split(data, "\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)
    {Enum.reject(complete, &(&1 == "")), rest}
  end

  # The same coercion `query_sql/3` applies (timestamps become DateTimes),
  # so a row is the same map streamed or not; it used to be the raw JSON.
  @spec decode_line(binary()) :: map()
  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, row} -> ResponseParser.coerce_types(row)
      {:error, reason} -> raise InfluxElixir.StreamError, kind: :decode, reason: reason
    end
  end

  @spec ack(pid(), reference()) :: :ok
  defp ack(producer, ref) do
    send(producer, {:ack, ref})
    :ok
  end

  # Tear down the producer and drain any of its messages from the consumer's
  # mailbox. The stream runs in the caller's process, so leftover chunk or
  # :DOWN messages would otherwise pollute that mailbox.
  @spec stream_cleanup(stream_state() | term()) :: :ok
  defp stream_cleanup(%{producer: producer, ref: ref, monitor: monitor}) do
    Process.exit(producer, :kill)
    Process.demonitor(monitor, [:flush])
    flush_ref(ref)
  end

  defp stream_cleanup(_state), do: :ok

  @spec flush_ref(reference()) :: :ok
  defp flush_ref(ref) do
    receive do
      {^ref, _msg} -> flush_ref(ref)
    after
      0 -> :ok
    end
  end

  # Build a stream that raises the given `InfluxElixir.StreamError` as soon as it
  # is enumerated. Used for pre-request failures (e.g. no database resolved)
  # that must surface as an error rather than an empty result.
  @spec raise_stream(keyword()) :: Enumerable.t()
  defp raise_stream(error_opts) do
    InfluxElixir.StreamError.stream(error_opts)
  end
end
