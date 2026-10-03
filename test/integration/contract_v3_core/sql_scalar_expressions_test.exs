defmodule InfluxElixir.Integration.ContractV3Core.SqlScalarExpressionsTest do
  @moduledoc """
  The `:expressions` part of `InfluxElixir.Contract.SQLScalar`
  (operators, CASE, COALESCE, unsigned and overflow, item names)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :expressions
end
