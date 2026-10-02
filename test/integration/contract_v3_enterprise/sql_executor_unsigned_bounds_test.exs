defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlExecutorUnsignedBoundsTest do
  @moduledoc """
  The `:unsigned_bounds` part of `InfluxElixir.Contract.SQLExecutor`
  (unsigned columns, bounds)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :unsigned_bounds
end
