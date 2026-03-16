defmodule InfluxElixir.Client.ProfileRejectionTest do
  @moduledoc """
  Verifies that each LocalClient profile correctly REJECTS operations
  it does NOT support by returning `{:error, :unsupported_operation}`.

  These tests only run against LocalClient — real backends reject natively.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  # ---------------------------------------------------------------------------
  # v3_core rejections
  # ---------------------------------------------------------------------------

  describe "v3_core rejects unsupported operations" do
    setup do
      {:ok, conn} = Local.start(profile: :v3_core)
      on_exit(fn -> Local.stop(conn) end)
      {:ok, conn: conn}
    end

    test "query_flux returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.query_flux(
                 conn,
                 "from(bucket: \"x\") |> range(start: -1h)"
               )
    end

    test "create_bucket returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.create_bucket(conn, "bkt")
    end

    test "list_buckets returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} = Local.list_buckets(conn)
    end

    test "delete_bucket returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.delete_bucket(conn, "bkt")
    end

    test "create_token returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.create_token(conn, "tok")
    end

    test "delete_token returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.delete_token(conn, "id")
    end
  end

  # ---------------------------------------------------------------------------
  # v3_enterprise rejections
  # ---------------------------------------------------------------------------

  describe "v3_enterprise rejects unsupported operations" do
    setup do
      {:ok, conn} = Local.start(profile: :v3_enterprise)
      on_exit(fn -> Local.stop(conn) end)
      {:ok, conn: conn}
    end

    test "query_flux returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.query_flux(
                 conn,
                 "from(bucket: \"x\") |> range(start: -1h)"
               )
    end

    test "create_bucket returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.create_bucket(conn, "bkt")
    end

    test "list_buckets returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} = Local.list_buckets(conn)
    end

    test "delete_bucket returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.delete_bucket(conn, "bkt")
    end
  end

  # ---------------------------------------------------------------------------
  # v2 rejections
  # ---------------------------------------------------------------------------

  describe "v2 rejects unsupported operations" do
    setup do
      {:ok, conn} = Local.start(profile: :v2)
      on_exit(fn -> Local.stop(conn) end)
      {:ok, conn: conn}
    end

    test "query_sql returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.query_sql(conn, "SELECT * FROM cpu")
    end

    test "query_sql_stream returns empty stream", %{conn: conn} do
      stream = Local.query_sql_stream(conn, "SELECT * FROM cpu")
      assert Enum.to_list(stream) == []
    end

    test "execute_sql returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.execute_sql(conn, "DELETE FROM cpu")
    end

    test "query_influxql returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.query_influxql(conn, "SELECT * FROM cpu")
    end

    test "create_database returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.create_database(conn, "db")
    end

    test "list_databases returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} = Local.list_databases(conn)
    end

    test "delete_database returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.delete_database(conn, "db")
    end

    test "create_token returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.create_token(conn, "tok")
    end

    test "delete_token returns {:error, :unsupported_operation}",
         %{conn: conn} do
      assert {:error, :unsupported_operation} =
               Local.delete_token(conn, "id")
    end
  end
end
