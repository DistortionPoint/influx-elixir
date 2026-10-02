defmodule InfluxElixir.ContractLocal.V3Core.InfluxqlFluxLpInfluxqlTypedTest do
  @moduledoc """
  The `:influxql_typed` part of `InfluxElixir.Contract.InfluxQLFluxLP`
  (InfluxQL typed comparisons, names, NOT)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.InfluxQLFluxLP,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :influxql_typed
end
