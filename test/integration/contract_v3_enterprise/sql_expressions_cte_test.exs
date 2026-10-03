defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlExpressionsCteTest do
  @moduledoc """
  The `:cte` part of `InfluxElixir.Contract.SQLExpressions`
  (projected expressions, CTEs, schema errors)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExpressions,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :cte
end
