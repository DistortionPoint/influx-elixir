defmodule InfluxElixir.ConnectionSupervisor.Registration do
  @moduledoc false
  # The first child of a `ConnectionSupervisor`, so the last to stop. The supervisor
  # registers the connection under its name when it starts; this process takes that
  # registration down, and releases the client's state for the connection (the ETS store
  # of `Client.Local`), whenever the supervisor stops: removed by `remove_connection/1`,
  # shut down with the application, or gone after too many restarts. Without it a supervisor
  # that gave up left its name resolving to a connection that was not running.

  use GenServer

  alias InfluxElixir.Connection

  @doc false
  @spec child_spec(atom()) :: Supervisor.child_spec()
  def child_spec(name) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [name]}, shutdown: 5_000}
  end

  @doc false
  @spec start_link(atom()) :: GenServer.on_start()
  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: process_name(name))

  @doc false
  @spec process_name(atom()) :: atom()
  def process_name(name), do: :"influx_elixir_#{name}_registration"

  @impl GenServer
  def init(name) do
    # Without this a supervisor's exit signal kills the process before terminate/2 runs.
    Process.flag(:trap_exit, true)
    {:ok, name}
  end

  @impl GenServer
  def terminate(_reason, name) do
    # The registration goes first, so a failing client cannot leave it behind.
    connection = Connection.get(name)
    Connection.delete(name)

    with {:ok, connection} <- connection do
      InfluxElixir.Client.impl().shutdown_connection(connection)
    end

    :ok
  end
end
