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
      assert {:ok, :written} = InfluxElixir.write(conn, "cpu value=1.0")
      assert {:ok, [%{"value" => 1.0}]} = InfluxElixir.query_sql(conn, "SELECT * FROM cpu")
    end

    test "each test gets its own isolated instance", %{conn: conn} do
      # Nothing written by the previous test is visible here.
      assert {:error, %{status: 400}} = InfluxElixir.query_sql(conn, "SELECT * FROM cpu")
    end

    test "passes :profile through" do
      {:ok, conn: v2} = setup_influx(profile: :v2)
      assert {:error, :unsupported_operation} = Local.query_sql(v2, "SELECT 1")
    end
  end
end
