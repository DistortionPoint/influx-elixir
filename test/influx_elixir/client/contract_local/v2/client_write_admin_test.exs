defmodule InfluxElixir.ContractLocal.V2.ClientWriteAdminTest do
  @moduledoc """
  The `:write_admin` part of `InfluxElixir.ClientContract`
  (health, writes, line protocol, timestamp range)
  against `Client.Local` with the `:v2` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v2

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v2,
    part: :write_admin
end
