defmodule InfluxElixir do
  @moduledoc """
  Elixir client library for InfluxDB v3 with v2 compatibility.

  All public API operations go through this facade module.
  Delegates to the configured client implementation
  (`InfluxElixir.Client.HTTP` or `InfluxElixir.Client.Local`).

  ## Named Connections

  All facade functions accept either a **keyword config** or an **atom name**.
  When an atom is passed, it is resolved via `InfluxElixir.Connection.fetch!/1`
  from the persistent-term registry (populated automatically by
  `InfluxElixir.ConnectionSupervisor` on startup).

      # Using a named connection (registered at startup)
      InfluxElixir.health(:trading)
      InfluxElixir.write(:trading, "cpu value=1.0", database: "prices")

      # Using a raw config (e.g. LocalClient in tests)
      InfluxElixir.health(conn)

  ## Configuration

      # config/config.exs
      config :influx_elixir, :client, InfluxElixir.Client.HTTP

      config :influx_elixir, :connections,
        trading: [
          host: "influx-trading:8086",
          token: "...",
          default_database: "prices"
        ]

      # config/test.exs
      config :influx_elixir, :client, InfluxElixir.Client.Local
  """

  alias InfluxElixir.Write.Point

  # ---------- Connection Resolution ----------

  @doc """
  Resolves a connection reference to a config keyword list.

  Accepts either an atom name (looked up via `Connection.fetch!/1`)
  or a keyword/map config (returned as-is).

  ## Examples

      resolve_connection(:trading)
      resolve_connection(host: "localhost", token: "t")
  """
  @spec resolve_connection(atom() | InfluxElixir.Client.connection()) ::
          InfluxElixir.Client.connection()
  def resolve_connection(name) when is_atom(name) do
    InfluxElixir.Connection.fetch!(name)
  end

  def resolve_connection(connection), do: connection

  # ---------- Client Resolution ----------

  @doc """
  Returns the configured client implementation module.
  """
  @spec client() :: module()
  def client do
    InfluxElixir.Client.impl()
  end

  # ---------- Write ----------

  @doc """
  Constructs a new Point struct.

  ## Parameters

    * `measurement` - measurement name
    * `fields` - field key-value pairs
    * `opts` - optional `:tags` and `:timestamp`

  ## Examples

      InfluxElixir.point("cpu", %{"value" => 0.64},
        tags: %{"host" => "server01"}
      )
  """
  @spec point(String.t(), %{String.t() => Point.field_value()}, keyword()) ::
          Point.t()
  def point(measurement, fields, opts \\ []) do
    Point.new(measurement, fields, opts)
  end

  @doc """
  Writes points to InfluxDB using the configured client.
  """
  @spec write(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.write_result()
  def write(connection, line_protocol, opts \\ []) do
    client().write(resolve_connection(connection), line_protocol, opts)
  end

  # ---------- Query — v3 SQL ----------

  @doc """
  Executes a SQL query against InfluxDB v3.

  Supports `transport: :http | :flight` option for transport selection.
  """
  @spec query_sql(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  def query_sql(connection, sql, opts \\ []) do
    client().query_sql(resolve_connection(connection), sql, opts)
  end

  @doc """
  Executes a streaming SQL query, returning a lazy Stream.

  Use for large result sets to avoid loading all rows into memory.
  """
  @spec query_sql_stream(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: Enumerable.t()
  def query_sql_stream(connection, sql, opts \\ []) do
    client().query_sql_stream(resolve_connection(connection), sql, opts)
  end

  @doc """
  Executes a non-SELECT SQL statement (DELETE, INSERT INTO ... SELECT).
  """
  @spec execute_sql(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def execute_sql(connection, sql, opts \\ []) do
    client().execute_sql(resolve_connection(connection), sql, opts)
  end

  # ---------- Query — v3 InfluxQL ----------

  @doc """
  Executes an InfluxQL query against InfluxDB v3.
  """
  @spec query_influxql(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  def query_influxql(connection, influxql, opts \\ []) do
    client().query_influxql(resolve_connection(connection), influxql, opts)
  end

  # ---------- Query — v2 Flux (compat) ----------

  @doc """
  Executes a Flux query against InfluxDB v2 (backwards compatibility).
  """
  @spec query_flux(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  def query_flux(connection, flux, opts \\ []) do
    client().query_flux(resolve_connection(connection), flux, opts)
  end

  # ---------- Admin — v3 databases ----------

  @doc """
  Creates a database in InfluxDB v3.
  """
  @spec create_database(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_database(connection, db_name, opts \\ []) do
    client().create_database(resolve_connection(connection), db_name, opts)
  end

  @doc """
  Lists all databases in InfluxDB v3.
  """
  @spec list_databases(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_databases(connection) do
    client().list_databases(resolve_connection(connection))
  end

  @doc """
  Deletes a database in InfluxDB v3.
  """
  @spec delete_database(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_database(connection, db_name) do
    client().delete_database(resolve_connection(connection), db_name)
  end

  # ---------- Admin — v2 buckets (compat) ----------

  @doc """
  Creates a bucket in InfluxDB v2 (backwards compatibility).
  """
  @spec create_bucket(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_bucket(connection, bucket_name, opts \\ []) do
    client().create_bucket(resolve_connection(connection), bucket_name, opts)
  end

  @doc """
  Lists all buckets in InfluxDB v2 (backwards compatibility).
  """
  @spec list_buckets(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_buckets(connection) do
    client().list_buckets(resolve_connection(connection))
  end

  @doc """
  Deletes a bucket in InfluxDB v2 (backwards compatibility).
  """
  @spec delete_bucket(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_bucket(connection, bucket_name) do
    client().delete_bucket(resolve_connection(connection), bucket_name)
  end

  # ---------- Admin — v3 tokens ----------

  @doc """
  Creates an API token in InfluxDB v3.
  """
  @spec create_token(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def create_token(connection, description, opts \\ []) do
    client().create_token(resolve_connection(connection), description, opts)
  end

  @doc """
  Deletes an API token in InfluxDB v3.
  """
  @spec delete_token(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_token(connection, token_id) do
    client().delete_token(resolve_connection(connection), token_id)
  end

  # ---------- Health ----------

  @doc """
  Checks the health of an InfluxDB instance.
  """
  @spec health(InfluxElixir.Client.connection()) ::
          {:ok, map()} | {:error, term()}
  def health(connection) do
    client().health(resolve_connection(connection))
  end

  # ---------- Batch Writer ----------

  @doc """
  Forces an immediate flush of the batch writer for a connection.

  Returns `:ok` on success or `{:error, :no_batch_writer}` if no
  batch writer is configured for the given connection.
  """
  @spec flush(atom()) :: :ok | {:error, :no_batch_writer}
  def flush(connection_name) do
    bw = InfluxElixir.ConnectionSupervisor.batch_writer_name(connection_name)

    if Process.whereis(bw) do
      InfluxElixir.Write.BatchWriter.flush(bw)
    else
      {:error, :no_batch_writer}
    end
  end

  @doc """
  Returns batch writer statistics for a connection.

  Returns `{:ok, stats_map}` or `{:error, :no_batch_writer}` if no
  batch writer is configured for the given connection.
  """
  @spec stats(atom()) :: {:ok, map()} | {:error, :no_batch_writer}
  def stats(connection_name) do
    bw = InfluxElixir.ConnectionSupervisor.batch_writer_name(connection_name)

    if Process.whereis(bw) do
      InfluxElixir.Write.BatchWriter.stats(bw)
    else
      {:error, :no_batch_writer}
    end
  end

  # ---------- Dynamic Connections ----------

  @doc """
  Adds a new named connection dynamically at runtime.
  """
  @spec add_connection(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def add_connection(name, opts) do
    config = Keyword.put(opts, :name, name)

    child_spec =
      Supervisor.child_spec(
        {InfluxElixir.ConnectionSupervisor, config},
        id: {InfluxElixir.ConnectionSupervisor, name}
      )

    case Supervisor.start_child(InfluxElixir.Supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes a named connection dynamically at runtime.
  """
  @spec remove_connection(atom()) :: :ok | {:error, term()}
  def remove_connection(name) do
    child_id = {InfluxElixir.ConnectionSupervisor, name}

    case Supervisor.terminate_child(InfluxElixir.Supervisor, child_id) do
      :ok ->
        result = Supervisor.delete_child(InfluxElixir.Supervisor, child_id)

        case InfluxElixir.Connection.get(name) do
          {:ok, conn} -> client().shutdown_connection(conn)
          {:error, :not_found} -> :ok
        end

        InfluxElixir.Connection.delete(name)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end
end
