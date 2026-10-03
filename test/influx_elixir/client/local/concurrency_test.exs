defmodule InfluxElixir.Client.Local.ConcurrencyTest do
  use ExUnit.Case, async: true

  import InfluxElixir.TestSupport.LocalHelpers

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["test_db"])
    {:ok, conn: conn}
  end

  # ---------------------------------------------------------------------------
  # Regression coverage for bug reports filed by consuming applications.
  # Each scenario reproduces a real downstream failure reported against this
  # library (see the GitHub issues and CHANGELOG for the original reports).
  # ---------------------------------------------------------------------------

  describe "write/3 and create_database/2 — concurrent callers" do
    # Points were stored as one list per measurement and every write
    # read-modify-wrote it, so parallel writers overwrote each other:
    # 159 of 480 rows survived while every call returned {:ok, :written}.
    setup %{conn: conn} do
      :ok = Local.create_database(conn, "shared_db")
      {:ok, db: "shared_db"}
    end

    test "every one of 480 parallel writes is stored", %{conn: conn, db: db} do
      writers = 8
      per_writer = 60

      tasks =
        for w <- 1..writers do
          Task.async(fn ->
            for i <- 1..per_writer do
              {:ok, :written} =
                Local.write(conn, "prices,symbol=W#{w}X#{i} price=1.0", database: db)
            end
          end)
        end

      Enum.each(tasks, &Task.await(&1, 30_000))

      expected = for w <- 1..writers, i <- 1..per_writer, do: "W#{w}X#{i}"
      symbols = column_values(conn, db, "SELECT symbol FROM prices", "symbol")

      assert Enum.sort(symbols) === Enum.sort(expected)
    end

    test "parallel create_database calls all register" do
      # Enterprise: Core allows only 5 databases.
      {:ok, conn} = Local.start(profile: :v3_enterprise)
      names = for i <- 1..16, do: "par_db_#{i}"

      names
      |> Enum.map(&Task.async(fn -> Local.create_database(conn, &1) end))
      |> Enum.each(&Task.await/1)

      assert {:ok, dbs} = Local.list_databases(conn)
      assert dbs |> Enum.map(& &1["name"]) |> Enum.sort() === Enum.sort(["_internal" | names])
    end

    test "a DELETE running beside writes only removes what it matched", %{db: db} do
      {:ok, ent} = Local.start(databases: [db], profile: :v3_enterprise)

      # Explicit timestamps: the untimed lines of one write share a time
      # and would be one point, as on the engines.
      {:ok, :written} =
        Local.write(ent, Enum.map_join(1..50, "\n", &"m,k=old v=#{&1}i #{&1}"), database: db)

      writer =
        Task.async(fn ->
          for i <- 1..50, do: Local.write(ent, "m,k=new v=#{i}i #{100 + i}", database: db)
        end)

      {:ok, %{"rows_affected" => 50}} =
        Local.execute_sql(ent, "DELETE FROM m WHERE k = 'old'", database: db)

      Task.await(writer)

      assert {:ok, rows} = Local.query_sql(ent, "SELECT k, v FROM m ORDER BY v", database: db)
      assert Enum.map(rows, &{&1["k"], &1["v"]}) === for(i <- 1..50, do: {"new", i})
    end
  end
end
