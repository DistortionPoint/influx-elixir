defmodule InfluxElixir.ContractLocal.V2.FluxPushdownTest do
  @moduledoc """
  The `:pushdown` part of `InfluxElixir.Contract.Flux`
  against `Client.Local` with the `:v2` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v2

  use InfluxElixir.Contract.Flux,
    client: InfluxElixir.Client.Local,
    profile: :v2,
    part: :pushdown
end
