defmodule InfluxElixir.Admin.Tokens do
  @moduledoc """
  InfluxDB 3 token management, by token name.

  Each function is the `InfluxElixir` facade function of the same operation:
  it takes a connection or a connection name. Admin operations emit no
  telemetry span; only writes and queries do (see `InfluxElixir.Telemetry`).

  The server must run with authentication: one started with
  `--without-auth` refuses every token call (405
  `endpoint disabled, started without auth`). `Client.Local` has no
  authentication and answers them as an authenticated server does.

  ## Examples

      {:ok, conn} = InfluxElixir.Client.Local.start()

      {:ok, %{"name" => "ci", "token" => "apiv3_" <> _secret}} =
        InfluxElixir.Admin.Tokens.create(conn, "ci", expiry_secs: 3600)

      :ok = InfluxElixir.Admin.Tokens.delete(conn, "ci")
  """

  @doc """
  Creates a token named `name` (verified against InfluxDB 3 Core; the
  request is the one the `influxdb3 create token` CLI sends).

  ## Options

    * `:permissions` - omit it for an admin token (Core and Enterprise).
      Given, a list of `"RESOURCE_TYPE:RESOURCE_NAMES:ACTIONS"` strings
      makes a resource token, as the CLI's `--permission` does:
      `["db:db1,db2:read,write", "system:*:read"]`. Resource tokens are
      InfluxDB 3 Enterprise's; Core answers 404 `Not found`. A string not
      in that form is `{:error, {:invalid_permission, string}}`, before any
      request.
    * `:expiry_secs` - seconds until the token expires; omitted, it never
      does. Anything but a non-negative integer is the server's 400
      (`serde json error: ..., expected u64 at line 1 column N`).

  ## Returns

    * `{:ok, map}` - `"id"`, `"name"`, `"token"` (the secret, shown only
      here), `"hash"`, `"created_at"` and `"expiry"` (`nil` when it never
      expires); the response's shape for a resource token is Enterprise's
      and has not been verified against a running Enterprise server
    * `{:error, %{status: 409, body: "token name already exists, NAME"}}` -
      a token of that name exists (the operator token is `_admin`)
    * `{:error, reason}` - any other failure
  """
  @spec create(InfluxElixir.Client.connection(), binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create(connection, name, opts \\ []) do
    InfluxElixir.create_token(connection, name, opts)
  end

  @doc """
  Deletes the token named `name`.

  ## Returns

    * `:ok` on success
    * `{:error, %{status: 404, body: "the requested resource was not found: NAME"}}` -
      no token has that name
    * `{:error, %{status: 405, body: "cannot delete operator token"}}` -
      for `_admin`
    * `{:error, reason}` - any other failure
  """
  @spec delete(InfluxElixir.Client.connection(), binary()) :: :ok | {:error, term()}
  def delete(connection, name) do
    InfluxElixir.delete_token(connection, name)
  end
end
