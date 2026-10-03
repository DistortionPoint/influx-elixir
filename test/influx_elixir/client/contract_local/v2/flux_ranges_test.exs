defmodule InfluxElixir.ContractLocal.V2.FluxRangesTest do
  @moduledoc """
  The `:ranges` part of `InfluxElixir.Contract.Flux`
  against `Client.Local` with the `:v2` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v2

  use InfluxElixir.Contract.Flux,
    client: InfluxElixir.Client.Local,
    profile: :v2,
    part: :ranges
end
