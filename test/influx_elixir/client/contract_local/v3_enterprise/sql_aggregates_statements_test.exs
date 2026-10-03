defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlAggregatesStatementsTest do
  @moduledoc """
  The `:statements` part of `InfluxElixir.Contract.SQLAggregates`
  (CROSS JOIN, a failed stream, an unknown column, DML and DDL)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLAggregates,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :statements
end
