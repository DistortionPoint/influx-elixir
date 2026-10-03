defmodule InfluxElixir.Integration.ContractV3Core.SqlExpressionsWhereTest do
  @moduledoc """
  The `:where` part of `InfluxElixir.Contract.SQLExpressions`
  (WHERE logic, comparands, operators)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLExpressions,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :where
end
