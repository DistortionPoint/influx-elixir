defmodule InfluxElixir.Query.SQLStreamTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Query.SQLStream

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  describe "stream/3" do
    test "returns an enumerable", %{conn: conn} do
      stream = SQLStream.stream(conn, "SELECT * FROM cpu")
      assert Enumerable.impl_for(stream)
    end

    test "can be consumed with Enum.to_list", %{conn: conn} do
      Local.write(conn, "cpu value=1i\ncpu value=2i", database: "test_db")

      result =
        conn
        |> SQLStream.stream("SELECT * FROM cpu", database: "test_db")
        |> Enum.to_list()

      assert is_list(result)
      assert length(result) == 2
    end

    # Parity with Client.HTTP (issue #11): querying a missing table surfaces as
    # an error, not a silent empty stream.
    test "raises StreamError when the table does not exist", %{conn: conn} do
      stream = SQLStream.stream(conn, "SELECT * FROM missing", database: "test_db")
      assert_raise InfluxElixir.StreamError, fn -> Enum.to_list(stream) end
    end
  end
end
