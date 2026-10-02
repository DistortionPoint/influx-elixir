defmodule InfluxElixir.ContractLocal.V3Core.ClientSqlQueryTest do
  @moduledoc """
  The `:sql_query` part of `InfluxElixir.ClientContract`
  (SQL queries, aggregates, CTEs, filters, joins, casts)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :sql_query
end
