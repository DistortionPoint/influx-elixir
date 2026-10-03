defmodule InfluxElixir.Client.Local.FormatTest do
  @moduledoc """
  What `Client.Local` does with a `format:` that the engine answers and the double
  does not model, through `query_sql/3`. What each format answers, the engine's
  words for a format or a parameter it refuses and the floats of its CSV are pinned
  against both clients by the contracts (`InfluxElixir.ClientContract.InfluxQLScalar`,
  `InfluxElixir.Contract.SQLParser` and `InfluxElixir.Contract.SQLExecutor`).
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["db"])
    {:ok, :written} = Local.write(conn, "m v=1.5 1", database: "db", precision: :second)
    {:ok, conn: conn}
  end

  test "parquet is refused by name", %{conn: conn} do
    assert {:error, %{status: 400, body: "Client.Local: format: :parquet" <> _rest}} =
             Local.query_sql(conn, "SELECT v FROM m", database: "db", format: :parquet)
  end

  test "a format the engine answers but the client cannot parse is unsupported", %{conn: conn} do
    for format <- [:pretty, "json", "csv"] do
      assert Local.query_sql(conn, "SELECT v FROM m", database: "db", format: format) ===
               {:error, {:unsupported_format, format}}
    end
  end

  test "a query error is answered before the format", %{conn: conn} do
    for format <- [:csv, :pretty] do
      assert {:error, %{status: 400, body: "Error during planning: table" <> _rest}} =
               Local.query_sql(conn, "SELECT v FROM nosuch", database: "db", format: format)
    end
  end
end
