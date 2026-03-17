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
    test "delegates to configured client" do
      {:ok, v2_conn} = Local.start(profile: :v2)
      on_exit(fn -> Local.stop(v2_conn) end)

      assert {:ok, rows} =
               InfluxElixir.query_flux(
                 v2_conn,
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
    test "delegates to configured client" do
      {:ok, v2_conn} = Local.start(profile: :v2)
      on_exit(fn -> Local.stop(v2_conn) end)
      assert :ok = InfluxElixir.create_bucket(v2_conn, "new_bucket")
    end
  end

  describe "list_buckets/1" do
    test "delegates to configured client" do
      {:ok, v2_conn} = Local.start(profile: :v2)
      on_exit(fn -> Local.stop(v2_conn) end)
      assert {:ok, buckets} = InfluxElixir.list_buckets(v2_conn)
      assert is_list(buckets)
    end
  end

  describe "delete_bucket/2" do
    test "delegates to configured client" do
      {:ok, v2_conn} = Local.start(profile: :v2)
      on_exit(fn -> Local.stop(v2_conn) end)
      assert :ok = InfluxElixir.delete_bucket(v2_conn, "test_bucket")
    end
  end

  describe "create_token/3" do
    test "delegates to configured client" do
      {:ok, ent_conn} = Local.start(profile: :v3_enterprise)
      on_exit(fn -> Local.stop(ent_conn) end)

      assert {:ok, token} =
               InfluxElixir.create_token(ent_conn, "test token")

      assert is_map(token)
    end
  end

  describe "delete_token/2" do
    test "delegates to configured client" do
      {:ok, ent_conn} = Local.start(profile: :v3_enterprise)
      on_exit(fn -> Local.stop(ent_conn) end)
      assert :ok = InfluxElixir.delete_token(ent_conn, "token_id")
    end
  end

  describe "health/1" do
    test "delegates to configured client", %{conn: conn} do
      assert {:ok, %{"status" => "pass"}} = InfluxElixir.health(conn)
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

  describe "resolve_connection/1" do
    test "passes through a keyword config unchanged", %{conn: conn} do
      assert InfluxElixir.resolve_connection(conn) == conn
    end

    test "resolves an atom name via Connection registry" do
      name = :"resolve_test_#{System.unique_integer([:positive])}"
      config = [host: "resolve-host", token: "t"]

      InfluxElixir.Connection.put(name, config)
      on_exit(fn -> InfluxElixir.Connection.delete(name) end)

      resolved = InfluxElixir.resolve_connection(name)
      assert resolved[:host] == "resolve-host"
    end

    test "raises ArgumentError for unregistered atom name" do
      assert_raise ArgumentError, fn ->
        InfluxElixir.resolve_connection(:no_such_connection)
      end
    end
  end

  describe "facade with named connections" do
    test "health/1 accepts an atom name" do
      name = :"facade_test_#{System.unique_integer([:positive])}"

      # Register a LocalClient connection under the name
      {:ok, local_conn} = Local.start(databases: ["facade_db"])
      on_exit(fn -> Local.stop(local_conn) end)

      InfluxElixir.Connection.put(name, local_conn)
      on_exit(fn -> InfluxElixir.Connection.delete(name) end)

      assert {:ok, %{"status" => "pass"}} = InfluxElixir.health(name)
    end

    test "write/3 and query_sql/3 accept an atom name" do
      name = :"facade_rw_#{System.unique_integer([:positive])}"

      {:ok, local_conn} = Local.start(databases: ["facade_rw_db"])
      on_exit(fn -> Local.stop(local_conn) end)

      InfluxElixir.Connection.put(name, local_conn)
      on_exit(fn -> InfluxElixir.Connection.delete(name) end)

      assert {:ok, :written} =
               InfluxElixir.write(name, "cpu value=1.0", database: "facade_rw_db")

      assert {:ok, [row]} =
               InfluxElixir.query_sql(name, "SELECT * FROM cpu", database: "facade_rw_db")

      assert row["value"] == 1.0
    end
  end
end
