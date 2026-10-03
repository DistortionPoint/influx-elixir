defmodule InfluxElixir.ContractLocal.V3Core.SqlAggregatesCandlesTest do
  @moduledoc """
  The `:candles` part of `InfluxElixir.Contract.SQLAggregates`
  (first_value/last_value, OHLCV candles, median)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLAggregates,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :candles
end
