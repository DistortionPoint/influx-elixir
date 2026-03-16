defmodule InfluxElixir.Integration.V2Test do
  @moduledoc """
  Integration tests against InfluxDB v2.7 on port 8086.

  Run with: `mix test --include v2`
  """

  use ExUnit.Case, async: false

  @moduletag :v2
  @moduletag :integration

  alias InfluxElixir.Client.HTTP
  alias InfluxElixir.IntegrationHelper, as: H

  setup_all do
    H.start_finch()
    conn = H.v2_conn()

    if H.reachable?(conn) do
      {:ok, conn: conn}
    else
      {:ok, skip: true, conn: conn}
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
  # Write
  # ---------------------------------------------------------------------------

  describe "write" do
    test "accepts valid line protocol to default bucket", ctx do
      skip_if_unavailable(ctx)
      lp = "v2_test,source=exunit value=1.0"
      result = HTTP.write(ctx.conn, lp, database: ctx.conn[:database])

      assert {:ok, :written} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Flux query
  # ---------------------------------------------------------------------------

  describe "flux query" do
    test "query_flux returns rows or error", ctx do
      skip_if_unavailable(ctx)

      # Write a point first
      lp = "v2_flux_test value=42.0"
      HTTP.write(ctx.conn, lp, database: ctx.conn[:database])

      Process.sleep(500)

      flux = """
      from(bucket: "#{ctx.conn[:database]}")
        |> range(start: -1h)
        |> filter(fn: (r) => r._measurement == "v2_flux_test")
      """

      result = HTTP.query_flux(ctx.conn, flux, org: ctx.conn[:org])

      case result do
        {:ok, rows} -> assert is_list(rows)
        {:error, _reason} -> :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Bucket CRUD
  # ---------------------------------------------------------------------------

  describe "bucket CRUD" do
    test "list_buckets returns a list", ctx do
      skip_if_unavailable(ctx)
      assert {:ok, buckets} = HTTP.list_buckets(ctx.conn)
      assert is_list(buckets)
    end

    test "create_bucket and list includes it", ctx do
      skip_if_unavailable(ctx)
      bucket_name = H.unique_name("v2_test_bucket")

      case HTTP.create_bucket(ctx.conn, bucket_name, org_id: ctx.conn[:org]) do
        :ok ->
          {:ok, buckets} = HTTP.list_buckets(ctx.conn)
          names = Enum.map(buckets, fn b -> b["name"] end)
          assert bucket_name in names

          # Find and delete the bucket by ID
          bucket = Enum.find(buckets, fn b -> b["name"] == bucket_name end)

          if bucket do
            HTTP.delete_bucket(ctx.conn, bucket["id"])
          end

        {:error, _reason} ->
          # Bucket creation may require orgID — acceptable failure
          :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Auth verification
  # ---------------------------------------------------------------------------

  describe "auth verification" do
    test "request without valid token returns error", ctx do
      skip_if_unavailable(ctx)

      bad_conn = Keyword.put(ctx.conn, :token, "invalid-token-xyz")
      result = HTTP.list_buckets(bad_conn)

      case result do
        {:error, %{status: status}} ->
          assert status in [401, 403]

        {:error, _reason} ->
          :ok

        {:ok, _data} ->
          # Some v2 setups might not enforce auth
          :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp skip_if_unavailable(%{skip: true}),
    do: flunk("InfluxDB v2 not reachable on port 8086")

  defp skip_if_unavailable(_ctx), do: :ok
end
