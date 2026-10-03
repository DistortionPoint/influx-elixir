defmodule InfluxElixir.TestHelperTest do
  use ExUnit.Case, async: true

  import InfluxElixir.TestHelper

  alias InfluxElixir.Client.Local

  # The helper is used exactly as a consumer would use it.
  setup do
    setup_influx(databases: ["helper_db"], database: "helper_db")
  end

  describe "setup_influx/1" do
    test "returns a working connection with the requested databases", %{conn: conn} do
      assert {:ok, :written} = InfluxElixir.write(conn, "cpu value=1.0 1")

      assert InfluxElixir.query_sql(conn, "SELECT * FROM cpu") ===
               {:ok, [%{"time" => ~U[1970-01-01 00:00:00.000000Z], "value" => 1.0}]}
    end

    test "each setup gets its own isolated instance", %{conn: conn} do
      {:ok, :written} = InfluxElixir.write(conn, "cpu value=1.0 1")

      {:ok, conn: other} = setup_influx(databases: ["helper_db"], database: "helper_db")

      assert {:error, %{status: 400, body: "Error during planning: table " <> _rest}} =
               InfluxElixir.query_sql(other, "SELECT * FROM cpu")

      assert InfluxElixir.query_sql(conn, "SELECT * FROM cpu") ===
               {:ok, [%{"time" => ~U[1970-01-01 00:00:00.000000Z], "value" => 1.0}]}
    end

    test "without options starts a v3 Core instance with no database" do
      {:ok, conn: bare} = setup_influx()

      assert InfluxElixir.list_databases(bare) === {:ok, [%{"name" => "_internal"}]}
    end

    test "passes :profile through" do
      {:ok, conn: v2} = setup_influx(profile: :v2)
      assert {:error, :unsupported_operation} = Local.query_sql(v2, "SELECT 1")
    end
  end
end
