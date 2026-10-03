defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlExpressionsWhereTest do
  @moduledoc """
  The `:where` part of `InfluxElixir.Contract.SQLExpressions`
  (WHERE logic, comparands, operators)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExpressions,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :where
end
