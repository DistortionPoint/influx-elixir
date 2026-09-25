defmodule InfluxElixir.Query.SQLTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Query.SQL

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    Local.write(conn, "cpu,host=web01 value=1i", database: "test_db")
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  describe "query/3" do
    test "returns the stored rows", %{conn: conn} do
      assert {:ok, [%{"host" => "web01", "value" => 1}]} =
               SQL.query(conn, "SELECT * FROM cpu", database: "test_db")
    end

    test "params reach the client and bind the placeholder", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "cpu,host=web02 value=2i", database: "test_db")

      assert {:ok, [%{"host" => "web02", "value" => 2}]} =
               SQL.query(conn, "SELECT * FROM cpu WHERE host = $host",
                 database: "test_db",
                 params: %{host: "web02"}
               )
    end

    test "returns error for non-existent measurement", %{conn: conn} do
      assert {:error,
              %{status: 400, body: "Error during planning: table 'public.iox.nope' not found"}} =
               SQL.query(conn, "SELECT * FROM nope", database: "test_db")
    end
  end

  describe "query_stream/3" do
    test "returns an enumerable with opts", %{conn: conn} do
      stream = SQL.query_stream(conn, "SELECT * FROM cpu", database: "test_db")
      assert Enumerable.impl_for(stream)
    end

    test "streams actual rows", %{conn: conn} do
      stream = SQL.query_stream(conn, "SELECT * FROM cpu", database: "test_db")
      rows = Enum.to_list(stream)
      assert length(rows) == 1
    end
  end

  describe "connection-level default database" do
    test "query/2, query_stream/2 and execute/2 use it" do
      {:ok, conn} = Local.start(database: "dflt_db")
      on_exit(fn -> Local.stop(conn) end)
      {:ok, :written} = Local.write(conn, "cpu value=7i")

      assert {:ok, [%{"value" => 7}]} = SQL.query(conn, "SELECT * FROM cpu")
      assert [%{"value" => 7}] = conn |> SQL.query_stream("SELECT * FROM cpu") |> Enum.to_list()
      assert {:ok, [%{"value" => 7}]} = SQL.execute(conn, "SELECT * FROM cpu")
    end
  end

  describe "execute/3" do
    test "DELETE on v3_core is the engine's planning error", %{conn: conn} do
      assert {:error, %{status: 400, body: "Error during planning: DML not supported: Delete"}} =
               SQL.execute(conn, "DELETE FROM cpu", database: "test_db")
    end

    test "a statement the engine does not implement is its 405", %{conn: conn} do
      assert {:error, %{status: 405, body: body}} =
               SQL.execute(conn, "ALTER TABLE foo ADD COLUMN y INT", database: "test_db")

      assert body ==
               "This feature is not implemented: Unsupported SQL statement: ALTER TABLE foo ADD COLUMN y INT"
    end
  end
end
