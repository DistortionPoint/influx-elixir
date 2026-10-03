defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlExpressionsWhereTest do
  @moduledoc """
  The `:where` part of `InfluxElixir.Contract.SQLExpressions`
  (WHERE logic, comparands, operators)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExpressions,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :where
end
