defmodule InfluxElixir.Integration.ContractV3Core.InfluxqlFluxLpInfluxqlTimeTest do
  @moduledoc """
  The `:influxql_time` part of `InfluxElixir.Contract.InfluxQLFluxLP`
  (InfluxQL times, constants, operators, SHOW)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.InfluxQLFluxLP,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :influxql_time
end
