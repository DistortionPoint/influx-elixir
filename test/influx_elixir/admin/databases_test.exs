defmodule InfluxElixir.Admin.DatabasesTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Admin.Databases
  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    {:ok, conn: conn}
  end

  describe "create/3 and list/1" do
    test "a created database is listed; creating it again is a no-op", %{conn: conn} do
      assert :ok = Databases.create(conn, "new_db")
      assert :ok = Databases.create(conn, "new_db")

      assert Databases.list(conn) ===
               {:ok, [%{"name" => "_internal"}, %{"name" => "new_db"}, %{"name" => "test_db"}]}
    end

    test "a valid retention duration is accepted and the database is created", %{conn: conn} do
      # Local validates the duration but keeps no retention, so none is observable.
      assert :ok = Databases.create(conn, "kept", retention: "30d")

      assert Databases.list(conn) ===
               {:ok, [%{"name" => "_internal"}, %{"name" => "kept"}, %{"name" => "test_db"}]}
    end

    test "an unreadable retention duration is the engine's 400 and creates nothing", %{conn: conn} do
      assert {:error,
              %{
                status: 400,
                body:
                  ~s|serde json error: invalid value: string "soon", expected a duration | <>
                    "at line 1 column 39"
              }} =
               Databases.create(conn, "never", retention: "soon")

      assert Databases.list(conn) === {:ok, [%{"name" => "_internal"}, %{"name" => "test_db"}]}
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
