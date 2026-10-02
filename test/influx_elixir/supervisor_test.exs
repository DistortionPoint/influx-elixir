defmodule InfluxElixir.SupervisorTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.ConnectionSupervisor

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  # The restart is asynchronous: wait (bounded) for the name to resolve to a new pid.
  defp await_restart(name, old_pid, attempts \\ 100) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _other when attempts > 0 ->
        Process.sleep(10)
        await_restart(name, old_pid, attempts - 1)

      _other ->
        flunk("#{inspect(name)} was not restarted")
    end
  end

  describe "crash isolation" do
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
          [
            ConnectionSupervisor.via(name),
            ConnectionSupervisor.finch_name(name),
            ConnectionSupervisor.batch_writer_name(name)
          ],
          &Process.whereis/1
        )
      end

      [^sup_a, finch_a, writer_a] = pids.(name_a)
      [^sup_b, _finch_b, _writer_b] = before_b = pids.(name_b)
      assert Enum.all?(before_b, &is_pid/1)

      ref = Process.monitor(writer_a)
      Process.exit(writer_a, :kill)
      assert_receive {:DOWN, ^ref, :process, ^writer_a, :killed}

      # Only the crashed child is replaced; its own supervisor and pool stay.
      new_writer_a = await_restart(ConnectionSupervisor.batch_writer_name(name_a), writer_a)
      assert [^sup_a, ^finch_a, ^new_writer_a] = pids.(name_a)

      assert InfluxElixir.stats(name_a) ===
               {:ok, %{total_writes: 0, total_errors: 0, total_bytes: 0}}

      # The sibling connection keeps the very same processes and still serves.
      assert pids.(name_b) == before_b
      assert {:ok, :written} = InfluxElixir.write(name_b, "cpu v=1i")
      assert InfluxElixir.query_sql(name_b, "SELECT v FROM cpu") === {:ok, [%{"v" => 1}]}

      assert InfluxElixir.stats(name_b) ===
               {:ok, %{total_writes: 0, total_errors: 0, total_bytes: 0}}
    end

    # A killed connection supervisor leaves its children stopping, still
    # holding their names; the restart used to fail with :already_started
    # until the top-level supervisor gave up and took every connection down.
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

      top = Process.monitor(Process.whereis(InfluxElixir.Supervisor))
      finch_b = Process.whereis(ConnectionSupervisor.finch_name(name_b))
      writer_b = Process.whereis(ConnectionSupervisor.batch_writer_name(name_b))

      Process.exit(sup_a, :kill)

      new_sup_a = await_restart(ConnectionSupervisor.via(name_a), sup_a)
      # The name is registered before init/1 returns; a call waits for it.
      assert [_finch, _writer] = Supervisor.which_children(new_sup_a)
      refute_received {:DOWN, ^top, :process, _pid, _reason}
      assert new_sup_a != sup_a
      assert {:ok, :written} = InfluxElixir.write(name_a, "cpu v=2i")
      assert InfluxElixir.query_sql(name_a, "SELECT v FROM cpu") === {:ok, [%{"v" => 2}]}

      assert InfluxElixir.stats(name_a) ===
               {:ok, %{total_writes: 0, total_errors: 0, total_bytes: 0}}

      assert Process.whereis(ConnectionSupervisor.via(name_b)) == sup_b
      assert Process.whereis(ConnectionSupervisor.finch_name(name_b)) == finch_b
      assert Process.whereis(ConnectionSupervisor.batch_writer_name(name_b)) == writer_b
      assert {:ok, :written} = InfluxElixir.write(name_b, "cpu v=3i")
    end

    test "init/1 builds a :one_for_one supervisor with one child per connection" do
      assert {:ok, {%{strategy: :one_for_one}, children}} =
               InfluxElixir.Supervisor.init(connections: [alpha: [host: "a"], beta: [host: "b"]])

      connection_ids =
        for %{id: {ConnectionSupervisor, name}} <- children, do: name

      assert connection_ids == [:alpha, :beta]
    end
  end
end
