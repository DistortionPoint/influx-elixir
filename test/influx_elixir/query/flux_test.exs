defmodule InfluxElixir.Query.FluxTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Query.Flux

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"], profile: :v2)
    {:ok, conn: conn}
  end

  # The rows with the columns the clock assigns removed, so that the rest is
  # compared whole.
  defp without({:ok, rows}, columns), do: {:ok, Enum.map(rows, &Map.drop(&1, columns))}

  describe "query/3" do
    test "returns the rows in the bucket's range", %{conn: conn} do
      :ok = Local.create_bucket(conn, "test")
      {:ok, :written} = Local.write(conn, "cpu value=1.0", database: "test")

      flux_query =
        "from(bucket: \"test\") |> range(start: -1h)"

      # `_start`, `_stop` and `_time` are the clock's.
      assert conn |> Flux.query(flux_query) |> without(["_start", "_stop", "_time"]) ===
               {:ok,
                [
                  %{
                    "result" => "_result",
                    "table" => 0,
                    "_measurement" => "cpu",
                    "_field" => "value",
                    "_value" => 1.0
                  }
                ]}
    end
  end
end
