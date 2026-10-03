defmodule InfluxElixir.Integration.ContractV3Core.SqlAggregatesCandlesTest do
  @moduledoc """
  The `:candles` part of `InfluxElixir.Contract.SQLAggregates`
  (first_value/last_value, OHLCV candles, median)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLAggregates,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :candles
end
