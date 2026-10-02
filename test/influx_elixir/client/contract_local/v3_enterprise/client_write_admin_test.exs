defmodule InfluxElixir.ContractLocal.V3Enterprise.ClientWriteAdminTest do
  @moduledoc """
  The `:write_admin` part of `InfluxElixir.ClientContract`
  (health, writes, line protocol, precision, databases)
  against `Client.Local` with the `:v3_enterprise` profile.

  `InfluxElixir.Contract.InfluxQLFluxLP` has no module here: it generates its
  tests for `:v3_core` and `:v2` only and nothing for `:v3_enterprise`, so
  `use`-ing it would run no test. The InfluxQL it covers is exercised for
  Enterprise by the shared client contract. Within the SQL executor contract the
  unknown-format wording test is gated to `:v3_core` for the same reason: it was
  read from a Core only.
  """

  use InfluxElixir.ContractLocal, profile: :v3_enterprise

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise,
    part: :write_admin
end
