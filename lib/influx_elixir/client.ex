defmodule InfluxElixir.Client do
  @moduledoc """
  Behaviour defining the InfluxDB client contract.

  All library modules use this behaviour — never a concrete
  implementation directly. The implementation is selected via
  application configuration:

      # config/config.exs (default: production HTTP client)
      config :influx_elixir, :client, InfluxElixir.Client.HTTP

      # config/test.exs (test: LocalClient)
      config :influx_elixir, :client, InfluxElixir.Client.Local

  ## Implementations

  - `InfluxElixir.Client.HTTP` — production Finch-based client
  - `InfluxElixir.Client.Local` — in-memory ETS-backed test client

  ## Connection Lifecycle

  Each implementation defines how connections are created and destroyed:

  - `init_connection/1` — converts raw keyword config into the
    implementation's native connection type. Called by
    `ConnectionSupervisor` during startup.
    - `Client.HTTP` returns the keyword config as-is
    - `Client.Local` creates an ETS table and returns a conn map

  - `shutdown_connection/1` — cleans up resources when a connection
    is removed. Called by `InfluxElixir.remove_connection/1`.
    - `Client.HTTP` is a no-op (Finch pool has its own supervisor)
    - `Client.Local` deletes the ETS table
  """

  @type connection :: term()
  @type query_result :: {:ok, [map()]} | {:error, term()}
  @type write_result :: {:ok, :written} | {:error, term()}

  # Connection lifecycle
  @callback init_connection(keyword()) :: {:ok, connection()} | {:error, term()}
  @callback shutdown_connection(connection()) :: :ok

  # Write
  @callback write(connection, binary(), keyword()) :: write_result()

  # Query — v3 SQL (transport: :http | :flight selected via opts)
  @callback query_sql(connection, binary(), keyword()) :: query_result()
  @callback query_sql_stream(connection, binary(), keyword()) ::
              Enumerable.t()
  @callback execute_sql(connection, binary(), keyword()) ::
              {:ok, map()} | {:error, term()}

  # Query — v3 InfluxQL
  @callback query_influxql(connection, binary(), keyword()) :: query_result()

  # Query — v2 Flux (compat)
  @callback query_flux(connection, binary(), keyword()) :: query_result()

  # Admin — v3 databases
  @callback create_database(connection, binary(), keyword()) ::
              :ok | {:error, term()}
  @callback list_databases(connection) ::
              {:ok, [map()]} | {:error, term()}
  @callback delete_database(connection, binary()) ::
              :ok | {:error, term()}

  # Admin — v2 buckets (compat)
  @callback create_bucket(connection, binary(), keyword()) ::
              :ok | {:error, term()}
  @callback list_buckets(connection) ::
              {:ok, [map()]} | {:error, term()}
  @callback delete_bucket(connection, binary()) ::
              :ok | {:error, term()}

  # Admin — v3 tokens
  @callback create_token(connection, binary(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback delete_token(connection, binary()) ::
              :ok | {:error, term()}

  # Health
  @callback health(connection) :: {:ok, map()} | {:error, term()}

  @doc """
  Returns the configured client implementation module.

  Defaults to `InfluxElixir.Client.HTTP` if not configured.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:influx_elixir, :client, InfluxElixir.Client.HTTP)
  end
end
