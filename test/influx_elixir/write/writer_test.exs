defmodule InfluxElixir.Write.WriterTest do
  use ExUnit.Case, async: true

  doctest InfluxElixir.Write.Writer

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Connection
  alias InfluxElixir.TestSupport.{ClosedPort, Telemetry}
  alias InfluxElixir.Write.{Point, Writer}

  setup do
    {:ok, conn} = Local.start(databases: ["w"])
    {:ok, conn: conn}
  end

  describe "write/3 — bodies and options it cannot read" do
    test "iodata is the text it stands for, gzipped or not", %{conn: conn} do
      assert Writer.write(conn, ["cpu value=", ["1.0", ?\s], "1"], database: "w") ===
               {:ok, :written}

      assert Writer.write(conn, ["cpu value=2.0 2"], database: "w", gzip: true) ===
               {:ok, :written}

      # Both timestamps (1ns and 2ns) read back as the same microsecond.
      assert Local.query_sql(conn, "SELECT * FROM cpu ORDER BY value", database: "w") ===
               {:ok,
                [
                  %{"time" => ~U[1970-01-01 00:00:00.000000Z], "value" => 1.0},
                  %{"time" => ~U[1970-01-01 00:00:00.000000Z], "value" => 2.0}
                ]}
    end

    test "a body that is not iodata is the client's answer, never a raise", %{conn: conn} do
      for body <- [5, %{}, [:a], nil] do
        assert Writer.write(conn, body, database: "w") ===
                 {:error, %{status: 400, body: "Client.Local: the line protocol is not a string"}}
      end
    end

    test "options that are not a keyword list are the client's answer, never a raise",
         %{conn: conn} do
      for opts <- [nil, :x, [1]] do
        assert Writer.write(conn, "cpu value=1.0 1", opts) ===
                 {:error,
                  %{status: 400, body: "Client.Local: the options are not a keyword list"}}
      end
    end
  end

  describe "write/3" do
    test "writes line protocol through the configured client", %{conn: conn} do
      assert Writer.write(conn, "cpu value=1.0 1", database: "w") === {:ok, :written}

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

      assert Writer.write(conn, lp, database: "w") === {:ok, :written}

      assert Local.query_sql(conn, "SELECT COUNT(value) AS n FROM cpu", database: "w") ===
               {:ok, [%{"n" => 100}]}
    end

    # gzip: true reached the client with the payload uncompressed, and the
    # server refused it: "error decoding gzip stream" (verified).
    test "gzip: true compresses a payload of any size; false leaves a large one plain",
         %{conn: conn} do
      assert Writer.write(conn, "small v=1i 1", database: "w", gzip: true) === {:ok, :written}

      large = Enum.map_join(1..100, "\n", &"large v=#{&1}i #{&1}")
      assert byte_size(large) > 1024
      assert Writer.write(conn, large, database: "w", gzip: false) === {:ok, :written}

      assert Local.query_sql(conn, "SELECT COUNT(v) AS n FROM small", database: "w") ===
               {:ok, [%{"n" => 1}]}

      assert Local.query_sql(conn, "SELECT COUNT(v) AS n FROM large", database: "w") ===
               {:ok, [%{"n" => 100}]}
    end

    test "opts such as :precision reach the client", %{conn: conn} do
      assert Writer.write(conn, "cpu value=1i 1700000000000", database: "w", precision: :ms) ===
               {:ok, :written}

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

  describe "write/3 — Points" do
    defp point(value, ns), do: Point.new("cpu", %{"value" => value}, timestamp: ns)

    defp row(value, us),
      do: %{"time" => DateTime.from_unix!(us, :microsecond), "value" => value}

    test "a Point, or a list of them, is encoded for the call", %{conn: conn} do
      assert Writer.write(conn, point(1.0, 1_000), database: "w") === {:ok, :written}

      assert Writer.write(conn, [point(2.0, 2_000), point(3.0, 3_000)], database: "w") ===
               {:ok, :written}

      assert Local.query_sql(conn, "SELECT * FROM cpu ORDER BY time", database: "w") ===
               {:ok, [row(1.0, 1), row(2.0, 2), row(3.0, 3)]}
    end

    test "a DateTime timestamp is written in the call's :precision", %{conn: conn} do
      timestamp = ~U[2026-09-28 12:00:00.123456Z]
      point = Point.new("cpu", %{"value" => 1}, timestamp: timestamp)

      assert Writer.write(conn, point, database: "w", precision: :millisecond) ===
               {:ok, :written}

      assert Local.query_sql(conn, "SELECT * FROM cpu", database: "w") ===
               {:ok, [%{"time" => ~U[2026-09-28 12:00:00.123000Z], "value" => 1}]}
    end

    test "a point is encoded for the connection's server" do
      # InfluxDB 2 and 3 read a backslash in a tag value differently: the same point is two
      # different lines, and each server stores the tag as it was given.
      point = Point.new("m", %{"f" => 1}, tags: %{"t" => "a\\b"}, timestamp: 5)

      {:ok, v3} = Local.start(profile: :v3_core, databases: ["w"])
      assert Writer.write(v3, point, database: "w", precision: :second) === {:ok, :written}

      assert Local.query_sql(v3, "SELECT t, f FROM m", database: "w") ===
               {:ok, [%{"t" => "a\\b", "f" => 1}]}

      {:ok, v2} = Local.start(profile: :v2, databases: ["b"])
      assert Writer.write(v2, point, database: "b", precision: :second) === {:ok, :written}

      assert Local.query_flux(v2, ~s[from(bucket: "b") |> range(start: 5, stop: 6)], []) ===
               {:ok,
                [
                  %{
                    "result" => "_result",
                    "table" => 0,
                    "_measurement" => "m",
                    "_field" => "f",
                    "_start" => ~U[1970-01-01 00:00:05.000000Z],
                    "_stop" => ~U[1970-01-01 00:00:06.000000Z],
                    "_time" => ~U[1970-01-01 00:00:05.000000Z],
                    "_value" => 1,
                    "t" => "a\\b"
                  }
                ]}
    end

    test "a point that cannot be encoded is the encoder's error, and nothing is sent",
         %{conn: conn} do
      assert Writer.write(conn, Point.new("cpu", %{}), database: "w") === {:error, :empty_fields}

      assert Writer.write(conn, [point(1.0, 1_000), :not_a_point], database: "w") ===
               {:error, {:invalid_point, :not_a_point}}

      assert Local.query_sql(conn, "SELECT * FROM cpu", database: "w") ===
               {:error,
                %{status: 400, body: "Error during planning: table 'public.iox.cpu' not found"}}
    end
  end

  describe "write/3 — a connection's name" do
    setup %{conn: conn} do
      name = :"writer_named_#{System.unique_integer([:positive])}"
      :ok = Connection.put(name, conn)
      on_exit(fn -> Connection.delete(name) end)
      {:ok, name: name}
    end

    test "is the connection it names", %{conn: conn, name: name} do
      assert Writer.write(name, "cpu value=1.0 1000", database: "w") === {:ok, :written}
      assert Writer.write(name, point(2.0, 2_000), database: "w") === {:ok, :written}

      assert Local.query_sql(conn, "SELECT * FROM cpu ORDER BY time", database: "w") ===
               {:ok, [row(1.0, 1), row(2.0, 2)]}
    end

    test "a term that is no connection (a host name, a number) is invalid, never a raise" do
      for connection <- ["hostname", 5, {:a}] do
        assert Writer.write(connection, "m v=1") === {:error, {:invalid_connection, connection}}

        assert InfluxElixir.write(connection, "m v=1") ===
                 {:error, {:invalid_connection, connection}}
      end
    end

    test "that is not registered is {:invalid_connection, name}, never a raise" do
      name = :"writer_unregistered_#{System.unique_integer([:positive])}"

      assert Writer.write(name, "cpu value=1.0 1000") === {:error, {:invalid_connection, name}}
    end
  end

  describe "write/3 — telemetry" do
    setup do
      Telemetry.attach([[:influx_elixir, :write, :stop]])
      :ok
    end

    test "point_count is the lines of the body, a trailing newline not one more",
         %{conn: conn} do
      for {body, count} <- [
            {"cpu value=1i 1", 1},
            {"cpu value=1i 1\ncpu value=2i 2", 2},
            {"cpu value=1i 1\ncpu value=2i 2\n", 2},
            {"cpu value=1i 1\ncpu value=2i 2\ncpu value=3i 3", 3}
          ] do
        assert Writer.write(conn, body, database: "w") === {:ok, :written}

        assert_receive {:telemetry, [:influx_elixir, :write, :stop], _measurements, metadata}

        # The span context is a generated reference.
        {context, rest} = Map.pop(metadata, :telemetry_span_context)
        assert is_reference(context)

        assert rest ===
                 %{database: "w", point_count: count, bytes: byte_size(body), result: :ok}
      end
    end

    test "an empty body has no lines", %{conn: conn} do
      assert Writer.write(conn, "", database: "w") ===
               {:error, %{status: 400, body: "incoming write was empty"}}

      assert_receive {:telemetry, [:influx_elixir, :write, :stop], _measurements, metadata}
      {_context, rest} = Map.pop(metadata, :telemetry_span_context)
      assert rest === %{database: "w", point_count: 0, bytes: 0, result: :error}
    end
  end
end
