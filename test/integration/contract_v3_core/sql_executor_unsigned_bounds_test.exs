defmodule InfluxElixir.Integration.ContractV3Core.SqlExecutorUnsignedBoundsTest do
  @moduledoc """
  The `:unsigned_bounds` part of `InfluxElixir.Contract.SQLExecutor`
  (unsigned columns, bounds)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :unsigned_bounds
end
