defmodule InfluxElixir.Integration.TokensV3CoreAuthTest do
  @moduledoc """
  Token contract tests against real InfluxDB 3 Core started with
  authentication on port 8183 (token endpoints are disabled on the
  `--without-auth` server the shared contract uses). The same assertions
  run against `Client.Local` in the Local contract modules.

  Run with: `mix test test/integration/tokens_v3_core_auth_test.exs
  --include v3_core_auth --include integration` against a fresh
  `influxdb3 serve` without `--without-auth`, or set `INFLUX_V3_AUTH_TOKEN`.
  """

  # async: false — token ids are compared with each other (`next == id + 1`), so no other
  # module may create a token on this server meanwhile.
  use ExUnit.Case, async: false

  @moduletag :v3_core_auth
  @moduletag :integration

  use InfluxElixir.TokenContract, client: InfluxElixir.Client.HTTP, profile: :v3_core

  alias InfluxElixir.IntegrationHelper, as: H

  setup_all do
    finch = Module.concat(__MODULE__, Finch)
    start_supervised!({Finch, name: finch, pools: %{default: [size: 5]}})

    case H.v3_core_auth_conn(finch_name: finch) do
      {:ok, conn} -> {:ok, conn: conn, shared: true}
      {:error, reason} -> {:ok, unavailable: reason}
    end
  end

  setup ctx do
    if reason = ctx[:unavailable] do
      flunk("No operator token for InfluxDB 3 Core on port 8183: #{inspect(reason)}")
    end

    :ok
  end
end
