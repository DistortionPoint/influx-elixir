defmodule InfluxElixir.Integration.ContractV3Core.SqlAggregatesStatementsTest do
  @moduledoc """
  The `:statements` part of `InfluxElixir.Contract.SQLAggregates`
  (CROSS JOIN, a failed stream, an unknown column, DML and DDL)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLAggregates,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :statements
end
