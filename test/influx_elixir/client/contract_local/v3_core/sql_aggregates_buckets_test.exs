defmodule InfluxElixir.ContractLocal.V3Core.SqlAggregatesBucketsTest do
  @moduledoc """
  The `:buckets` part of `InfluxElixir.Contract.SQLAggregates`
  (DISTINCT, bucketed and scalar aggregates, COUNT)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLAggregates,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :buckets
end
