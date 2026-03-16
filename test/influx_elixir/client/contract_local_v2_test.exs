defmodule InfluxElixir.Client.ContractLocalV2Test do
  @moduledoc """
  Contract tests for LocalClient with `:v2` profile.

  Proves LocalClient behaves identically to real InfluxDB v2
  for all v2-supported operations (write, flux, buckets).
  """

  use ExUnit.Case, async: true

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v2

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} =
      Local.start(databases: ["contract_db"], profile: :v2)

    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn, database: "contract_db", query_delay: 0}
  end
end
