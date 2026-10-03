defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlAggregatesBucketsTest do
  @moduledoc """
  The `:buckets` part of `InfluxElixir.Contract.SQLAggregates`
  (DISTINCT, bucketed and scalar aggregates, COUNT)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLAggregates,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :buckets
end
