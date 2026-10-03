defmodule InfluxElixir.Integration.ContractV3Core.SqlExpressionsCteTest do
  @moduledoc """
  The `:cte` part of `InfluxElixir.Contract.SQLExpressions`
  (projected expressions, CTEs, schema errors)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLExpressions,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :cte
end
