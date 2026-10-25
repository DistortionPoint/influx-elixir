defmodule InfluxElixirTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.TestSupport.{Await, Telemetry, Tokens}

  # The write's own time, so every row is compared whole, `time` included.
  @ts 1_700_000_000_000_000_000
  @time ~U[2023-11-14 22:13:20.000000Z]

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    Local.write(conn, "cpu value=1i #{@ts}", database: "test_db")
    {:ok, conn: conn}
  end

  # `:telemetry.span/3` adds a generated `telemetry_span_context` reference to the metadata of
  # every event it emits. Returns the metadata without it, once it is seen to be a reference.
  defp without_span_context(metadata) do
    {context, rest} = Map.pop(metadata, :telemetry_span_context)
    assert is_reference(context)
    rest
  end

  describe "client/0" do
    test "returns the configured client implementation and falls back to Client.HTTP when nil or non-module" do
      assert InfluxElixir.client() === InfluxElixir.Client.Local

      try do
        for invalid <- [nil, true, false, "Local", 123] do
          Application.put_env(:influx_elixir, :client, invalid)
          assert InfluxElixir.client() === InfluxElixir.Client.HTTP
        end
      after
        Application.put_env(:influx_elixir, :client, InfluxElixir.Client.Local)
      end
    end
  end

  describe "point/3" do
    test "constructs a Point struct with defaults" do
      point = InfluxElixir.point("cpu", %{"value" => 0.64})

      assert point === %InfluxElixir.Write.Point{
               measurement: "cpu",
               fields: %{"value" => 0.64},
               tags: %{},
               timestamp: nil
             }
    end

    test "constructs a Point struct with tags and timestamp" do
      point =
        InfluxElixir.point("cpu", %{"value" => 0.64},
          tags: %{"host" => "server01"},
          timestamp: 1_630_424_257_000_000_000
        )

      assert point === %InfluxElixir.Write.Point{
               measurement: "cpu",
               fields: %{"value" => 0.64},
               tags: %{"host" => "server01"},
               timestamp: 1_630_424_257_000_000_000
             }
    end
  end

  describe "write/3" do
    test "delegates to configured client", %{conn: conn} do
      assert InfluxElixir.write(conn, "cpu value=2i", database: "test_db") === {:ok, :written}
    end

    test "takes a Point, and a list of Points, as line protocol it encodes", %{conn: conn} do
      point = InfluxElixir.point("pts", %{"value" => 0.5}, tags: %{"h" => "a"}, timestamp: @ts)

      later =
        InfluxElixir.point("pts", %{"value" => 1.5}, tags: %{"h" => "a"}, timestamp: @ts + 1_000)

      assert InfluxElixir.write(conn, point, database: "test_db") === {:ok, :written}
      assert InfluxElixir.write(conn, [later], database: "test_db") === {:ok, :written}

      assert InfluxElixir.query_sql(conn, "SELECT * FROM pts ORDER BY time", database: "test_db") ===
               {:ok,
                [
                  %{"h" => "a", "time" => @time, "value" => 0.5},
                  %{"h" => "a", "time" => DateTime.add(@time, 1, :microsecond), "value" => 1.5}
                ]}
    end

    test "writes a Point's DateTime in the call's :precision", %{conn: conn} do
      point = InfluxElixir.point("pts", %{"v" => 1}, timestamp: ~U[2026-09-28 12:00:00.123456Z])

      assert InfluxElixir.write(conn, point, database: "test_db", precision: :second) ===
               {:ok, :written}

      assert InfluxElixir.query_sql(conn, "SELECT * FROM pts", database: "test_db") ===
               {:ok, [%{"time" => ~U[2026-09-28 12:00:00.000000Z], "v" => 1}]}
    end

    test "a Point that cannot be encoded is its error, not an invalid body", %{conn: conn} do
      assert InfluxElixir.write(conn, InfluxElixir.point("pts", %{}), database: "test_db") ===
               {:error, :empty_fields}
    end
  end

  describe "write_batched/3" do
    setup do
      name = :"write_batched_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        InfluxElixir.add_connection(name,
          database: "wb",
          batch_writer: [flush_interval_ms: 600_000, batch_size: 10]
        )

      on_exit(fn -> InfluxElixir.remove_connection(name) end)
      {:ok, name: name}
    end

    test "buffers Points and line protocol until the writer flushes", %{name: name} do
      point = InfluxElixir.point("wb", %{"v" => 1}, timestamp: 1_000)

      assert InfluxElixir.write_batched(name, point) === :ok

      assert InfluxElixir.write_batched(name, [
               InfluxElixir.point("wb", %{"v" => 2}, timestamp: 2_000)
             ]) === :ok

      assert InfluxElixir.write_batched(name, ["wb v=3i ", "3000"]) === :ok

      # Nothing has been taken from the buffer yet.
      assert InfluxElixir.stats(name) ===
               {:ok, %{total_writes: 0, total_errors: 0, total_bytes: 0}}

      assert InfluxElixir.flush(name) === :ok

      assert InfluxElixir.query_sql(name, "SELECT v FROM wb ORDER BY v") ===
               {:ok, [%{"v" => 1}, %{"v" => 2}, %{"v" => 3}]}

      assert InfluxElixir.stats(name) ===
               {:ok, %{total_writes: 1, total_errors: 0, total_bytes: 38}}
    end

    test "sync: true returns once the payload is written", %{name: name} do
      assert InfluxElixir.write_batched(name, "wb v=1i 1000", sync: true) === :ok

      assert InfluxElixir.query_sql(name, "SELECT v FROM wb") === {:ok, [%{"v" => 1}]}
    end

    test "sync: true is the write's own failure", %{name: name} do
      assert {:error, %{status: 400, body: body} = error} =
               InfluxElixir.write_batched(name, "!!!", sync: true)

      # Only the keys of the error are pinned here; the key order of its JSON body is not.
      assert error === %{status: 400, body: body}

      assert Jason.decode!(body) === %{
               "error" => "partial write of line protocol occurred",
               "data" => [
                 %{
                   "error_message" => "Expected at least one space character, got end of input",
                   "line_number" => 1,
                   "original_line" => "!!!"
                 }
               ]
             }
    end

    test "a payload that is none of the forms is an error and the writer keeps going",
         %{name: name} do
      assert InfluxElixir.write_batched(name, nil) === {:error, {:invalid_payload, nil}}

      assert InfluxElixir.write_batched(name, [:a], sync: true) ===
               {:error, {:invalid_payload, [:a]}}

      assert InfluxElixir.write_batched(name, "wb v=1i 1000", timeout: 10_000) === :ok
      assert InfluxElixir.flush(name) === :ok
      assert InfluxElixir.query_sql(name, "SELECT v FROM wb") === {:ok, [%{"v" => 1}]}
    end

    test "options that are not a keyword list or have invalid :sync or :timeout are an error",
         %{name: name} do
      for bad_opts <- [
            :sync,
            [sync: nil],
            [sync: "false"],
            [sync: :yes],
            [timeout: false],
            [timeout: -1],
            [timeout: "60000"]
          ] do
        assert InfluxElixir.write_batched(name, "wb v=1i 1000", bad_opts) ===
                 {:error, {:invalid_options, bad_opts}}
      end

      assert InfluxElixir.write_batched(name, "wb v=1i 1000", timeout: :infinity) === :ok
    end

    test "a connection without a batch writer, or a non-name connection, has none to write to",
         %{conn: conn} do
      name = :"write_batched_none_#{System.unique_integer([:positive])}"
      {:ok, _pid} = InfluxElixir.add_connection(name, database: "wb")
      on_exit(fn -> InfluxElixir.remove_connection(name) end)

      for no_writer <- [
            name,
            :never_registered_for_batching,
            nil,
            true,
            false,
            conn,
            [host: "h"]
          ] do
        assert InfluxElixir.write_batched(no_writer, "wb v=1i 1000") ===
                 {:error, :no_batch_writer}
      end
    end
  end

  describe "query_sql/3" do
    test "delegates to configured client", %{conn: conn} do
      assert InfluxElixir.query_sql(conn, "SELECT * FROM cpu", database: "test_db") ===
               {:ok, [%{"time" => @time, "value" => 1}]}
    end
  end

  describe "execute_sql/3" do
    test "delegates to configured client", %{conn: conn} do
      assert InfluxElixir.execute_sql(conn, "DELETE FROM cpu", database: "test_db") ===
               {:error, %{status: 400, body: "Error during planning: DML not supported: Delete"}}
    end
  end

  describe "query_influxql/3" do
    test "delegates to configured client", %{conn: conn} do
      assert InfluxElixir.query_influxql(conn, "SELECT * FROM cpu", database: "test_db") ===
               {:ok, [%{"iox::measurement" => "cpu", "time" => @time, "value" => 1}]}
    end
  end

  describe "query_flux/3" do
    test "delegates to configured client" do
      {:ok, v2_conn} = Local.start(profile: :v2)

      :ok = InfluxElixir.create_bucket(v2_conn, "test")

      assert InfluxElixir.write(v2_conn, "cpu value=1.0 #{@ts}", database: "test") ===
               {:ok, :written}

      assert InfluxElixir.query_flux(
               v2_conn,
               "from(bucket: \"test\") |> range(start: 0, stop: #{div(@ts, 1_000_000_000) + 1})"
             ) ===
               {:ok,
                [
                  %{
                    "result" => "_result",
                    "table" => 0,
                    "_start" => ~U[1970-01-01 00:00:00.000000Z],
                    "_stop" => ~U[2023-11-14 22:13:21.000000Z],
                    "_time" => @time,
                    "_measurement" => "cpu",
                    "_field" => "value",
                    "_value" => 1.0
                  }
                ]}
    end
  end

  describe "create_database/3" do
    test "delegates to configured client", %{conn: conn} do
      assert InfluxElixir.create_database(conn, "new_db") === :ok
    end
  end

  describe "list_databases/1" do
    test "delegates to configured client", %{conn: conn} do
      # The engine's own `_internal` database is always listed, sorted first.
      assert InfluxElixir.list_databases(conn) ===
               {:ok, [%{"name" => "_internal"}, %{"name" => "test_db"}]}
    end
  end

  describe "delete_database/2" do
    test "delegates to configured client", %{conn: conn} do
      assert InfluxElixir.delete_database(conn, "test_db") === :ok
    end
  end

  describe "create_bucket/3" do
    test "delegates to configured client" do
      {:ok, v2_conn} = Local.start(profile: :v2)
      assert InfluxElixir.create_bucket(v2_conn, "new_bucket") === :ok
    end
  end

  describe "list_buckets/1" do
    test "delegates to configured client" do
      {:ok, v2_conn} = Local.start(profile: :v2)
      :ok = InfluxElixir.create_bucket(v2_conn, "listed_bucket")

      # The ids are derived from SHA-256 hashes (the bucket's, and the org's) and the two
      # timestamps are the creation time: each is bound, then pinned by where it is used.
      assert {:ok, [bucket]} = InfluxElixir.list_buckets(v2_conn)
      %{"id" => id, "orgID" => org_id, "createdAt" => created_at} = bucket

      assert byte_size(id) === 16
      assert byte_size(org_id) === 16
      assert byte_size(created_at) === 30

      assert bucket === %{
               "id" => id,
               "orgID" => org_id,
               "type" => "user",
               "name" => "listed_bucket",
               "retentionRules" => [
                 %{
                   "type" => "expire",
                   "everySeconds" => 0,
                   "shardGroupDurationSeconds" => 604_800
                 }
               ],
               "createdAt" => created_at,
               "updatedAt" => created_at,
               "links" => %{
                 "labels" => "/api/v2/buckets/#{id}/labels",
                 "members" => "/api/v2/buckets/#{id}/members",
                 "org" => "/api/v2/orgs/#{org_id}",
                 "owners" => "/api/v2/buckets/#{id}/owners",
                 "self" => "/api/v2/buckets/#{id}",
                 "write" => "/api/v2/write?org=#{org_id}&bucket=#{id}"
               },
               "labels" => []
             }
    end
  end

  describe "delete_bucket/2" do
    test "delegates to configured client" do
      {:ok, v2_conn} = Local.start(profile: :v2)
      :ok = InfluxElixir.create_bucket(v2_conn, "test_bucket")
      assert InfluxElixir.delete_bucket(v2_conn, "test_bucket") === :ok

      assert InfluxElixir.delete_bucket(v2_conn, "test_bucket") ===
               {:error, %{status: 404, body: "bucket not found: test_bucket"}}
    end
  end

  describe "create_token/3 and delete_token/2" do
    test "create a named token and delete it by name", %{conn: conn} do
      # The secret, its hash and the creation time are generated: `public/1`
      # checks their shape (secret, 128 hex digits, RFC 3339) and drops them.
      assert conn |> InfluxElixir.create_token("facade") |> Tokens.public() ===
               {:ok, %{"id" => 1, "name" => "facade", "expiry" => nil}}

      assert InfluxElixir.delete_token(conn, "facade") === :ok

      assert InfluxElixir.delete_token(conn, "facade") ===
               {:error, %{status: 404, body: "the requested resource was not found: facade"}}
    end
  end

  describe "health/1" do
    test "delegates to configured client", %{conn: conn} do
      assert InfluxElixir.health(conn) === {:ok, %{"status" => "pass"}}
    end
  end

  describe "telemetry" do
    setup do
      Telemetry.attach([[:influx_elixir, :write, :stop], [:influx_elixir, :query, :stop]])
      :ok
    end

    test "write/3 emits a write span with database, bytes and point count", %{conn: conn} do
      lp = "cpu value=1i\ncpu value=2i"
      assert InfluxElixir.write(conn, lp, database: "test_db") === {:ok, :written}

      assert_received {:telemetry, [:influx_elixir, :write, :stop], _measurements, metadata}

      assert without_span_context(metadata) ===
               %{database: "test_db", bytes: byte_size(lp), point_count: 2, result: :ok}
    end

    test "query_sql/3 emits a query span with transport and row count", %{conn: conn} do
      assert InfluxElixir.query_sql(conn, "SELECT * FROM cpu", database: "test_db") ===
               {:ok, [%{"time" => @time, "value" => 1}]}

      assert_received {:telemetry, [:influx_elixir, :query, :stop], _measurements, metadata}

      assert without_span_context(metadata) ===
               %{
                 database: "test_db",
                 transport: InfluxElixir.Client.Local,
                 row_count: 1,
                 result: :ok
               }
    end

    test "a client error is a :stop with result: :error, not an exception", %{conn: conn} do
      assert InfluxElixir.query_sql(conn, "SELECT * FROM nope", database: "test_db") ===
               {:error,
                %{
                  status: 400,
                  body: "Error during planning: table 'public.iox.nope' not found"
                }}

      assert_received {:telemetry, [:influx_elixir, :query, :stop], _measurements, metadata}

      # No row_count: the result was an error, not a list of rows.
      assert without_span_context(metadata) ===
               %{database: "test_db", transport: InfluxElixir.Client.Local, result: :error}
    end
  end

  describe "flush/1 and stats/1" do
    test "a running connection configured without a batch writer has none to flush" do
      name = :"no_writer_#{System.unique_integer([:positive])}"
      {:ok, _pid} = InfluxElixir.add_connection(name, database: "no_writer_db")
      on_exit(fn -> InfluxElixir.remove_connection(name) end)

      assert InfluxElixir.write(name, "cpu v=1i") === {:ok, :written}
      assert InfluxElixir.flush(name) === {:error, :no_batch_writer}
      assert InfluxElixir.stats(name) === {:error, :no_batch_writer}
    end

    test "an unregistered connection name or non-name connection has no batch writer",
         %{conn: conn} do
      name = :"never_registered_#{System.unique_integer([:positive])}"

      for no_writer <- [name, nil, true, false, conn, [host: "h"]] do
        assert InfluxElixir.flush(no_writer) === {:error, :no_batch_writer}
        assert InfluxElixir.stats(no_writer) === {:error, :no_batch_writer}
      end

      for bad_timeout <- [false, nil, -1, "5000"] do
        assert InfluxElixir.flush(name, bad_timeout) === {:error, {:invalid_timeout, bad_timeout}}
        assert InfluxElixir.stats(name, bad_timeout) === {:error, {:invalid_timeout, bad_timeout}}
      end
    end

    test "flush/2 and stats/2 accept :infinity as timeout" do
      name = :"infinity_writer_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        InfluxElixir.add_connection(name, batch_writer: [flush_interval_ms: 600_000])

      on_exit(fn -> InfluxElixir.remove_connection(name) end)

      assert InfluxElixir.flush(name, :infinity) === :ok

      assert InfluxElixir.stats(name, :infinity) ===
               {:ok, %{total_writes: 0, total_errors: 0, total_bytes: 0}}
    end

    # The writer answers the calls it has taken before it stops; a call still in its mailbox
    # exited the caller with `{:shutdown, {GenServer, :call, _}}`.
    test "a writer that stops with the call in its mailbox has none" do
      name = :"stopping_writer_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        InfluxElixir.add_connection(name, batch_writer: [flush_interval_ms: 600_000])

      on_exit(fn -> InfluxElixir.remove_connection(name) end)

      for call <- [&InfluxElixir.stats/1, &InfluxElixir.flush/1] do
        # The supervisor restarts the writer each round stops.
        writer = Await.until(fn -> Process.whereis(:"influx_elixir_#{name}_batch_writer") end)
        :ok = :sys.suspend(writer)
        task = Task.async(fn -> call.(name) end)

        Await.until(fn ->
          Process.info(writer, :message_queue_len) === {:message_queue_len, 1}
        end)

        :ok = GenServer.stop(writer, :shutdown)

        assert Task.await(task, Await.bound()) === {:error, :no_batch_writer}
      end
    end
  end

  describe "connection-level default database" do
    test "write and query functions fall back to it when opts omit :database" do
      {:ok, conn} = Local.start(database: "dflt_db")

      assert InfluxElixir.write(conn, "cpu value=1i #{@ts}") === {:ok, :written}

      row = %{"time" => @time, "value" => 1}

      assert InfluxElixir.query_sql(conn, "SELECT * FROM cpu") === {:ok, [row]}

      assert InfluxElixir.query_influxql(conn, "SELECT * FROM cpu") ===
               {:ok, [Map.put(row, "iox::measurement", "cpu")]}

      assert InfluxElixir.execute_sql(conn, "SELECT * FROM cpu") === {:ok, [row]}

      assert conn |> InfluxElixir.query_sql_stream("SELECT * FROM cpu") |> Enum.to_list() ===
               [row]
    end
  end

  describe "add_connection/2 and remove_connection/1" do
    test "remove_connection/1 for an unknown name returns {:error, :not_found}" do
      assert InfluxElixir.remove_connection(:never_added_connection) === {:error, :not_found}
    end

    test "remove_connection/1 succeeds when the registry entry is already gone" do
      name = :"orphan_registry_#{System.unique_integer([:positive])}"
      {:ok, _pid} = InfluxElixir.add_connection(name, [])

      InfluxElixir.Connection.delete(name)

      assert InfluxElixir.remove_connection(name) === :ok
    end

    test "a connection added at runtime is usable by name until it is removed" do
      # The supervisor registry is VM-global: a unique name keeps this test
      # isolated from every other async module.
      name = :"dynamic_test_#{System.unique_integer([:positive])}"

      # The pid of the connection's supervisor is generated.
      assert {:ok, pid} = InfluxElixir.add_connection(name, database: "dyn")
      assert is_pid(pid)
      assert InfluxElixir.write(name, "cpu v=1i") === {:ok, :written}
      assert InfluxElixir.query_sql(name, "SELECT v FROM cpu") === {:ok, [%{"v" => 1}]}

      assert InfluxElixir.remove_connection(name) === :ok
      refute Process.alive?(pid)

      message =
        "no InfluxElixir connection named #{inspect(name)}: list it under " <>
          "`config :influx_elixir, :connections` or add it with " <>
          "InfluxElixir.add_connection/2"

      assert_raise ArgumentError, message, fn ->
        InfluxElixir.write(name, "cpu v=2i")
      end
    end
  end

  describe "resolve_connection/1" do
    test "passes through a keyword config, map, nil, or boolean unchanged", %{conn: conn} do
      for passthrough <- [conn, [host: "h"], nil, true, false] do
        assert InfluxElixir.resolve_connection(passthrough) === passthrough
      end

      for bad_conn <- [nil, true, false] do
        assert InfluxElixir.write(bad_conn, "cpu v=1i") ===
                 {:error, {:invalid_connection, bad_conn}}

        assert InfluxElixir.query_sql(bad_conn, "SELECT 1") ===
                 {:error, {:invalid_connection, bad_conn}}

        assert InfluxElixir.health(bad_conn) ===
                 {:error,
                  %{
                    status: 400,
                    body: "Client.Local: the connection is not one Client.Local.start/1 returned"
                  }}
      end
    end

    test "resolves an atom name via Connection registry" do
      name = :"resolve_test_#{System.unique_integer([:positive])}"
      config = [host: "resolve-host", token: "t"]

      InfluxElixir.Connection.put(name, config)
      on_exit(fn -> InfluxElixir.Connection.delete(name) end)

      assert InfluxElixir.resolve_connection(name) === config
    end

    test "raises ArgumentError for unregistered atom name" do
      message =
        "no InfluxElixir connection named :no_such_connection: list it under " <>
          "`config :influx_elixir, :connections` or add it with " <>
          "InfluxElixir.add_connection/2"

      assert_raise ArgumentError, message, fn ->
        InfluxElixir.resolve_connection(:no_such_connection)
      end
    end
  end

  describe "facade with named connections" do
    test "health/1 accepts an atom name" do
      name = :"facade_test_#{System.unique_integer([:positive])}"

      # Register a LocalClient connection under the name
      {:ok, local_conn} = Local.start(databases: ["facade_db"])

      InfluxElixir.Connection.put(name, local_conn)
      on_exit(fn -> InfluxElixir.Connection.delete(name) end)

      assert InfluxElixir.health(name) === {:ok, %{"status" => "pass"}}
    end

    test "write/3 and query_sql/3 accept an atom name" do
      name = :"facade_rw_#{System.unique_integer([:positive])}"

      {:ok, local_conn} = Local.start(databases: ["facade_rw_db"])

      InfluxElixir.Connection.put(name, local_conn)
      on_exit(fn -> InfluxElixir.Connection.delete(name) end)

      assert InfluxElixir.write(name, "cpu value=1.0", database: "facade_rw_db") ===
               {:ok, :written}

      assert {:ok, [row]} =
               InfluxElixir.query_sql(name, "SELECT * FROM cpu", database: "facade_rw_db")

      # The write had no timestamp, so its `time` is assigned by the write.
      assert {%DateTime{}, rest} = Map.pop(row, "time")
      assert rest === %{"value" => 1.0}
    end
  end
end
