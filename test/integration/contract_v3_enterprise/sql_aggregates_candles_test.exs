defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlAggregatesCandlesTest do
  @moduledoc """
  The `:candles` part of `InfluxElixir.Contract.SQLAggregates`
  (first_value/last_value, OHLCV candles, median)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLAggregates,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :candles
end
