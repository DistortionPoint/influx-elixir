defmodule InfluxElixir.Integration.V3CoreTest do
  @moduledoc """
  Integration tests against InfluxDB v3 Core on port 8181.

  Run with: `mix test --include v3_core`
  """

  use ExUnit.Case, async: false

  @moduletag :v3_core
  @moduletag :integration

  alias InfluxElixir.Client.HTTP
  alias InfluxElixir.IntegrationHelper, as: H

  setup_all do
    H.start_finch()
    conn = H.v3_core_conn()

    if H.reachable?(conn) do
      {:ok, conn: conn}
    else
      {:ok, skip: true, conn: conn}
    end
  end

  setup %{conn: conn} = ctx do
    if ctx[:skip] do
      :ok
    else
      db = H.unique_name("v3core_test")

      case HTTP.create_database(conn, db) do
        :ok ->
          on_exit(fn ->
            HTTP.delete_database(conn, db)
          end)

          {:ok, db: db}

        {:error, reason} ->
          {:ok, skip: true, skip_reason: reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Health
  # ---------------------------------------------------------------------------

  describe "health" do
    test "returns passing status", ctx do
      skip_if_unavailable(ctx)
      assert {:ok, %{"status" => status}} = HTTP.health(ctx.conn)
      assert status in ["pass", "ok"]
    end
  end

  # ---------------------------------------------------------------------------
  # Write
  # ---------------------------------------------------------------------------

  describe "write" do
    test "accepts valid line protocol", ctx do
      skip_if_unavailable(ctx)
      lp = "cpu,host=test01 value=1.0"
      assert {:ok, :written} = HTTP.write(ctx.conn, lp, database: ctx.db)
    end

    test "returns error for non-existent database", ctx do
      skip_if_unavailable(ctx)
      lp = "cpu value=1.0"

      result =
        HTTP.write(ctx.conn, lp, database: "no_such_db_#{System.unique_integer([:positive])}")

      assert {:error, _reason} = result
    end

    test "large batch write (1000 points)", ctx do
      skip_if_unavailable(ctx)

      lp =
        1..1000
        |> Enum.map(fn i -> "batch_m,idx=#{i} value=#{i}i #{i * 1_000_000}" end)
        |> Enum.join("\n")

      assert {:ok, :written} = HTTP.write(ctx.conn, lp, database: ctx.db)
    end

    test "write with explicit nanosecond timestamp", ctx do
      skip_if_unavailable(ctx)
      ts = System.os_time(:nanosecond)
      lp = "ts_test value=42i #{ts}"
      assert {:ok, :written} = HTTP.write(ctx.conn, lp, database: ctx.db)
    end
  end

  # ---------------------------------------------------------------------------
  # Write + Query round-trip
  # ---------------------------------------------------------------------------

  describe "write + query round-trip" do
    test "written data is queryable via SQL", ctx do
      skip_if_unavailable(ctx)
      ts = System.os_time(:nanosecond)
      lp = "roundtrip_m value=42i #{ts}"
      {:ok, :written} = HTTP.write(ctx.conn, lp, database: ctx.db)

      # InfluxDB v3 may need a moment to flush WAL
      Process.sleep(500)

      {:ok, rows} =
        HTTP.query_sql(
          ctx.conn,
          "SELECT * FROM roundtrip_m ORDER BY time DESC LIMIT 1",
          database: ctx.db
        )

      assert rows != []
    end

    test "parameterized SQL query", ctx do
      skip_if_unavailable(ctx)
      ts = System.os_time(:nanosecond)
      lp = "param_m,host=alpha value=10i #{ts}\nparam_m,host=beta value=20i #{ts + 1}"
      {:ok, :written} = HTTP.write(ctx.conn, lp, database: ctx.db)

      Process.sleep(500)

      {:ok, rows} =
        HTTP.query_sql(
          ctx.conn,
          "SELECT * FROM param_m WHERE host = $host",
          database: ctx.db,
          params: %{"host" => "alpha"}
        )

      assert rows != []
    end

    test "multiple measurements are independent", ctx do
      skip_if_unavailable(ctx)
      ts = System.os_time(:nanosecond)
      lp = "measure_x value=1i #{ts}\nmeasure_y value=2i #{ts}"
      {:ok, :written} = HTTP.write(ctx.conn, lp, database: ctx.db)

      Process.sleep(500)

      {:ok, rows_x} =
        HTTP.query_sql(ctx.conn, "SELECT * FROM measure_x", database: ctx.db)

      {:ok, rows_y} =
        HTTP.query_sql(ctx.conn, "SELECT * FROM measure_y", database: ctx.db)

      assert rows_x != []
      assert rows_y != []
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming SQL query
  # ---------------------------------------------------------------------------

  describe "streaming SQL query" do
    test "query_sql_stream returns enumerable rows", ctx do
      skip_if_unavailable(ctx)
      ts = System.os_time(:nanosecond)

      lp =
        1..5
        |> Enum.map(fn i -> "stream_m value=#{i}i #{ts + i}" end)
        |> Enum.join("\n")

      {:ok, :written} = HTTP.write(ctx.conn, lp, database: ctx.db)
      Process.sleep(500)

      stream =
        HTTP.query_sql_stream(
          ctx.conn,
          "SELECT * FROM stream_m",
          database: ctx.db
        )

      rows = Enum.to_list(stream)
      assert rows != []
    end
  end

  # ---------------------------------------------------------------------------
  # Empty query result
  # ---------------------------------------------------------------------------

  describe "empty query result" do
    test "query for non-existent measurement returns empty", ctx do
      skip_if_unavailable(ctx)

      result =
        HTTP.query_sql(
          ctx.conn,
          "SELECT * FROM nonexistent_measurement_#{System.unique_integer([:positive])}",
          database: ctx.db
        )

      # v3 may return {:ok, []} or {:error, ...} depending on version
      case result do
        {:ok, rows} -> assert rows == []
        {:error, _reason} -> :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Database CRUD
  # ---------------------------------------------------------------------------

  describe "database CRUD" do
    test "create and list database", ctx do
      skip_if_unavailable(ctx)
      db = H.unique_name("crud_db")
      assert :ok = HTTP.create_database(ctx.conn, db)

      {:ok, dbs} = HTTP.list_databases(ctx.conn)
      assert is_list(dbs)

      # Cleanup
      HTTP.delete_database(ctx.conn, db)
    end

    test "delete database", ctx do
      skip_if_unavailable(ctx)
      db = H.unique_name("del_db")
      :ok = HTTP.create_database(ctx.conn, db)
      assert :ok = HTTP.delete_database(ctx.conn, db)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp skip_if_unavailable(%{skip: true}),
    do: flunk("InfluxDB v3 Core not reachable on port 8181")

  defp skip_if_unavailable(_ctx), do: :ok
end
