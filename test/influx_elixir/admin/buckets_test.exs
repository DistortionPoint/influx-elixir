defmodule InfluxElixir.Admin.BucketsTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Admin.Buckets
  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(profile: :v2)
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  describe "create/3 and list/1" do
    test "a created bucket is listed with no expiry by default", %{conn: conn} do
      assert :ok = Buckets.create(conn, "my_bucket")

      assert {:ok, [bucket]} = Buckets.list(conn)
      assert bucket["name"] == "my_bucket"
      assert bucket["retentionRules"] == [%{"type" => "expire", "everySeconds" => 0}]
      assert is_binary(bucket["id"])
    end

    test ":retention is kept in seconds and listed as the bucket's rule", %{conn: conn} do
      assert :ok = Buckets.create(conn, "hourly", retention: 3600)

      assert {:ok, [%{"name" => "hourly", "retentionRules" => [%{"everySeconds" => 3600}]}]} =
               Buckets.list(conn)
    end

    test "a retention under one hour is refused the way InfluxDB 2 refuses it", %{conn: conn} do
      assert {:error, %{status: 500, body: body}} = Buckets.create(conn, "short", retention: 60)

      assert Jason.decode!(body)["message"] == "retention policy duration must be at least 1h0m0s"
      assert {:ok, []} = Buckets.list(conn)
    end
  end

  describe "delete/2" do
    test "removes the bucket; deleting it again is a 404", %{conn: conn} do
      :ok = Buckets.create(conn, "my_bucket")

      assert :ok = Buckets.delete(conn, "my_bucket")
      assert {:ok, []} = Buckets.list(conn)

      assert {:error, %{status: 404, body: "bucket not found: my_bucket"}} =
               Buckets.delete(conn, "my_bucket")
    end
  end
end
