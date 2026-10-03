defmodule InfluxElixir.ContractLocal.V2.ClientV2FluxTest do
  @moduledoc """
  The `:v2_flux` part of `InfluxElixir.ClientContract`
  (the Flux pipeline and queries)
  against `Client.Local` with the `:v2` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v2

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v2,
    part: :v2_flux
end
