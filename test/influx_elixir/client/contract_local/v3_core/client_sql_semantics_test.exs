defmodule InfluxElixir.ContractLocal.V3Core.ClientSqlSemanticsTest do
  @moduledoc """
  The `:sql_semantics` part of `InfluxElixir.ClientContract`
  (OFFSET, DISTINCT, parameters, literals, NULLs)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :sql_semantics
end
