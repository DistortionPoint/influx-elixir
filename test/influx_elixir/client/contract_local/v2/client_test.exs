defmodule InfluxElixir.ContractLocal.V2.ClientTest do
  @moduledoc """
  The `InfluxElixir.ClientContract` contract
  against `Client.Local` with the `:v2` profile.

  The same assertions run against the real server in `test/integration`.
  """

  use InfluxElixir.ContractLocal, profile: :v2
  use InfluxElixir.ClientContract, client: InfluxElixir.Client.Local, profile: :v2
end
