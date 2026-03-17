defmodule InfluxElixir.ConnectionSupervisorTest do
  use ExUnit.Case

  alias InfluxElixir.{Connection, ConnectionSupervisor}

  defp unique_name do
    :"conn_sup_test_#{System.unique_integer([:positive])}"
  end

  describe "init/1 — registry population" do
    test "registers initialized connection in persistent_term on start" do
      name = unique_name()

      config = [
        name: name,
        host: "localhost",
        token: "test-token",
        default_database: "mydb"
      ]

      {:ok, pid} =
        InfluxElixir.add_connection(name, config)

      on_exit(fn ->
        InfluxElixir.remove_connection(name)
      end)

      assert Process.alive?(pid)

      # Connection should be resolvable by name and be an initialized
      # connection (Client.Local returns a map with :table, :databases, :profile)
      assert {:ok, registered} = Connection.get(name)
      assert is_map(registered)
      assert Map.has_key?(registered, :table)
      assert Map.has_key?(registered, :databases)
      assert Map.has_key?(registered, :profile)
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
      # Returns an initialized connection, usable by the configured client
      assert is_map(conn)
      assert Map.has_key?(conn, :table)
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
  end

  describe "remove_connection — registry cleanup" do
    test "deregisters connection from persistent_term on removal" do
      name = unique_name()

      {:ok, _pid} =
        InfluxElixir.add_connection(name, host: "h", token: "t")

      # Verify it's registered
      assert {:ok, _config} = Connection.get(name)

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
