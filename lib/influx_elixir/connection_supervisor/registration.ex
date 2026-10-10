defmodule InfluxElixir.ConnectionSupervisor.Registration do
  @moduledoc false
  # The first child of a `ConnectionSupervisor`, so the first to start and the last to stop.
  # It registers the connection the client initialised under its name when it starts, and
  # takes that registration down, and releases the client's state for the connection (the ETS
  # store of `Client.Local`), whenever the supervisor stops: removed by `remove_connection/1`,
  # shut down with the application, after a child failed to start, or gone after too many
  # restarts. It keeps the client and the connection it registered, so what it releases is
  # what it registered, whatever the registry or the configured client say by then; and as
  # the only process that writes the name, nothing else can erase a later connection's.

  use GenServer

  alias InfluxElixir.Connection

  # The connection travels as a closure: a child spec and a process's state are printed when a
  # start fails or the process crashes, and an HTTP connection holds its token.
  @typep state :: {atom(), module(), (-> term())}

  @doc false
  @spec child_spec({atom(), module(), term()}) :: Supervisor.child_spec()
  def child_spec({name, client, connection}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [{name, client, fn -> connection end}]},
      shutdown: 5_000
    }
  end

  @doc false
  @spec start_link(state()) :: GenServer.on_start()
  def start_link({name, _client, _connection} = state),
    do: GenServer.start_link(__MODULE__, state, name: process_name(name))

  @doc false
  @spec process_name(atom()) :: atom()
  def process_name(name), do: :"influx_elixir_#{name}_registration"

  @impl GenServer
  def init({name, _client, connection} = state) do
    # Without this a supervisor's exit signal kills the process before terminate/2 runs.
    Process.flag(:trap_exit, true)
    Connection.put(name, connection.())
    {:ok, state}
  end

  @impl GenServer
  def terminate(_reason, {name, client, connection}) do
    # The registration goes first, so a failing client cannot leave it behind.
    Connection.delete(name)
    client.shutdown_connection(connection.())
    :ok
  end
end
