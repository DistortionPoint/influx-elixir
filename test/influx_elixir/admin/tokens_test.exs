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

  # The secret, its hash and the creation time are generated, so they are
  # checked for being there and taken out; the rest is compared whole.
  defp public(
         {:ok,
          %{"token" => "apiv3_" <> _secret, "hash" => hash, "created_at" => created_at} = token}
       )
       when is_binary(hash) and is_binary(created_at),
       do: {:ok, Map.drop(token, ["token", "hash", "created_at"])}

  defp public(other), do: other

  describe "create/3 and delete/2" do
    test "create a token by name, then delete it by that name", %{conn: conn} do
      assert conn |> Tokens.create("ci") |> public() ===
               {:ok, %{"id" => 1, "name" => "ci", "expiry" => nil}}

      assert :ok = Tokens.delete(conn, "ci")

      assert {:error, %{status: 404, body: "the requested resource was not found: ci"}} =
               Tokens.delete(conn, "ci")
    end

    test "permissions make a resource token on Enterprise", %{conn: conn} do
      assert conn |> Tokens.create("reader", permissions: ["db:metrics:read"]) |> public() ===
               {:ok, %{"id" => 1, "name" => "reader", "expiry" => nil}}
    end

    test "a permission in another form is refused before any request", %{conn: conn} do
      for permission <- ["db:read", "db::read", "db:x:", ":x:read", :read] do
        assert {:error, {:invalid_permission, ^permission}} =
                 Tokens.create(conn, "bad", permissions: [permission])
      end

      # Nothing was created, so the name is still free.
      assert conn |> Tokens.create("bad") |> public() ===
               {:ok, %{"id" => 1, "name" => "bad", "expiry" => nil}}
    end

    test "a connection name resolves through the facade" do
      name = :"tokens_test_#{System.unique_integer([:positive])}"
      {:ok, _pid} = InfluxElixir.add_connection(name, profile: :v3_core)
      on_exit(fn -> InfluxElixir.remove_connection(name) end)

      assert name |> Tokens.create("named") |> public() ===
               {:ok, %{"id" => 1, "name" => "named", "expiry" => nil}}

      assert :ok = Tokens.delete(name, "named")
    end
  end
end
