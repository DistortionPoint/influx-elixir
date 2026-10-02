defmodule InfluxElixir.ContractLocal.V3Core.InfluxqlFluxLpLineProtocolTest do
  @moduledoc """
  The `:line_protocol` part of `InfluxElixir.Contract.InfluxQLFluxLP`
  (line protocol of InfluxDB 3)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.InfluxQLFluxLP,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :line_protocol
end
