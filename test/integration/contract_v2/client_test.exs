defmodule InfluxElixir.Integration.ContractV2.ClientTest do
  @moduledoc """
  The `InfluxElixir.ClientContract` contract
  against the real server of the `:v2` profile.

  The same assertions run against `Client.Local` in
  `test/influx_elixir/client/contract_local`. Run with `mix test --include v2`.
  """

  use InfluxElixir.ContractServer, profile: :v2
  use InfluxElixir.ClientContract, client: InfluxElixir.Client.HTTP, profile: :v2
end
