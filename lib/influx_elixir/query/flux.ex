defmodule InfluxElixir.Query.Flux do
  @moduledoc """
  v2 Flux query executor for backwards compatibility.

  Flux is the query language for InfluxDB v2. This module provides
  compatibility for v2-to-v3 migration workflows.

  ## Usage

      InfluxElixir.Query.Flux.query(conn,
        ~S(from(bucket: "my-bucket") |> range(start: -1h) |> filter(fn: (r) => r._measurement == "cpu"))
      )
  """

  @doc """
  Executes a Flux query and returns parsed results.

  ## Options

    * `:org` - organization name (required for v2)
  """
  @spec query(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  def query(connection, flux, opts \\ []) do
    InfluxElixir.Client.impl().query_flux(connection, flux, opts)
  end
end
