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
end
