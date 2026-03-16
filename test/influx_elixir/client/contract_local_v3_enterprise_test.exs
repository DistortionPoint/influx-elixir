defmodule InfluxElixir.Client.ContractLocalV3EnterpriseTest do
  @moduledoc """
  Contract tests for LocalClient with `:v3_enterprise` profile.

  Proves LocalClient behaves identically to real InfluxDB v3 Enterprise
  for all v3_enterprise-supported operations (v3_core + tokens).
  """

  use ExUnit.Case, async: true

  use InfluxElixir.ClientContract,
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
