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

  # Waits until `pid` is contending for a lock: its reductions grow three times in a row
  # while the function it was started to run has not run. A process that is not yet in the
  # store's wait loop is parked in a `receive` and gains none; one that is in it wakes
  # again and again, so only a contender keeps growing. This reads nothing private of the
  # store, and no clock decides when it ends: each step waits for the growth itself.
  defp await_contending(pid) do
    {:reductions, first} = Process.info(pid, :reductions)

    Enum.reduce(1..3, first, fn _step, seen ->
      Await.until(fn ->
        case Process.info(pid, :reductions) do
          {:reductions, now} when now > seen -> now
          _gone_or_idle -> false
        end
      end)
    end)
  end

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

      # The holder is killed only once the waiter is contending for the lock it holds.
      await_contending(waiter.pid)
      refute Store.database?(table, "next")
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

      # The holder is released only once the waiter is contending for its lock, and the
      # waiter's function has not run.
      await_contending(waiter.pid)
      refute_received :waiter_ran
      refute Store.database?(table, "other")
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

      # The creation holds the lock until it is told to release it, so a drop that is
      # contending for the lock cannot have gone further, and the database it is to
      # remove is still there.
      await_contending(dropper.pid)
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
