defmodule InfluxElixir.ContractLocal.V3Core.SqlExpressionsCteTest do
  @moduledoc """
  The `:cte` part of `InfluxElixir.Contract.SQLExpressions`
  (projected expressions, CTEs, schema errors)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLExpressions,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :cte
end
