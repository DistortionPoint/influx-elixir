defmodule InfluxElixir.Query.SQLTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Query.SQL

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  describe "query/3" do
    test "returns {:ok, rows} from client", %{conn: conn} do
      assert {:ok, rows} = SQL.query(conn, "SELECT * FROM cpu")
      assert is_list(rows)
    end

    test "passes opts through to client", %{conn: conn} do
      assert {:ok, _rows} =
               SQL.query(conn, "SELECT * FROM cpu",
                 params: %{symbol: "BTC"},
                 format: :json
               )
    end
  end

  describe "query_stream/3" do
    test "returns an enumerable", %{conn: conn} do
      stream = SQL.query_stream(conn, "SELECT * FROM cpu")
      assert Enumerable.impl_for(stream)
    end
  end

  describe "execute/3" do
    test "returns {:ok, result}", %{conn: conn} do
      assert {:ok, result} =
               SQL.execute(conn, "DELETE FROM cpu")

      assert is_map(result)
    end
  end
end
