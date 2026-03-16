defmodule InfluxElixir.Client.ContractLocalV3CoreTest do
  @moduledoc """
  Contract tests for LocalClient with `:v3_core` profile.

  Proves LocalClient behaves identically to real InfluxDB v3 Core
  for all v3_core-supported operations.
  """

  use ExUnit.Case, async: true

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v3_core

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} =
      Local.start(databases: ["contract_db"], profile: :v3_core)

    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn, database: "contract_db", query_delay: 0}
  end
end
