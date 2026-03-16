defmodule InfluxElixir.Integration.ContractV3CoreTest do
  @moduledoc """
  Contract tests against real InfluxDB v3 Core on port 8181.

  Run with: `mix test --include v3_core`

  These are the SAME assertions that run against LocalClient in
  `ContractLocalV3CoreTest`. If both pass, LocalClient is proven
  faithful to real InfluxDB v3 Core.
  """

  use ExUnit.Case, async: false

  @moduletag :v3_core
  @moduletag :integration

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.HTTP,
    profile: :v3_core

  alias InfluxElixir.Client.HTTP
  alias InfluxElixir.IntegrationHelper, as: H

  setup_all do
    H.start_finch()
    conn = H.v3_core_conn()

    if H.reachable?(conn) do
      {:ok, base_conn: conn}
    else
      {:ok, skip: true, base_conn: conn}
    end
  end

  setup %{base_conn: base_conn} = ctx do
    if ctx[:skip] do
      flunk("InfluxDB v3 Core not reachable on port 8181")
    end

    db = H.unique_name("contract_v3core")

    case HTTP.create_database(base_conn, db) do
      :ok ->
        on_exit(fn -> HTTP.delete_database(base_conn, db) end)
        {:ok, conn: base_conn, database: db, query_delay: 500}

      {:error, reason} ->
        flunk("Failed to create test database: #{inspect(reason)}")
    end
  end
end
