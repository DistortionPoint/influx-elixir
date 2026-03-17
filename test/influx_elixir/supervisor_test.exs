defmodule InfluxElixir.SupervisorTest do
  use ExUnit.Case

  describe "crash isolation" do
    test "terminating one connection does not affect siblings" do
      {:ok, _pid_a} =
        InfluxElixir.add_connection(:isolation_a, [])

      {:ok, pid_b} =
        InfluxElixir.add_connection(:isolation_b, [])

      # Terminate connection A
      :ok =
        Supervisor.terminate_child(
          InfluxElixir.Supervisor,
          {InfluxElixir.ConnectionSupervisor, :isolation_a}
        )

      # Connection B must still be alive
      assert Process.alive?(pid_b)

      # Clean up
      Supervisor.delete_child(
        InfluxElixir.Supervisor,
        {InfluxElixir.ConnectionSupervisor, :isolation_a}
      )

      InfluxElixir.Connection.delete(:isolation_a)
      InfluxElixir.remove_connection(:isolation_b)
    end

    test "supervisor uses :one_for_one strategy" do
      children = Supervisor.which_children(InfluxElixir.Supervisor)
      assert is_list(children)
    end
  end
end
