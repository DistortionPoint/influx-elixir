defmodule InfluxElixir.ContractLocal.V3Core.SqlScalarAggregatesTest do
  @moduledoc """
  The `:aggregates` part of `InfluxElixir.Contract.SQLScalar`
  (aggregate expressions, HAVING and aliases)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :aggregates
end
