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

  These tests target `Store`'s lock directly, which is justified: a function that runs
  inside the lock and waits for a message cannot be built from the public API.

  A test that releases the holder must first know that the other process is waiting for
  the lock, or a broken lock would pass whenever that process arrived late (after the
  release, it would take a free lock). `waiting_for_lock/1` asks the process where it is
  (`Process.info/2` with `:current_function`) and polls with `Await.until/2` until it is in
  `Store.acquire/2`, the retry loop of the lock: a coupling to the module under test and to
  nothing else. That coupling is two facts about `Store`'s private lock, and a change to
  either breaks these tests loudly (the wait ends at the failure bound, it never passes):
  the retry loop is the function `{Store, :acquire, 2}`, and it retries on a short sleep of
  about 1 ms, so a waiter is inside `acquire/2` for as long as the lock is held. Rename the
  function or give the loop another shape and `waiting_for_lock/1` must follow. Each holder also runs a function that is inside the critical section from the
  moment it sends `:holding` until it returns, so an outcome that would break mutual
  exclusion is visible to it, or in the order the functions ran, whichever way the other
  process was scheduled.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.Store
  alias InfluxElixir.TestSupport.Await

  # The shared failure bound (`Await.bound/0`) on every wait for a message: far above what a
  # healthy run needs, so it only ever ends a failing one.
  @bound Await.bound()

  # The next of the two messages that tell the order the functions ran in: the mailbox is
  # scanned in arrival order, so this is the one that was sent first.
  defp next_run do
    receive do
      message when message in [:holder_done, :waiter_ran] -> message
    after
      @bound -> flunk("neither :holder_done nor :waiter_ran arrived")
    end
  end

  # Blocks until the process is in the lock's retry loop, `Store.acquire/2`: it has asked for
  # the lock and not been given it. The loop is a private function of the module under test.
  defp waiting_for_lock(pid) do
    Await.until(fn ->
      Process.info(pid, :current_function) === {:current_function, {Store, :acquire, 2}}
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

      assert_receive :holding, @bound

      # The waiter is started while the holder is inside the lock; whether it has reached
      # the lock when the holder is killed, its creation must go through, and the killed
      # holder's database must never exist.
      waiter =
        Task.async(fn ->
          send(parent, :waiter_started)
          Store.create_database(table, "next", fn _existing -> :ok end)
        end)

      assert_receive :waiter_started, @bound
      waiting_for_lock(waiter.pid)
      Process.exit(holder, :kill)

      assert Task.await(waiter, @bound) === :ok
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

      assert_receive :holding, @bound

      waiter =
        Task.async(fn ->
          send(parent, :waiter_started)

          Store.create_database(table, "other", fn _databases ->
            send(parent, :waiter_ran)
            :ok
          end)
        end)

      assert_receive :waiter_started, @bound
      waiting_for_lock(waiter.pid)
      send(holder.pid, :release)

      assert Task.await(holder, @bound) === :ok
      assert Task.await(waiter, @bound) === :ok
      assert Store.databases(table) === MapSet.new(["slow", "other"])

      # The waiter's function can only run once the holder's has returned, however the two
      # were scheduled: the holder's message is the first of the two to have been sent.
      assert next_run() === :holder_done
      assert next_run() === :waiter_ran
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

            # still inside the lock: no drop has removed the database in the meantime
            send(parent, {:still_there, Store.database?(table, "gone")})
            :ok
          end)
        end)

      assert_receive :holding, @bound

      dropper =
        Task.async(fn ->
          send(parent, :dropper_started)
          Store.drop_database(table, "gone")
        end)

      assert_receive :dropper_started, @bound
      waiting_for_lock(dropper.pid)
      send(holder.pid, :release)

      assert Task.await(holder, @bound) === :ok
      assert Task.await(dropper, @bound) === :ok
      assert_receive {:still_there, true}, @bound
      refute Store.database?(table, "gone")
      assert Store.retention(table, "gone") === nil
      assert Store.database?(table, "other")
    end
  end
end
