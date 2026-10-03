defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlScalarAggregatesTest do
  @moduledoc """
  The `:aggregates` part of `InfluxElixir.Contract.SQLScalar`
  (aggregate expressions, HAVING and aliases)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :aggregates
end
