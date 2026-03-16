defmodule InfluxElixir.Integration.ContractV3EnterpriseTest do
  @moduledoc """
  Contract tests against real InfluxDB v3 Enterprise on port 8182.

  Run with: `mix test --include v3_enterprise`

  These are the SAME assertions that run against LocalClient in
  `ContractLocalV3EnterpriseTest`. If both pass, LocalClient is proven
  faithful to real InfluxDB v3 Enterprise.
  """

  use ExUnit.Case, async: false

  @moduletag :v3_enterprise
  @moduletag :integration

  use InfluxElixir.ClientContract,
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
        {:ok, conn: base_conn, database: db, query_delay: 500}

      {:error, reason} ->
        flunk("Failed to create test database: #{inspect(reason)}")
    end
  end
end
