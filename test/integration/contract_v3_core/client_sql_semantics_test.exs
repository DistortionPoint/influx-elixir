defmodule InfluxElixir.Integration.ContractV3Core.ClientSqlSemanticsTest do
  @moduledoc """
  The `:sql_semantics` part of `InfluxElixir.ClientContract`
  (OFFSET, DISTINCT, parameters, literals, NULLs)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :sql_semantics
end
