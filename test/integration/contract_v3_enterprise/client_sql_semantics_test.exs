defmodule InfluxElixir.Integration.ContractV3Enterprise.ClientSqlSemanticsTest do
  @moduledoc """
  The `:sql_semantics` part of `InfluxElixir.ClientContract`
  (OFFSET, DISTINCT, parameters, literals, NULLs)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :sql_semantics
end
