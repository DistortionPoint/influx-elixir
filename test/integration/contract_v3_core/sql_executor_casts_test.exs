defmodule InfluxElixir.Integration.ContractV3Core.SqlExecutorCastsTest do
  @moduledoc """
  The `:casts` part of `InfluxElixir.Contract.SQLExecutor`
  (casts, overflow, plan cuts)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :casts
end
