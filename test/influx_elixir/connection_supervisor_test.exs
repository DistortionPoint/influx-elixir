defmodule InfluxElixir.ConnectionSupervisorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

  # A connection whose writer has `batch_size: 0` fails to start with the writer's own
  # refusal, which `BatchWriter.start_link/1` gives before it starts anything.
  defp writer_refusal(name) do
    {:error, error} =
      InfluxElixir.Write.BatchWriter.start_link(batch_size: 0, connection: name, name: name)

    {:shutdown, {:failed_to_start_child, InfluxElixir.Write.BatchWriter, error}}
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

    test "the per-connection Finch pool is a child named after the connection" do
      name = unique_name()
      finch_name = :"influx_elixir_#{name}_finch"

      {:ok, sup} =
        InfluxElixir.add_connection(name, host: "h", token: "t")

      on_exit(fn ->
        InfluxElixir.remove_connection(name)
      end)

      assert {^finch_name, child, :worker, [Finch]} =
               List.keyfind(Supervisor.which_children(sup), finch_name, 0)

      # Finch names its top supervisor `<name>.Supervisor`, and its registry `<name>`.
      assert Process.whereis(:"#{finch_name}.Supervisor") === child
    end

    # `finch_name: nil` (an unset `Application.get_env/2`, say) names no pool: the HTTP client
    # then uses the connection's own, which the supervisor did not start.
    test "finch_name: nil starts the per-connection pool" do
      name = unique_name()
      finch_name = :"influx_elixir_#{name}_finch"

      {:ok, sup} = InfluxElixir.add_connection(name, host: "h", token: "t", finch_name: nil)
      on_exit(fn -> InfluxElixir.remove_connection(name) end)

      assert {^finch_name, child, :worker, [Finch]} =
               List.keyfind(Supervisor.which_children(sup), finch_name, 0)

      # Finch names its top supervisor `<name>.Supervisor`, and its registry `<name>`.
      assert Process.whereis(:"#{finch_name}.Supervisor") === child
    end

    test "no per-connection Finch pool is started when :finch_name names an existing one" do
      name = unique_name()
      finch = :"conn_sup_existing_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch})

      {:ok, _pid} =
        InfluxElixir.add_connection(name, host: "h", token: "t", finch_name: finch)

      on_exit(fn -> InfluxElixir.remove_connection(name) end)

      assert Process.whereis(:"influx_elixir_#{name}_finch") === nil
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

      writer = :"influx_elixir_#{name}_batch_writer"
      :ok = InfluxElixir.Write.BatchWriter.write_sync(writer, "cpu value=1.0 1")

      assert InfluxElixir.query_sql(name, "SELECT * FROM cpu", database: "bw_db") ===
               {:ok, [%{"time" => ~U[1970-01-01 00:00:00.000000Z], "value" => 1.0}]}

      assert InfluxElixir.stats(name) ===
               {:ok, %{total_writes: 1, total_errors: 0, total_bytes: 15}}

      assert InfluxElixir.flush(name) === :ok
    end
  end

  describe "batch_writer: validation" do
    test "a misconfigured writer fails the connection's start, naming the option" do
      name = unique_name()

      assert {:error, {reason, _child}} =
               InfluxElixir.add_connection(name, batch_writer: [batch_size: 0])

      assert reason === writer_refusal(name)
      assert Connection.get(name) === {:error, :not_found}

      # Nothing was left behind, so the corrected config starts.
      assert {:ok, _pid} = InfluxElixir.add_connection(name, batch_writer: [batch_size: 10])
      on_exit(fn -> InfluxElixir.remove_connection(name) end)
      assert {:ok, config} = Connection.get(name)
      assert_local_config(config)
    end

    test "options that are not a keyword list are an error, and nothing starts" do
      name = unique_name()

      for opts <- [nil, :x, [1]] do
        assert InfluxElixir.add_connection(name, opts) === {:error, {:invalid_options, opts}}
      end

      assert Connection.get(name) === {:error, :not_found}
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
      assert Connection.get(name) === {:error, :not_found}
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

  describe "the registration follows the supervisor" do
    test "a supervisor that stops by itself erases its registration" do
      # `remove_connection/1` erased it itself; a supervisor that gives up after too many
      # restarts, or is stopped any other way, left a name that resolved to a dead connection.
      name = unique_name()
      {:ok, sup} = ConnectionSupervisor.start_link(name: name, databases: ["x"])

      {:ok, connection} = Connection.get(name)
      assert Map.delete(connection, :table) === %{profile: :v3_core, database: "x", org: "local"}
      :ok = Supervisor.stop(sup)

      assert Connection.get(name) === {:error, :not_found}

      assert_raise ArgumentError, ~r/no InfluxElixir connection named/, fn ->
        InfluxElixir.health(name)
      end
    end

    # The facade erased the name after any failed start, which raised for a name that is not
    # an atom, and could erase a connection another call had started under the name since.
    test "add_connection/2 with a name that is not an atom is an error, never a raise" do
      assert {:error, {{:invalid_options, [name: "not an atom", host: "h"]}, _child}} =
               InfluxElixir.add_connection("not an atom", host: "h")
    end
  end

  describe "start_link/1 with a config that names no connection" do
    test "is an error naming the config, never a raise" do
      for config <- [:x, nil, [1], [host: "h"], [name: "not an atom"], [name: nil]] do
        assert InfluxElixir.ConnectionSupervisor.start_link(config) ===
                 {:error, {:invalid_options, config}}
      end
    end
  end

  describe "a failed start" do
    test "holds the token neither in its error nor in the logs" do
      name = unique_name()
      token = "secret-token-#{System.unique_integer([:positive])}"

      {{:error, reason}, log} =
        with_log(fn ->
          InfluxElixir.add_connection(name, token: token, batch_writer: [batch_size: 0])
        end)

      assert {refusal, _child} = reason
      assert refusal === writer_refusal(name)
      refute inspect(reason, limit: :infinity, printable_limit: :infinity) =~ token
      refute log =~ token
    end

    test "the child spec carries the token opaque" do
      token = "secret-token-#{System.unique_integer([:positive])}"
      spec = ConnectionSupervisor.child_spec(name: :spec_test, token: token, host: "h")

      refute inspect(spec, limit: :infinity) =~ token

      # Only the token is hidden; the rest of the config is passed as it was given.
      assert %{id: ConnectionSupervisor, type: :supervisor} = spec
      assert {ConnectionSupervisor, :start_link, [config]} = spec.start
      assert Keyword.delete(config, :token) === [name: :spec_test, host: "h"]
    end
  end

  describe "the batch writer of a connection" do
    test "is reached by name from the facade" do
      name = unique_name()

      {:ok, _pid} =
        InfluxElixir.add_connection(name,
          database: "bw_name_db",
          batch_writer: [flush_interval_ms: 60_000, batch_size: 10]
        )

      on_exit(fn -> InfluxElixir.remove_connection(name) end)

      point = InfluxElixir.point("cpu", %{"value" => 1}, timestamp: 1_000)
      assert InfluxElixir.write_batched(name, point, sync: true) === :ok

      assert InfluxElixir.query_sql(name, "SELECT value FROM cpu") === {:ok, [%{"value" => 1}]}
    end
  end
end
