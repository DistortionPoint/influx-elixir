defmodule InfluxElixir.ContractLocal.V3Enterprise.SqlExecutorFoldingTest do
  @moduledoc """
  The `:folding` part of `InfluxElixir.Contract.SQLExecutor`
  (the simplifier, batches, ranges, decimals, scales)
  against `Client.Local` with the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :folding
end
