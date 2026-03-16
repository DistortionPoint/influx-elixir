defmodule InfluxElixir.Query.FluxTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Query.Flux

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"], profile: :v2)
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  describe "query/3" do
    test "returns {:ok, rows} from client", %{conn: conn} do
      flux_query =
        "from(bucket: \"test\") |> range(start: -1h)"

      assert {:ok, rows} = Flux.query(conn, flux_query)
      assert is_list(rows)
    end
  end
end
