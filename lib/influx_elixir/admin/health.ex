defmodule InfluxElixir.Admin.Health do
  @moduledoc """
  Health and ping checks for InfluxDB instances.

  Delegates to the configured `InfluxElixir.Client` implementation.
  Use this module to verify connectivity and service health.

  ## Examples

      {:ok, conn} = InfluxElixir.Client.Local.start()

      {:ok, %{status: "pass"}} = InfluxElixir.Admin.Health.check(conn)
  """

  @doc """
  Checks the health of an InfluxDB instance.

  ## Parameters

    * `connection` - a client connection term

  ## Returns

    * `{:ok, map()}` with status details on success (e.g. `%{status: "pass"}`)
    * `{:error, reason}` if the instance is unreachable or unhealthy
  """
  @spec check(InfluxElixir.Client.connection()) :: {:ok, map()} | {:error, term()}
  def check(connection) do
    InfluxElixir.Client.impl().health(connection)
  end
end
