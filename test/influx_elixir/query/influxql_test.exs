defmodule InfluxElixir.Query.InfluxQLTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Query.InfluxQL

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    Local.write(conn, "cpu,host=web01 value=1i", database: "test_db")
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  describe "query/3" do
    test "returns {:ok, rows} from client", %{conn: conn} do
      assert {:ok, rows} =
               InfluxQL.query(conn, "SELECT * FROM cpu", database: "test_db")

      assert is_list(rows)
    end

    test "SHOW DATABASES works without database option", %{conn: conn} do
      assert {:ok, dbs} = InfluxQL.query(conn, "SHOW DATABASES")
      names = Enum.map(dbs, & &1["iox::database"])
      assert "test_db" in names
    end

    test "SHOW MEASUREMENTS requires database option", %{conn: conn} do
      assert {:ok, measurements} =
               InfluxQL.query(conn, "SHOW MEASUREMENTS", database: "test_db")

      names = Enum.map(measurements, & &1["name"])
      assert "cpu" in names
    end
  end
end
