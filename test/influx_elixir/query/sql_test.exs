defmodule InfluxElixir.Query.SQLTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Query.SQL

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    Local.write(conn, "cpu,host=web01 value=1i", database: "test_db")
    {:ok, conn: conn}
  end

  # The rows with the columns the clock assigns removed, so that the rest is
  # compared whole.
  defp without({:ok, rows}, columns), do: {:ok, without(rows, columns)}
  defp without(rows, columns), do: Enum.map(rows, &Map.drop(&1, columns))

  # These modules used to call the client directly: a connection name was a
  # FunctionClauseError and no telemetry span was emitted. They now behave
  # exactly as the facade functions they document.
  describe "the same entry point as the facade" do
    test "a connection name resolves, and each call is a telemetry span" do
      name = :"sql_module_#{System.unique_integer([:positive])}"
      {:ok, _pid} = InfluxElixir.add_connection(name, database: "named_db")
      on_exit(fn -> InfluxElixir.remove_connection(name) end)
      {:ok, :written} = InfluxElixir.write(name, "cpu v=1i")

      handler = "sql-module-#{name}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:influx_elixir, :query, :stop],
        &__MODULE__.forward_event/4,
        %{test_pid: test_pid}
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert SQL.query(name, "SELECT v FROM cpu") === {:ok, [%{"v" => 1}]}
      assert_receive {:query_stop, %{database: "named_db", result: :ok, row_count: 1}}

      assert name |> SQL.query_stream("SELECT v FROM cpu") |> Enum.to_list() === [%{"v" => 1}]
      assert SQL.execute(name, "SELECT v FROM cpu") === {:ok, [%{"v" => 1}]}
      assert {:ok, [_one, _two]} = InfluxElixir.Admin.Databases.list(name)
      assert InfluxElixir.Admin.Health.check(name) === {:ok, %{"status" => "pass"}}
    end
  end

  @doc false
  @spec forward_event([atom()], map(), map(), %{test_pid: pid()}) :: :ok
  def forward_event(_event, _measurements, metadata, %{test_pid: test_pid}) do
    # Handlers are global: forward only this test process's spans.
    if self() == test_pid, do: send(test_pid, {:query_stop, metadata})
    :ok
  end

  describe "query/3" do
    test "returns the stored rows", %{conn: conn} do
      assert conn |> SQL.query("SELECT * FROM cpu", database: "test_db") |> without(["time"]) ===
               {:ok, [%{"host" => "web01", "value" => 1}]}
    end

    test "params reach the client and bind the placeholder", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "cpu,host=web02 value=2i", database: "test_db")

      assert conn
             |> SQL.query("SELECT * FROM cpu WHERE host = $host",
               database: "test_db",
               params: %{host: "web02"}
             )
             |> without(["time"]) === {:ok, [%{"host" => "web02", "value" => 2}]}
    end

    test "returns error for non-existent measurement", %{conn: conn} do
      assert {:error,
              %{status: 400, body: "Error during planning: table 'public.iox.nope' not found"}} =
               SQL.query(conn, "SELECT * FROM nope", database: "test_db")
    end
  end

  describe "query_stream/3" do
    test "streams actual rows", %{conn: conn} do
      stream = SQL.query_stream(conn, "SELECT * FROM cpu", database: "test_db")
      rows = Enum.to_list(stream)
      assert without(rows, ["time"]) === [%{"host" => "web01", "value" => 1}]
    end
  end

  describe "connection-level default database" do
    test "query/2, query_stream/2 and execute/2 use it" do
      {:ok, conn} = Local.start(database: "dflt_db")
      {:ok, :written} = Local.write(conn, "cpu value=7i")

      assert conn |> SQL.query("SELECT * FROM cpu") |> without(["time"]) ===
               {:ok, [%{"value" => 7}]}

      assert conn |> SQL.query_stream("SELECT * FROM cpu") |> without(["time"]) === [
               %{"value" => 7}
             ]

      assert conn |> SQL.execute("SELECT * FROM cpu") |> without(["time"]) ===
               {:ok, [%{"value" => 7}]}
    end
  end

  describe "execute/3" do
    test "DELETE on v3_core is the engine's planning error", %{conn: conn} do
      assert {:error, %{status: 400, body: "Error during planning: DML not supported: Delete"}} =
               SQL.execute(conn, "DELETE FROM cpu", database: "test_db")
    end

    test "a statement the engine does not implement is its 405", %{conn: conn} do
      assert {:error, %{status: 405, body: body}} =
               SQL.execute(conn, "ALTER TABLE foo ADD COLUMN y INT", database: "test_db")

      assert body ==
               "This feature is not implemented: Unsupported SQL statement: ALTER TABLE foo ADD COLUMN y INT"
    end
  end
end
