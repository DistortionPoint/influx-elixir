defmodule InfluxElixir.SupervisorTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.ConnectionSupervisor
  alias InfluxElixir.ConnectionSupervisor.Registration
  alias InfluxElixir.TestSupport.Await
  alias InfluxElixir.Write.BatchWriter

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  # The names a connection's processes are registered under.
  defp supervisor_name(name), do: :"influx_elixir_conn_#{name}"
  defp finch_name(name), do: :"influx_elixir_#{name}_finch"
  defp writer_name(name), do: :"influx_elixir_#{name}_batch_writer"

  # The old process is known dead once its :DOWN arrives; the restart is
  # asynchronous, so wait (with a deadline) for the name to resolve to a new pid.
  defp await_restart(name, old_pid) do
    Await.until(fn ->
      case Process.whereis(name) do
        pid when is_pid(pid) and pid !== old_pid -> pid
        _other -> nil
      end
    end)
  end

  describe "crash isolation" do
    @tag :capture_log
    test "a crash inside one connection's tree is contained to that connection" do
      name_a = unique_name(:isolation_a)
      name_b = unique_name(:isolation_b)
      writer = [flush_interval_ms: 60_000]

      {:ok, sup_a} = InfluxElixir.add_connection(name_a, database: "iso_a", batch_writer: writer)
      {:ok, sup_b} = InfluxElixir.add_connection(name_b, database: "iso_b", batch_writer: writer)

      on_exit(fn ->
        InfluxElixir.remove_connection(name_a)
        InfluxElixir.remove_connection(name_b)
      end)

      pids = fn name ->
        Enum.map(
          [supervisor_name(name), finch_name(name), writer_name(name)],
          &Process.whereis/1
        )
      end

      [registered_sup_a, finch_a, writer_a] = pids.(name_a)
      assert registered_sup_a === sup_a
      assert is_pid(finch_a)
      assert is_pid(writer_a)

      before_b = pids.(name_b)
      assert hd(before_b) === sup_b
      assert Enum.all?(before_b, &is_pid/1)

      ref = Process.monitor(writer_a)
      Process.exit(writer_a, :kill)
      assert_receive {:DOWN, ^ref, :process, ^writer_a, :killed}, Await.bound()

      # Only the crashed child is replaced; its own supervisor and pool stay.
      new_writer_a = await_restart(writer_name(name_a), writer_a)
      assert pids.(name_a) === [sup_a, finch_a, new_writer_a]

      assert InfluxElixir.stats(name_a) ===
               {:ok, %{total_writes: 0, total_errors: 0, total_bytes: 0}}

      # The sibling connection keeps the very same processes and still serves.
      assert pids.(name_b) === before_b
      assert InfluxElixir.write(name_b, "cpu v=1i") === {:ok, :written}
      assert InfluxElixir.query_sql(name_b, "SELECT v FROM cpu") === {:ok, [%{"v" => 1}]}

      assert InfluxElixir.stats(name_b) ===
               {:ok, %{total_writes: 0, total_errors: 0, total_bytes: 0}}
    end

    # A killed connection supervisor leaves its children stopping, still
    # holding their names; the restart used to fail with :already_started
    # until the top-level supervisor gave up and took every connection down.
    #
    # This kills a ConnectionSupervisor of the global application supervisor,
    # which counts against that supervisor's restart intensity (default 3
    # restarts in 5 s). Keep this the only test that kills one: a second such
    # test, running concurrently, could exceed the intensity and take down every
    # connection of every other test.
    @tag :capture_log
    test "a killed connection supervisor restarts alone, the others untouched" do
      name_a = unique_name(:killed_a)
      name_b = unique_name(:killed_b)
      writer = [flush_interval_ms: 60_000]

      {:ok, sup_a} = InfluxElixir.add_connection(name_a, database: "kill_a", batch_writer: writer)
      {:ok, sup_b} = InfluxElixir.add_connection(name_b, database: "kill_b", batch_writer: writer)

      on_exit(fn ->
        InfluxElixir.remove_connection(name_a)
        InfluxElixir.remove_connection(name_b)
      end)

      top = Process.whereis(InfluxElixir.Supervisor)
      finch_b = Process.whereis(finch_name(name_b))
      writer_b = Process.whereis(writer_name(name_b))

      sup_ref = Process.monitor(sup_a)
      Process.exit(sup_a, :kill)
      assert_receive {:DOWN, ^sup_ref, :process, ^sup_a, :killed}, Await.bound()

      new_sup_a = await_restart(supervisor_name(name_a), sup_a)
      # The name is registered before init/1 returns; a call waits for it. The pids are
      # generated: the ids, types and modules are pinned, and the writer's pid by its name.
      finch_id = finch_name(name_a)

      assert [
               {BatchWriter, writer_a, :worker, [BatchWriter]},
               {^finch_id, finch_a, :worker, [Finch]},
               {Registration, registration_a, :worker, [Registration]}
             ] = Supervisor.which_children(new_sup_a)

      assert writer_a === Process.whereis(writer_name(name_a))
      assert is_pid(finch_a)
      assert is_pid(registration_a)
      # The top-level supervisor stayed up through the restart: same name, same live pid.
      assert Process.whereis(InfluxElixir.Supervisor) === top
      assert Process.alive?(top)
      assert new_sup_a !== sup_a
      assert InfluxElixir.write(name_a, "cpu v=2i") === {:ok, :written}
      assert InfluxElixir.query_sql(name_a, "SELECT v FROM cpu") === {:ok, [%{"v" => 2}]}

      assert InfluxElixir.stats(name_a) ===
               {:ok, %{total_writes: 0, total_errors: 0, total_bytes: 0}}

      assert Process.whereis(supervisor_name(name_b)) === sup_b
      assert Process.whereis(finch_name(name_b)) === finch_b
      assert Process.whereis(writer_name(name_b)) === writer_b
      assert InfluxElixir.write(name_b, "cpu v=3i") === {:ok, :written}
    end

    # There is no public way to give the application's supervisor a list of connections: its
    # own `start_link/1` registers the one global name, so `init/1` is read directly. The gRPC
    # supervisor child is absent because grpc 1.0+ starts its own (`GRPC.Client.Application`).
    test "init/1 builds a :one_for_one supervisor with one child per connection" do
      connections = [alpha: [host: "a"], beta: [host: "b"]]

      assert InfluxElixir.Supervisor.init(connections: connections) ===
               {:ok,
                {%{strategy: :one_for_one, intensity: 3, period: 5, auto_shutdown: :never},
                 [
                   %{
                     id: {ConnectionSupervisor, :alpha},
                     start: {ConnectionSupervisor, :start_link, [[name: :alpha, host: "a"]]},
                     type: :supervisor
                   },
                   %{
                     id: {ConnectionSupervisor, :beta},
                     start: {ConnectionSupervisor, :start_link, [[name: :beta, host: "b"]]},
                     type: :supervisor
                   }
                 ]}}
    end
  end
end
