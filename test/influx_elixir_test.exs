defmodule InfluxElixirTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    Local.write(conn, "cpu value=1i", database: "test_db")
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
               InfluxElixir.write(conn, "cpu value=1.0", database: "test_db")
    end
  end

  describe "query_sql/3" do
    test "delegates to configured client", %{conn: conn} do
      assert {:ok, [%{"value" => 1}]} =
               InfluxElixir.query_sql(conn, "SELECT * FROM cpu", database: "test_db")
    end
  end

  describe "query_sql_stream/3" do
    test "returns an enumerable", %{conn: conn} do
      stream =
        InfluxElixir.query_sql_stream(conn, "SELECT * FROM cpu", database: "test_db")

      assert Enumerable.impl_for(stream)
    end
  end

  describe "execute_sql/3" do
    test "delegates to configured client", %{conn: conn} do
      assert {:error, :delete_not_supported} =
               InfluxElixir.execute_sql(conn, "DELETE FROM cpu", database: "test_db")
    end
  end

  describe "query_influxql/3" do
    test "delegates to configured client", %{conn: conn} do
      assert {:ok, [%{"value" => 1}]} =
               InfluxElixir.query_influxql(conn, "SELECT * FROM cpu", database: "test_db")
    end
  end

  describe "query_flux/3" do
    test "delegates to configured client" do
      {:ok, v2_conn} = Local.start(profile: :v2)
      on_exit(fn -> Local.stop(v2_conn) end)

      :ok = InfluxElixir.create_bucket(v2_conn, "test")
      {:ok, :written} = InfluxElixir.write(v2_conn, "cpu value=1.0", database: "test")

      assert {:ok, [%{"_measurement" => "cpu", "_field" => "value", "_value" => 1.0}]} =
               InfluxElixir.query_flux(
                 v2_conn,
                 "from(bucket: \"test\") |> range(start: -1h)"
               )
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
      assert %{"name" => "test_db"} in dbs
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
      :ok = InfluxElixir.create_bucket(v2_conn, "listed_bucket")

      assert {:ok, buckets} = InfluxElixir.list_buckets(v2_conn)
      assert "listed_bucket" in Enum.map(buckets, & &1["name"])
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

      assert {:ok, %{"token" => secret, "description" => "test token"}} =
               InfluxElixir.create_token(ent_conn, "test token")

      assert byte_size(secret) > 0
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

  describe "telemetry" do
    setup do
      handler_id = "influx-elixir-facade-#{inspect(self())}"

      # Handlers are global; forward only events emitted by this test
      # process so concurrent modules cannot leak spans in.
      :telemetry.attach_many(
        handler_id,
        [[:influx_elixir, :write, :stop], [:influx_elixir, :query, :stop]],
        &__MODULE__.forward_event/4,
        %{test_pid: self()}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    @doc false
    @spec forward_event([atom()], map(), map(), %{test_pid: pid()}) :: :ok
    def forward_event(event, measurements, metadata, %{test_pid: test_pid}) do
      if self() == test_pid do
        send(test_pid, {:telemetry, event, measurements, metadata})
      end

      :ok
    end

    test "write/3 emits a write span with database, bytes and point count", %{conn: conn} do
      lp = "cpu value=1.0\ncpu value=2.0"
      assert {:ok, :written} = InfluxElixir.write(conn, lp, database: "test_db")

      assert_receive {:telemetry, [:influx_elixir, :write, :stop], %{duration: duration},
                      %{database: "test_db", bytes: bytes, point_count: 2, result: :ok}}

      assert bytes == byte_size(lp)
      assert duration >= 0
    end

    test "query_sql/3 emits a query span with transport and row count", %{conn: conn} do
      assert {:ok, [_row]} =
               InfluxElixir.query_sql(conn, "SELECT * FROM cpu", database: "test_db")

      assert_receive {:telemetry, [:influx_elixir, :query, :stop], _measurements,
                      %{
                        database: "test_db",
                        transport: InfluxElixir.Client.Local,
                        row_count: 1,
                        result: :ok
                      }}
    end

    test "a client error is a :stop with result: :error, not an exception", %{conn: conn} do
      assert {:error, _reason} =
               InfluxElixir.query_sql(conn, "SELECT * FROM nope", database: "test_db")

      assert_receive {:telemetry, [:influx_elixir, :query, :stop], _measurements,
                      %{result: :error} = metadata}

      refute Map.has_key?(metadata, :row_count)
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

  describe "connection-level default database" do
    test "write and query functions fall back to it when opts omit :database" do
      {:ok, conn} = Local.start(database: "dflt_db")
      on_exit(fn -> Local.stop(conn) end)

      assert {:ok, :written} = InfluxElixir.write(conn, "cpu value=1i")
      assert {:ok, [%{"value" => 1}]} = InfluxElixir.query_sql(conn, "SELECT * FROM cpu")
      assert {:ok, [%{"value" => 1}]} = InfluxElixir.query_influxql(conn, "SELECT * FROM cpu")
      assert {:ok, %{"rows_affected" => 0}} = InfluxElixir.execute_sql(conn, "ALTER TABLE cpu")

      assert [%{"value" => 1}] =
               conn |> InfluxElixir.query_sql_stream("SELECT * FROM cpu") |> Enum.to_list()
    end
  end

  describe "add_connection/2 and remove_connection/1" do
    test "remove_connection/1 for an unknown name returns {:error, :not_found}" do
      assert {:error, :not_found} = InfluxElixir.remove_connection(:never_added_connection)
    end

    test "remove_connection/1 succeeds when the registry entry is already gone" do
      name = :"orphan_registry_#{System.unique_integer([:positive])}"
      {:ok, _pid} = InfluxElixir.add_connection(name, [])

      InfluxElixir.Connection.delete(name)

      assert :ok = InfluxElixir.remove_connection(name)
    end

    test "dynamically adds and removes a connection" do
      # The supervisor registry is VM-global: a unique name keeps this test
      # isolated from every other async module.
      name = :"dynamic_test_#{System.unique_integer([:positive])}"

      assert {:ok, pid} = InfluxElixir.add_connection(name, [])

      assert is_pid(pid)
      assert Process.alive?(pid)

      assert :ok = InfluxElixir.remove_connection(name)
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
