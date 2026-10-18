defmodule InfluxElixir.Admin.Buckets do
  @moduledoc """
  v2 bucket CRUD operations for backwards compatibility.

  Each function is the `InfluxElixir` facade function of the same operation:
  it takes a connection or a connection name. Admin operations emit no
  telemetry span; only writes and queries do (see `InfluxElixir.Telemetry`).

  Use this module when working with InfluxDB v2 bucket APIs.

  ## Examples

      {:ok, conn} = InfluxElixir.Client.Local.start(profile: :v2)

      :ok = InfluxElixir.Admin.Buckets.create(conn, "my_bucket")
      {:ok, buckets} = InfluxElixir.Admin.Buckets.list(conn)
      :ok = InfluxElixir.Admin.Buckets.delete(conn, "my_bucket")
  """

  @doc """
  Creates a bucket in InfluxDB v2.

  ## Parameters

    * `connection` - a client connection term
    * `name` - the bucket name to create
    * `opts` - optional keyword list:
      * `:retention` - retention in seconds (default `0`, no expiry). InfluxDB 2
        refuses anything between 1 and 3599 with a 500 `retention policy
        duration must be at least 1h0m0s` (verified); the bucket lists its
        rule as `"retentionRules" => [%{"type" => "expire", "everySeconds" => n}]`
      * `:org_id` - the org ID; looked up from the connection's `:org` when omitted
        (`Client.Local` holds one org and ignores it)

  ## Returns

    * `:ok` on success, and for a bucket that exists, which is left as it was (its
      retention unchanged): InfluxDB 2 answers that with a 422 conflict
    * `{:error, %{status: 400, body: body}}` - with neither `:org_id` nor a connection
      `:org`: InfluxDB 2 answers `organization id must be provided` (verified)
    * `{:error, reason}` on failure
  """
  @spec create(InfluxElixir.Client.connection(), binary(), keyword()) ::
          :ok | {:error, term()}
  def create(connection, name, opts \\ []) do
    InfluxElixir.create_bucket(connection, name, opts)
  end

  @doc """
  Lists all buckets in InfluxDB v2.

  ## Parameters

    * `connection` - a client connection term

  Every bucket of the connection's `:org`, across all of the server's
  pages.

  ## Returns

    * `{:ok, [map()]}` on success
    * `{:error, reason}` on failure
  """
  @spec list(InfluxElixir.Client.connection()) :: {:ok, [map()]} | {:error, term()}
  def list(connection) do
    InfluxElixir.list_buckets(connection)
  end

  @doc """
  Deletes a bucket in InfluxDB v2.

  ## Parameters

    * `connection` - a client connection term
    * `name` - the bucket name to delete

  ## Returns

    * `:ok` on success
    * `{:error, %{status: 404, body: "bucket not found: " <> name}}` for a bucket that
      does not exist
    * `{:error, reason}` on any other failure
  """
  @spec delete(InfluxElixir.Client.connection(), binary()) :: :ok | {:error, term()}
  def delete(connection, name) do
    InfluxElixir.delete_bucket(connection, name)
  end
end
