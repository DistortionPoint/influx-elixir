defmodule InfluxElixir.ConnectionSupervisorClientErrorTest do
  # The configured client is application-wide, so this module swaps it and runs alone
  # (ExUnit runs the synchronous modules after the asynchronous ones).
  use ExUnit.Case, async: false

  alias InfluxElixir.{Connection, ConnectionSupervisor}

  # A client whose connections cannot be made. Only the lifecycle callbacks are used.
  defmodule Refusing do
    @moduledoc false
    @spec init_connection(keyword()) :: {:error, term()}
    def init_connection(config), do: {:error, {:refused, Keyword.fetch!(config, :name)}}
    @spec shutdown_connection(term()) :: :ok
    def shutdown_connection(_connection), do: :ok
  end

  setup do
    previous = Application.fetch_env!(:influx_elixir, :client)
    Application.put_env(:influx_elixir, :client, Refusing)
    on_exit(fn -> Application.put_env(:influx_elixir, :client, previous) end)
    {:ok, name: :"refused_#{System.unique_integer([:positive])}"}
  end

  test "start_link/1 returns the error init_connection/1 returned", %{name: name} do
    # It was a MatchError raised inside the supervisor's init. A failed start_link exits the
    # process it started, and the exit signal would end a caller that does not trap exits
    # before OTP's start_link could consume it; trapped, the caller gets the error.
    Process.flag(:trap_exit, true)

    assert ConnectionSupervisor.start_link(name: name, host: "h", token: "t") ===
             {:error, {:refused, name}}

    assert Connection.get(name) === {:error, :not_found}
  end

  test "add_connection/2 returns it too, with nothing registered and no token", %{name: name} do
    token = "secret-token-#{System.unique_integer([:positive])}"

    assert {:error, reason} = InfluxElixir.add_connection(name, host: "h", token: token)

    assert inspect(reason) =~ "{:refused, #{inspect(name)}}"
    refute inspect(reason, limit: :infinity, printable_limit: :infinity) =~ token
    assert Connection.get(name) === {:error, :not_found}
  end
end
