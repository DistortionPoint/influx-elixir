defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlScalarAggregatesTest do
  @moduledoc """
  The `:aggregates` part of `InfluxElixir.Contract.SQLScalar`
  (aggregate expressions, HAVING and aliases)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :aggregates
end
