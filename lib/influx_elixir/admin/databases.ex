defmodule InfluxElixir.Admin.Databases do
  @moduledoc """
  v3 database CRUD operations via `/api/v3/configure/database`.

  Delegates to the configured `InfluxElixir.Client` implementation.
  In production this performs HTTP requests; in tests the `LocalClient`
  is used for fast, isolated operation.

  ## Examples

      {:ok, conn} = InfluxElixir.Client.Local.start()

      :ok = InfluxElixir.Admin.Databases.create(conn, "my_db")
      {:ok, dbs} = InfluxElixir.Admin.Databases.list(conn)
      :ok = InfluxElixir.Admin.Databases.delete(conn, "my_db")
  """

  @doc """
  Creates a database in InfluxDB v3.

  ## Parameters

    * `connection` - a client connection term
    * `name` - the database name to create
    * `opts` - optional keyword list (e.g. `:retention_period`)

  ## Returns

    * `:ok` on success
    * `{:error, reason}` on failure
  """
  @spec create(InfluxElixir.Client.connection(), binary(), keyword()) ::
          :ok | {:error, term()}
  def create(connection, name, opts \\ []) do
    InfluxElixir.Client.impl().create_database(connection, name, opts)
  end

  @doc """
  Lists all databases in InfluxDB v3.

  ## Parameters

    * `connection` - a client connection term

  ## Returns

    * `{:ok, [map()]}` on success
    * `{:error, reason}` on failure
  """
  @spec list(InfluxElixir.Client.connection()) :: {:ok, [map()]} | {:error, term()}
  def list(connection) do
    InfluxElixir.Client.impl().list_databases(connection)
  end

  @doc """
  Deletes a database in InfluxDB v3.

  ## Parameters

    * `connection` - a client connection term
    * `name` - the database name to delete

  ## Returns

    * `:ok` on success
    * `{:error, reason}` on failure
  """
  @spec delete(InfluxElixir.Client.connection(), binary()) :: :ok | {:error, term()}
  def delete(connection, name) do
    InfluxElixir.Client.impl().delete_database(connection, name)
  end
end
