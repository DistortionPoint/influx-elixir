defmodule InfluxElixir.Application do
  @moduledoc """
  OTP Application entry point for InfluxElixir.

  Starts the top-level supervisor which manages
  per-connection supervisors (Finch pools + BatchWriters).

  ## Configuration

      config :influx_elixir, :connections,
        trading: [
          host: "influx-trading:8086",
          token: "...",
          default_database: "prices"
        ]
  """

  use Application

  @impl true
  @spec start(Application.start_type(), term()) ::
          {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    connections =
      Application.get_env(:influx_elixir, :connections, [])

    InfluxElixir.Supervisor.start_link(connections: connections)
  end
end
