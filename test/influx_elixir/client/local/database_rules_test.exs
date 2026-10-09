defmodule InfluxElixir.Client.Local.DatabaseRulesTest do
  @moduledoc """
  The rules for database names and counts (verified against InfluxDB 3 Core), read through
  the public calls that apply them: `Local.create_database/3` and `Local.start/1`.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  describe "create_database/3 — names" do
    test "accepts what the engine accepts" do
      for name <- [
            "a",
            "A",
            "1",
            "1abc",
            "a-b",
            "a_b",
            "a/b",
            "a/_b",
            "a/B",
            String.duplicate("c", 200)
          ] do
        # Core holds five databases: each name is made in a store of its own.
        {:ok, own} = Local.start(profile: :v3_core)
        assert Local.create_database(own, name, []) === :ok, inspect(name)
        assert {:ok, listed} = Local.list_databases(own)
        assert Enum.any?(listed, &(&1["name"] === name)), inspect(name)
      end
    end

    test "refuses what the engine refuses, with the first rule a name breaks" do
      {:ok, conn} = Local.start(profile: :v3_core)

      for {name, start} <- [
            {"", "db name cannot be empty"},
            {"_x", "db name did not start"},
            {"-", "db name did not start"},
            {"_a/b/c", "db name did not start"},
            {"a.b", "invalid character"},
            {"héllo", "invalid character"},
            {"a b", "invalid character"},
            {"a.b/c/d", "invalid character"},
            {"a.b/", "invalid character"},
            {"x/", "db name with invalid retention policy"},
            {"a//b", "db name with invalid retention policy"},
            {"a/b/c", "db name with invalid retention policy"}
          ] do
        assert {:error, %{status: 400, body: body}} = Local.create_database(conn, name, [])
        assert %{"error" => ^start <> _rest} = Jason.decode!(body), inspect(name)
      end

      assert {:ok, [%{"name" => "_internal"}]} = Local.list_databases(conn)
    end
  end

  describe "create_database/3 — the Core limit" do
    defp full_store(profile) do
      {:ok, conn} = Local.start(profile: profile)
      for name <- ~w(a b c d e), do: :ok = Local.create_database(conn, name, [])
      conn
    end

    test "a sixth database is the engine's 422 on :v3_core only" do
      body = ~s({"error":"Adding a new database would exceed limit of 5 databases"})

      assert {:error, %{status: 422, body: ^body}} =
               Local.create_database(full_store(:v3_core), "f", [])

      assert Local.create_database(full_store(:v3_enterprise), "f", []) === :ok
    end

    test "an existing database passes at the limit; a bad name is still its 400" do
      conn = full_store(:v3_core)
      assert Local.create_database(conn, "a", []) === :ok
      assert {:error, %{status: 400}} = Local.create_database(conn, "_f", [])
    end
  end

  describe "start/1 — the databases it makes" do
    test "raises the engine's message for the first it would refuse" do
      error =
        assert_raise ArgumentError, fn ->
          Local.start(databases: ["ok", "_bad", "a b"], profile: :v3_core)
        end

      assert error.message ===
               ~s|Client.Local.start/1: _bad: {"error":"db name did not start with a number | <>
                 ~s|or letter"}|

      assert_raise ArgumentError, ~r/exceed limit of 5 databases/, fn ->
        Local.start(databases: ~w(a b c d e f), profile: :v3_core)
      end

      assert {:ok, _conn} = Local.start(databases: ~w(a b c d e f), profile: :v3_enterprise)
    end

    test "raises a named ArgumentError for names that are not strings" do
      for opts <- [[database: 1], [databases: nil], [databases: [:a]], [databases: "a"]] do
        assert_raise ArgumentError, ~r/:databases must be a list of strings/, fn ->
          Local.start(opts)
        end
      end
    end
  end
end
