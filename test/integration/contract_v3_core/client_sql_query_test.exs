defmodule InfluxElixir.Integration.ContractV3Core.ClientSqlQueryTest do
  @moduledoc """
  The `:sql_query` part of `InfluxElixir.ClientContract`
  (SQL queries, aggregates, CTEs, filters, joins, casts)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :sql_query
end
