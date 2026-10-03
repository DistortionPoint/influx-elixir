defmodule InfluxElixir.Integration.ContractV3Core.InfluxqlPlannerTest do
  @moduledoc """
  `InfluxElixir.Contract.InfluxQLPlanner` against the real server of the
  `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.InfluxQLPlanner, client: InfluxElixir.Client.HTTP
end
