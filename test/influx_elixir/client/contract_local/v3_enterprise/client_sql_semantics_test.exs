defmodule InfluxElixir.ContractLocal.V3Enterprise.ClientSqlSemanticsTest do
  @moduledoc """
  The `:sql_semantics` part of `InfluxElixir.ClientContract`
  (OFFSET, DISTINCT, parameters, literals, NULLs)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :sql_semantics
end
