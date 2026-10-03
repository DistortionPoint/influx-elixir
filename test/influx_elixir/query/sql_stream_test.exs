defmodule InfluxElixir.Query.SQLStreamTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Query.SQLStream

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    {:ok, conn: conn}
  end

  describe "stream/3" do
    test "can be consumed with Enum.to_list", %{conn: conn} do
      Local.write(conn, "cpu value=1i 1\ncpu value=2i 2", database: "test_db")

      result =
        conn
        |> SQLStream.stream("SELECT * FROM cpu", database: "test_db")
        |> Enum.to_list()

      assert Enum.sort(Enum.map(result, & &1["value"])) === [1, 2]
    end

    test "without options reads the connection's default database" do
      {:ok, conn} = Local.start(databases: ["test_db"], database: "test_db")
      {:ok, :written} = Local.write(conn, "cpu value=1i 1", database: "test_db")

      assert conn |> SQLStream.stream("SELECT value FROM cpu") |> Enum.to_list() ===
               [%{"value" => 1}]
    end

    # Parity with Client.HTTP (issue #11): querying a missing table surfaces as
    # an error, not a silent empty stream.
    test "raises StreamError when the table does not exist", %{conn: conn} do
      stream = SQLStream.stream(conn, "SELECT * FROM missing", database: "test_db")
      assert_raise InfluxElixir.StreamError, fn -> Enum.to_list(stream) end
    end
  end
end
