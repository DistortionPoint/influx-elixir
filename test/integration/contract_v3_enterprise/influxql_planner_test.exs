defmodule InfluxElixir.Integration.ContractV3Enterprise.InfluxqlPlannerTest do
  @moduledoc """
  `InfluxElixir.Contract.InfluxQLPlanner` against the real server of the
  `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.InfluxQLPlanner, client: InfluxElixir.Client.HTTP
end
