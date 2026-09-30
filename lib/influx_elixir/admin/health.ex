defmodule InfluxElixir.Admin.Health do
  @moduledoc """
  Health and ping checks for InfluxDB instances.

  Each function is the `InfluxElixir` facade function of the same operation:
  it takes a connection or a connection name. Admin operations emit no
  telemetry span; only writes and queries do (see `InfluxElixir.Telemetry`).

  Use this module to verify connectivity and service health.

  ## Examples

      {:ok, conn} = InfluxElixir.Client.Local.start()

      {:ok, %{"status" => "pass"}} = InfluxElixir.Admin.Health.check(conn)
  """

  @doc """
  Checks the health of an InfluxDB instance.

  ## Parameters

    * `connection` - a client connection term

  ## Returns

    * `{:ok, map()}` with string keys, as decoded from the server's JSON
      (e.g. `%{"status" => "pass"}`); `Client.Local` returns the same shape
    * `{:error, reason}` if the instance is unreachable or unhealthy
  """
  @spec check(InfluxElixir.Client.connection()) :: {:ok, map()} | {:error, term()}
  def check(connection) do
    InfluxElixir.health(connection)
  end
end
