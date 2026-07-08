defmodule InfluxElixir.Supervisor do
  @moduledoc """
  Top-level supervisor for InfluxElixir.

  Uses `:one_for_one` strategy to provide crash isolation between
  connections. A trading connection crash does NOT restart
  the analytics connection.
  """

  use Supervisor

  @doc """
  Starts the top-level supervisor with the given connections.

  ## Options

    * `:connections` - keyword list of `{name, config}` pairs
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  @spec init(keyword()) ::
          {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec() | {module(), term()}]}}
  def init(opts) do
    connections = Keyword.get(opts, :connections, [])

    connection_children =
      Enum.map(connections, fn {name, config} ->
        Supervisor.child_spec(
          {InfluxElixir.ConnectionSupervisor, Keyword.put(config, :name, name)},
          id: {InfluxElixir.ConnectionSupervisor, name}
        )
      end)

    # GRPC.Client.Supervisor manages outbound gRPC connections for Arrow Flight.
    # grpc 1.0+ auto-starts it via GRPC.Client.Application; only add the child
    # when running against grpc 0.11.x, where the consumer is responsible.
    children = grpc_supervisor_child() ++ connection_children

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec grpc_supervisor_child() :: [Supervisor.child_spec() | {module(), term()}]
  defp grpc_supervisor_child do
    if Code.ensure_loaded?(GRPC.Client.Application) do
      []
    else
      [{GRPC.Client.Supervisor, []}]
    end
  end
end
