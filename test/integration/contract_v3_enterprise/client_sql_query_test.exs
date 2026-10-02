defmodule InfluxElixir.Integration.ContractV3Enterprise.ClientSqlQueryTest do
  @moduledoc """
  The `:sql_query` part of `InfluxElixir.ClientContract`
  (SQL queries, aggregates, CTEs, filters, joins, casts)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :sql_query
end
