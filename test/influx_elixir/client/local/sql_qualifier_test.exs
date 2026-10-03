defmodule InfluxElixir.Client.Local.SqlQualifierTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  # A qualifier that is no relation but a column of one is read by the engine as a field
  # access of that column, and the error it raises depends on the column's type and on the
  # clause. The double refuses it by name rather than word a different error.

  setup do
    {:ok, conn} = Local.start(databases: ["q_db"], profile: :v3_core)

    lines =
      "main,host=h0 n=1i,x=1.5 1700000000000000000\nmain,host=h1 n=2i,x=2.5 1700000030000000000"

    {:ok, :written} = Local.write(conn, lines, database: "q_db", precision: :nanosecond)
    {:ok, conn: conn}
  end

  for sql <- [
        "SELECT x.host FROM main",
        "SELECT n.y FROM main m",
        "SELECT host FROM main WHERE x.host = 'h0'",
        "SELECT max(n.y) FROM main"
      ] do
    test "#{sql} is refused by name", %{conn: conn} do
      assert {:error, %{status: 400, body: "Client.Local: " <> reason}} =
               Local.query_sql(conn, unquote(sql), database: "q_db")

      assert reason =~ "a column used as the relation of another"
    end
  end

  test "an unknown relation that is no column is the engine's schema error", %{conn: conn} do
    assert {:error, %{status: 500, body: body}} =
             Local.query_sql(conn, "SELECT zz.host FROM main m", database: "q_db")

    assert body == "Schema error: No field named zz.host. Did you mean 'm.host'?."
  end
end
