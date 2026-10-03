defmodule InfluxElixir.ContractLocal.V3Core.SqlExpressionsWhereTest do
  @moduledoc """
  The `:where` part of `InfluxElixir.Contract.SQLExpressions`
  (WHERE logic, comparands, operators)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLExpressions,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :where
end
