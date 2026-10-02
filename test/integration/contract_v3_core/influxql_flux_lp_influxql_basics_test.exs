defmodule InfluxElixir.Integration.ContractV3Core.InfluxqlFluxLpInfluxqlBasicsTest do
  @moduledoc """
  The `:influxql_basics` part of `InfluxElixir.Contract.InfluxQLFluxLP`
  (InfluxQL WHERE, clauses, parsing, reserved words)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.InfluxQLFluxLP,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :influxql_basics
end
