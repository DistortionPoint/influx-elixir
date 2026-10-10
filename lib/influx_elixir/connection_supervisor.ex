defmodule InfluxElixir.ConnectionSupervisor do
  @release_timeout_ms 15_000

  @moduledoc """
  Per-connection supervisor using `:rest_for_one` strategy.

  Manages a Finch pool (unless the config names an existing one with
  `:finch_name`) and a BatchWriter GenServer for a
  single named InfluxDB connection with crash isolation.

  On init, registers the connection config in
  `InfluxElixir.Connection` so it can be resolved by name
  from any process via `Connection.fetch!/1` or the facade. The
  registration is taken down, and the client's state for the connection
  released, whenever the supervisor stops, including when it gives up after
  too many restarts: a name never resolves to a connection that is not
  running. A call made in the moment between the registration and the pool
  starting is `{:error, {:connection_error, :no_pool}}`, never a raise.

  If the Finch pool crashes, the connection's BatchWriter (at most one)
  restarts with it, since it depends on the pool. A BatchWriter crash
  does NOT take down the pool. The writer is started with the connection's
  *name* (`connection: name`), so it writes through whatever is registered
  and its child spec, which supervisors print when a start fails, holds no
  token.

  Children stop in reverse start order, so on shutdown the BatchWriter
  writes its buffer while the Finch pool is still up.

  If this supervisor is killed outright, its children outlive it for a
  moment (they stop when they see it exit, the writer after writing its
  buffer) and still hold their registered names. A restart waits for
  those names to be released, up to `#{@release_timeout_ms}` ms each,
  before starting new children: starting at once failed with
  `:already_started`, and the repeated failures took the top-level
  supervisor, and every other connection, down with it.

  ## Failures to start

  A client whose `init_connection/1` returns `{:error, reason}` makes
  `start_link/1` return `{:error, reason}`. The `:token` never appears in
  that error or in the logs of a failed start: the child spec and the
  supervisor's argument carry it opaque (`inspect/1` prints
  `#InfluxElixir.ConnectionSupervisor.Secret<...>`).
  """

  use Supervisor

  alias InfluxElixir.Connection
  alias InfluxElixir.ConnectionSupervisor.{Registration, Secret}

  @doc """
  The child spec that starts a ConnectionSupervisor for `config`, with its `:token`
  made opaque (see "Failures to start").
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [Secret.redact(config)]},
      type: :supervisor
    }
  end

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
  @spec start_link(keyword()) :: Supervisor.on_start() | {:error, {:invalid_options, term()}}
  def start_link(config) do
    # A config that is not a keyword list holding an atom `:name` cannot name a connection:
    # the caller's error, never a raise.
    with true <- InfluxElixir.Client.Options.keyword?(config),
         name when is_atom(name) and name != nil <- Keyword.get(config, :name) do
      start_named(name, config)
    else
      _invalid -> {:error, {:invalid_options, config}}
    end
  end

  defp start_named(name, config) do
    case Supervisor.start_link(__MODULE__, Secret.redact(config), name: via(name)) do
      # The client refused the config: its error, not the supervisor's wrapping of an exit.
      {:error, {:shutdown, {:init_connection, reason}}} -> {:error, reason}
      started_or_other -> started_or_other
    end
  end

  @impl true
  @spec init(keyword()) ::
          {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec() | {module(), term()}]}}
  def init(config) do
    client = InfluxElixir.Client.impl()
    config = config |> Secret.reveal() |> then(&validate_config(client, &1))
    name = Keyword.fetch!(config, :name)
    finch_name = finch_name(name)
    pool_size = Keyword.get(config, :pool_size, 10)

    # Finch registers its own supervisor as `<name>.Supervisor`, the top of
    # its tree and so the last of its names to go; the pool's registry
    # (`<name>`) can be released before it. The registration is released last, and a
    # predecessor's still-running one would take down what is registered below.
    Enum.each(
      [
        :"#{finch_name}.Supervisor",
        finch_name,
        batch_writer_name(name),
        Registration.process_name(name)
      ],
      &await_release/1
    )

    # Initialize the connection via the configured client implementation
    # and register it in the persistent_term registry so that callers can
    # resolve it by name via Connection.fetch!/1.
    case client.init_connection(config) do
      {:ok, conn} ->
        Connection.put(name, conn)
        Supervisor.init(children(config, name, finch_name, pool_size), strategy: :rest_for_one)

      {:error, reason} ->
        # A supervisor's init has no error return; an exit is how it fails with a reason,
        # and `start_link/1` hands the reason back as the client gave it.
        exit({:shutdown, {:init_connection, reason}})
    end
  end

  # The registration first, so it stops last and takes the connection down after the writer's
  # final flush. `:finch_name` points at a pool the consumer runs; starting another one
  # here would leave an idle pool per connection and make the writer depend (rest_for_one)
  # on a pool it never uses. The writer gets the connection's *name*: `Writer` resolves it
  # to the *initialised* connection (for Client.Local the ETS-backed map, which the raw
  # keyword list is not), and no child spec holds the config.
  @spec children(keyword(), atom(), atom(), pos_integer()) :: [
          Supervisor.child_spec() | {module(), term()}
        ]
  defp children(config, name, finch_name, pool_size) do
    finch_children =
      if Keyword.has_key?(config, :finch_name) do
        []
      else
        [{Finch, name: finch_name, pools: %{default: [size: pool_size]}}]
      end

    writer_children =
      case Keyword.get(config, :batch_writer) do
        nil ->
          []

        batch_opts ->
          [
            {InfluxElixir.Write.BatchWriter,
             Keyword.merge(batch_opts, connection: name, name: batch_writer_name(name))}
          ]
      end

    [Registration.child_spec(name)] ++ finch_children ++ writer_children
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
