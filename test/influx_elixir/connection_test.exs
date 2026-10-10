defmodule InfluxElixir.ConnectionTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Connection

  # Only api_version/1's examples run: the others put a fixed name (`:test`) in the registry
  # every test shares.
  doctest InfluxElixir.Connection, only: [api_version: 1]

  # Each test gets a unique atom prefix so async tests do not collide in
  # :persistent_term, which is a global VM-wide store.
  defp unique_name(suffix) do
    :"influx_conn_test_#{System.unique_integer([:positive])}_#{suffix}"
  end

  # ---------------------------------------------------------------------------
  # put/2 + get/1
  # ---------------------------------------------------------------------------

  describe "put/2 and get/1" do
    test "stores a config and retrieves it by name" do
      name = unique_name(:put_get)
      config = [host: "localhost", token: "abc", port: 8086]

      on_exit(fn -> Connection.delete(name) end)

      assert :ok = Connection.put(name, config)
      assert {:ok, retrieved} = Connection.get(name)
      assert retrieved[:host] === "localhost"
      assert retrieved[:token] === "abc"
      assert retrieved[:port] === 8086
    end

    test "stored config is returned verbatim as a keyword list" do
      name = unique_name(:verbatim)
      config = [host: "h", token: "t", scheme: :http, port: 9999, pool_size: 5]

      on_exit(fn -> Connection.delete(name) end)

      Connection.put(name, config)
      assert {:ok, got} = Connection.get(name)
      assert got === config
    end

    test "overwriting a name replaces the stored config" do
      name = unique_name(:overwrite)
      on_exit(fn -> Connection.delete(name) end)

      Connection.put(name, host: "first", token: "t")
      Connection.put(name, host: "second", token: "t")

      assert {:ok, got} = Connection.get(name)
      assert got[:host] === "second"
    end

    test "different names are stored independently" do
      name_a = unique_name(:indep_a)
      name_b = unique_name(:indep_b)

      on_exit(fn ->
        Connection.delete(name_a)
        Connection.delete(name_b)
      end)

      Connection.put(name_a, host: "alpha", token: "ta")
      Connection.put(name_b, host: "beta", token: "tb")

      assert {:ok, a} = Connection.get(name_a)
      assert {:ok, b} = Connection.get(name_b)
      assert a[:host] === "alpha"
      assert b[:host] === "beta"
    end
  end

  # ---------------------------------------------------------------------------
  # get/1 — not found
  # ---------------------------------------------------------------------------

  describe "get/1 — unknown name" do
    test "returns {:error, :not_found} for a name that was never stored" do
      name = unique_name(:not_found)
      assert {:error, :not_found} = Connection.get(name)
    end

    test "returns {:error, :not_found} after the entry has been deleted" do
      name = unique_name(:deleted_then_get)

      Connection.put(name, host: "h", token: "t")
      Connection.delete(name)

      assert {:error, :not_found} = Connection.get(name)
    end
  end

  # ---------------------------------------------------------------------------
  # fetch!/1
  # ---------------------------------------------------------------------------

  describe "fetch!/1" do
    test "returns the stored config when the name exists" do
      name = unique_name(:fetch_ok)
      on_exit(fn -> Connection.delete(name) end)

      Connection.put(name, host: "h", token: "t")
      config = Connection.fetch!(name)
      assert config[:host] === "h"
    end

    test "raises an ArgumentError that names the missing connection" do
      name = unique_name(:fetch_raise)

      assert_raise ArgumentError,
                   ~r/no InfluxElixir connection named :influx_conn_test_.*_fetch_raise/,
                   fn ->
                     Connection.fetch!(name)
                   end
    end

    test "raises ArgumentError after the entry has been deleted" do
      name = unique_name(:fetch_after_delete)

      Connection.put(name, host: "h", token: "t")
      Connection.delete(name)

      assert_raise ArgumentError, fn ->
        Connection.fetch!(name)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # delete/1
  # ---------------------------------------------------------------------------

  describe "delete/1" do
    test "removes a stored config so subsequent get returns :not_found" do
      name = unique_name(:delete_removes)

      Connection.put(name, host: "h", token: "t")
      assert :ok = Connection.delete(name)
      assert {:error, :not_found} = Connection.get(name)
    end

    test "returns :ok when deleting a name that does not exist" do
      name = unique_name(:delete_nonexistent)
      assert :ok = Connection.delete(name)
    end

    test "is idempotent — second delete also returns :ok" do
      name = unique_name(:delete_twice)

      Connection.put(name, host: "h", token: "t")
      assert :ok = Connection.delete(name)
      assert :ok = Connection.delete(name)
    end

    test "deleting one name does not affect another" do
      name_a = unique_name(:del_isolation_a)
      name_b = unique_name(:del_isolation_b)

      on_exit(fn -> Connection.delete(name_b) end)

      Connection.put(name_a, host: "a", token: "ta")
      Connection.put(name_b, host: "b", token: "tb")

      Connection.delete(name_a)

      assert {:error, :not_found} = Connection.get(name_a)
      assert {:ok, b} = Connection.get(name_b)
      assert b[:host] === "b"
    end
  end

  # ---------------------------------------------------------------------------
  # finch_name/1
  # ---------------------------------------------------------------------------

  describe "finch_name/1" do
    test "of a name registered without :finch_name, or not at all, is derived from the name" do
      # Unique names: a fixed one is a key in the registry every test shares.
      unregistered = :"finch_derived_#{System.unique_integer([:positive])}"
      registered = :"finch_derived_#{System.unique_integer([:positive])}"
      :ok = Connection.put(registered, host: "h")
      on_exit(fn -> Connection.delete(registered) end)

      assert Connection.finch_name(unregistered) === :"influx_elixir_#{unregistered}_finch"
      assert Connection.finch_name(registered) === :"influx_elixir_#{registered}_finch"
    end

    test "is the pool a connection was given with :finch_name" do
      name = :"finch_given_#{System.unique_integer([:positive])}"
      :ok = Connection.put(name, host: "h", finch_name: :given_pool)
      on_exit(fn -> Connection.delete(name) end)

      # It named the derived pool whatever the connection said.
      assert Connection.finch_name(name) === :given_pool
    end

    test "is the derived pool for a registered connection that names none" do
      name = :"finch_derived_#{System.unique_integer([:positive])}"
      :ok = Connection.put(name, host: "h")
      on_exit(fn -> Connection.delete(name) end)

      assert Connection.finch_name(name) === :"influx_elixir_#{name}_finch"
    end
  end
end
