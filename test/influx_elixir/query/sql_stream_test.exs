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
      result =
        conn
        |> SQLStream.stream("SELECT * FROM cpu")
        |> Enum.to_list()

      assert is_list(result)
    end
  end
end
