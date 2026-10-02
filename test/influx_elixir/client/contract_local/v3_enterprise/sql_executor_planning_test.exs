defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlExecutorPlanningTest do
  @moduledoc """
  The `:planning` part of `InfluxElixir.Contract.SQLExecutor`
  (planning order, booleans, results, infinities, joins)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :planning
end
