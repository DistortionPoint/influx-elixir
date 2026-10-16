defmodule InfluxElixir.Admin.BucketsTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Admin.Buckets
  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(profile: :v2)
    {:ok, conn: conn}
  end

  describe "create/3 and list/1" do
    test "a created bucket is listed with no expiry by default", %{conn: conn} do
      assert :ok = Buckets.create(conn, "my_bucket")

      assert {:ok, [bucket]} = Buckets.list(conn)
      assert bucket["name"] === "my_bucket"
      # With no expiry a bucket's shard groups are a week long (verified).
      assert bucket["retentionRules"] === [
               %{"type" => "expire", "everySeconds" => 0, "shardGroupDurationSeconds" => 604_800}
             ]

      # 16 lowercase hex digits, as InfluxDB 2's; the double derives it from the name.
      assert bucket["id"] === "251c400b498dbc3b"
      assert bucket["links"]["self"] === "/api/v2/buckets/" <> bucket["id"]
      assert bucket["type"] === "user"
    end

    test ":retention is kept in seconds and listed as the bucket's rule", %{conn: conn} do
      assert :ok = Buckets.create(conn, "hourly", retention: 3600)

      # The ids, links and timestamps are generated; the name and the rules are the subject.
      assert {:ok, [bucket]} = Buckets.list(conn)

      assert Map.take(bucket, ["name", "retentionRules"]) ===
               %{
                 "name" => "hourly",
                 "retentionRules" => [
                   %{
                     "type" => "expire",
                     "everySeconds" => 3600,
                     "shardGroupDurationSeconds" => 3600
                   }
                 ]
               }
    end

    test "a retention under one hour is refused the way InfluxDB 2 refuses it", %{conn: conn} do
      assert {:error, %{status: 500, body: body}} = Buckets.create(conn, "short", retention: 60)

      assert Jason.decode!(body)["message"] ===
               "retention policy duration must be at least 1h0m0s"

      assert {:ok, []} = Buckets.list(conn)
    end

    # InfluxDB 2.7 answers a bucket that exists with a 422 conflict (verified), which is
    # success here; the bucket keeps the retention it was created with. The conflict comes
    # before the hour's minimum, so a short retention is no 500 for it either.
    test "a bucket that exists is :ok and kept as it was", %{conn: conn} do
      :ok = Buckets.create(conn, "kept", retention: 7200)

      assert Buckets.create(conn, "kept", retention: 3600) === :ok
      assert Buckets.create(conn, "kept", retention: 60) === :ok

      assert {:ok, [%{"retentionRules" => rules}]} = Buckets.list(conn)

      assert rules === [
               %{"type" => "expire", "everySeconds" => 7200, "shardGroupDurationSeconds" => 3600}
             ]
    end

    test "a negative retention is the engine's 422, one not an integer refused by name, nil 0",
         %{conn: conn} do
      # Both verified on InfluxDB 2.7: `null` is read as no expiry.
      assert Buckets.create(conn, "neg", retention: -5) ===
               {:error,
                %{
                  status: 422,
                  body:
                    ~s({"code":"unprocessable entity",) <>
                      ~s("message":"expiration seconds cannot be negative"})
                }}

      for retention <- [7200.5, "2h"] do
        assert Buckets.create(conn, "odd", retention: retention) ===
                 {:error,
                  %{
                    status: 400,
                    body:
                      "Client.Local: retention: must be a whole number of seconds, " <>
                        "got #{inspect(retention)}"
                  }}
      end

      assert Buckets.create(conn, "none", retention: nil) === :ok
      assert {:ok, [%{"name" => "none", "retentionRules" => rules}]} = Buckets.list(conn)

      assert rules === [
               %{"type" => "expire", "everySeconds" => 0, "shardGroupDurationSeconds" => 604_800}
             ]
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
