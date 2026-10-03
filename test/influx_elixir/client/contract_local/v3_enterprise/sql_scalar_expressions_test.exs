defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlScalarExpressionsTest do
  @moduledoc """
  The `:expressions` part of `InfluxElixir.Contract.SQLScalar`
  (operators, CASE, COALESCE, unsigned and overflow, item names)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :expressions
end
