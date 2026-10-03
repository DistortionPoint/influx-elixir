defmodule InfluxElixir.ContractLocal.V3Core.SqlExpressionsOrderTest do
  @moduledoc """
  The `:order` part of `InfluxElixir.Contract.SQLExpressions`
  (ORDER BY, GROUP BY references, OFFSET)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLExpressions,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :order
end
