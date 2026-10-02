defmodule InfluxElixir.ContractLocal.V3Core.TokensTest do
  @moduledoc """
  The `InfluxElixir.TokenContract` contract
  against `Client.Local` with the `:v3_core` profile.

  The same assertions run against the real server in `test/integration`.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core
  use InfluxElixir.TokenContract, client: InfluxElixir.Client.Local, profile: :v3_core
end
