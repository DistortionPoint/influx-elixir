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

  # Arrow Flight is HTTP-client only (Local is in-memory), so it lives
  # outside the shared contract. InfluxDB 3 Core serves Flight gRPC on the
  # same port as HTTP, without TLS.
  describe "query_sql/3 with transport: :flight" do
    test "returns the same rows as the HTTP transport", ctx do
      {:ok, :written} =
        HTTP.write(
          ctx.conn,
          "flight_probe,host=a value=1.5,count=2i 1700000000000000000",
          database: ctx.database
        )

      Process.sleep(ctx.query_delay)
      sql = "SELECT host, value, count FROM flight_probe"

      assert {:ok, [http_row]} = HTTP.query_sql(ctx.conn, sql, database: ctx.database)

      assert {:ok, [flight_row]} =
               HTTP.query_sql(ctx.conn, sql,
                 database: ctx.database,
                 transport: :flight,
                 flight_port: ctx.conn[:port],
                 tls: false
               )

      assert flight_row == http_row
      assert %{"host" => "a", "value" => 1.5, "count" => 2} = flight_row
    end

    test "rejects params over Flight instead of dropping them", ctx do
      assert {:error, :params_unsupported_over_flight} =
               HTTP.query_sql(ctx.conn, "SELECT 1",
                 database: ctx.database,
                 transport: :flight,
                 params: %{x: 1}
               )
    end
  end
end
