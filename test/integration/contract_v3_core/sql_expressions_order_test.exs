defmodule InfluxElixir.Integration.ContractV3Core.SqlExpressionsOrderTest do
  @moduledoc """
  The `:order` part of `InfluxElixir.Contract.SQLExpressions`
  (ORDER BY, GROUP BY references, OFFSET)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLExpressions,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :order
end
