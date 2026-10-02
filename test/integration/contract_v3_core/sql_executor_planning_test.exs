defmodule InfluxElixir.Integration.ContractV3Core.SqlExecutorPlanningTest do
  @moduledoc """
  The `:planning` part of `InfluxElixir.Contract.SQLExecutor`
  (planning order, booleans, results, infinities, joins)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :planning
end
