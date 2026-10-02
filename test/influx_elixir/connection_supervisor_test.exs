defmodule InfluxElixir.ConnectionSupervisorTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.{Connection, ConnectionSupervisor}

  defp unique_name do
    :"conn_sup_test_#{System.unique_integer([:positive])}"
  end

  # The registered connection is what the client built from the added
  # options: under the double, its profile, default database and org around
  # the store. Neither case adds a database, and `host` and `token` are the
  # HTTP client's alone.
  defp assert_local_config(config) do
    assert %{table: table} = config
    assert is_reference(table)
    assert Map.delete(config, :table) === %{profile: :v3_core, database: nil, org: "local"}
  end

  describe "init/1 — registry population" do
    test "registers initialized connection in persistent_term on start" do
      name = unique_name()

      config = [
        name: name,
        host: "localhost",
        token: "test-token",
        database: "mydb"
      ]

      {:ok, pid} =
        InfluxElixir.add_connection(name, config)

      on_exit(fn ->
        InfluxElixir.remove_connection(name)
      end)

      assert Process.alive?(pid)

      # The registered term is an initialised connection the configured
      # client can use straight away.
      assert {:ok, registered} = Connection.get(name)
      assert InfluxElixir.health(registered) === {:ok, %{"status" => "pass"}}
      assert InfluxElixir.health(name) === {:ok, %{"status" => "pass"}}
    end

    test "fetch!/1 works for a started connection" do
      name = unique_name()

      {:ok, _pid} =
        InfluxElixir.add_connection(name,
          host: "influx.local",
          token: "abc"
        )

      on_exit(fn ->
        InfluxElixir.remove_connection(name)
      end)

      conn = Connection.fetch!(name)
      # Returns an initialised connection, usable by the configured client
      assert InfluxElixir.health(conn) === {:ok, %{"status" => "pass"}}
    end

    test "finch pool name is derivable from registered connection" do
      name = unique_name()

      {:ok, _pid} =
        InfluxElixir.add_connection(name, host: "h", token: "t")

      on_exit(fn ->
        InfluxElixir.remove_connection(name)
      end)

      finch_name = ConnectionSupervisor.finch_name(name)
      assert Process.whereis(finch_name) != nil
    end

    test "no per-connection Finch pool is started when :finch_name names an existing one" do
      name = unique_name()
      finch = :"conn_sup_existing_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch})

      {:ok, _pid} =
        InfluxElixir.add_connection(name, host: "h", token: "t", finch_name: finch)

      on_exit(fn -> InfluxElixir.remove_connection(name) end)

      assert Process.whereis(ConnectionSupervisor.finch_name(name)) == nil
      assert InfluxElixir.health(name) === {:ok, %{"status" => "pass"}}
    end
  end

  describe "init/1 — batch writer child" do
    test "the writer flushes through the initialised connection" do
      # Regression: the writer received the raw config keyword list, which
      # Client.Local.write/3 cannot use (it needs the ETS-backed map).
      name = unique_name()

      {:ok, _pid} =
        InfluxElixir.add_connection(name,
          database: "bw_db",
          batch_writer: [flush_interval_ms: 60_000, batch_size: 10]
        )

      on_exit(fn -> InfluxElixir.remove_connection(name) end)

      writer = ConnectionSupervisor.batch_writer_name(name)
      :ok = InfluxElixir.Write.BatchWriter.write_sync(writer, "cpu value=1.0 1")

      assert InfluxElixir.query_sql(name, "SELECT * FROM cpu", database: "bw_db") ===
               {:ok, [%{"time" => ~U[1970-01-01 00:00:00.000000Z], "value" => 1.0}]}

      assert InfluxElixir.stats(name) ===
               {:ok, %{total_writes: 1, total_errors: 0, total_bytes: 15}}

      assert :ok = InfluxElixir.flush(name)
    end
  end

  describe "batch_writer: validation" do
    test "a misconfigured writer fails the connection's start, naming the option" do
      name = unique_name()

      assert {:error, reason} =
               InfluxElixir.add_connection(name, batch_writer: [batch_size: 0])

      assert inspect(reason) =~ "invalid value for :batch_size option"
      assert {:error, :not_found} = Connection.get(name)

      # Nothing was left behind, so the corrected config starts.
      assert {:ok, _pid} = InfluxElixir.add_connection(name, batch_writer: [batch_size: 10])
      on_exit(fn -> InfluxElixir.remove_connection(name) end)
      assert {:ok, config} = Connection.get(name)
      assert_local_config(config)
    end
  end

  describe "remove_connection — registry cleanup" do
    test "deregisters connection from persistent_term on removal" do
      name = unique_name()

      {:ok, _pid} =
        InfluxElixir.add_connection(name, host: "h", token: "t")

      # Verify it's registered
      assert {:ok, config} = Connection.get(name)
      assert_local_config(config)

      # Remove the connection
      :ok = InfluxElixir.remove_connection(name)

      # Should no longer be in the registry
      assert {:error, :not_found} = Connection.get(name)
    end

    test "fetch!/1 raises after connection is removed" do
      name = unique_name()

      {:ok, _pid} =
        InfluxElixir.add_connection(name, host: "h", token: "t")

      :ok = InfluxElixir.remove_connection(name)

      assert_raise ArgumentError, fn ->
        Connection.fetch!(name)
      end
    end
  end
end
