defmodule InfluxElixir.ContractLocal.V3Enterprise.TokensTest do
  @moduledoc """
  The `InfluxElixir.TokenContract` contract
  against `Client.Local` with the `:v3_enterprise` profile.

  The same assertions run against the real server in `test/integration`.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise
  use InfluxElixir.TokenContract, client: InfluxElixir.Client.Local, profile: :v3_enterprise
end
