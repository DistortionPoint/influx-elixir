defmodule InfluxElixir.SupervisorTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.{Connection, ConnectionSupervisor}

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  describe "crash isolation" do
    test "terminating one connection does not affect siblings" do
      name_a = unique_name(:isolation_a)
      name_b = unique_name(:isolation_b)

      {:ok, _pid_a} = InfluxElixir.add_connection(name_a, [])
      {:ok, pid_b} = InfluxElixir.add_connection(name_b, [])

      on_exit(fn ->
        Supervisor.delete_child(InfluxElixir.Supervisor, {ConnectionSupervisor, name_a})
        Connection.delete(name_a)
        InfluxElixir.remove_connection(name_b)
      end)

      :ok =
        Supervisor.terminate_child(
          InfluxElixir.Supervisor,
          {ConnectionSupervisor, name_a}
        )

      assert Process.alive?(pid_b)
      assert {:ok, _conn} = Connection.get(name_b)
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
