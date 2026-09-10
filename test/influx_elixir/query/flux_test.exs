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
    test "returns the rows in the bucket's range", %{conn: conn} do
      :ok = Local.create_bucket(conn, "test")
      {:ok, :written} = Local.write(conn, "cpu value=1.0", database: "test")

      flux_query =
        "from(bucket: \"test\") |> range(start: -1h)"

      assert {:ok, [%{"_measurement" => "cpu", "_field" => "value", "_value" => 1.0}]} =
               Flux.query(conn, flux_query)
    end
  end
end
