defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlAggregatesBucketsTest do
  @moduledoc """
  The `:buckets` part of `InfluxElixir.Contract.SQLAggregates`
  (DISTINCT, bucketed and scalar aggregates, COUNT)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLAggregates,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :buckets
end
