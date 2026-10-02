defmodule InfluxElixir.Integration.ContractV3Core.SqlExecutorFoldingTest do
  @moduledoc """
  The `:folding` part of `InfluxElixir.Contract.SQLExecutor`
  (the simplifier, batches, ranges, decimals, scales)
  against the real server of the `:v3_core` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core,
    part: :folding
end
