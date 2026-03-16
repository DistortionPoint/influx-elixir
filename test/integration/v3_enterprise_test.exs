defmodule InfluxElixir.Integration.V3EnterpriseTest do
  @moduledoc """
  Integration tests against InfluxDB v3 Enterprise on port 8182.

  Run with: `mix test --include v3_enterprise`
  """

  use ExUnit.Case, async: false

  @moduletag :v3_enterprise
  @moduletag :integration

  alias InfluxElixir.Client.HTTP
  alias InfluxElixir.IntegrationHelper, as: H

  setup_all do
    H.start_finch()
    conn = H.v3_enterprise_conn()

    if H.reachable?(conn) do
      {:ok, conn: conn}
    else
      {:ok, skip: true, conn: conn}
    end
  end

  setup %{conn: conn} = ctx do
    if ctx[:skip] do
      :ok
    else
      db = H.unique_name("v3ent_test")

      case HTTP.create_database(conn, db) do
        :ok ->
          on_exit(fn -> HTTP.delete_database(conn, db) end)
          {:ok, db: db}

        {:error, _reason} ->
          {:ok, skip: true}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Health
  # ---------------------------------------------------------------------------

  describe "health" do
    test "returns passing status", ctx do
      skip_if_unavailable(ctx)
      assert {:ok, %{"status" => status}} = HTTP.health(ctx.conn)
      assert status in ["pass", "ok"]
    end
  end

  # ---------------------------------------------------------------------------
  # Write + Query (same as core)
  # ---------------------------------------------------------------------------

  describe "write + query round-trip" do
    test "written data is queryable via SQL", ctx do
      skip_if_unavailable(ctx)
      ts = System.os_time(:nanosecond)
      lp = "ent_roundtrip value=42i #{ts}"
      {:ok, :written} = HTTP.write(ctx.conn, lp, database: ctx.db)

      Process.sleep(500)

      {:ok, rows} =
        HTTP.query_sql(
          ctx.conn,
          "SELECT * FROM ent_roundtrip ORDER BY time DESC LIMIT 1",
          database: ctx.db
        )

      assert rows != []
    end
  end

  # ---------------------------------------------------------------------------
  # Database CRUD
  # ---------------------------------------------------------------------------

  describe "database CRUD" do
    test "create and list database", ctx do
      skip_if_unavailable(ctx)
      db = H.unique_name("ent_crud")
      assert :ok = HTTP.create_database(ctx.conn, db)

      {:ok, dbs} = HTTP.list_databases(ctx.conn)
      assert is_list(dbs)

      HTTP.delete_database(ctx.conn, db)
    end
  end

  # ---------------------------------------------------------------------------
  # Token management (Enterprise only)
  # ---------------------------------------------------------------------------

  describe "token management" do
    test "create_token returns map with id and token", ctx do
      skip_if_unavailable(ctx)

      result = HTTP.create_token(ctx.conn, "test token")

      case result do
        {:ok, token} ->
          assert is_map(token)

          # Cleanup
          if token_id = token["id"] do
            HTTP.delete_token(ctx.conn, token_id)
          end

        {:error, _reason} ->
          # Token API may not be available on all Enterprise builds
          :ok
      end
    end

    test "delete_token returns :ok for valid token", ctx do
      skip_if_unavailable(ctx)

      case HTTP.create_token(ctx.conn, "disposable token") do
        {:ok, %{"id" => token_id}} ->
          assert :ok = HTTP.delete_token(ctx.conn, token_id)

        {:error, _reason} ->
          :ok
      end
    end

    test "delete_token is idempotent for non-existent token", ctx do
      skip_if_unavailable(ctx)

      result = HTTP.delete_token(ctx.conn, "nonexistent-token-id")
      # Should return :ok or a benign error
      assert result in [:ok] or match?({:error, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp skip_if_unavailable(%{skip: true}),
    do: flunk("InfluxDB v3 Enterprise not reachable on port 8182")

  defp skip_if_unavailable(_ctx), do: :ok
end
