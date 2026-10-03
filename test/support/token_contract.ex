defmodule InfluxElixir.TokenContract do
  @moduledoc """
  Token contract tests, run against `InfluxElixir.Client.Local` and against
  a real InfluxDB 3 that has authentication (token endpoints are disabled on
  a server started `--without-auth`, which the shared contract's servers
  are).

      use InfluxElixir.TokenContract, client: InfluxElixir.Client.Local, profile: :v3_core

  The `setup` callback must return `conn`, plus `shared: true` for a real
  server: its tokens outlive a test, so they are deleted after it. A real
  server is shared between runs, so names are unique and ids are compared
  with each other, never with fixed numbers.
  """

  @doc false
  defmacro __using__(opts) do
    client = Keyword.fetch!(opts, :client)
    profile = Keyword.fetch!(opts, :profile)

    quote location: :keep do
      defp token_name(prefix),
        do: InfluxElixir.IntegrationHelper.unique_name(prefix)

      # A real server outlives the test: its tokens are deleted after it.
      defp delete_after(%{shared: true} = ctx, names) do
        on_exit(fn -> Enum.each(names, &unquote(client).delete_token(ctx.conn, &1)) end)
      end

      defp delete_after(_ctx, _names), do: :ok

      describe "tokens — contract" do
        test "an admin token carries the engine's fields; its secret is shown here only", ctx do
          name = token_name("contract_tok")
          delete_after(ctx, [name])

          assert {:ok, token} = unquote(client).create_token(ctx.conn, name, expiry_secs: 3600)

          assert %{
                   "id" => id,
                   "name" => ^name,
                   "token" => "apiv3_" <> secret,
                   "hash" => hash,
                   "created_at" => created_at,
                   "expiry" => expiry
                 } = token

          assert map_size(token) === 6
          assert is_integer(id) and id > 0
          assert byte_size(secret) === 86
          assert hash =~ ~r/\A[0-9a-f]{128}\z/
          assert {:ok, created, 0} = DateTime.from_iso8601(created_at)
          assert {:ok, expires, 0} = DateTime.from_iso8601(expiry)
          assert DateTime.diff(expires, created, :millisecond) === 3_600_000
          # To the millisecond, with no fraction when it is zero.
          assert created_at =~ ~r/:\d{2}(\.\d{3})?Z\z/
          refute created_at =~ ~r/\.000Z\z/
        end

        test "ids count up and are never reused; no expiry is nil", ctx do
          [first, second] = names = [token_name("contract_ida"), token_name("contract_idb")]
          delete_after(ctx, names)

          assert {:ok, %{"id" => id, "expiry" => nil}} =
                   unquote(client).create_token(ctx.conn, first)

          assert :ok = unquote(client).delete_token(ctx.conn, first)

          assert {:ok, %{"id" => next}} = unquote(client).create_token(ctx.conn, second)
          assert next === id + 1
        end

        test "a taken name is the engine's 409 and spends no id", ctx do
          [name, other] = names = [token_name("contract_dup"), token_name("contract_dupx")]
          delete_after(ctx, names)

          assert {:ok, %{"id" => id}} = unquote(client).create_token(ctx.conn, name)

          assert {:error, %{status: 409, body: "token name already exists, " <> ^name}} =
                   unquote(client).create_token(ctx.conn, name)

          assert {:error, %{status: 409, body: "token name already exists, _admin"}} =
                   unquote(client).create_token(ctx.conn, "_admin")

          assert {:ok, %{"id" => next}} = unquote(client).create_token(ctx.conn, other)
          assert next === id + 1
        end

        # The column is the end of the value, the body's last: the byte
        # before its closing brace (verified).
        test "expiry_secs is a u64; anything else is the engine's JSON error", ctx do
          name = token_name("contract_exp")

          for {expiry, json, what} <- [
                {-5, "-5", "invalid value: integer `-5`"},
                {1.5, "1.5", "invalid type: floating point `1.5`"},
                {true, "true", "invalid type: boolean `true`"},
                {"1d", ~s("1d"), ~s|invalid type: string "1d"|}
              ] do
            body = ~s|{"token_name":"#{name}","expiry_secs":#{json}}|
            column = byte_size(body) - 1

            expected =
              "serde json error: #{what}, expected u64 at line 1 column #{column}"

            assert {:error, %{status: 400, body: ^expected}} =
                     unquote(client).create_token(ctx.conn, name, expiry_secs: expiry)
          end
        end

        test "delete is by name: an unknown one is the engine's 404, _admin its 405", ctx do
          name = token_name("contract_del")
          assert {:ok, token} = unquote(client).create_token(ctx.conn, name)

          assert %{"id" => id, "name" => ^name, "token" => "apiv3_" <> _secret} = token
          assert map_size(token) === 6
          assert is_integer(id) and id > 0
          assert :ok = unquote(client).delete_token(ctx.conn, name)

          assert {:error, %{status: 404, body: "the requested resource was not found: " <> ^name}} =
                   unquote(client).delete_token(ctx.conn, name)

          assert {:error, %{status: 405, body: "cannot delete operator token"}} =
                   unquote(client).delete_token(ctx.conn, "_admin")
        end

        test "a name needs no escaping", ctx do
          name = token_name("contract a&b")
          assert {:ok, %{"name" => ^name}} = unquote(client).create_token(ctx.conn, name)
          assert :ok = unquote(client).delete_token(ctx.conn, name)
        end

        test "a permission not in the CLI's form is refused before any request", ctx do
          assert {:error, {:invalid_permission, "db:read"}} =
                   unquote(client).create_token(ctx.conn, token_name("contract_perm"),
                     permissions: ["db:*:read", "db:read"]
                   )
        end

        if unquote(profile) == :v3_core do
          test "resource tokens are Enterprise's: Core answers 404", ctx do
            assert {:error, %{status: 404, body: "Not found"}} =
                     unquote(client).create_token(ctx.conn, token_name("contract_res"),
                       permissions: ["db:*:read"]
                     )
          end
        else
          test "a resource token is created and deleted by name", ctx do
            name = token_name("contract_res")

            assert {:ok, %{"name" => ^name, "token" => "apiv3_" <> _secret}} =
                     unquote(client).create_token(ctx.conn, name,
                       permissions: ["db:*:read,write", "system:*:read"]
                     )

            assert :ok = unquote(client).delete_token(ctx.conn, name)
          end
        end
      end
    end
  end
end
