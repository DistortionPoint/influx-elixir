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

  # A client that tells the process named in the config which connection it shut down.
  defmodule Recording do
    @moduledoc false
    @spec init_connection(keyword()) :: {:ok, term()}
    def init_connection(config),
      do: {:ok, {:recorded, Keyword.fetch!(config, :name), Keyword.fetch!(config, :owner)}}

    @spec shutdown_connection(term()) :: :ok
    def shutdown_connection({:recorded, _name, owner} = connection) do
      send(owner, {:shut_down, connection})
      :ok
    end
  end

  setup do
    previous = Application.fetch_env!(:influx_elixir, :client)
    on_exit(fn -> Application.put_env(:influx_elixir, :client, previous) end)
    {:ok, name: :"refused_#{System.unique_integer([:positive])}"}
  end

  describe "a client that refuses the connection" do
    setup do
      Application.put_env(:influx_elixir, :client, Refusing)
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

    # The supervisor adds the child it could not start to the error; that child's spec holds
    # the token opaque, which is all of it this test reads.
    test "add_connection/2 returns it too, with nothing registered and no token",
         %{name: name} do
      token = "secret-token-#{System.unique_integer([:positive])}"

      assert {:error, {{:refused, ^name}, child} = reason} =
               InfluxElixir.add_connection(name, host: "h", token: token)

      refute inspect(child, limit: :infinity, printable_limit: :infinity) =~ token
      refute inspect(reason, limit: :infinity, printable_limit: :infinity) =~ token
      assert Connection.get(name) === {:error, :not_found}
    end
  end

  describe "a connection's release" do
    setup do
      Application.put_env(:influx_elixir, :client, Recording)
    end

    # The release read the registry when the connection stopped: a name erased by then
    # released nothing.
    test "shuts down the connection it registered, even once its name is erased",
         %{name: name} do
      {:ok, _pid} = InfluxElixir.add_connection(name, owner: self())
      assert Connection.get(name) === {:ok, {:recorded, name, self()}}

      :ok = Connection.delete(name)
      assert InfluxElixir.remove_connection(name) === :ok

      owner = self()
      assert_received {:shut_down, {:recorded, ^name, ^owner}}
    end

    # The release read the configured client when the connection stopped, and handed the
    # connection to whichever client was configured by then.
    test "goes to the client that made the connection", %{name: name} do
      {:ok, _pid} = InfluxElixir.add_connection(name, owner: self())
      Application.put_env(:influx_elixir, :client, Refusing)

      assert InfluxElixir.remove_connection(name) === :ok

      owner = self()
      assert_received {:shut_down, {:recorded, ^name, ^owner}}
      assert Connection.get(name) === {:error, :not_found}
    end
  end
end
