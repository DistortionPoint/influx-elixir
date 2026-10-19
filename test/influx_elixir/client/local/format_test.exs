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
    assert Local.query_sql(conn, "SELECT v FROM m", database: "db", format: :parquet) ===
             {:error,
              %{
                status: 400,
                body:
                  "Client.Local: format: :parquet is not supported by the test double; " <>
                    "cover Parquet in the integration tier"
              }}
  end

  test "a format the engine answers but the client cannot parse is unsupported", %{conn: conn} do
    for format <- [:pretty, "json", "csv"] do
      assert Local.query_sql(conn, "SELECT v FROM m", database: "db", format: format) ===
               {:error, {:unsupported_format, format}}
    end
  end

  test "a format the client cannot write into its request body is refused, not raised", %{
    conn: conn
  } do
    assert Local.query_sql(conn, "SELECT v FROM m", database: "db", format: <<255>>) ===
             {:error,
              %{
                status: 400,
                body:
                  "Client.Local: format: a value that is not valid UTF-8 " <>
                    "(the client cannot write it into the request body)"
              }}

    for format <- [5, %{}, [:csv]] do
      assert Local.query_sql(conn, "SELECT v FROM m", database: "db", format: format) ===
               {:error,
                %{
                  status: 400,
                  body: "Client.Local: format: a value that is neither an atom nor a string"
                }}
    end
  end

  test "a query error is answered before the format", %{conn: conn} do
    for format <- [:csv, :pretty] do
      assert Local.query_sql(conn, "SELECT v FROM nosuch", database: "db", format: format) ===
               {:error,
                %{status: 400, body: "Error during planning: table 'public.iox.nosuch' not found"}}
    end
  end

  test "format: nil uses the default :json format on both SQL and InfluxQL", %{conn: conn} do
    assert Local.query_sql(conn, "SELECT v FROM m", database: "db", format: nil) ===
             {:ok, [%{"v" => 1.5}]}

    assert Local.query_influxql(conn, "SELECT v FROM m", database: "db", format: nil) ===
             {:ok,
              [
                %{
                  "iox::measurement" => "m",
                  "time" => ~U[1970-01-01 00:00:01.000000Z],
                  "v" => 1.5
                }
              ]}
  end

  test "format: false is refused as an unknown variant, not treated as :json", %{conn: conn} do
    expected =
      {:error,
       %{
         status: 400,
         body:
           "serde json error: unknown variant `false`, expected one of `parquet`, `csv`, " <>
             "`pretty`, `json`, `json_lines`, `jsonl` at line 1 column 27"
       }}

    assert Local.query_sql(conn, "SELECT v FROM m", database: "db", format: false) === expected

    assert Local.query_influxql(conn, "SELECT v FROM m", database: "db", format: false) ===
             expected
  end
end
