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

    * Write: `POST /api/v3/write_lp?db=DATABASE&precision=PRECISION`, plus
      `&accept_partial=false` / `&no_sync=true` when those opts are given
    * SQL Query: `POST /api/v3/query_sql` (JSON body)
    * InfluxQL: `POST /api/v3/query_influxql` (JSON body)
    * Databases: `GET/POST/DELETE /api/v3/configure/database`
    * Tokens: `POST /api/v3/configure/token/named_admin` (admin),
      `POST /api/v3/enterprise/configure/token` (with permissions, Enterprise),
      `DELETE /api/v3/configure/token?token_name=NAME`
    * Health: `GET /health`

  ## InfluxDB v2 (`api_version: :v2`)

  Set `api_version: :v2` on the connection. A v2 server answers `200` to the
  v3 write path **without storing anything**, so the version must be explicit.

    * Write: `POST /api/v2/write?org=ORG&bucket=DATABASE&precision=ns|us|ms|s`
      (the connection's `:org` and the `:database` opt name the bucket)
    * Flux: `POST /api/v2/query` (JSON body, `#datatype`-annotated CSV back)
    * Buckets: `GET/POST/DELETE /api/v2/buckets`. `create_bucket/3` resolves
      the org ID from the connection's `:org` name (override with `org_id:`);
      `delete_bucket/2` accepts a bucket name or a 16-hex bucket ID. A name
      is looked up, and `list_buckets/1` lists, within the connection's
      `:org` (every org the token can read when it is `""`); the listing
      reads every page, not just the server's first 20 buckets.

  Names are percent-encoded in the URL, so a bucket, org or database name
  may hold `&`, `+`, `#`, `=` or spaces.

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

  import InfluxElixir.Client.HTTP.Request,
    only: [
      conn_val: 2,
      conn_val: 3,
      decode_json: 1,
      delete_named: 4,
      get: 3,
      json_body: 1,
      options: 1,
      post_json: 5,
      query_value: 1,
      request: 7,
      url_values: 1
    ]

  alias InfluxElixir.Admin.TokenRequest
  alias InfluxElixir.Client.HTTP.{Buckets, Request}
  alias InfluxElixir.Client.{Options, QueryParams}
  alias InfluxElixir.Query.ResponseParser

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
  @spec write(InfluxElixir.Client.connection(), iodata(), keyword()) ::
          InfluxElixir.Client.write_result()
  def write(connection, line_protocol, opts \\ []) do
    with :ok <- options(opts),
         {:ok, body} <- iodata_body(line_protocol),
         {:ok, database} <- resolve_database(opts, connection),
         precision = Keyword.get(opts, :precision, "nanosecond"),
         :ok <- url_values(database: database, precision: precision) do
      url = write_url(connection, database, precision) <> write_flags(connection, opts)

      headers =
        if Keyword.get(opts, :gzip, false) do
          [{"content-encoding", "gzip"} | Request.auth_headers(connection)]
        else
          Request.auth_headers(connection)
        end

      with {:ok, _response} <- request(:post, url, headers, body, connection, opts, [200, 204]) do
        {:ok, :written}
      end
    end
  end

  # A write body is iodata (a binary, or a list of binaries and bytes): anything else has no
  # bytes to send, the caller's error, never a raise.
  @spec iodata_body(term()) :: {:ok, binary()} | {:error, {:invalid_body, term()}}
  defp iodata_body(body) do
    case Options.iodata(body) do
      {:ok, text} -> {:ok, text}
      :error -> {:error, {:invalid_body, body}}
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

        Request.base_url(connection) <>
          "/api/v2/write?org=#{query_value(org)}&bucket=#{query_value(database)}" <>
          "&precision=#{query_value(v2_precision(precision))}"

      :v3 ->
        Request.base_url(connection) <>
          "/api/v3/write_lp?db=#{query_value(database)}&precision=#{query_value(precision)}"
    end
  end

  # InfluxDB 3's `accept_partial` (false: all-or-nothing) and `no_sync`
  # (acknowledge before the WAL is persisted) write parameters. Sent only
  # when given, and only on v3 — InfluxDB 2's endpoint has neither.
  @spec write_flags(keyword(), keyword()) :: binary()
  defp write_flags(connection, opts) do
    if api_version(connection) == :v3 do
      for key <- [:accept_partial, :no_sync], Keyword.has_key?(opts, key), into: "" do
        "&#{key}=#{query_value(Keyword.fetch!(opts, key))}"
      end
    else
      ""
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
    with :ok <- options(opts) do
      case Keyword.get(opts, :transport, :http) do
        :flight -> flight_query_sql(connection, sql, opts)
        :http -> http_query_sql(connection, sql, opts)
        other -> {:error, {:unknown_transport, other}}
      end
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
        flight_opts(opts, connection)
      )
    end
  end

  # The Flight call's options: the call's own `:timeout`, else the connection's, as for the
  # HTTP request (`resolve_timeout/2`), with `:connect_timeout` and `:tls` as the call has them.
  @spec flight_opts(keyword(), keyword()) :: keyword()
  defp flight_opts(opts, connection) do
    [{:timeout, resolve_timeout(opts, connection)} | Keyword.take(opts, [:connect_timeout, :tls])]
  end

  @spec reject_flight_params(keyword()) ::
          :ok | {:error, :params_unsupported_over_flight | QueryParams.error()}
  defp reject_flight_params(opts) do
    case query_params(opts) do
      {:ok, params} when map_size(params) == 0 -> :ok
      {:ok, _params} -> {:error, :params_unsupported_over_flight}
      {:error, _reason} = error -> error
    end
  end

  # `params:` may be a map or a keyword list; both clients accept both, and
  # read them through `InfluxElixir.Client.QueryParams`, which refuses a
  # value that has no JSON form and sends a `Decimal` as a JSON number (a
  # JSON string would be compared as text).
  @spec query_params(keyword()) :: {:ok, QueryParams.t()} | {:error, QueryParams.error()}
  defp query_params(opts), do: QueryParams.normalize(Keyword.get(opts, :params, %{}))

  # The JSON body of a `POST /api/v3/query_sql`: `db`, `q`, `params` and, when
  # `format` is not `nil`, `format`. Jason writes the keys in that order
  # (`db`, `format`, `params`, `q`), which `Client.Local` relies on to place
  # the byte where the engine's JSON parser stops
  # (`InfluxElixir.Client.Local.Format.check_params/3`); the SQL contract pins
  # both against the engine.
  @spec sql_request_body(binary(), binary(), keyword(), term()) ::
          {:ok, binary()} | {:error, QueryParams.error()}
  defp sql_request_body(database, sql, opts, format) do
    with {:ok, params} <- query_params(opts),
         :ok <- encodable_text(sql),
         :ok <- encodable_text(database) do
      {:ok, QueryParams.request_body(database, sql, params, format)}
    end
  end

  @spec encodable_text(term()) :: :ok | {:error, {:unencodable_body, binary()}}
  # Whatever JSON cannot carry (text that is not UTF-8, a tuple, a pid) is the caller's error;
  # what it can (an atom, a number) is sent as it always was.
  defp encodable_text(value) do
    with {:ok, _body} <- json_body(%{"text" => value}), do: :ok
  end

  @spec http_query_sql(keyword(), binary(), keyword()) :: InfluxElixir.Client.query_result()
  defp http_query_sql(connection, sql, opts) do
    format = Keyword.get(opts, :format) || :json

    with {:ok, database} <- resolve_database(opts, connection),
         {:ok, body} <- sql_request_body(database, sql, opts, format),
         {:ok, %Finch.Response{body: resp_body}} <-
           post_json(connection, "/api/v3/query_sql", body, opts, [200]) do
      ResponseParser.parse(resp_body, format)
    end
  end

  @impl true
  @spec query_sql_stream(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: Enumerable.t()
  def query_sql_stream(connection, sql, opts \\ []) do
    with :ok <- options(opts),
         {:ok, database} <- resolve_database(opts, connection),
         {:ok, body} <- sql_request_body(database, sql, opts, "jsonl"),
         {:ok, finch_name} <- Request.resolve_finch(connection) do
      InfluxElixir.Client.HTTP.Stream.resource(
        finch_name,
        Request.base_url(connection) <> "/api/v3/query_sql",
        Request.json_headers(connection),
        body,
        Request.finch_opts(opts, connection)
      )
    else
      # The return type is Enumerable.t(), so we cannot return an error
      # tuple. Surface the failure by raising when the stream is enumerated
      # rather than yielding an empty list that looks like "zero rows".
      {:error, :no_database_specified} -> raise_stream(kind: :no_database)
      {:error, reason} -> raise_stream(kind: :transport, reason: reason)
    end
  end

  @impl true
  @spec execute_sql(InfluxElixir.Client.connection(), binary(), keyword()) ::
          {:ok, map() | [map()]} | {:error, term()}
  def execute_sql(connection, sql, opts \\ []) do
    with :ok <- options(opts),
         {:ok, database} <- resolve_database(opts, connection),
         {:ok, body} <- sql_request_body(database, sql, opts, nil),
         # A SELECT answers rows, typed like `query_sql/3` rows; a summary map
         # passes through.
         {:ok, %Finch.Response{body: resp_body}} <-
           post_json(connection, "/api/v3/query_sql", body, opts, [200]),
         {:ok, decoded} <- decode_json(resp_body) do
      if is_list(decoded),
        do: {:ok, Enum.map(decoded, &ResponseParser.coerce_types/1)},
        else: {:ok, decoded}
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
    with :ok <- options(opts), do: influxql_request(connection, influxql, opts)
  end

  @spec influxql_request(keyword(), term(), keyword()) :: InfluxElixir.Client.query_result()
  defp influxql_request(connection, influxql, opts) do
    database =
      case resolve_database(opts, connection) do
        {:ok, db} -> db
        {:error, :no_database_specified} -> ""
      end

    format = Keyword.get(opts, :format) || :json

    body_map = %{"q" => influxql, "format" => to_string(format)}

    body_map =
      if database != "" do
        Map.put(body_map, "db", database)
      else
        body_map
      end

    with {:ok, %Finch.Response{body: resp_body}} <-
           post_json(connection, "/api/v3/query_influxql", body_map, opts, [200]) do
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
    with :ok <- options(opts),
         org = Keyword.get(opts, :org, conn_val(connection, :org, "")),
         :ok <- url_values(org: org),
         do: flux_request(connection, flux, org, opts)
  end

  @spec flux_request(keyword(), term(), term(), keyword()) :: InfluxElixir.Client.query_result()
  defp flux_request(connection, flux, org, opts) do
    # The `#datatype` annotation lets ResponseParser type each column
    # (double/long/boolean/RFC3339) instead of returning every cell as text.
    body_map = %{
      "query" => flux,
      "type" => "flux",
      "dialect" => %{"annotations" => ["datatype"], "header" => true, "delimiter" => ","}
    }

    with {:ok, %Finch.Response{body: resp_body}} <-
           post_json(connection, "/api/v2/query?org=#{query_value(org)}", body_map, opts, [200]) do
      ResponseParser.parse(resp_body, :flux_csv)
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
    with :ok <- options(opts), do: create_database_request(connection, name, opts)
  end

  @spec create_database_request(keyword(), term(), keyword()) :: :ok | {:error, term()}
  defp create_database_request(connection, name, opts) do
    body_map = %{"db" => name}

    body_map =
      case Keyword.get(opts, :retention) do
        nil -> body_map
        retention -> Map.put(body_map, "retention_period", retention)
      end

    # 409 = already exists, which is success for an idempotent create.
    with {:ok, _response} <-
           post_json(connection, "/api/v3/configure/database", body_map, opts, [200, 201, 409]) do
      :ok
    end
  end

  @impl true
  @spec list_databases(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_databases(connection) do
    with {:ok, %Finch.Response{body: resp_body}} <-
           get(connection, "/api/v3/configure/database?format=json", [200]),
         {:ok, rows} when is_list(rows) <- decode_json(resp_body) do
      {:ok, Enum.map(rows, fn row -> %{"name" => row["iox::database"]} end)}
    else
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  @spec delete_database(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_database(connection, name) do
    delete_named(connection, "/api/v3/configure/database", "db", name)
  end

  # ---------------------------------------------------------------------------
  # Admin — v2 buckets (compat), in `InfluxElixir.Client.HTTP.Buckets`
  # ---------------------------------------------------------------------------

  @impl true
  @spec create_bucket(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_bucket(connection, name, opts \\ []) do
    with :ok <- options(opts), do: Buckets.create(connection, name, opts)
  end

  @impl true
  @spec list_buckets(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_buckets(connection), do: Buckets.list(connection)

  @impl true
  @spec delete_bucket(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_bucket(connection, bucket), do: Buckets.delete(connection, bucket)

  # ---------------------------------------------------------------------------
  # Admin — v3 tokens
  # ---------------------------------------------------------------------------

  @impl true
  @spec create_token(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  # The token endpoints are the ones InfluxDB 3 Core and Enterprise serve
  # (verified); `InfluxElixir.Admin.TokenRequest` builds the request.
  def create_token(connection, name, opts \\ []) do
    with :ok <- options(opts),
         {:ok, {_kind, path, body}} <- TokenRequest.build(name, opts),
         {:ok, %Finch.Response{body: resp_body}} <-
           post_json(connection, path, body, opts, [200, 201]) do
      decode_json(resp_body)
    end
  end

  @impl true
  @spec delete_token(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_token(connection, name) do
    delete_named(connection, "/api/v3/configure/token", "token_name", name)
  end

  # ---------------------------------------------------------------------------
  # Health
  # ---------------------------------------------------------------------------

  @impl true
  @spec health(InfluxElixir.Client.connection()) ::
          {:ok, map()} | {:error, term()}
  def health(connection) do
    with {:ok, %Finch.Response{body: resp_body}} <- get(connection, "/health", [200]) do
      # A 200 with a body that is no JSON object (older builds answer plain text, `OK`) is
      # still a passing health check.
      case Jason.decode(resp_body) do
        {:ok, map} when is_map(map) -> {:ok, map}
        _not_an_object -> {:ok, %{"status" => "pass"}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @doc false
  # Resolves the receive timeout in milliseconds. Precedence:
  #   opts[:timeout] → connection[:timeout] → 30_000
  # Exposed (with @doc false) for the default alone: the precedence is pinned
  # through the query functions, but a 30 second default is not waited for.
  @spec resolve_timeout(keyword(), keyword()) :: non_neg_integer()
  defdelegate resolve_timeout(opts, connection), to: Request

  @doc false
  # Resolves the pool checkout timeout in milliseconds. Precedence:
  #   opts[:pool_timeout] → connection[:pool_timeout] → 5_000
  @spec resolve_pool_timeout(keyword(), keyword()) :: non_neg_integer()
  defdelegate resolve_pool_timeout(opts, connection), to: Request

  @spec resolve_database(keyword(), keyword()) ::
          {:ok, binary()} | {:error, :no_database_specified}
  # `database: nil` is no database given, as in Client.Local and the
  # facade's telemetry; the connection's default applies.
  defp resolve_database(opts, connection) do
    case Keyword.get(opts, :database) || conn_val(connection, :database) do
      nil -> {:error, :no_database_specified}
      db -> {:ok, db}
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
