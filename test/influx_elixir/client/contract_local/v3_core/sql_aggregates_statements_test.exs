defmodule InfluxElixir.ContractLocal.V3Core.SqlAggregatesStatementsTest do
  @moduledoc """
  The `:statements` part of `InfluxElixir.Contract.SQLAggregates`
  (CROSS JOIN, a failed stream, an unknown column, DML and DDL)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLAggregates,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :statements
end
