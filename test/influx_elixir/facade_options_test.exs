defmodule InfluxElixir.FacadeOptionsTest do
  @moduledoc """
  The facade reads its options for telemetry before the client runs: options that are not a
  keyword list must reach the configured client (here `Client.Local`), which names them,
  never raise in the facade.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  @not_keyword {:error, %{status: 400, body: "Client.Local: the options are not a keyword list"}}

  setup do
    {:ok, conn} = Local.start(databases: ["f"])
    {:ok, conn: conn}
  end

  test "every query and the write name options that are not a keyword list", %{conn: conn} do
    for opts <- [nil, :x, [1], [{:a, 1} | :t]] do
      assert InfluxElixir.query_sql(conn, "SELECT 1", opts) === @not_keyword
      assert InfluxElixir.execute_sql(conn, "SELECT 1", opts) === @not_keyword
      assert InfluxElixir.query_influxql(conn, "SHOW DATABASES", opts) === @not_keyword
      assert InfluxElixir.write(conn, "m v=1 1", opts) === @not_keyword
    end
  end

  test "iodata is a write body through the facade", %{conn: conn} do
    assert InfluxElixir.write(conn, ["m v=", "1 1"], database: "f") === {:ok, :written}

    assert InfluxElixir.query_sql(conn, "SELECT v FROM m", database: "f") ===
             {:ok, [%{"v" => 1.0}]}
  end
end
