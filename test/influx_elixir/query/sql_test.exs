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

    test "passes params through to client", %{conn: conn} do
      assert {:ok, _rows} =
               SQL.query(conn, "SELECT * FROM cpu WHERE host = $host",
                 database: "test_db",
                 params: %{host: "web01"}
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

  describe "execute/3" do
    test "returns {:error, _} for DELETE on v3_core", %{conn: conn} do
      assert {:error, :delete_not_supported} =
               SQL.execute(conn, "DELETE FROM cpu", database: "test_db")
    end

    test "returns {:ok, map} for non-SELECT statement", %{conn: conn} do
      assert {:ok, %{"rows_affected" => 0}} =
               SQL.execute(conn, "ALTER TABLE foo", database: "test_db")
    end
  end
end
