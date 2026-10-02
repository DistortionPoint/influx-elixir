defmodule InfluxElixir.Query.FluxTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Query.Flux

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"], profile: :v2)
    {:ok, conn: conn}
  end

  describe "query/3" do
    test "returns the rows in the bucket's range", %{conn: conn} do
      :ok = Local.create_bucket(conn, "test")
      {:ok, :written} = Local.write(conn, "cpu value=1.0 1700000000000000000", database: "test")

      flux_query = "from(bucket: \"test\") |> range(start: 0, stop: 1700000001)"

      assert Flux.query(conn, flux_query) ===
               {:ok,
                [
                  %{
                    "result" => "_result",
                    "table" => 0,
                    "_start" => ~U[1970-01-01 00:00:00.000000Z],
                    "_stop" => ~U[2023-11-14 22:13:21.000000Z],
                    "_time" => ~U[2023-11-14 22:13:20.000000Z],
                    "_measurement" => "cpu",
                    "_field" => "value",
                    "_value" => 1.0
                  }
                ]}
    end
  end
end
