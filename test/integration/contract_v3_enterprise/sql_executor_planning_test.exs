defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlExecutorPlanningTest do
  @moduledoc """
  The `:planning` part of `InfluxElixir.Contract.SQLExecutor`
  (planning order, booleans, results, infinities, joins)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :planning
end
