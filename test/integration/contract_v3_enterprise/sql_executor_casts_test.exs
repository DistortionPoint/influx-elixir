defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlExecutorCastsTest do
  @moduledoc """
  The `:casts` part of `InfluxElixir.Contract.SQLExecutor`
  (casts, overflow, plan cuts)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :casts
end
