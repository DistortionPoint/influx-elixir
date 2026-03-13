defmodule InfluxElixir.Admin.BucketsTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Admin.Buckets
  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start()
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  describe "create/3" do
    test "returns :ok on success", %{conn: conn} do
      assert :ok = Buckets.create(conn, "my_bucket")
    end

    test "accepts optional opts", %{conn: conn} do
      assert :ok = Buckets.create(conn, "my_bucket", retention_seconds: 3600)
    end

    test "defaults opts to empty list", %{conn: conn} do
      assert :ok = Buckets.create(conn, "another_bucket")
    end
  end

  describe "list/1" do
    test "returns {:ok, list} from client", %{conn: conn} do
      assert {:ok, buckets} = Buckets.list(conn)
      assert is_list(buckets)
    end
  end

  describe "delete/2" do
    test "returns :ok on success", %{conn: conn} do
      assert :ok = Buckets.delete(conn, "my_bucket")
    end
  end
end
