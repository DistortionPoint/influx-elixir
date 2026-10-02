defmodule InfluxElixir.Integration.ContractV3Enterprise.SqlExecutorFoldingTest do
  @moduledoc """
  The `:folding` part of `InfluxElixir.Contract.SQLExecutor`
  (the simplifier, batches, ranges, decimals, scales)
  against the real server of the `:v3_enterprise` profile.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :folding
end
