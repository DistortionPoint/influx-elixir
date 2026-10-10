defmodule InfluxElixir.Integration.ContractV2.FluxPushdownTest do
  @moduledoc """
  The `:pushdown` part of `InfluxElixir.Contract.Flux`
  against the real server of the `:v2` profile.
  """

  use InfluxElixir.ContractServer, profile: :v2

  use InfluxElixir.Contract.Flux,
    client: InfluxElixir.Client.HTTP,
    profile: :v2,
    part: :pushdown
end
