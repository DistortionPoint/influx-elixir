defmodule InfluxElixir.Admin.Tokens do
  @moduledoc """
  v3 token management via `/api/v3/configure/token`.

  Delegates to the configured `InfluxElixir.Client` implementation.
  Use this module to create and delete API tokens in InfluxDB v3.

  ## Examples

      {:ok, conn} = InfluxElixir.Client.Local.start()

      {:ok, token} = InfluxElixir.Admin.Tokens.create(conn, "my token")
      :ok = InfluxElixir.Admin.Tokens.delete(conn, token["id"])
  """

  @doc """
  Creates an API token in InfluxDB v3.

  ## Parameters

    * `connection` - a client connection term
    * `description` - human-readable description for the token
    * `opts` - optional keyword list (e.g. `:permissions`)

  ## Returns

    * `{:ok, map()}` containing token details on success
    * `{:error, reason}` on failure
  """
  @spec create(InfluxElixir.Client.connection(), binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create(connection, description, opts \\ []) do
    InfluxElixir.Client.impl().create_token(connection, description, opts)
  end

  @doc """
  Deletes an API token in InfluxDB v3.

  ## Parameters

    * `connection` - a client connection term
    * `token_id` - the ID of the token to delete

  ## Returns

    * `:ok` on success
    * `{:error, reason}` on failure
  """
  @spec delete(InfluxElixir.Client.connection(), binary()) :: :ok | {:error, term()}
  def delete(connection, token_id) do
    InfluxElixir.Client.impl().delete_token(connection, token_id)
  end
end
