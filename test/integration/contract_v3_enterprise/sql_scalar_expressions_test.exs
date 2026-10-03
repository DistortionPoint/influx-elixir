defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlScalarExpressionsTest do
  @moduledoc """
  The `:expressions` part of `InfluxElixir.Contract.SQLScalar`
  (operators, CASE, COALESCE, unsigned and overflow, item names)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :expressions
end
