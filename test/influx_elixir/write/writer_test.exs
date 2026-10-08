defmodule InfluxElixir.Write.WriterTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.TestSupport.ClosedPort
  alias InfluxElixir.Write.Writer

  setup do
    {:ok, conn} = Local.start(databases: ["w"])
    {:ok, conn: conn}
  end

  describe "write/3" do
    test "writes line protocol through the configured client", %{conn: conn} do
      assert {:ok, :written} = Writer.write(conn, "cpu value=1.0 1", database: "w")

      assert Local.query_sql(conn, "SELECT * FROM cpu", database: "w") ===
               {:ok, [%{"time" => ~U[1970-01-01 00:00:00.000000Z], "value" => 1.0}]}
    end

    test "a payload over 1 KB is gzipped and still stored in full", %{conn: conn} do
      # 100 distinct points; the client receives the compressed payload
      # with gzip: true (Local, like the servers, decompresses only then)
      # and stores every one.
      lp =
        Enum.map_join(
          1..100,
          "\n",
          &"cpu,host=h#{&1} value=#{&1}i #{1_700_000_000_000_000_000 + &1}"
        )

      assert byte_size(lp) > 1024

      assert {:ok, :written} = Writer.write(conn, lp, database: "w")

      assert Local.query_sql(conn, "SELECT COUNT(value) AS n FROM cpu", database: "w") ===
               {:ok, [%{"n" => 100}]}
    end

    # gzip: true reached the client with the payload uncompressed, and the
    # server refused it: "error decoding gzip stream" (verified).
    test "gzip: true compresses a payload of any size; false leaves a large one plain",
         %{conn: conn} do
      assert {:ok, :written} = Writer.write(conn, "small v=1i 1", database: "w", gzip: true)

      large = Enum.map_join(1..100, "\n", &"large v=#{&1}i #{&1}")
      assert byte_size(large) > 1024
      assert {:ok, :written} = Writer.write(conn, large, database: "w", gzip: false)

      assert Local.query_sql(conn, "SELECT COUNT(v) AS n FROM small", database: "w") ===
               {:ok, [%{"n" => 1}]}

      assert Local.query_sql(conn, "SELECT COUNT(v) AS n FROM large", database: "w") ===
               {:ok, [%{"n" => 100}]}
    end

    test "opts such as :precision reach the client", %{conn: conn} do
      assert {:ok, :written} =
               Writer.write(conn, "cpu value=1i 1700000000000", database: "w", precision: :ms)

      assert Local.query_sql(conn, "SELECT time FROM cpu", database: "w") ===
               {:ok, [%{"time" => ~U[2023-11-14 22:13:20.000000Z]}]}
    end

    # Only the HTTP client can answer with a refused connection, so this error proves
    # the :client opt was taken and used. Neither real client reads a :client key from its
    # options (HTTP builds its Finch options from :timeout and :pool_timeout alone, Local
    # reads named keys), so no real client answers differently were it forwarded.
    test "the :client opt selects the client" do
      port = ClosedPort.port()
      finch = :"writer_test_finch_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch, pools: %{"http://127.0.0.1:#{port}" => [size: 1]}})
      http_conn = [host: "127.0.0.1", port: port, scheme: :http, token: "t", finch_name: finch]

      assert Writer.write(http_conn, "cpu value=1.0",
               database: "w",
               client: InfluxElixir.Client.HTTP
             ) ===
               {:error, {:connection_error, %Mint.TransportError{reason: :econnrefused}}}
    end
  end
end
