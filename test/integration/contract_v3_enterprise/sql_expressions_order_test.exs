defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlExpressionsOrderTest do
  @moduledoc """
  The `:order` part of `InfluxElixir.Contract.SQLExpressions`
  (ORDER BY, GROUP BY references, OFFSET)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExpressions,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :order
end
