defmodule InfluxElixir.Integration.ContractV2.ClientV2FluxTest do
  @moduledoc """
  The `:v2_flux` part of `InfluxElixir.ClientContract`
  (Flux query errors)
  against the real server of the `:v2` profile.
  Run with `mix test --include integration --include v2`.
  """

  use InfluxElixir.ContractServer, profile: :v2

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.HTTP,
    profile: :v2,
    part: :v2_flux
end
