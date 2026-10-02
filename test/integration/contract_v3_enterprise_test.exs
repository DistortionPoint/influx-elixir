defmodule InfluxElixir.Integration.ContractV3EnterpriseTest do
  @moduledoc """
  Contract tests against real InfluxDB v3 Enterprise on port 8182.

  Run with: `mix test --include v3_enterprise`

  These are the SAME assertions that run against LocalClient in
  `ContractLocalV3EnterpriseTest`. If both pass, LocalClient is proven
  faithful to real InfluxDB v3 Enterprise.

  **Enterprise is unverified**: no licensed InfluxDB 3 Enterprise server is
  available, so this module has never run against one. Its expectations are
  those proven on Core plus what the documentation says of Enterprise (for
  example `DELETE FROM`); treat a failure here as either a finding or a wrong
  expectation. The token contract is not run here for the same reason.

  What runs: the shared client contract and the SQL parser and executor
  contracts.
  `InfluxElixir.Contract.InfluxQLFluxLP` does not: it generates tests for
  `:v3_core` and `:v2` only, so for `:v3_enterprise` it would run nothing.
  The `time_slack` of the context is how far, in seconds, the server's clock
  may be from this one.
  """

  # async: false — shares the one real server and the globally named :integration_finch
  # pool with the other integration modules, and its writes are timed against its clock.
  use ExUnit.Case, async: false

  @moduletag :v3_enterprise
  @moduletag :integration

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise

  use InfluxElixir.Contract.SQLParser,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise

  use InfluxElixir.Contract.SQLExecutor,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_enterprise

  alias InfluxElixir.Client.HTTP
  alias InfluxElixir.IntegrationHelper, as: H

  setup_all do
    H.start_finch()
    conn = H.v3_enterprise_conn()

    if H.reachable?(conn) do
      {:ok, base_conn: conn}
    else
      {:ok, skip: true, base_conn: conn}
    end
  end

  setup %{base_conn: base_conn} = ctx do
    if ctx[:skip] do
      flunk("InfluxDB v3 Enterprise not reachable on port 8182")
    end

    db = H.unique_name("contract_v3ent")

    case HTTP.create_database(base_conn, db) do
      :ok ->
        on_exit(fn -> HTTP.delete_database(base_conn, db) end)
        {:ok, conn: base_conn, database: db, query_delay: 500, time_slack: 60}

      {:error, reason} ->
        flunk("Failed to create test database: #{inspect(reason)}")
    end
  end
end
