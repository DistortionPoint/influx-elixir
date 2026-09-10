defmodule InfluxElixir.Admin.BucketsTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Admin.Buckets
  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(profile: :v2)
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
    test "lists created buckets by name", %{conn: conn} do
      :ok = Buckets.create(conn, "my_bucket")

      assert {:ok, buckets} = Buckets.list(conn)
      assert "my_bucket" in Enum.map(buckets, & &1["name"])
    end
  end

  describe "delete/2" do
    test "returns :ok on success", %{conn: conn} do
      assert :ok = Buckets.delete(conn, "my_bucket")
    end
  end
end
