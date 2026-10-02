defmodule InfluxElixir.Client.ContractLocalV3EnterpriseTest do
  @moduledoc """
  Contract tests for LocalClient with `:v3_enterprise` profile.

  Proves LocalClient behaves identically to real InfluxDB v3 Enterprise
  for all v3_enterprise-supported operations (v3_core + tokens). Runs the
  shared client contract, the token contract and the SQL parser and
  executor contracts.

  `InfluxElixir.Contract.InfluxQLFluxLP` is not used here: it generates its
  tests for `:v3_core` and `:v2` only and nothing for `:v3_enterprise`, so
  `use`-ing it would run no test. The InfluxQL it covers is exercised for
  Enterprise by the shared client contract. Within the SQL executor contract
  the unknown-format wording test is gated to `:v3_core` for the same reason:
  it was read from a Core only.
  """

  use ExUnit.Case, async: true

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise

  use InfluxElixir.TokenContract, client: InfluxElixir.Client.Local, profile: :v3_enterprise

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.Local,
    profile: :v3_enterprise

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} =
      Local.start(databases: ["contract_db"], profile: :v3_enterprise)

    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn, database: "contract_db", query_delay: 0}
  end
end
