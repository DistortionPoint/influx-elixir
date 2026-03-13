defmodule InfluxElixir.Query.InfluxQLTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Query.InfluxQL

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  describe "query/3" do
    test "returns {:ok, rows} from client", %{conn: conn} do
      assert {:ok, rows} =
               InfluxQL.query(conn, "SELECT * FROM cpu")

      assert is_list(rows)
    end
  end
end
