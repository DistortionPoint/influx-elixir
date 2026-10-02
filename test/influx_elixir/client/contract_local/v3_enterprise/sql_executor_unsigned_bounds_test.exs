defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlExecutorUnsignedBoundsTest do
  @moduledoc """
  The `:unsigned_bounds` part of `InfluxElixir.Contract.SQLExecutor`
  (unsigned columns, bounds)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :unsigned_bounds
end
