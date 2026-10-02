defmodule InfluxElixir.ContractLocal.V3Core.InfluxqlFluxLpInfluxqlBasicsTest do
  @moduledoc """
  The `:influxql_basics` part of `InfluxElixir.Contract.InfluxQLFluxLP`
  (InfluxQL WHERE, clauses, parsing, reserved words)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.InfluxQLFluxLP,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :influxql_basics
end
