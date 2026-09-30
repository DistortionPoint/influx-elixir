defmodule InfluxElixir.ConnectionSupervisor do
  @release_timeout_ms 15_000

  @moduledoc """
  Per-connection supervisor using `:rest_for_one` strategy.

  Manages a Finch pool (unless the config names an existing one with
  `:finch_name`) and a BatchWriter GenServer for a
  single named InfluxDB connection with crash isolation.

  On init, registers the connection config in
  `InfluxElixir.Connection` so it can be resolved by name
  from any process via `Connection.fetch!/1` or the facade.

  If a Finch pool crashes, all BatchWriters under that connection
  restart (they depend on the pool). A single BatchWriter crash
  does NOT take down the pool or sibling writers.

  Children stop in reverse start order, so on shutdown the BatchWriter
  writes its buffer while the Finch pool is still up.

  If this supervisor is killed outright, its children outlive it for a
  moment (they stop when they see it exit, the writer after writing its
  buffer) and still hold their registered names. A restart waits for
  those names to be released, up to `#{@release_timeout_ms}` ms each,
  before starting new children: starting at once failed with
  `:already_started`, and the repeated failures took the top-level
  supervisor, and every other connection, down with it.
  """

  use Supervisor

  @doc """
  Starts a ConnectionSupervisor for a named connection.

  ## Config

    * `:name` - connection name (atom, required)
    * `:host` - InfluxDB host (no scheme)
    * `:token` - authentication token
    * `:database` - default database for writes/queries
    * `:databases` - list of database names (see `InfluxElixir.Config`)
    * `:pool_size` - Finch connection pool size (default: 10)
    * `:finch_name` - an existing Finch pool to use; no per-connection pool is started
    * `:batch_writer` - keyword options for an `InfluxElixir.Write.BatchWriter`
      child; omitted means no writer
    * any other `InfluxElixir.Config` option (`:api_version`, `:scheme`, ...)

  When the configured client is `InfluxElixir.Client.HTTP` the config is
  validated with `InfluxElixir.Config.validate!/1`, so a typo such as
  `default_database:` fails at startup instead of being silently ignored.
  `InfluxElixir.Client.Local` needs no host, so its config is not validated.
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
    client = InfluxElixir.Client.impl()
    config = validate_config(client, config)
    name = Keyword.fetch!(config, :name)
    finch_name = finch_name(name)
    pool_size = Keyword.get(config, :pool_size, 10)

    # Initialize the connection via the configured client implementation
    # and register it in the persistent_term registry so that callers can
    # resolve it by name via Connection.fetch!/1.
    {:ok, conn} = client.init_connection(config)
    InfluxElixir.Connection.put(name, conn)

    # `:finch_name` points at a pool the consumer runs; starting another one
    # here would leave an idle pool per connection and make the writer
    # depend (rest_for_one) on a pool it never uses.
    finch_children =
      if Keyword.has_key?(config, :finch_name) do
        []
      else
        [{Finch, name: finch_name, pools: %{default: [size: pool_size]}}]
      end

    batch_opts = Keyword.get(config, :batch_writer)

    # Finch registers its own supervisor as `<name>.Supervisor`, the top of
    # its tree and so the last of its names to go; the pool's registry
    # (`<name>`) can be released before it.
    Enum.each(
      [:"#{finch_name}.Supervisor", finch_name, batch_writer_name(name)],
      &await_release/1
    )

    # The writer gets the *initialised* connection, not the raw config: for
    # Client.Local that is the ETS-backed map, and the raw keyword list would
    # not match `Local.write/3`.
    children =
      if batch_opts do
        writer_opts =
          Keyword.merge(batch_opts,
            connection: conn,
            name: batch_writer_name(name)
          )

        finch_children ++ [{InfluxElixir.Write.BatchWriter, writer_opts}]
      else
        finch_children
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # A child left over from a killed predecessor still holds its name until
  # it has stopped; wait for that rather than fail to start.
  @spec await_release(atom()) :: :ok
  defp await_release(registered_name) do
    case Process.whereis(registered_name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          @release_timeout_ms ->
            Process.demonitor(ref, [:flush])
            :ok
        end
    end
  end

  @spec validate_config(module(), keyword()) :: keyword()
  defp validate_config(InfluxElixir.Client.HTTP, config),
    do: InfluxElixir.Config.validate!(config)

  defp validate_config(_client, config), do: config

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
  @spec via(atom()) :: atom()
  def via(name) do
    :"influx_elixir_conn_#{name}"
  end
end
