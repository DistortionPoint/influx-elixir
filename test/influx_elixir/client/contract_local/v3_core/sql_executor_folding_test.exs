defmodule InfluxElixir.ContractLocal.V3Core.SqlExecutorFoldingTest do
  @moduledoc """
  The `:folding` part of `InfluxElixir.Contract.SQLExecutor`
  (the simplifier, batches, ranges, decimals, scales)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :folding
end
