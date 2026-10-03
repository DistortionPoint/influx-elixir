defmodule InfluxElixir.Client.Local.LifecycleAdminTest do
  use ExUnit.Case, async: true

  import InfluxElixir.TestSupport.LocalHelpers

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    {:ok, conn: conn}
  end

  # The time every row written with `@ts` reads back as.
  @ts 1_700_000_000_000_000_000

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  describe "supports?/2" do
    test "answers per profile, matching the capability table in the moduledoc" do
      {:ok, core} = Local.start(profile: :v3_core)
      {:ok, enterprise} = Local.start(profile: :v3_enterprise)
      {:ok, v2} = Local.start(profile: :v2)

      assert Local.supports?(core, :query_sql)
      refute Local.supports?(core, :query_flux)
      assert Local.supports?(core, :create_token)

      assert Local.supports?(enterprise, :create_token)
      refute Local.supports?(enterprise, :create_bucket)

      assert Local.supports?(v2, :query_flux)
      assert Local.supports?(v2, :create_bucket)
      refute Local.supports?(v2, :query_sql)

      # An operation no profile knows is simply unsupported.
      refute Local.supports?(core, :not_an_operation)
    end
  end

  describe "start/1 and stop/1" do
    test "a stopped connection can no longer be used" do
      {:ok, conn} = Local.start(databases: ["gone"])
      assert {:ok, :written} = Local.write(conn, "m v=1i 1")
      assert :ok = Local.stop(conn)

      assert_raise ArgumentError, fn ->
        Local.query_sql(conn, "SELECT v FROM m", database: "gone")
      end
    end

    test "pre-creates databases from options, listed with the engine's _internal" do
      {:ok, conn} = Local.start(databases: ["db2", "db1"])
      assert {:ok, dbs} = Local.list_databases(conn)
      assert Enum.map(dbs, & &1["name"]) === ["_internal", "db1", "db2"]
      Local.stop(conn)
    end

    test "stop is safe to call twice" do
      {:ok, conn} = Local.start()
      assert :ok = Local.stop(conn)
      assert :ok = Local.stop(conn)
    end

    test "each instance is isolated" do
      {:ok, conn_a} = Local.start(databases: ["only_a"])
      {:ok, conn_b} = Local.start(databases: ["only_b"])

      {:ok, dbs_a} = Local.list_databases(conn_a)
      {:ok, dbs_b} = Local.list_databases(conn_b)

      names_a = Enum.map(dbs_a, & &1["name"])
      names_b = Enum.map(dbs_b, & &1["name"])

      assert "only_a" in names_a
      refute "only_b" in names_a
      assert "only_b" in names_b
      refute "only_a" in names_b

      Local.stop(conn_a)
      Local.stop(conn_b)
    end

    test ":database is the connection-level default and is pre-created" do
      {:ok, conn} = Local.start(database: "metrics")
      assert {:ok, :written} = Local.write(conn, "m v=1i")

      assert Local.query_sql(conn, "SELECT v FROM m", database: "metrics") ===
               {:ok, [%{"v" => 1}]}

      assert {:ok, [_internal, %{"name" => "metrics"}]} = Local.list_databases(conn)
      Local.stop(conn)
    end

    test "without :database the first of :databases is the default, as over HTTP" do
      # Client.HTTP.init_connection/1 does the same; Local used to write to
      # a "default" database instead, so the same config diverged.
      {:ok, conn} = Local.start(databases: ["x", "y"])
      assert {:ok, :written} = Local.write(conn, "m v=1i")
      assert Local.query_sql(conn, "SELECT v FROM m", database: "x") === {:ok, [%{"v" => 1}]}
      Local.stop(conn)
    end

    test "pre-creates both :database and :databases when both are given" do
      {:ok, conn} = Local.start(database: "primary", databases: ["a", "b"])
      assert {:ok, dbs} = Local.list_databases(conn)
      assert Enum.map(dbs, & &1["name"]) === ["_internal", "a", "b", "primary"]
      assert {:ok, :written} = Local.write(conn, "m v=1i")
      assert {:ok, [_row]} = Local.query_sql(conn, "SELECT v FROM m", database: "primary")
      Local.stop(conn)
    end

    test "refuses a database the engine would refuse, with the engine's message" do
      assert_raise ArgumentError, ~r/a\.b: .*invalid character in database or rp name/, fn ->
        Local.start(databases: ["a.b"])
      end

      assert_raise ArgumentError, ~r/exceed limit of 5 databases/, fn ->
        Local.start(databases: Enum.map(1..6, &"db#{&1}"))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Connection-level :database resolution
  #
  # Regression coverage for issue #2: Local previously ignored connection
  # config's singular :database key. Both impls must resolve the same database
  # for the same config, so a typo (e.g. :default_database) cannot silently
  # pass tests against Local while breaking against HTTP.
  # ---------------------------------------------------------------------------

  describe "init_connection/1 — :database resolution parity" do
    test "init_connection passes :database through to conn-level default" do
      {:ok, conn} = Local.init_connection(database: "metrics")
      assert conn.database === "metrics"
      Local.stop(conn)
    end

    test "write uses connection-level :database when opts omits it" do
      {:ok, conn} = Local.init_connection(database: "primary")
      assert {:ok, :written} = Local.write(conn, "cpu value=1.0")

      {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM cpu")
      assert row["value"] === 1.0

      # The write created no other database.
      assert Local.list_databases(conn) ===
               {:ok, [%{"name" => "_internal"}, %{"name" => "primary"}]}

      Local.stop(conn)
    end

    test "opts :database still wins over connection-level default" do
      {:ok, conn} = Local.init_connection(database: "primary", databases: ["other"])

      assert {:ok, :written} =
               Local.write(conn, "cpu value=1.0", database: "other")

      assert {:error,
              %{status: 400, body: "Error during planning: table 'public.iox.cpu' not found"}} =
               Local.query_sql(conn, "SELECT * FROM cpu")

      assert {:ok, [_row]} =
               Local.query_sql(conn, "SELECT * FROM cpu", database: "other")

      Local.stop(conn)
    end

    test "with no database anywhere, each operation answers as Client.HTTP does" do
      # Local used to fall back to a "default" database the server does not
      # have: code that forgot `database:` passed against the double and
      # failed against InfluxDB.
      {:ok, conn} = Local.init_connection([])

      assert {:error, :no_database_specified} = Local.write(conn, "cpu value=1.0")
      assert {:error, :no_database_specified} = Local.query_sql(conn, "SELECT 1")
      assert {:error, :no_database_specified} = Local.execute_sql(conn, "SELECT 1")

      error =
        assert_raise InfluxElixir.StreamError, fn ->
          conn |> Local.query_sql_stream("SELECT 1") |> Enum.to_list()
        end

      assert error.kind === :no_database
    end

    test "init_connection ignores unknown keys without auto-pre-creating them" do
      # A typo like :default_database must not silently become a database.
      {:ok, conn} = Local.init_connection(default_database: "typo_db")
      assert Local.list_databases(conn) === {:ok, [%{"name" => "_internal"}]}
      assert {:error, :no_database_specified} = Local.write(conn, "m v=1i")
      Local.stop(conn)
    end
  end

  # Bucket admin covered by contract tests (contract_local_v2_test.exs)

  # Token admin covered by contract tests (contract_local_v3_enterprise_test.exs)

  # Health covered by contract tests (all contract_local_*_test.exs)

  # ---------------------------------------------------------------------------
  # execute_sql/3 — DELETE support
  # ---------------------------------------------------------------------------

  describe "execute_sql/3 — DELETE (v3_enterprise supports)" do
    setup do
      {:ok, conn} =
        Local.start(
          databases: ["del_db"],
          profile: :v3_enterprise
        )

      {:ok, :written} =
        Local.write(
          conn,
          "cpu,host=web01 value=10i 1\ncpu,host=web02 value=20i 2\ncpu,host=web01 value=30i 3",
          database: "del_db"
        )

      {:ok, conn: conn, db: "del_db"}
    end

    test "DELETE FROM removes every point and leaves an empty table", %{conn: conn, db: db} do
      assert Local.execute_sql(conn, "DELETE FROM cpu", database: db) ===
               {:ok, %{"rows_affected" => 3}}

      # The table stays in the catalog: no rows, not "table not found".
      assert {:ok, []} = Local.query_sql(conn, "SELECT * FROM cpu", database: db)
    end

    test "DELETE follows SQL's identifier rules, as SELECT does", %{conn: conn, db: db} do
      {:ok, :written} =
        Local.write(conn, "Cpu,Host=a v=1i 1\nCpu,Host=b v=2i 2", database: db)

      # Unquoted names fold: `Cpu` and `HOST` are table cpu and its host tag.
      assert Local.execute_sql(conn, ~s|DELETE FROM Cpu WHERE HOST = 'web01'|, database: db) ===
               {:ok, %{"rows_affected" => 2}}

      assert Local.query_sql(conn, "SELECT * FROM cpu", database: db) ===
               {:ok,
                [%{"host" => "web02", "time" => ~U[1970-01-01 00:00:00.000000Z], "value" => 20}]}

      assert Local.execute_sql(conn, ~s|DELETE FROM "Cpu" WHERE "Host" = 'a'|, database: db) ===
               {:ok, %{"rows_affected" => 1}}

      assert Local.query_sql(conn, ~s|SELECT * FROM "Cpu"|, database: db) ===
               {:ok, [%{"Host" => "b", "time" => ~U[1970-01-01 00:00:00.000000Z], "v" => 2}]}
    end

    test "DELETE FROM with WHERE removes matching points only",
         %{conn: conn, db: db} do
      assert Local.execute_sql(
               conn,
               "DELETE FROM cpu WHERE host = 'web01'",
               database: db
             ) === {:ok, %{"rows_affected" => 2}}

      assert Local.query_sql(conn, "SELECT * FROM cpu", database: db) ===
               {:ok,
                [%{"host" => "web02", "time" => ~U[1970-01-01 00:00:00.000000Z], "value" => 20}]}
    end
  end

  # ---------------------------------------------------------------------------
  # query_sql/3 — multi-database isolation
  # ---------------------------------------------------------------------------

  describe "query_sql/3 — multi-database isolation" do
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "db_a")
      :ok = Local.create_database(conn, "db_b")
      {:ok, :written} = Local.write(conn, "m value=1i #{@ts}", database: "db_a")
      {:ok, :written} = Local.write(conn, "m value=2i #{@ts}", database: "db_b")
      :ok
    end

    test "points in db_a are NOT visible from db_b", %{conn: conn} do
      assert Local.query_sql(conn, "SELECT * FROM m", database: "db_a") ===
               {:ok, [%{"time" => iq_time(0), "value" => 1}]}

      assert Local.query_sql(conn, "SELECT * FROM m", database: "db_b") ===
               {:ok, [%{"time" => iq_time(0), "value" => 2}]}
    end

    test "query without explicit database uses the connection's default", %{conn: conn} do
      # setup starts with databases: ["test_db"], the default as over HTTP.
      {:ok, :written} = Local.write(conn, "m value=99i #{@ts}", database: "test_db")

      assert Local.query_sql(conn, "SELECT * FROM m") ===
               {:ok, [%{"time" => iq_time(0), "value" => 99}]}
    end
  end

  # ---------------------------------------------------------------------------
  # start/1 — invalid profile validation
  # ---------------------------------------------------------------------------

  describe "start/1 — invalid profile" do
    test "raises ArgumentError naming the profile and listing the valid ones" do
      assert_raise ArgumentError,
                   "invalid profile: :invalid_thing. Must be one of: :v3_core, :v3_enterprise, :v2",
                   fn -> Local.start(profile: :invalid_thing) end
    end
  end

  # ---------------------------------------------------------------------------
  # execute_sql/3 — DELETE on non-existent measurement (v3_enterprise)
  # ---------------------------------------------------------------------------

  describe "execute_sql/3 — DELETE non-existent measurement" do
    setup do
      {:ok, conn} = Local.start(databases: ["del_ne_db"], profile: :v3_enterprise)
      {:ok, conn: conn, db: "del_ne_db"}
    end

    test "DELETE FROM non-existent measurement returns 0 rows affected",
         %{conn: conn, db: db} do
      assert Local.execute_sql(conn, "DELETE FROM nonexistent", database: db) ===
               {:ok, %{"rows_affected" => 0}}
    end

    test "DELETE honours OR, NOT and parentheses in its WHERE", %{conn: conn, db: db} do
      # The delete path folded predicates with the pre-boolean-expression
      # helper and crashed on an {:or, _} node.
      {:ok, :written} =
        Local.write(conn, "m,host=a v=1i\nm,host=b v=2i\nm,host=c v=3i\nm,host=d v=4i",
          database: db
        )

      assert Local.execute_sql(conn, "DELETE FROM m WHERE host = 'a' OR host = 'b'", database: db) ===
               {:ok, %{"rows_affected" => 2}}

      assert Local.execute_sql(conn, "DELETE FROM m WHERE NOT (host = 'c' OR v > 9)",
               database: db
             ) ===
               {:ok, %{"rows_affected" => 1}}

      assert Local.query_sql(conn, "SELECT host FROM m", database: db) ===
               {:ok, [%{"host" => "c"}]}
    end
  end
end
