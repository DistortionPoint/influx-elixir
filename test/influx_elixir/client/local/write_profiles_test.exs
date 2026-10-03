defmodule InfluxElixir.Client.Local.WriteProfilesTest do
  @moduledoc """
  What `Client.Local` does with a write that depends on the profile or on the
  double's own store. What the engines answer to a write (precision spellings,
  line protocol, duplicate points, `accept_partial`) is pinned for the double and
  for the real servers by `InfluxElixir.ClientContract` and
  `InfluxElixir.Contract.WriteRules`.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  describe "Client.Local: a write to a database that does not exist" do
    test "the :v3_enterprise profile creates it" do
      {:ok, conn} = Local.start(databases: ["ent_db"], profile: :v3_enterprise)

      assert {:ok, :written} = Local.write(conn, "cpu value=1.0", database: "auto_db")
      assert {:ok, dbs} = Local.list_databases(conn)
      assert Enum.map(dbs, & &1["name"]) === ["_internal", "auto_db", "ent_db"]
    end
  end

  describe "Client.Local: provided timestamps are stored, never replaced by the clock" do
    setup do
      {:ok, conn} = Local.start(databases: ["ts_keep_db"])
      {:ok, conn: conn, db: "ts_keep_db"}
    end

    test "six points written 900 seconds apart, out of order, read back in time order",
         %{conn: conn, db: db} do
      base_ns = 1_700_000_000_000_000_000
      step_ns = 900 * 1_000_000_000

      lines =
        for i <- [3, 0, 5, 1, 4, 2] do
          "candles,symbol=BTC close=#{100 + i}.0 #{base_ns + i * step_ns}"
        end

      {:ok, :written} = Local.write(conn, Enum.join(lines, "\n"), database: db)

      assert {:ok, rows} =
               Local.query_sql(conn, "SELECT * FROM candles ORDER BY time ASC", database: db)

      assert Enum.map(rows, &{&1["time"], &1["close"]}) === [
               {~U[2023-11-14 22:13:20.000000Z], 100.0},
               {~U[2023-11-14 22:28:20.000000Z], 101.0},
               {~U[2023-11-14 22:43:20.000000Z], 102.0},
               {~U[2023-11-14 22:58:20.000000Z], 103.0},
               {~U[2023-11-14 23:13:20.000000Z], 104.0},
               {~U[2023-11-14 23:28:20.000000Z], 105.0}
             ]
    end
  end

  # Enterprise runs DELETE where Core refuses it. No licensed server was available,
  # so the double's merge-then-delete is not verified against one.
  describe "Client.Local: DELETE on the :v3_enterprise profile" do
    test "removes a merged point and counts it once" do
      {:ok, conn} = Local.start(databases: ["dup"], profile: :v3_enterprise)
      t = "1700000000000000000"

      {:ok, :written} =
        Local.write(conn, "f,h=x v=1i #{t}\nf,h=x w=1i #{t}\nf,h=y v=9i #{t}", database: "dup")

      assert Local.execute_sql(conn, "DELETE FROM f WHERE w = 1", database: "dup") ===
               {:ok, %{"rows_affected" => 1}}

      assert Local.query_sql(conn, "SELECT * FROM f", database: "dup") ===
               {:ok, [%{"h" => "y", "time" => ~U[2023-11-14 22:13:20.000000Z], "v" => 9}]}
    end
  end

  describe "Client.Local: the :v2 profile" do
    test "has neither accept_partial nor no_sync and ignores them" do
      {:ok, conn} = Local.start(profile: :v2)
      :ok = Local.create_bucket(conn, "b")

      assert {:ok, :written} =
               Local.write(conn, "m v=1i 1", database: "b", accept_partial: "yes", no_sync: "yes")
    end
  end
end
