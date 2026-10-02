defmodule InfluxElixir.Integration.ContractV3Enterprise.ClientWriteAdminTest do
  @moduledoc """
  The `:write_admin` part of `InfluxElixir.ClientContract`
  (health, writes, line protocol, precision, databases)
  against the real server of the `:v3_enterprise` profile.

  Run with: `mix test --include v3_enterprise`

  **Enterprise is unverified**: no licensed InfluxDB 3 Enterprise server is
  available, so these modules have never run against one. Their expectations are
  those proven on Core plus what the documentation says of Enterprise (for
  example `DELETE FROM`); treat a failure here as either a finding or a wrong
  expectation. The token contract is not run here for the same reason, and
  `InfluxElixir.Contract.InfluxQLFluxLP` does not either: it generates tests for
  `:v3_core` and `:v2` only, so for `:v3_enterprise` it would run nothing.
  """

  use InfluxElixir.ContractServer, profile: :v3_enterprise

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise,
    part: :write_admin
end
