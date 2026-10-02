defmodule InfluxElixir.IntegrationHelper do
  @moduledoc """
  Shared helpers for integration tests against real InfluxDB instances.

  Reads connection config from environment variables with defaults
  matching the Docker Compose dev setup. Starts a dedicated Finch pool
  and provides ready-to-use connection keyword lists.

  ## Environment Variables

      INFLUX_V2_HOST      (default: "localhost")
      INFLUX_V2_PORT      (default: "8086")
      INFLUX_V2_TOKEN     (default: "dev-influx-token-123456789")
      INFLUX_V2_ORG       (default: "dev-influx")
      INFLUX_V2_BUCKET    (default: "metrics")

      INFLUX_V3_CORE_HOST (default: "localhost")
      INFLUX_V3_CORE_PORT (default: "8181")

      INFLUX_V3_ENT_HOST  (default: "localhost")
      INFLUX_V3_ENT_PORT  (default: "8182")

      INFLUX_V3_AUTH_HOST  (default: "localhost")
      INFLUX_V3_AUTH_PORT  (default: "8183")
      INFLUX_V3_AUTH_TOKEN (default: created on a fresh server; see
                            `v3_core_auth_conn/1`)
  """

  @doc """
  Returns a v2 connection keyword list for InfluxDB 2.7 on port 8086.
  """
  @spec v2_conn(keyword()) :: keyword()
  def v2_conn(overrides \\ []) do
    base = [
      host: env("INFLUX_V2_HOST", "localhost"),
      port: env_int("INFLUX_V2_PORT", 8086),
      token: env("INFLUX_V2_TOKEN", "dev-influx-token-123456789"),
      org: env("INFLUX_V2_ORG", "dev-influx"),
      database: env("INFLUX_V2_BUCKET", "metrics"),
      api_version: :v2,
      scheme: :http,
      name: :integration_v2,
      finch_name: :integration_finch
    ]

    Keyword.merge(base, overrides)
  end

  @doc """
  Returns a v3 Core connection keyword list for InfluxDB 3 Core on port 8181.
  """
  @spec v3_core_conn(keyword()) :: keyword()
  def v3_core_conn(overrides \\ []) do
    base = [
      host: env("INFLUX_V3_CORE_HOST", "localhost"),
      port: env_int("INFLUX_V3_CORE_PORT", 8181),
      token: "",
      scheme: :http,
      name: :integration_v3_core,
      finch_name: :integration_finch
    ]

    Keyword.merge(base, overrides)
  end

  @doc """
  Returns a v3 Enterprise connection keyword list for InfluxDB 3 Enterprise on port 8182.
  """
  @spec v3_enterprise_conn(keyword()) :: keyword()
  def v3_enterprise_conn(overrides \\ []) do
    base = [
      host: env("INFLUX_V3_ENT_HOST", "localhost"),
      port: env_int("INFLUX_V3_ENT_PORT", 8182),
      token: "",
      scheme: :http,
      name: :integration_v3_ent,
      finch_name: :integration_finch
    ]

    Keyword.merge(base, overrides)
  end

  @doc """
  Starts the shared Finch pool for integration tests.

  Call this from `setup_all` in your integration test module:

      setup_all do
        InfluxElixir.IntegrationHelper.start_finch()
        :ok
      end
  """
  @spec start_finch() :: pid()
  def start_finch do
    case Finch.start_link(name: :integration_finch, pools: %{default: [size: 5]}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @doc """
  Returns `{:ok, conn}` for InfluxDB 3 Core started *with* authentication
  on port 8183 (token endpoints are disabled without it), its operator
  token from `INFLUX_V3_AUTH_TOKEN` or, on a fresh server, created with
  `POST /api/v3/configure/token/admin` (which works once per server).
  `{:error, reason}` when neither gives a token.
  """
  @spec v3_core_auth_conn() :: {:ok, keyword()} | {:error, term()}
  def v3_core_auth_conn do
    base = [
      host: env("INFLUX_V3_AUTH_HOST", "localhost"),
      port: env_int("INFLUX_V3_AUTH_PORT", 8183),
      scheme: :http,
      name: :integration_v3_core_auth,
      finch_name: :integration_finch
    ]

    with {:ok, token} <- operator_token(base), do: {:ok, Keyword.put(base, :token, token)}
  end

  @spec operator_token(keyword()) :: {:ok, binary()} | {:error, term()}
  defp operator_token(conn) do
    case System.get_env("INFLUX_V3_AUTH_TOKEN") do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _unset ->
        url = "http://#{conn[:host]}:#{conn[:port]}/api/v3/configure/token/admin"

        case Finch.request(Finch.build(:post, url), :integration_finch) do
          {:ok, %Finch.Response{status: 201, body: body}} -> {:ok, Jason.decode!(body)["token"]}
          {:ok, %Finch.Response{status: status, body: body}} -> {:error, {status, body}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Checks if a given InfluxDB instance is reachable via its health endpoint.

  Returns `true` if the health check responds with a 200, `false` otherwise.
  """
  @spec reachable?(keyword()) :: boolean()
  def reachable?(conn) do
    scheme = Keyword.get(conn, :scheme, :http)
    host = Keyword.fetch!(conn, :host)
    port = Keyword.fetch!(conn, :port)
    url = "#{scheme}://#{host}:#{port}/health"

    request = Finch.build(:get, url)

    case Finch.request(request, :integration_finch, receive_timeout: 2_000) do
      {:ok, %Finch.Response{}} -> true
      _other -> false
    end
  rescue
    _err -> false
  end

  @doc """
  Generates a name unique across runs: the wall-clock millisecond is part of it
  because `System.unique_integer/1` restarts in every BEAM, so a later run
  against the same server would otherwise reuse a name and join stale data.

  ## Examples

      iex> name = InfluxElixir.IntegrationHelper.unique_name("test_db")
      "test_db_1700000000000_42"
  """
  @spec unique_name(binary()) :: binary()
  def unique_name(prefix) do
    "#{prefix}_#{System.system_time(:millisecond)}_#{System.unique_integer([:positive])}"
  end

  @spec env(binary(), binary()) :: binary()
  defp env(key, default), do: System.get_env(key, default)

  @spec env_int(binary(), integer()) :: integer()
  defp env_int(key, default) do
    case System.get_env(key) do
      nil -> default
      val -> String.to_integer(val)
    end
  end
end
