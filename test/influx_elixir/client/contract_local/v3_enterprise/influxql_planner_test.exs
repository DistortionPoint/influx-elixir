defmodule InfluxElixir.ContractLocal.V3Enterprise.InfluxqlPlannerTest do
  @moduledoc """
  `InfluxElixir.Contract.InfluxQLPlanner` against `Client.Local` with the
  `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.InfluxQLPlanner, client: InfluxElixir.Client.Local
end
