defmodule InfluxElixir.ContractLocal.V2.ClientV2WriteTest do
  @moduledoc """
  The `:v2_write` part of `InfluxElixir.ClientContract`
  (buckets, v2 write rules, bodies, precision, duplicates)
  against `Client.Local` with the `:v2` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v2

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v2,
    part: :v2_write
end
