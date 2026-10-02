defmodule InfluxElixir.ContractLocal.V3Core.SqlExecutorCastsTest do
  @moduledoc """
  The `:casts` part of `InfluxElixir.Contract.SQLExecutor`
  (casts, overflow, plan cuts)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :casts
end
