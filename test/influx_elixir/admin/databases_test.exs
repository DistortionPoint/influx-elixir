defmodule InfluxElixir.Admin.DatabasesTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Admin.Databases
  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  describe "create/3 and list/1" do
    test "a created database is listed; creating it again is a no-op", %{conn: conn} do
      assert :ok = Databases.create(conn, "new_db")
      assert :ok = Databases.create(conn, "new_db")

      assert {:ok, dbs} = Databases.list(conn)
      assert "new_db" in Enum.map(dbs, & &1["name"])
    end

    test "accepts a retention duration string", %{conn: conn} do
      assert :ok = Databases.create(conn, "kept", retention: "30d")
      assert {:ok, dbs} = Databases.list(conn)
      assert %{"name" => "kept"} in dbs
    end
  end

  describe "delete/2" do
    test "removes the database; deleting it again is the engine's 404", %{conn: conn} do
      assert :ok = Databases.delete(conn, "test_db")
      assert {:ok, dbs} = Databases.list(conn)
      refute %{"name" => "test_db"} in dbs

      assert {:error, %{status: 404, body: "the requested resource was not found: test_db"}} =
               Databases.delete(conn, "test_db")
    end
  end
end
