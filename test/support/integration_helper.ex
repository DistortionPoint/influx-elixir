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
      {:ok, %Finch.Response{status: 200}} -> true
      _other -> false
    end
  rescue
    _err -> false
  end

  @doc """
  Generates a unique name for test databases/measurements to avoid collisions.

  ## Examples

      iex> name = InfluxElixir.IntegrationHelper.unique_name("test_db")
      "test_db_..." # with unique integer suffix
  """
  @spec unique_name(binary()) :: binary()
  def unique_name(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
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
