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

  ## InfluxDB v3 API Endpoints

    * Write: `POST /api/v2/write?db=DATABASE&precision=PRECISION`
    * SQL Query: `POST /api/v3/query_sql` (JSON body)
    * InfluxQL: `POST /api/v3/query_influxql` (JSON body)
    * Databases: `GET/POST/DELETE /api/v3/configure/database`
    * Tokens: `POST/DELETE /api/v3/configure/token`
    * Health: `GET /health`

  ## InfluxDB v2 Compatibility

    * Flux: `POST /api/v2/query` (JSON body)
    * Buckets: `GET/POST/DELETE /api/v2/buckets`
  """

  @behaviour InfluxElixir.Client

  alias InfluxElixir.Query.ResponseParser

  # ---------------------------------------------------------------------------
  # Write
  # ---------------------------------------------------------------------------

  @impl true
  @spec write(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.write_result()
  def write(connection, line_protocol, opts \\ []) do
    with {:ok, database} <- resolve_database(opts, connection) do
      precision = Keyword.get(opts, :precision, "nanosecond")
      gzip? = Keyword.get(opts, :gzip, false)

      url =
        base_url(connection) <>
          "/api/v2/write?db=#{URI.encode(database)}" <>
          "&precision=#{precision}"

      headers = auth_headers(connection)

      {body, headers} =
        if gzip? do
          {line_protocol, [{"content-encoding", "gzip"} | headers]}
        else
          {line_protocol, headers}
        end

      case do_request(:post, url, headers, body, connection) do
        {:ok, %Finch.Response{status: status}} when status in [200, 204] ->
          {:ok, :written}

        {:ok, %Finch.Response{status: status, body: resp_body}} ->
          {:error, %{status: status, body: resp_body}}

        {:error, reason} ->
          {:error, {:connection_error, reason}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Query — v3 SQL
  # ---------------------------------------------------------------------------

  @impl true
  @spec query_sql(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  def query_sql(connection, sql, opts \\ []) do
    with {:ok, database} <- resolve_database(opts, connection) do
      params = Keyword.get(opts, :params, %{})
      format = Keyword.get(opts, :format, :json)

      body =
        Jason.encode!(%{
          "database" => database,
          "sql" => sql,
          "params" => params,
          "format" => to_string(format)
        })

      url = base_url(connection) <> "/api/v3/query_sql"
      headers = json_headers(connection)

      case do_request(:post, url, headers, body, connection) do
        {:ok, %Finch.Response{status: 200, body: resp_body}} ->
          ResponseParser.parse(resp_body, format)

        {:ok, %Finch.Response{status: status, body: resp_body}} ->
          {:error, %{status: status, body: resp_body}}

        {:error, reason} ->
          {:error, {:connection_error, reason}}
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
        params = Keyword.get(opts, :params, %{})

        body =
          Jason.encode!(%{
            "database" => database,
            "sql" => sql,
            "params" => params,
            "format" => "jsonl"
          })

        url = base_url(connection) <> "/api/v3/query_sql"
        headers = json_headers(connection)
        finch_name = resolve_finch(connection)

        Stream.resource(
          fn -> start_stream(finch_name, url, headers, body) end,
          &stream_next/1,
          &stream_cleanup/1
        )

      {:error, _reason} ->
        Stream.map([], & &1)
    end
  end

  @impl true
  @spec execute_sql(InfluxElixir.Client.connection(), binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_sql(connection, sql, opts \\ []) do
    with {:ok, database} <- resolve_database(opts, connection) do
      body = Jason.encode!(%{"database" => database, "sql" => sql})

      url = base_url(connection) <> "/api/v3/query_sql"
      headers = json_headers(connection)

      case do_request(:post, url, headers, body, connection) do
        {:ok, %Finch.Response{status: 200, body: resp_body}} ->
          Jason.decode(resp_body)

        {:ok, %Finch.Response{status: status, body: resp_body}} ->
          {:error, %{status: status, body: resp_body}}

        {:error, reason} ->
          {:error, {:connection_error, reason}}
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
    with {:ok, database} <- resolve_database(opts, connection) do
      format = Keyword.get(opts, :format, :json)

      body =
        Jason.encode!(%{
          "database" => database,
          "query" => influxql,
          "format" => to_string(format)
        })

      url = base_url(connection) <> "/api/v3/query_influxql"
      headers = json_headers(connection)

      case do_request(:post, url, headers, body, connection) do
        {:ok, %Finch.Response{status: 200, body: resp_body}} ->
          ResponseParser.parse(resp_body, format)

        {:ok, %Finch.Response{status: status, body: resp_body}} ->
          {:error, %{status: status, body: resp_body}}

        {:error, reason} ->
          {:error, {:connection_error, reason}}
      end
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

    body =
      Jason.encode!(%{
        "query" => flux,
        "type" => "flux"
      })

    url = base_url(connection) <> "/api/v2/query?org=#{URI.encode(org)}"
    headers = json_headers(connection)

    case do_request(:post, url, headers, body, connection) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        ResponseParser.parse(resp_body, :csv)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
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
    retention = Keyword.get(opts, :retention, 0)

    body =
      Jason.encode!(%{
        "name" => name,
        "retentionPeriod" => retention
      })

    url = base_url(connection) <> "/api/v3/configure/database"
    headers = json_headers(connection)

    case do_request(:post, url, headers, body, connection) do
      {:ok, %Finch.Response{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @impl true
  @spec list_databases(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_databases(connection) do
    url = base_url(connection) <> "/api/v3/configure/database"
    headers = auth_headers(connection)

    case do_request(:get, url, headers, nil, connection) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        Jason.decode(resp_body)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @impl true
  @spec delete_database(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_database(connection, name) do
    url =
      base_url(connection) <>
        "/api/v3/configure/database?name=#{URI.encode(name)}"

    headers = auth_headers(connection)

    case do_request(:delete, url, headers, nil, connection) do
      {:ok, %Finch.Response{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
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
    org_id = Keyword.get(opts, :org_id, "")
    retention = Keyword.get(opts, :retention, 0)

    body =
      Jason.encode!(%{
        "name" => name,
        "orgID" => org_id,
        "retentionRules" => [%{"everySeconds" => retention}]
      })

    url = base_url(connection) <> "/api/v2/buckets"
    headers = json_headers(connection)

    case do_request(:post, url, headers, body, connection) do
      {:ok, %Finch.Response{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @impl true
  @spec list_buckets(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_buckets(connection) do
    url = base_url(connection) <> "/api/v2/buckets"
    headers = auth_headers(connection)

    case do_request(:get, url, headers, nil, connection) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, %{"buckets" => buckets}} -> {:ok, buckets}
          {:ok, other} -> {:ok, List.wrap(other)}
          error -> error
        end

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @impl true
  @spec delete_bucket(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_bucket(connection, bucket_id) do
    url =
      base_url(connection) <>
        "/api/v2/buckets/#{URI.encode(bucket_id)}"

    headers = auth_headers(connection)

    case do_request(:delete, url, headers, nil, connection) do
      {:ok, %Finch.Response{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
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

    case do_request(:post, url, headers, body, connection) do
      {:ok, %Finch.Response{status: status, body: resp_body}}
      when status in [200, 201] ->
        Jason.decode(resp_body)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
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

    case do_request(:delete, url, headers, nil, connection) do
      {:ok, %Finch.Response{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
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

    case do_request(:get, url, headers, nil, connection) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        Jason.decode(resp_body)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: HTTP helpers
  # ---------------------------------------------------------------------------

  @spec do_request(
          :get | :post | :delete,
          binary(),
          [{binary(), binary()}],
          binary() | nil,
          keyword()
        ) :: {:ok, Finch.Response.t()} | {:error, term()}
  defp do_request(method, url, headers, body, connection) do
    finch_name = resolve_finch(connection)

    request = Finch.build(method, url, headers, body)
    Finch.request(request, finch_name)
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
    token = conn_val(connection, :token)
    [{"authorization", "Bearer #{token}"}]
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
  # ---------------------------------------------------------------------------

  @spec start_stream(atom(), binary(), list(), binary()) ::
          {:ok, Finch.Response.t()} | {:error, term()}
  defp start_stream(finch_name, url, headers, body) do
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, finch_name) do
      {:ok, %Finch.Response{status: 200, body: resp_body} = resp} ->
        lines =
          resp_body
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!/1)

        {:lines, lines, resp}

      {:ok, resp} ->
        {:done, resp}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec stream_next(term()) ::
          {[map()], term()} | {:halt, term()}
  defp stream_next({:lines, [], resp}), do: {:halt, resp}
  defp stream_next({:lines, lines, resp}), do: {lines, {:lines, [], resp}}
  defp stream_next({:done, resp}), do: {:halt, resp}
  defp stream_next({:error, _reason} = err), do: {:halt, err}

  @spec stream_cleanup(term()) :: :ok
  defp stream_cleanup(_state), do: :ok
end
