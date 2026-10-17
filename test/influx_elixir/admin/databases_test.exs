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
      # Local keeps the retention in whole seconds; SHOW RETENTION POLICIES prints 30 days
      # (720 hours) as the engine does.
      assert :ok = Databases.create(conn, "kept", retention: "30d")

      assert Databases.list(conn) ===
               {:ok, [%{"name" => "_internal"}, %{"name" => "kept"}, %{"name" => "test_db"}]}

      assert Local.query_influxql(conn, "SHOW RETENTION POLICIES", database: "kept") ===
               {:ok,
                [%{"iox::database" => "kept", "name" => "autogen", "duration" => "720h0m0s"}]}
    end

    test "an unreadable retention duration is the engine's 400 and creates nothing", %{conn: conn} do
      assert Databases.create(conn, "never", retention: "soon") ===
               {:error,
                %{
                  status: 400,
                  body:
                    ~s|serde json error: invalid value: string "soon", expected a duration | <>
                      "at line 1 column 39"
                }}

      assert Databases.list(conn) === {:ok, [%{"name" => "_internal"}, %{"name" => "test_db"}]}
    end
  end

  describe "delete/2" do
    test "removes the database; deleting it again is the engine's 404", %{conn: conn} do
      assert Databases.delete(conn, "test_db") === :ok
      assert Databases.list(conn) === {:ok, [%{"name" => "_internal"}]}

      assert Databases.delete(conn, "test_db") ===
               {:error, %{status: 404, body: "the requested resource was not found: test_db"}}
    end
  end
end
