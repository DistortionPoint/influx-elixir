defmodule InfluxElixir.ContractTest do
  @moduledoc """
  Contract tests verifying `LocalClient` and a real InfluxDB behave identically.

  These tests exercise the public client contract — write, query, and admin —
  asserting on response shapes and semantics rather than implementation details.

  ## Running

  Against `LocalClient` (default, no external service needed):

      mix test test/integration/contract_test.exs

  Against a real InfluxDB v3 instance:

      mix test --include integration test/integration/contract_test.exs

  Real-InfluxDB tests are tagged `@tag :integration` and excluded from CI by
  default (see `test/test_helper.exs`).
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Write.{LineProtocol, Point}

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    {:ok, conn} = Local.start(databases: ["contract_db"])
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn, database: "contract_db"}
  end

  # ---------------------------------------------------------------------------
  # Database administration
  # ---------------------------------------------------------------------------

  describe "create_database/3" do
    test "returns :ok for a new database name", %{conn: conn} do
      assert :ok == Local.create_database(conn, "new_db", [])
    end

    test "is idempotent — creating a duplicate name returns :ok", %{conn: conn} do
      assert :ok == Local.create_database(conn, "dup_db", [])
      assert :ok == Local.create_database(conn, "dup_db", [])
    end
  end

  describe "list_databases/1" do
    test "includes databases that were pre-created at start", %{conn: conn} do
      {:ok, dbs} = Local.list_databases(conn)

      names = Enum.map(dbs, & &1.name)
      assert "contract_db" in names
    end

    test "includes newly created databases", %{conn: conn} do
      :ok = Local.create_database(conn, "extra_db", [])
      {:ok, dbs} = Local.list_databases(conn)

      names = Enum.map(dbs, & &1.name)
      assert "extra_db" in names
    end

    test "each entry is a map with a :name key containing a string", %{conn: conn} do
      {:ok, dbs} = Local.list_databases(conn)

      Enum.each(dbs, fn db ->
        assert is_map(db)
        assert is_binary(db.name)
      end)
    end
  end

  describe "delete_database/2" do
    test "returns :ok for an existing database", %{conn: conn} do
      :ok = Local.create_database(conn, "to_delete", [])
      assert :ok == Local.delete_database(conn, "to_delete")
    end

    test "returns {:error, map} with status 404 for a non-existent database", %{conn: conn} do
      assert {:error, %{status: 404}} = Local.delete_database(conn, "ghost_db")
    end

    test "database is no longer listed after deletion", %{conn: conn} do
      :ok = Local.create_database(conn, "gone_db", [])
      :ok = Local.delete_database(conn, "gone_db")
      {:ok, dbs} = Local.list_databases(conn)
      names = Enum.map(dbs, & &1.name)
      refute "gone_db" in names
    end
  end

  # ---------------------------------------------------------------------------
  # Write contract
  # ---------------------------------------------------------------------------

  describe "write/3" do
    test "accepts valid line protocol and returns {:ok, :written}", %{conn: conn} do
      lp = "cpu,host=server01 value=0.64 1630424257000000000"
      assert {:ok, :written} == Local.write(conn, lp, database: "contract_db")
    end

    test "returns {:error, map} with status 404 for an unknown database",
         %{conn: conn} do
      lp = "cpu value=1.0"
      assert {:error, %{status: 404}} = Local.write(conn, lp, database: "ghost_db")
    end

    test "returns {:error, map} with status 400 for malformed line protocol",
         %{conn: conn} do
      assert {:error, %{status: 400}} =
               Local.write(conn, "this is not line protocol!!", database: "contract_db")
    end

    test "accepts gzip-compressed line protocol", %{conn: conn} do
      lp = "cpu value=1.0"
      compressed = :zlib.gzip(lp)

      assert {:ok, :written} ==
               Local.write(conn, compressed, database: "contract_db")
    end
  end

  # ---------------------------------------------------------------------------
  # Field type round-trips (write then query)
  # ---------------------------------------------------------------------------

  describe "field type round-trips" do
    test "integer field survives write/query cycle", %{conn: conn} do
      ts = System.os_time(:nanosecond)
      lp = "roundtrip,type=int count=#{ts}i #{ts}"
      {:ok, :written} = Local.write(conn, lp, database: "contract_db")

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM roundtrip WHERE type = 'int' LIMIT 1",
          database: "contract_db"
        )

      assert rows != []
      assert is_integer(hd(rows)["count"])
      assert hd(rows)["count"] == ts
    end

    test "float field survives write/query cycle", %{conn: conn} do
      lp = "roundtrip,type=float ratio=3.14"
      {:ok, :written} = Local.write(conn, lp, database: "contract_db")

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM roundtrip WHERE type = 'float' LIMIT 1",
          database: "contract_db"
        )

      assert rows != []
      assert_in_delta hd(rows)["ratio"], 3.14, 1.0e-10
    end

    test "string field survives write/query cycle", %{conn: conn} do
      lp = ~s(roundtrip,type=string label="hello world")
      {:ok, :written} = Local.write(conn, lp, database: "contract_db")

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM roundtrip WHERE type = 'string' LIMIT 1",
          database: "contract_db"
        )

      assert rows != []
      assert hd(rows)["label"] == "hello world"
    end

    test "boolean field survives write/query cycle", %{conn: conn} do
      lp = "roundtrip,type=bool active=true"
      {:ok, :written} = Local.write(conn, lp, database: "contract_db")

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM roundtrip WHERE type = 'bool' LIMIT 1",
          database: "contract_db"
        )

      assert rows != []
      assert hd(rows)["active"] == true
    end

    test "large integer (> 2^53) round-trips without precision loss", %{conn: conn} do
      # Integers beyond JS Number.MAX_SAFE_INTEGER — must stay exact
      large = 9_007_199_254_740_993
      lp = "roundtrip,type=bigint value=#{large}i"
      {:ok, :written} = Local.write(conn, lp, database: "contract_db")

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM roundtrip WHERE type = 'bigint' LIMIT 1",
          database: "contract_db"
        )

      assert rows != []
      assert hd(rows)["value"] == large
    end
  end

  # ---------------------------------------------------------------------------
  # Query semantics
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — basic SELECT" do
    test "returns empty list when no rows match", %{conn: conn} do
      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM empty_measurement",
          database: "contract_db"
        )

      assert rows == []
    end

    test "LIMIT restricts the number of returned rows", %{conn: conn} do
      Enum.each(1..5, fn i ->
        Local.write(conn, "limited_m value=#{i}i", database: "contract_db")
      end)

      {:ok, rows} =
        Local.query_sql(conn, "SELECT * FROM limited_m LIMIT 2", database: "contract_db")

      assert length(rows) == 2
    end

    test "ORDER BY time DESC returns most-recent rows first", %{conn: conn} do
      # Write points with explicit, ascending timestamps
      Enum.each([100, 200, 300], fn ts ->
        Local.write(conn, "ordered_m value=#{ts}i #{ts}", database: "contract_db")
      end)

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM ordered_m ORDER BY time DESC",
          database: "contract_db"
        )

      timestamps = Enum.map(rows, & &1["time"])
      assert timestamps == Enum.sort(timestamps, :desc)
    end

    test "WHERE clause filters by tag value", %{conn: conn} do
      Local.write(conn, "tagged_m,host=alpha value=1i", database: "contract_db")
      Local.write(conn, "tagged_m,host=beta value=2i", database: "contract_db")

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM tagged_m WHERE host = 'alpha'",
          database: "contract_db"
        )

      assert length(rows) == 1
      assert hd(rows)["value"] == 1
    end
  end

  describe "query_sql/3 — multiple measurements" do
    test "querying one measurement does not return rows from another", %{conn: conn} do
      Local.write(conn, "measure_a value=1i", database: "contract_db")
      Local.write(conn, "measure_b value=2i", database: "contract_db")

      {:ok, rows_a} =
        Local.query_sql(conn, "SELECT * FROM measure_a", database: "contract_db")

      {:ok, rows_b} =
        Local.query_sql(conn, "SELECT * FROM measure_b", database: "contract_db")

      assert length(rows_a) == 1
      assert length(rows_b) == 1
      assert hd(rows_a)["value"] == 1
      assert hd(rows_b)["value"] == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Point struct + LineProtocol integration
  # ---------------------------------------------------------------------------

  describe "Point + LineProtocol → write → query" do
    test "a Point encoded to line protocol can be written and queried back", %{conn: conn} do
      point =
        Point.new(
          "sensors",
          %{"temp" => 22.5, "humidity" => 55},
          tags: %{"location" => "lab"},
          timestamp: 1_630_424_257_000_000_000
        )

      {:ok, lp} = LineProtocol.encode(point)
      assert {:ok, :written} == Local.write(conn, lp, database: "contract_db")

      {:ok, rows} =
        Local.query_sql(
          conn,
          "SELECT * FROM sensors WHERE location = 'lab' LIMIT 1",
          database: "contract_db"
        )

      assert rows != []
      row = hd(rows)
      assert_in_delta row["temp"], 22.5, 1.0e-10
      assert row["humidity"] == 55
    end
  end

  # ---------------------------------------------------------------------------
  # Health check contract
  # ---------------------------------------------------------------------------

  describe "health/1" do
    test "returns {:ok, map} with a :status key", %{conn: conn} do
      {:ok, result} = Local.health(conn)
      assert is_map(result)
      assert Map.has_key?(result, :status)
    end

    test "reports a passing status", %{conn: conn} do
      {:ok, %{status: status}} = Local.health(conn)
      assert status == "pass"
    end
  end

  # ---------------------------------------------------------------------------
  # Integration tag — same assertions against real InfluxDB
  # ---------------------------------------------------------------------------

  @tag :integration
  test "real InfluxDB: health returns passing status" do
    conn = build_real_conn()
    {:ok, %{status: status}} = InfluxElixir.Client.HTTP.health(conn)
    assert status in ["pass", "ok"]
  end

  @tag :integration
  test "real InfluxDB: write and query round-trip" do
    conn = build_real_conn()
    db = integration_database()
    lp = "contract_check value=42i"

    assert {:ok, :written} == InfluxElixir.Client.HTTP.write(conn, lp, database: db)

    {:ok, rows} =
      InfluxElixir.Client.HTTP.query_sql(
        conn,
        "SELECT * FROM contract_check LIMIT 1",
        database: db
      )

    assert rows != []
  end

  # ---------------------------------------------------------------------------
  # Private helpers used only by @tag :integration tests
  # ---------------------------------------------------------------------------

  @spec build_real_conn() :: map()
  defp build_real_conn do
    %{
      host: System.get_env("INFLUXDB_HOST", "http://localhost:8086"),
      token: System.fetch_env!("INFLUXDB_TOKEN"),
      org: System.get_env("INFLUXDB_ORG", "")
    }
  end

  @spec integration_database() :: binary()
  defp integration_database do
    System.get_env("INFLUXDB_DATABASE", "contract_test")
  end
end
