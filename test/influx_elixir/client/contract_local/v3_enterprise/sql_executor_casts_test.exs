defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlExecutorCastsTest do
  @moduledoc """
  The `:casts` part of `InfluxElixir.Contract.SQLExecutor`
  (casts, overflow, plan cuts)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :casts
end
