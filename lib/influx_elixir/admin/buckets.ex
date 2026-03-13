defmodule InfluxElixir.Admin.Buckets do
  @moduledoc """
  v2 bucket CRUD operations for backwards compatibility.

  Delegates to the configured `InfluxElixir.Client` implementation.
  Use this module when working with InfluxDB v2 bucket APIs.

  ## Examples

      {:ok, conn} = InfluxElixir.Client.Local.start()

      :ok = InfluxElixir.Admin.Buckets.create(conn, "my_bucket")
      {:ok, buckets} = InfluxElixir.Admin.Buckets.list(conn)
      :ok = InfluxElixir.Admin.Buckets.delete(conn, "my_bucket")
  """

  @doc """
  Creates a bucket in InfluxDB v2.

  ## Parameters

    * `connection` - a client connection term
    * `name` - the bucket name to create
    * `opts` - optional keyword list (e.g. `:org_id`, `:retention_seconds`)

  ## Returns

    * `:ok` on success
    * `{:error, reason}` on failure
  """
  @spec create(InfluxElixir.Client.connection(), binary(), keyword()) ::
          :ok | {:error, term()}
  def create(connection, name, opts \\ []) do
    InfluxElixir.Client.impl().create_bucket(connection, name, opts)
  end

  @doc """
  Lists all buckets in InfluxDB v2.

  ## Parameters

    * `connection` - a client connection term

  ## Returns

    * `{:ok, [map()]}` on success
    * `{:error, reason}` on failure
  """
  @spec list(InfluxElixir.Client.connection()) :: {:ok, [map()]} | {:error, term()}
  def list(connection) do
    InfluxElixir.Client.impl().list_buckets(connection)
  end

  @doc """
  Deletes a bucket in InfluxDB v2.

  ## Parameters

    * `connection` - a client connection term
    * `name` - the bucket name to delete

  ## Returns

    * `:ok` on success
    * `{:error, reason}` on failure
  """
  @spec delete(InfluxElixir.Client.connection(), binary()) :: :ok | {:error, term()}
  def delete(connection, name) do
    InfluxElixir.Client.impl().delete_bucket(connection, name)
  end
end
