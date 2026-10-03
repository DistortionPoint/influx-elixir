defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlAggregatesCandlesTest do
  @moduledoc """
  The `:candles` part of `InfluxElixir.Contract.SQLAggregates`
  (first_value/last_value, OHLCV candles, median)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLAggregates,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :candles
end
