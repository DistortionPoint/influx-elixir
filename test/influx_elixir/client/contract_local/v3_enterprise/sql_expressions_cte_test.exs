defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlExpressionsCteTest do
  @moduledoc """
  The `:cte` part of `InfluxElixir.Contract.SQLExpressions`
  (projected expressions, CTEs, schema errors)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExpressions,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :cte
end
