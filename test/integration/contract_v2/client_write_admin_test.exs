defmodule InfluxElixir.Integration.ContractV2.ClientWriteAdminTest do
  @moduledoc """
  The `:write_admin` part of `InfluxElixir.ClientContract`
  (health, writes, line protocol, timestamp range)
  against the real server of the `:v2` profile.
  Run with `mix test --include integration --include v2`.
  """

  use InfluxElixir.ContractServer, profile: :v2

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.HTTP,
    profile: :v2,
    part: :write_admin
end
