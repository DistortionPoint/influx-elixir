defmodule InfluxElixir.Integration.ContractV2Test do
  @moduledoc """
  Contract tests against real InfluxDB v2.7 on port 8086.

  Run with: `mix test --include v2`

  These are the SAME assertions that run against LocalClient in
  `ContractLocalV2Test`. If both pass, LocalClient is proven
  faithful to real InfluxDB v2.
  """

  use ExUnit.Case, async: false

  @moduletag :v2
  @moduletag :integration

  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.HTTP,
    profile: :v2

  alias InfluxElixir.Client.HTTP
  alias InfluxElixir.IntegrationHelper, as: H

  setup_all do
    H.start_finch()
    conn = H.v2_conn()

    if H.reachable?(conn) do
      {:ok, base_conn: conn}
    else
      {:ok, skip: true, base_conn: conn}
    end
  end

  setup %{base_conn: base_conn} = ctx do
    if ctx[:skip] do
      flunk("InfluxDB v2 not reachable on port 8086")
    end

    {:ok, conn: base_conn, database: base_conn[:database], query_delay: 500}
  end

  # Bucket names are per org. The name lookup behind `delete_bucket/2`
  # spanned every org the token can read, and deleted another org's bucket
  # of the same name (verified). Orgs exist only on the server, so this is
  # outside the shared contract.
  describe "bucket names are scoped to the connection's org" do
    test "delete_bucket leaves another org's bucket of the same name", ctx do
      suffix = System.unique_integer([:positive])
      name = "shared_#{suffix}"
      other_org = api(ctx.conn, :post, "/api/v2/orgs", %{"name" => "other_org_#{suffix}"})

      other =
        api(ctx.conn, :post, "/api/v2/buckets", %{"name" => name, "orgID" => other_org["id"]})

      on_exit(fn -> api(ctx.conn, :delete, "/api/v2/orgs/#{other_org["id"]}", nil) end)

      :ok = HTTP.create_bucket(ctx.conn, name, [])

      {:ok, listed} = HTTP.list_buckets(ctx.conn)
      refute Enum.any?(listed, &(&1["id"] == other["id"]))

      assert :ok = HTTP.delete_bucket(ctx.conn, name)
      assert %{"name" => ^name} = api(ctx.conn, :get, "/api/v2/buckets/#{other["id"]}", nil)
    end
  end

  # A raw v2 API call for what the client does not expose (orgs).
  defp api(conn, method, path, body) do
    request =
      Finch.build(
        method,
        "http://#{conn[:host]}:#{conn[:port]}#{path}",
        [{"authorization", "Token #{conn[:token]}"}, {"content-type", "application/json"}],
        body && Jason.encode!(body)
      )

    {:ok, %Finch.Response{status: status, body: resp}} = Finch.request(request, conn[:finch_name])
    assert status in 200..299, resp
    if resp == "", do: nil, else: Jason.decode!(resp)
  end
end
