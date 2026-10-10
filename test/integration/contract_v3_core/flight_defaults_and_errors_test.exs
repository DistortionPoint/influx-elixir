defmodule InfluxElixir.Integration.ContractV3Core.FlightDefaultsAndErrorsTest do
  @moduledoc """
  What Arrow Flight returns for the types FlatBuffers leave at their schema default
  (UInt columns, Float16, Float32's shortest decimal, Date64) and how its failures read,
  against InfluxDB v3 Core on port 8181. Every Flight answer is compared with the HTTP answer
  to the same statement and pinned to the exact values.

  Run with: `mix test --include v3_core`
  """

  use InfluxElixir.ContractServer, profile: :v3_core

  alias InfluxElixir.Client.HTTP
  alias InfluxElixir.IntegrationHelper, as: H

  defp http(ctx, sql), do: HTTP.query_sql(ctx.conn, sql, database: ctx.database)

  defp flight(ctx, sql, extra \\ []) do
    HTTP.query_sql(
      ctx.conn,
      sql,
      Keyword.merge(
        [database: ctx.database, transport: :flight, flight_port: ctx.conn[:port], tls: false],
        extra
      )
    )
  end

  defp same_rows(ctx, sql) do
    assert {:ok, rows} = http(ctx, sql)
    assert flight(ctx, sql) === {:ok, rows}
    rows
  end

  describe "unsigned integers" do
    test "are unsigned over Flight, up to the largest UInt64", ctx do
      m = H.unique_name("flight_unsigned")

      lp = """
      #{m} u8=200u,u16=60000u,u32=3000000000u,u64=18446744073709551615u,i=-5i 1700000000000000000
      #{m} u8=0u,u16=1u,u32=2u,u64=9223372036854775808u,i=7i 1700000000000000001
      """

      assert {:ok, :written} = HTTP.write(ctx.conn, String.trim(lp), database: ctx.database)
      InfluxElixir.ClientContract.settle(ctx)

      assert same_rows(ctx, "SELECT u8, u16, u32, u64, i FROM #{m} ORDER BY time") === [
               %{
                 "u8" => 200,
                 "u16" => 60_000,
                 "u32" => 3_000_000_000,
                 "u64" => 18_446_744_073_709_551_615,
                 "i" => -5
               },
               %{
                 "u8" => 0,
                 "u16" => 1,
                 "u32" => 2,
                 "u64" => 9_223_372_036_854_775_808,
                 "i" => 7
               }
             ]
    end

    test "casts to every width keep their sign", ctx do
      sql =
        "SELECT arrow_cast(200,'UInt8') a, arrow_cast(60000,'UInt16') b, " <>
          "arrow_cast(3000000000,'UInt32') c, arrow_cast(10000000000000000000,'UInt64') d, " <>
          "arrow_cast(-5,'Int8') e, arrow_cast(-300,'Int16') f"

      assert same_rows(ctx, sql) === [
               %{
                 "a" => 200,
                 "b" => 60_000,
                 "c" => 3_000_000_000,
                 "d" => 10_000_000_000_000_000_000,
                 "e" => -5,
                 "f" => -300
               }
             ]
    end
  end

  describe "floating point" do
    test "Float16 is read, with HTTP's shortest-decimal rendering and null for infinity", ctx do
      sql =
        "SELECT arrow_cast(1.5,'Float16') a, arrow_cast(0.1,'Float16') b, " <>
          "arrow_cast(1e10,'Float16') c, arrow_cast(0.3333,'Float16') d, " <>
          "arrow_cast(-0.0,'Float16') e, arrow_cast(0.000000059604645,'Float16') f, " <>
          "arrow_cast(65504,'Float16') g, 2 z"

      assert same_rows(ctx, sql) === [
               %{
                 "a" => 1.5,
                 "b" => 0.099975586,
                 "c" => nil,
                 "d" => 0.33325195,
                 "e" => -0.0,
                 "f" => 5.9604645e-8,
                 "g" => 65_504.0,
                 "z" => 2
               }
             ]
    end

    test "Float32 is the shortest decimal that reads back, and infinity is a null cell", ctx do
      sql =
        "SELECT arrow_cast(0.1,'Float32') a, arrow_cast(3.14159,'Float32') b, " <>
          "arrow_cast(1e30,'Float32') c, arrow_cast(1e300,'Float32') d, 1.0/0.0 e"

      assert same_rows(ctx, sql) === [
               %{"a" => 0.1, "b" => 3.14159, "c" => 1.0e30, "d" => nil, "e" => nil}
             ]
    end
  end

  test "Date64 is a datetime and Date32 a date, as over HTTP", ctx do
    sql =
      "SELECT arrow_cast(86400500,'Date64') a, arrow_cast(1,'Date32') b, " <>
        "arrow_cast(-1,'Date32') c"

    assert same_rows(ctx, sql) === [
             %{"a" => ~U[1970-01-02 00:00:00.500000Z], "b" => "1970-01-02", "c" => "1969-12-31"}
           ]
  end

  describe "a refused query" do
    test "is %{status: 400, body: message} over Flight as over HTTP, the message prefixed", ctx do
      for sql <- ["selec 1", "SELECT * FROM no_such_table_fxi"] do
        assert {:error, %{status: 400, body: http_body}} = http(ctx, sql)
        assert {:error, %{status: 400, body: flight_body}} = flight(ctx, sql)
        assert String.contains?(flight_body, http_body), "#{sql}: #{flight_body}"
      end
    end

    test "a schema error is 500 over HTTP and 400 over Flight (INVALID_ARGUMENT)", ctx do
      sql = "SELECT no_such_column FROM (SELECT 1 AS one)"
      assert {:error, %{status: 500, body: http_body}} = http(ctx, sql)
      assert {:error, %{status: 400, body: flight_body}} = flight(ctx, sql)
      assert flight_body === "Error while logically planning query: " <> http_body
    end

    test "a database that does not exist is 404 over HTTP and 500 over Flight (INTERNAL)", ctx do
      assert {:error, %{status: 404}} =
               HTTP.query_sql(ctx.conn, "SELECT 1", database: "fxi_no_such_database")

      assert flight(ctx, "SELECT 1", database: "fxi_no_such_database") ===
               {:error,
                %{
                  status: 500,
                  body:
                    "Cannot retrieve database: External error: database not found: " <>
                      "fxi_no_such_database"
                }}
    end
  end

  test "an empty token is no authorization at all, which a server without auth accepts", ctx do
    conn = Keyword.put(ctx.conn, :token, "")

    assert HTTP.query_sql(conn, "SELECT 1 AS one",
             database: ctx.database,
             transport: :flight,
             flight_port: conn[:port],
             tls: false
           ) === {:ok, [%{"one" => 1}]}
  end
end
