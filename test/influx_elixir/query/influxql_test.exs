defmodule InfluxElixir.Query.InfluxQLTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Query.InfluxQL

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])

    {:ok, :written} =
      Local.write(conn, "cpu,host=web01 value=1i 1700000000000000000", database: "test_db")

    {:ok, conn: conn}
  end

  describe "query/3" do
    test "returns {:ok, rows} from client", %{conn: conn} do
      assert InfluxQL.query(conn, "SELECT * FROM cpu", database: "test_db") ===
               {:ok,
                [
                  %{
                    "iox::measurement" => "cpu",
                    "time" => ~U[2023-11-14 22:13:20.000000Z],
                    "host" => "web01",
                    "value" => 1
                  }
                ]}
    end

    test "SHOW DATABASES needs no database option", %{conn: conn} do
      assert InfluxQL.query(conn, "SHOW DATABASES") ===
               {:ok,
                [
                  %{"iox::database" => "_internal", "deleted" => false},
                  %{"iox::database" => "test_db", "deleted" => false}
                ]}
    end

    test "SHOW MEASUREMENTS lists the measurements of the database option", %{conn: conn} do
      assert InfluxQL.query(conn, "SHOW MEASUREMENTS", database: "test_db") ===
               {:ok, [%{"iox::measurement" => "measurements", "name" => "cpu"}]}
    end
  end
end
