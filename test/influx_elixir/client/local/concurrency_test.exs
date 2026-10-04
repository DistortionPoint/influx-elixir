defmodule InfluxElixir.Client.Local.ConcurrencyTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.TestSupport.Tokens, as: TokenShape

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
      assert {:ok, rows} = Local.query_sql(conn, "SELECT symbol FROM prices", database: db)
      symbols = Enum.map(rows, & &1["symbol"])

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

  # Enough tasks at once that a race shows without a lucky schedule.
  @tasks 16

  describe "Client.Local: first writes and creates to new databases at once" do
    test "stop at Core's five" do
      {:ok, conn} = Local.start(profile: :v3_core)

      results =
        at_once(@tasks, fn n -> Local.write(conn, "m v=1 #{n}", database: "limit#{n}") end)

      assert Enum.count(results, &(&1 === {:ok, :written})) === 5
      assert Enum.count(results, &match?({:error, %{status: 422}}, &1)) === @tasks - 5

      assert {:ok, listed} = Local.list_databases(conn)
      assert length(listed) === 6
    end

    test "cannot pass Core's limit through create_database either" do
      {:ok, conn} = Local.start(profile: :v3_core)

      results = at_once(@tasks, fn n -> Local.create_database(conn, "db#{n}") end)

      assert Enum.count(results, &(&1 === :ok)) === 5
      assert Enum.count(results, &match?({:error, %{status: 422}}, &1)) === @tasks - 5
    end
  end

  describe "Client.Local: tokens created and deleted at once" do
    setup do
      {:ok, conn} = Local.start(profile: :v3_core)
      {:ok, conn: conn}
    end

    test "different names get the ids 1 up, each its own", %{conn: conn} do
      ids =
        at_once(@tasks, fn n ->
          assert {:ok, %{"id" => id}} = Local.create_token(conn, "tok#{n}")
          id
        end)

      assert Enum.sort(ids) === Enum.to_list(1..@tasks)
    end

    test "one name makes one token and spends one id", %{conn: conn} do
      results = at_once(@tasks, fn _n -> Local.create_token(conn, "same") end)

      assert Enum.count(results, &match?({:ok, %{"id" => 1}}, &1)) === 1
      assert Enum.count(results, &match?({:error, %{status: 409}}, &1)) === @tasks - 1
      assert {:ok, %{"id" => 2}} = Local.create_token(conn, "next")
    end

    test "a taken name, and _admin, are a 409 that spends no id", %{conn: conn} do
      # The secret, its hash and the creation time are generated: `public/1`
      # checks their shape and drops them.
      assert conn |> Local.create_token("tok1") |> TokenShape.public() ===
               {:ok, %{"id" => 1, "name" => "tok1", "expiry" => nil}}

      assert {:error, %{status: 409}} = Local.create_token(conn, "tok1")
      assert {:error, %{status: 409}} = Local.create_token(conn, "_admin")

      assert conn |> Local.create_token("tok2") |> TokenShape.public() ===
               {:ok, %{"id" => 2, "name" => "tok2", "expiry" => nil}}
    end

    test "a deleted name is free again with the next id", %{conn: conn} do
      assert {:ok, %{"id" => 1}} = Local.create_token(conn, "t")
      assert :ok = Local.delete_token(conn, "t")
      assert {:error, %{status: 404}} = Local.delete_token(conn, "t")
      assert {:ok, %{"id" => 2}} = Local.create_token(conn, "t")
    end

    test "a token deleted while it is created ends as one of the two orders left it",
         %{conn: conn} do
      for round <- 1..16 do
        name = "race#{round}"

        [created, deleted] =
          at_once(2, fn
            1 -> Local.create_token(conn, name)
            2 -> Local.delete_token(conn, name)
          end)

        # Delete first: nothing to delete, and the token stays. Create first: the
        # delete removes it, and a second delete finds nothing.
        case {created, deleted} do
          {{:ok, _token}, {:error, %{status: 404}}} ->
            assert :ok = Local.delete_token(conn, name)

          {{:ok, _token}, :ok} ->
            assert {:error, %{status: 404}} = Local.delete_token(conn, name)
        end
      end
    end
  end

  describe "Client.Local: writers of one series at once" do
    test "leave one point per time" do
      {:ok, conn} = Local.start(databases: ["db"], profile: :v3_core)
      payload = Enum.map_join(1..500, "\n", &"m,h=a v=#{&1} #{&1}")

      results = at_once(@tasks, fn _n -> Local.write(conn, payload, database: "db") end)
      assert Enum.all?(results, &(&1 === {:ok, :written}))

      assert {:ok, rows} = Local.query_influxql(conn, "SELECT v FROM m", database: "db")
      assert Enum.map(rows, & &1["v"]) === Enum.map(1..500, &(&1 * 1.0))
    end
  end

  describe "Client.Local: a point written again after a DELETE" do
    test "is not merged with the deleted one" do
      {:ok, conn} = Local.start(databases: ["db"], profile: :v3_enterprise)

      {:ok, :written} = Local.write(conn, "m,h=x v=1i 5", database: "db")
      {:ok, :written} = Local.write(conn, "m,h=x w=2i 5", database: "db")

      assert {:ok, %{"rows_affected" => 1}} =
               Local.execute_sql(conn, "DELETE FROM m", database: "db")

      {:ok, :written} = Local.write(conn, "m,h=x v=3i 5", database: "db")

      assert {:ok, [row]} = Local.query_sql(conn, "SELECT * FROM m", database: "db")
      assert Map.take(row, ["h", "v", "w"]) === %{"h" => "x", "v" => 3}
    end
  end

  # Runs `fun.(n)` for n in 1..count, each in a task of its own. The tasks all
  # wait for one message before they start, so they start together, and the
  # results come back in order of n.
  defp at_once(count, fun) do
    parent = self()

    tasks =
      for n <- 1..count do
        Task.async(fn ->
          send(parent, {:ready, n})

          receive do
            :go -> fun.(n)
          end
        end)
      end

    for n <- 1..count, do: assert_receive({:ready, ^n}, 30_000)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 30_000))
  end
end
