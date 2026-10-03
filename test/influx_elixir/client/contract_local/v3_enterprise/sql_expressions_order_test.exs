defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlExpressionsOrderTest do
  @moduledoc """
  The `:order` part of `InfluxElixir.Contract.SQLExpressions`
  (ORDER BY, GROUP BY references, OFFSET)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExpressions,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :order
end
