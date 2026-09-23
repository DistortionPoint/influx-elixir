defmodule InfluxElixir.Write.WriterTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Write.Writer

  setup do
    {:ok, conn} = Local.start(databases: ["w"])
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  describe "write/3" do
    test "writes line protocol through the configured client", %{conn: conn} do
      assert {:ok, :written} = Writer.write(conn, "cpu value=1.0", database: "w")

      assert {:ok, [%{"value" => 1.0}]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: "w")
    end

    test "a payload over 1 KB is gzipped and still stored in full", %{conn: conn} do
      # 100 distinct points; the client receives the compressed payload
      # (Local decompresses on the gzip magic bytes) and stores every one.
      lp = Enum.map_join(1..100, "\n", &"cpu,host=h#{&1} value=#{&1}i 17000000000000000#{&1}")
      assert byte_size(lp) > 1024

      assert {:ok, :written} = Writer.write(conn, lp, database: "w")

      assert {:ok, [%{"n" => 100}]} =
               Local.query_sql(conn, "SELECT COUNT(value) AS n FROM cpu", database: "w")
    end

    test "opts such as :precision reach the client", %{conn: conn} do
      assert {:ok, :written} =
               Writer.write(conn, "cpu value=1i 1700000000000", database: "w", precision: :ms)

      assert {:ok, [%{"time" => ~U[2023-11-14 22:13:20.000000Z]}]} =
               Local.query_sql(conn, "SELECT time FROM cpu", database: "w")
    end

    test "the :client opt selects the client and is not forwarded to it" do
      finch = :"writer_test_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch, pools: %{default: [size: 1]}})
      http_conn = [host: "127.0.0.1", port: 1, scheme: :http, token: "t", finch_name: finch]

      # Only the HTTP client can produce a transport error.
      assert {:error, {:connection_error, _reason}} =
               Writer.write(http_conn, "cpu value=1.0",
                 database: "w",
                 client: InfluxElixir.Client.HTTP
               )
    end
  end
end
