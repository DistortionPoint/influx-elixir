defmodule InfluxElixir.TestHelperTest do
  use ExUnit.Case, async: true

  import InfluxElixir.TestHelper

  # The helper is used exactly as a consumer would use it.
  setup do
    setup_influx(databases: ["helper_db"], database: "helper_db")
  end

  describe "setup_influx/1" do
    test "returns a working connection with the requested databases", %{conn: conn} do
      assert InfluxElixir.write(conn, "cpu value=1.0 1") === {:ok, :written}

      assert InfluxElixir.query_sql(conn, "SELECT * FROM cpu") ===
               {:ok, [%{"time" => ~U[1970-01-01 00:00:00.000000Z], "value" => 1.0}]}
    end

    test "each setup gets its own isolated instance", %{conn: conn} do
      assert InfluxElixir.write(conn, "cpu value=1.0 1") === {:ok, :written}

      {:ok, conn: other} = setup_influx(databases: ["helper_db"], database: "helper_db")

      assert InfluxElixir.query_sql(other, "SELECT * FROM cpu") ===
               {:error,
                %{status: 400, body: "Error during planning: table 'public.iox.cpu' not found"}}

      assert InfluxElixir.query_sql(conn, "SELECT * FROM cpu") ===
               {:ok, [%{"time" => ~U[1970-01-01 00:00:00.000000Z], "value" => 1.0}]}
    end

    test "without options starts a v3 Core instance with no database" do
      {:ok, conn: bare} = setup_influx()

      assert InfluxElixir.list_databases(bare) === {:ok, [%{"name" => "_internal"}]}
    end

    test "passes :profile through" do
      {:ok, conn: v2} = setup_influx(profile: :v2, databases: ["b"])

      assert InfluxElixir.query_sql(v2, "SELECT 1") === {:error, :unsupported_operation}
      assert InfluxElixir.write(v2, "m v=1i 1000000000", database: "b") === {:ok, :written}

      flux =
        ~s|from(bucket: "b") \|> range(start: 1970-01-01T00:00:00Z, stop: 1970-01-01T00:00:02Z)|

      assert InfluxElixir.query_flux(v2, flux) ===
               {:ok,
                [
                  %{
                    "_field" => "v",
                    "_measurement" => "m",
                    "_start" => ~U[1970-01-01 00:00:00.000000Z],
                    "_stop" => ~U[1970-01-01 00:00:02.000000Z],
                    "_time" => ~U[1970-01-01 00:00:01.000000Z],
                    "_value" => 1,
                    "result" => "_result",
                    "table" => 0
                  }
                ]}
    end

    test "raises the ArgumentError Client.Local.start/1 raises for options it refuses" do
      assert_raise ArgumentError,
                   "invalid profile: :bogus. Must be one of: :v3_core, :v3_enterprise, :v2",
                   fn -> setup_influx(profile: :bogus) end
    end
  end
end
