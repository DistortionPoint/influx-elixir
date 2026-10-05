defmodule InfluxElixir.Client.Local.DatabaseRulesTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.DatabaseRules

  @none MapSet.new()

  describe "check_new/3 — names (verified against InfluxDB 3 Core)" do
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
        assert DatabaseRules.check_new(name, @none, :v3_core) === :ok, inspect(name)
      end
    end

    test "refuses what the engine refuses, with the first rule a name breaks" do
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
        assert {:error, %{status: 400, body: body}} =
                 DatabaseRules.check_new(name, @none, :v3_core)

        assert %{"error" => ^start <> _rest} = Jason.decode!(body), inspect(name)
      end
    end
  end

  describe "check_new/3 — the Core limit" do
    @five MapSet.new(~w(a b c d e))

    test "a sixth database is the engine's 422 on :v3_core only" do
      body = ~s({"error":"Adding a new database would exceed limit of 5 databases"})
      assert {:error, %{status: 422, body: ^body}} = DatabaseRules.check_new("f", @five, :v3_core)
      assert :ok = DatabaseRules.check_new("f", @five, :v3_enterprise)
    end

    test "an existing database passes at the limit; a bad name is still its 400" do
      assert :ok = DatabaseRules.check_new("a", @five, :v3_core)
      assert {:error, %{status: 400}} = DatabaseRules.check_new("_f", @five, :v3_core)
    end
  end
end
