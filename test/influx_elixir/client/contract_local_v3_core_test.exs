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

  use InfluxElixir.TokenContract, client: InfluxElixir.Client.Local, profile: :v3_core

  use InfluxElixir.Contract.SQLParser, client: InfluxElixir.Client.Local, profile: :v3_core

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.Local,
    profile: :v3_core

  use InfluxElixir.Contract.InfluxQLFluxLP,
    client: InfluxElixir.Client.Local,
    profile: :v3_core

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} =
      Local.start(databases: ["contract_db"], profile: :v3_core)

    {:ok, conn: conn, database: "contract_db", query_delay: 0}
  end
end
