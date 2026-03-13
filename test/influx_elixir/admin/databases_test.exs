defmodule InfluxElixir.Admin.DatabasesTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Admin.Databases
  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  describe "create/3" do
    test "returns :ok on success", %{conn: conn} do
      assert :ok = Databases.create(conn, "new_db")
    end

    test "accepts optional opts", %{conn: conn} do
      assert :ok = Databases.create(conn, "new_db", retention_period: 86_400)
    end

    test "defaults opts to empty list", %{conn: conn} do
      assert :ok = Databases.create(conn, "another_db")
    end
  end

  describe "list/1" do
    test "returns {:ok, list} from client", %{conn: conn} do
      assert {:ok, dbs} = Databases.list(conn)
      assert is_list(dbs)
    end
  end

  describe "delete/2" do
    test "returns :ok on success", %{conn: conn} do
      assert :ok = Databases.delete(conn, "test_db")
    end
  end
end
