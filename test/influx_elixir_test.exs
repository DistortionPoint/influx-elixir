defmodule InfluxElixirTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  describe "client/0" do
    test "returns the configured client implementation" do
      assert InfluxElixir.client() == InfluxElixir.Client.Local
    end
  end

  describe "point/3" do
    test "constructs a Point struct with defaults" do
      point = InfluxElixir.point("cpu", %{"value" => 0.64})

      assert point.measurement == "cpu"
      assert point.fields == %{"value" => 0.64}
      assert point.tags == %{}
      assert point.timestamp == nil
    end

    test "constructs a Point struct with tags and timestamp" do
      point =
        InfluxElixir.point("cpu", %{"value" => 0.64},
          tags: %{"host" => "server01"},
          timestamp: 1_630_424_257_000_000_000
        )

      assert point.tags == %{"host" => "server01"}
      assert point.timestamp == 1_630_424_257_000_000_000
    end
  end

  describe "write/3" do
    test "delegates to configured client", %{conn: conn} do
      assert {:ok, :written} =
               InfluxElixir.write(conn, "cpu value=1.0")
    end
  end

  describe "query_sql/3" do
    test "delegates to configured client", %{conn: conn} do
      assert {:ok, rows} =
               InfluxElixir.query_sql(conn, "SELECT * FROM cpu")

      assert is_list(rows)
    end
  end

  describe "query_sql_stream/3" do
    test "returns an enumerable", %{conn: conn} do
      stream =
        InfluxElixir.query_sql_stream(conn, "SELECT * FROM cpu")

      assert Enumerable.impl_for(stream)
    end
  end

  describe "execute_sql/3" do
    test "delegates to configured client", %{conn: conn} do
      assert {:ok, result} =
               InfluxElixir.execute_sql(conn, "DELETE FROM cpu")

      assert is_map(result)
    end
  end

  describe "query_influxql/3" do
    test "delegates to configured client", %{conn: conn} do
      assert {:ok, rows} =
               InfluxElixir.query_influxql(conn, "SELECT * FROM cpu")

      assert is_list(rows)
    end
  end

  describe "query_flux/3" do
    test "delegates to configured client", %{conn: conn} do
      assert {:ok, rows} =
               InfluxElixir.query_flux(
                 conn,
                 "from(bucket: \"test\") |> range(start: -1h)"
               )

      assert is_list(rows)
    end
  end

  describe "create_database/3" do
    test "delegates to configured client", %{conn: conn} do
      assert :ok = InfluxElixir.create_database(conn, "new_db")
    end
  end

  describe "list_databases/1" do
    test "delegates to configured client", %{conn: conn} do
      assert {:ok, dbs} = InfluxElixir.list_databases(conn)
      assert is_list(dbs)
    end
  end

  describe "delete_database/2" do
    test "delegates to configured client", %{conn: conn} do
      assert :ok = InfluxElixir.delete_database(conn, "test_db")
    end
  end

  describe "create_bucket/3" do
    test "delegates to configured client", %{conn: conn} do
      assert :ok = InfluxElixir.create_bucket(conn, "new_bucket")
    end
  end

  describe "list_buckets/1" do
    test "delegates to configured client", %{conn: conn} do
      assert {:ok, buckets} = InfluxElixir.list_buckets(conn)
      assert is_list(buckets)
    end
  end

  describe "delete_bucket/2" do
    test "delegates to configured client", %{conn: conn} do
      assert :ok = InfluxElixir.delete_bucket(conn, "test_bucket")
    end
  end

  describe "create_token/3" do
    test "delegates to configured client", %{conn: conn} do
      assert {:ok, token} =
               InfluxElixir.create_token(conn, "test token")

      assert is_map(token)
    end
  end

  describe "delete_token/2" do
    test "delegates to configured client", %{conn: conn} do
      assert :ok = InfluxElixir.delete_token(conn, "token_id")
    end
  end

  describe "health/1" do
    test "delegates to configured client", %{conn: conn} do
      assert {:ok, %{status: "pass"}} = InfluxElixir.health(conn)
    end
  end

  describe "flush/1" do
    test "returns {:error, :no_batch_writer} when no writer configured" do
      assert {:error, :no_batch_writer} = InfluxElixir.flush(:default)
    end
  end

  describe "stats/1" do
    test "returns {:error, :no_batch_writer} when no writer configured" do
      assert {:error, :no_batch_writer} = InfluxElixir.stats(:default)
    end
  end

  describe "add_connection/2 and remove_connection/1" do
    test "dynamically adds and removes a connection" do
      assert {:ok, pid} =
               InfluxElixir.add_connection(:dynamic_test, [])

      assert is_pid(pid)
      assert Process.alive?(pid)

      assert :ok = InfluxElixir.remove_connection(:dynamic_test)
      refute Process.alive?(pid)
    end
  end
end
