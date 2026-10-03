defmodule InfluxElixir.Integration.ContractV3Core.SqlScalarAggregatesTest do
  @moduledoc """
  The `:aggregates` part of `InfluxElixir.Contract.SQLScalar`
  (aggregate expressions, HAVING and aliases)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :aggregates
end
