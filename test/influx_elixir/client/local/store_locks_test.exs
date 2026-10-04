defmodule InfluxElixir.Client.Local.StoreLocksTest do
  @moduledoc """
  The one part of `Client.Local.Store` that no public call can reach: how its
  creation locks behave while a caller-supplied function holds one. A public
  `create_database` or `create_token` runs the store's own function inside the
  lock, so a holder that is killed, that takes its lock again or that waits for a
  message can only be built by handing the store such a function directly.

  Everything else the store does (what is stored, merged, listed, limited,
  deleted, numbered) is observable through `Client.Local` and is tested there, in
  `InfluxElixir.Client.Local.ConcurrencyTest` and in the contracts.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.Store
  alias InfluxElixir.TestSupport.Await

  describe "a lock holder" do
    test "that is killed does not block the next creator" do
      table = Store.new([])
      parent = self()

      holder =
        spawn(fn ->
          Store.create_database(table, "held", fn _existing ->
            send(parent, :holding)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :holding, 30_000

      waiter = Task.async(fn -> Store.create_database(table, "next", fn _existing -> :ok end) end)
      Process.exit(holder, :kill)

      assert Task.await(waiter, 30_000) === :ok
      assert Store.database?(table, "next")
      refute Store.database?(table, "held")
    end

    test "that takes its own lock again raises instead of spinning" do
      table = Store.new([])

      assert_raise RuntimeError, ~r/databases lock is already held by this process/, fn ->
        Store.create_database(table, "outer", fn _databases ->
          Store.create_database(table, "inner", fn _databases -> :ok end)
        end)
      end

      assert_raise RuntimeError, ~r/tokens lock is already held by this process/, fn ->
        Store.create_token(table, "outer", fn _id ->
          Store.create_token(table, "inner", fn id -> %{"id" => id} end)
        end)
      end

      # the raise released the locks: neither resource is stuck, nor half made
      refute Store.database?(table, "outer")
      assert :ok = Store.create_database(table, "later", fn _databases -> :ok end)
      assert {:ok, %{"id" => 1}} = Store.create_token(table, "later", &%{"id" => &1})
    end

    test "is waited for by another process, which then runs after it" do
      table = Store.new([])
      parent = self()

      holder =
        Task.async(fn ->
          Store.create_database(table, "slow", fn _databases ->
            send(parent, :holding)

            receive do
              :release -> send(parent, :holder_done)
            end

            :ok
          end)
        end)

      assert_receive :holding, 30_000

      waiter =
        Task.async(fn ->
          send(parent, :waiter_started)

          Store.create_database(table, "other", fn _databases ->
            send(parent, :waiter_ran)
            :ok
          end)
        end)

      assert_receive :waiter_started, 30_000
      send(holder.pid, :release)

      assert Task.await(holder, 30_000) === :ok
      assert Task.await(waiter, 30_000) === :ok
      assert Store.databases(table) === MapSet.new(["slow", "other"])

      # Mailbox order is the order the two functions ran in: the waiter's
      # function can only run once the holder's has returned.
      assert Process.info(self(), :messages) === {:messages, [:holder_done, :waiter_ran]}
    end

    test "a drop of a database is not run while a creation holds the databases lock, " <>
           "and then removes only its own database" do
      table = Store.new([])
      parent = self()
      assert :ok = Store.create_database(table, "gone", fn _databases -> :ok end, 3600)

      holder =
        Task.async(fn ->
          Store.create_database(table, "other", fn _databases ->
            send(parent, :holding)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :holding, 30_000

      dropper = Task.async(fn -> Store.drop_database(table, "gone") end)

      # The drop is waiting on the lock once it is inside the store's wait loop; the
      # creation holds the lock until it is told to release it, so the drop cannot
      # have gone further, and the database it is to remove is still there.
      Await.until(fn ->
        Process.info(dropper.pid, :current_function) === {:current_function, {Store, :acquire, 2}}
      end)

      assert Store.database?(table, "gone")

      send(holder.pid, :release)

      assert Task.await(holder, 30_000) === :ok
      assert Task.await(dropper, 30_000) === :ok
      refute Store.database?(table, "gone")
      assert Store.retention(table, "gone") === nil
      assert Store.database?(table, "other")
    end
  end
end
