defmodule InfluxElixir.Admin.TokensTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Admin.Tokens
  alias InfluxElixir.Client.Local

  # The engine's answers are pinned by `InfluxElixir.TokenContract`, against
  # Client.Local and a real InfluxDB 3; these cover the module's own surface.

  setup do
    {:ok, conn} = Local.start(profile: :v3_enterprise)
    {:ok, conn: conn}
  end

  describe "create/3 and delete/2" do
    test "create a token by name, then delete it by that name", %{conn: conn} do
      assert {:ok, %{"id" => 1, "name" => "ci", "expiry" => nil}} = Tokens.create(conn, "ci")
      assert :ok = Tokens.delete(conn, "ci")

      assert {:error, %{status: 404, body: "the requested resource was not found: ci"}} =
               Tokens.delete(conn, "ci")
    end

    test "permissions make a resource token on Enterprise", %{conn: conn} do
      assert {:ok, %{"name" => "reader"}} =
               Tokens.create(conn, "reader", permissions: ["db:metrics:read"])
    end

    test "a permission in another form is refused before any request", %{conn: conn} do
      for permission <- ["db:read", "db::read", "db:x:", ":x:read", :read] do
        assert {:error, {:invalid_permission, ^permission}} =
                 Tokens.create(conn, "bad", permissions: [permission])
      end

      # Nothing was created, so the name is still free.
      assert {:ok, %{"name" => "bad"}} = Tokens.create(conn, "bad")
    end

    test "a connection name resolves through the facade" do
      name = :"tokens_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = InfluxElixir.add_connection(name, profile: :v3_core)
      on_exit(fn -> InfluxElixir.remove_connection(name) end)

      assert {:ok, %{"name" => "named"}} = Tokens.create(name, "named")
      assert :ok = Tokens.delete(name, "named")
    end
  end
end
