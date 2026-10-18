defmodule InfluxElixir.ConnectionTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Connection

  # Only api_version/1's examples run: the others put a fixed name (`:test`) in the registry
  # every test shares.
  doctest InfluxElixir.Connection, only: [api_version: 1]

  # Each test gets a unique atom prefix so async tests do not collide in
  # :persistent_term, which is a global VM-wide store.
  defp unique_name(suffix) do
    :"influx_conn_test_#{System.unique_integer([:positive])}_#{suffix}"
  end

  defp missing_message(name) do
    "no InfluxElixir connection named #{inspect(name)}: list it under " <>
      "`config :influx_elixir, :connections` or add it with " <>
      "InfluxElixir.add_connection/2"
  end

  # ---------------------------------------------------------------------------
  # put/2 + get/1
  # ---------------------------------------------------------------------------

  describe "put/2 and get/1" do
    test "stores a config and retrieves it by name, verbatim as a keyword list" do
      name = unique_name(:put_get)
      config = [host: "h", token: "t", scheme: :http, port: 9999, pool_size: 5]

      on_exit(fn -> Connection.delete(name) end)

      assert Connection.put(name, config) === :ok
      assert Connection.get(name) === {:ok, config}
    end

    test "overwriting a name replaces the stored config" do
      name = unique_name(:overwrite)
      on_exit(fn -> Connection.delete(name) end)

      Connection.put(name, host: "first", token: "t")
      Connection.put(name, host: "second", token: "t")

      assert Connection.get(name) === {:ok, [host: "second", token: "t"]}
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

      assert Connection.get(name_a) === {:ok, [host: "alpha", token: "ta"]}
      assert Connection.get(name_b) === {:ok, [host: "beta", token: "tb"]}
    end
  end

  # ---------------------------------------------------------------------------
  # get/1 — not found
  # ---------------------------------------------------------------------------

  describe "get/1 — unknown name" do
    test "returns {:error, :not_found} for a name that was never stored" do
      name = unique_name(:not_found)
      assert Connection.get(name) === {:error, :not_found}
    end

    test "returns {:error, :not_found} after the entry has been deleted" do
      name = unique_name(:deleted_then_get)

      Connection.put(name, host: "h", token: "t")
      Connection.delete(name)

      assert Connection.get(name) === {:error, :not_found}
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
      assert Connection.fetch!(name) === [host: "h", token: "t"]
    end

    test "raises an ArgumentError that names the missing connection" do
      name = unique_name(:fetch_raise)

      assert_raise ArgumentError, missing_message(name), fn ->
        Connection.fetch!(name)
      end
    end

    test "raises ArgumentError after the entry has been deleted" do
      name = unique_name(:fetch_after_delete)

      Connection.put(name, host: "h", token: "t")
      Connection.delete(name)

      assert_raise ArgumentError, missing_message(name), fn ->
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
      assert Connection.delete(name) === :ok
      assert Connection.get(name) === {:error, :not_found}
    end

    test "returns :ok when deleting a name that does not exist" do
      name = unique_name(:delete_nonexistent)
      assert Connection.delete(name) === :ok
    end

    test "is idempotent — second delete also returns :ok" do
      name = unique_name(:delete_twice)

      Connection.put(name, host: "h", token: "t")
      assert Connection.delete(name) === :ok
      assert Connection.delete(name) === :ok
    end

    test "deleting one name does not affect another" do
      name_a = unique_name(:del_isolation_a)
      name_b = unique_name(:del_isolation_b)

      on_exit(fn -> Connection.delete(name_b) end)

      Connection.put(name_a, host: "a", token: "ta")
      Connection.put(name_b, host: "b", token: "tb")

      Connection.delete(name_a)

      assert Connection.get(name_a) === {:error, :not_found}
      assert Connection.get(name_b) === {:ok, [host: "b", token: "tb"]}
    end
  end

  # ---------------------------------------------------------------------------
  # api_version/1
  # ---------------------------------------------------------------------------

  describe "api_version/1" do
    test "reads a keyword connection, a Local connection and a registered name" do
      assert Connection.api_version(host: "h", api_version: :v3) === :v3

      {:ok, v2} = Local.start(profile: :v2)
      {:ok, v3} = Local.start(profile: :v3_core)
      assert Connection.api_version(v2) === :v2
      assert Connection.api_version(v3) === :v3

      name = unique_name(:api_version)
      on_exit(fn -> Connection.delete(name) end)
      :ok = Connection.put(name, host: "h", api_version: :v2)
      assert Connection.api_version(name) === :v2
    end

    test "anything else, an unregistered name included, is v3" do
      assert Connection.api_version(unique_name(:api_version_not_registered)) === :v3
      assert Connection.api_version(nil) === :v3
      assert Connection.api_version("host") === :v3
      assert Connection.api_version([1, 2]) === :v3
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
  end
end
