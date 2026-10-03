defmodule InfluxElixir.Integration.ContractV3Core.SqlAggregatesBucketsTest do
  @moduledoc """
  The `:buckets` part of `InfluxElixir.Contract.SQLAggregates`
  (DISTINCT, bucketed and scalar aggregates, COUNT)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLAggregates,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :buckets
end
