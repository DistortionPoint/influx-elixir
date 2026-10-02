defmodule InfluxElixir.ContractLocal.V3Enterprise.ClientSqlQueryTest do
  @moduledoc """
  The `:sql_query` part of `InfluxElixir.ClientContract`
  (SQL queries, aggregates, CTEs, filters, joins, casts)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :sql_query
end
