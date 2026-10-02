defmodule InfluxElixir.Integration.ContractV3Core.InfluxqlFluxLpInfluxqlTypedTest do
  @moduledoc """
  The `:influxql_typed` part of `InfluxElixir.Contract.InfluxQLFluxLP`
  (InfluxQL typed comparisons, names, NOT)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.InfluxQLFluxLP,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :influxql_typed
end
