defmodule InfluxElixir.ContractLocal.V3Core.InfluxqlPlannerTest do
  @moduledoc """
  `InfluxElixir.Contract.InfluxQLPlanner` against `Client.Local` with the
  `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.InfluxQLPlanner, client: InfluxElixir.Client.Local
end
