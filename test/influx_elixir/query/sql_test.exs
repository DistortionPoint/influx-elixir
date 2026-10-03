defmodule InfluxElixir.Query.SQLTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Query.SQL
  alias InfluxElixir.TestSupport.Telemetry

  # The write's own time, so rows are compared whole, `time` included.
  @ts 1_700_000_000_000_000_000
  @time ~U[2023-11-14 22:13:20.000000Z]

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    Local.write(conn, "cpu,host=web01 value=1i #{@ts}", database: "test_db")
    {:ok, conn: conn}
  end

  # These modules used to call the client directly: a connection name was a
  # FunctionClauseError and no telemetry span was emitted. They now behave
  # exactly as the facade functions they document.
  describe "the same entry point as the facade" do
    test "a connection name resolves, and each call is a telemetry span" do
      name = :"sql_module_#{System.unique_integer([:positive])}"
      {:ok, _pid} = InfluxElixir.add_connection(name, database: "named_db")
      on_exit(fn -> InfluxElixir.remove_connection(name) end)
      {:ok, :written} = InfluxElixir.write(name, "cpu v=1i")

      Telemetry.attach([[:influx_elixir, :query, :stop]])

      assert SQL.query(name, "SELECT v FROM cpu") === {:ok, [%{"v" => 1}]}

      assert_receive {:telemetry, [:influx_elixir, :query, :stop], _measurements,
                      %{database: "named_db", result: :ok, row_count: 1}}

      assert name |> SQL.query_stream("SELECT v FROM cpu") |> Enum.to_list() === [%{"v" => 1}]
      assert SQL.execute(name, "SELECT v FROM cpu") === {:ok, [%{"v" => 1}]}
      assert {:ok, [_one, _two]} = InfluxElixir.Admin.Databases.list(name)
      assert InfluxElixir.Admin.Health.check(name) === {:ok, %{"status" => "pass"}}
    end
  end

  describe "query/3" do
    test "returns the stored rows", %{conn: conn} do
      assert SQL.query(conn, "SELECT * FROM cpu", database: "test_db") ===
               {:ok, [%{"host" => "web01", "time" => @time, "value" => 1}]}
    end

    test "params reach the client and bind the placeholder", %{conn: conn} do
      {:ok, :written} = Local.write(conn, "cpu,host=web02 value=2i #{@ts}", database: "test_db")

      assert SQL.query(conn, "SELECT * FROM cpu WHERE host = $host",
               database: "test_db",
               params: %{host: "web02"}
             ) === {:ok, [%{"host" => "web02", "time" => @time, "value" => 2}]}
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

      assert Enum.to_list(stream) === [%{"host" => "web01", "time" => @time, "value" => 1}]
    end
  end

  describe "connection-level default database" do
    test "query/2, query_stream/2 and execute/2 use it" do
      {:ok, conn} = Local.start(database: "dflt_db")
      {:ok, :written} = Local.write(conn, "cpu value=7i #{@ts}")
      row = %{"time" => @time, "value" => 7}

      assert SQL.query(conn, "SELECT * FROM cpu") === {:ok, [row]}
      assert conn |> SQL.query_stream("SELECT * FROM cpu") |> Enum.to_list() === [row]
      assert SQL.execute(conn, "SELECT * FROM cpu") === {:ok, [row]}
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

      assert body ===
               "This feature is not implemented: Unsupported SQL statement: ALTER TABLE foo ADD COLUMN y INT"
    end
  end
end
