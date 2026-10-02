defmodule InfluxElixir.ContractLocal.V3Core.ClientWriteAdminTest do
  @moduledoc """
  The `:write_admin` part of `InfluxElixir.ClientContract`
  (health, writes, line protocol, precision, databases)
  against `Client.Local` with the `:v3_core` profile.
  """

  use InfluxElixir.ContractLocal, profile: :v3_core

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v3_core,
    part: :write_admin
end
