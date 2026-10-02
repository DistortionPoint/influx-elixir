defmodule InfluxElixir.Integration.ContractV3Core.InfluxqlFluxLpLineProtocolTest do
  @moduledoc """
  The `:line_protocol` part of `InfluxElixir.Contract.InfluxQLFluxLP`
  (line protocol of InfluxDB 3)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.InfluxQLFluxLP,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :line_protocol
end
