defmodule InfluxElixir.ContractLocal.V3Core.SqlExecutorUnsignedBoundsTest do
  @moduledoc """
  The `:unsigned_bounds` part of `InfluxElixir.Contract.SQLExecutor`
  (unsigned columns, bounds)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :unsigned_bounds
end
