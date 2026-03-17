defmodule InfluxElixir.ConnectionSupervisor do
  @moduledoc """
  Per-connection supervisor using `:rest_for_one` strategy.

  Manages a Finch pool and BatchWriter GenServers for a
  single named InfluxDB connection with crash isolation.

  On init, registers the connection config in
  `InfluxElixir.Connection` so it can be resolved by name
  from any process via `Connection.fetch!/1` or the facade.

  If a Finch pool crashes, all BatchWriters under that connection
  restart (they depend on the pool). A single BatchWriter crash
  does NOT take down the pool or sibling writers.
  """

  use Supervisor

  @doc """
  Starts a ConnectionSupervisor for a named connection.

  ## Config

    * `:name` - connection name (atom, required)
    * `:host` - InfluxDB host URL
    * `:token` - authentication token
    * `:default_database` - default database for writes/queries
    * `:pool_size` - Finch connection pool size (default: 10)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(config) do
    name = Keyword.fetch!(config, :name)

    Supervisor.start_link(
      __MODULE__,
      config,
      name: via(name)
    )
  end

  @impl true
  @spec init(keyword()) ::
          {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec() | {module(), term()}]}}
  def init(config) do
    name = Keyword.fetch!(config, :name)
    finch_name = finch_name(name)
    pool_size = Keyword.get(config, :pool_size, 10)

    # Initialize the connection via the configured client implementation
    # and register it in the persistent_term registry so that callers can
    # resolve it by name via Connection.fetch!/1.
    {:ok, conn} = InfluxElixir.Client.impl().init_connection(config)
    InfluxElixir.Connection.put(name, conn)

    finch_child =
      {Finch,
       name: finch_name,
       pools: %{
         :default => [size: pool_size]
       }}

    batch_opts = Keyword.get(config, :batch_writer)

    children =
      if batch_opts do
        writer_opts =
          Keyword.merge(batch_opts,
            connection: config,
            name: batch_writer_name(name)
          )

        [finch_child, {InfluxElixir.Write.BatchWriter, writer_opts}]
      else
        [finch_child]
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  @spec finch_name(atom()) :: atom()
  def finch_name(connection_name) do
    :"influx_elixir_#{connection_name}_finch"
  end

  @doc false
  @spec batch_writer_name(atom()) :: atom()
  def batch_writer_name(connection_name) do
    :"influx_elixir_#{connection_name}_batch_writer"
  end

  @doc false
  @spec via(atom()) :: {:via, Registry, term()} | atom()
  def via(name) do
    :"influx_elixir_conn_#{name}"
  end
end
