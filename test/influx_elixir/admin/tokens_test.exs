defmodule InfluxElixir.Admin.TokensTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Admin.Tokens
  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(profile: :v3_enterprise)
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  describe "create/3" do
    test "returns a token carrying the description and a secret", %{conn: conn} do
      assert {:ok, %{"token" => secret, "description" => "my token description"}} =
               Tokens.create(conn, "my token description")

      assert byte_size(secret) > 0
    end

    test "accepts optional opts", %{conn: conn} do
      assert {:ok, %{"description" => "read-only token"}} =
               Tokens.create(conn, "read-only token", permissions: ["read"])
    end

    test "defaults opts to empty list", %{conn: conn} do
      assert {:ok, _token} = Tokens.create(conn, "default token")
    end
  end

  describe "delete/2" do
    test "returns :ok on success", %{conn: conn} do
      assert :ok = Tokens.delete(conn, "token-id-123")
    end
  end
end
