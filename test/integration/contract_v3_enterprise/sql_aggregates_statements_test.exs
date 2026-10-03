defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlAggregatesStatementsTest do
  @moduledoc """
  The `:statements` part of `InfluxElixir.Contract.SQLAggregates`
  (CROSS JOIN, a failed stream, an unknown column, DML and DDL)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLAggregates,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :statements
end
