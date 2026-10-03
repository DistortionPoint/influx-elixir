defmodule InfluxElixir.ContractLocal.V3Core.SqlScalarExpressionsTest do
  @moduledoc """
  The `:expressions` part of `InfluxElixir.Contract.SQLScalar`
  (operators, CASE, COALESCE, unsigned and overflow, item names)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLScalar,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :expressions
end
