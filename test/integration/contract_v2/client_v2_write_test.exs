defmodule InfluxElixir.Integration.ContractV2.ClientV2WriteTest do
  @moduledoc """
  The `:v2_write` part of `InfluxElixir.ClientContract`
  (buckets, v2 write rules, bodies, precision, duplicates)
  against the real server of the `:v2` profile.
  Run with `mix test --include integration --include v2`.
  """

  use InfluxElixir.ContractServer, profile: :v2

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.HTTP,
    profile: :v2,
    part: :v2_write
end
