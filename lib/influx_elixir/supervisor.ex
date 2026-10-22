defmodule InfluxElixir.Supervisor do
  @moduledoc """
  Top-level supervisor for InfluxElixir.

  Uses `:one_for_one` strategy to provide crash isolation between
  connections. A trading connection crash does NOT restart
  the analytics connection.
  """

  use Supervisor

  alias InfluxElixir.Client.Options

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
  @spec init(term()) ::
          {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec() | {module(), term()}]}}
  def init(opts) do
    # GRPC.Client.Supervisor manages outbound gRPC connections for Arrow Flight.
    # grpc 1.0+ auto-starts it via GRPC.Client.Application; only add the child
    # when running against grpc 0.11.x, where the consumer is responsible.
    children = grpc_supervisor_child() ++ connection_children(opts)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec connection_children(term()) :: [Supervisor.child_spec()]
  defp connection_children(opts) do
    with true <- Options.keyword?(opts),
         connections when is_list(connections) <- Keyword.get(opts, :connections, []),
         true <- proper_list?(connections) do
      for {name, config} <- connections do
        child_config =
          if Options.keyword?(config), do: Keyword.put(config, :name, name), else: config

        Supervisor.child_spec(
          {InfluxElixir.ConnectionSupervisor, child_config},
          id: {InfluxElixir.ConnectionSupervisor, name}
        )
      end
    else
      _invalid -> []
    end
  end

  @spec proper_list?(list()) :: boolean()
  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_improper), do: false

  @spec grpc_supervisor_child() :: [Supervisor.child_spec() | {module(), term()}]
  defp grpc_supervisor_child do
    if Code.ensure_loaded?(GRPC.Client.Application) do
      []
    else
      [{GRPC.Client.Supervisor, []}]
    end
  end
end
