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

      # Using a raw config (e.g. a `Client.Local` connection in tests)
      InfluxElixir.health(conn)

  ## Configuration

      # config/config.exs
      config :influx_elixir, :client, InfluxElixir.Client.HTTP

      config :influx_elixir, :connections,
        trading: [
          host: "influx-trading",
          token: "...",
          database: "prices"
        ]

      # config/test.exs
      config :influx_elixir, :client, InfluxElixir.Client.Local

  ## Writing

  `write/3` sends line protocol, a `InfluxElixir.Write.Point` or a list of them in one
  request. A connection with a `batch_writer:` option also takes `write_batched/3`, which
  buffers the payload and returns; the writer sends the buffer in batches, retries the
  failures a retry can mend, and answers `flush/2` and `stats/2` while it waits for the
  server. See `InfluxElixir.Write.BatchWriter`.

  ## Telemetry

  `write/3` and the query functions emit `[:influx_elixir, :write | :query,
  :start | :stop | :exception]` events; see `InfluxElixir.Telemetry`.
  """

  alias InfluxElixir.Client.Options
  alias InfluxElixir.Telemetry
  alias InfluxElixir.Write.{BatchWriter, Point, Writer}

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
    * `fields` - field key-value pairs (`nil` is none)
    * `opts` - optional `:tags` (`nil` is none) and `:timestamp`

  See `InfluxElixir.Write.Point.new/3`.

  ## Examples

      InfluxElixir.point("cpu", %{"value" => 0.64},
        tags: %{"host" => "server01"}
      )
  """
  @spec point(String.t(), %{String.t() => Point.field_value()} | nil, keyword()) ::
          Point.t()
  def point(measurement, fields, opts \\ []) do
    Point.new(measurement, fields, opts)
  end

  @doc """
  Writes line protocol, or Points, to InfluxDB using the configured client.

  Goes through `InfluxElixir.Write.Writer`, so payloads over 1 KB are
  gzipped and a `[:influx_elixir, :write, ...]` telemetry span is emitted.
  The payload may be:

    * line protocol, a binary or iodata (a list of binaries and bytes);
    * a `InfluxElixir.Write.Point` (see `point/3`), or a list of them. They are
      encoded with `InfluxElixir.Write.LineProtocol.encode/2` for this call's
      `:precision` (a `DateTime` timestamp is written in that unit) and the
      connection's `:api_version`. A point no server accepts is that function's
      `{:error, reason}` and nothing is sent.

  Any other body, or options that are not a keyword list, is the client's error
  (`{:error, {:invalid_body, body}}` and `{:error, {:invalid_options, opts}}` over
  HTTP), never a raise. To buffer writes and send them in batches, see
  `write_batched/3`.

  ## Options

    * `:database` — overrides the connection-level default database.
    * `:precision` — the unit of the timestamps (default nanoseconds); see
      `InfluxElixir.Client.Local` for the spellings each server accepts.
    * `:accept_partial` — InfluxDB 3 only. `false` makes the write
      all-or-nothing: the first bad line (a parse error or a schema
      conflict, in line order) rejects the payload, nothing is stored, and
      the error is `{:error, %{status: 400, body: json}}` with
      `"line protocol parsing error"` and that one line under `"data"`.
      Default `true`: good lines are stored and the bad ones reported as a
      partial write.
    * `:no_sync` — InfluxDB 3 only. `true` acknowledges the write before
      it is persisted to the write-ahead log: faster, and a query right
      after it may not see the points yet (verified).
    * `:gzip` — `true` compresses every payload, `false` none; by default
      only payloads over 1 KB (see `InfluxElixir.Write.Writer.write/3`).

  ## Examples

      point = InfluxElixir.point("cpu", %{"value" => 0.64}, tags: %{"host" => "web01"})
      {:ok, :written} = InfluxElixir.write(:default, point)
      {:ok, :written} = InfluxElixir.write(:default, [point], precision: :millisecond)
  """
  @spec write(
          InfluxElixir.Client.connection(),
          iodata() | Point.t() | [Point.t()],
          keyword()
        ) :: InfluxElixir.Client.write_result()
  def write(connection, line_protocol, opts \\ []) do
    Writer.write(resolve_connection(connection), line_protocol, opts)
  end

  # Wraps a query in a `[:influx_elixir, :query, ...]` span. The :stop event
  # carries `row_count` for list results and `result: :ok | :error`.
  @spec query_span(term(), keyword(), (-> result)) ::
          result | {:error, {:invalid_connection, term()}}
        when result: term()
  defp query_span(connection, opts, fun) do
    if connection?(connection) do
      metadata = %{
        database: option(opts, :database) || Options.database(connection),
        transport: client()
      }

      Telemetry.span_query(metadata, fun)
    else
      {:error, {:invalid_connection, connection}}
    end
  end

  # A connection is a keyword list (HTTP) or a map (Local); a host name, a number, a
  # list of other things is the caller's error to name, not a raise from inside a span.
  @spec connection?(term()) :: boolean()
  defp connection?(connection), do: is_map(connection) or Options.keyword?(connection)

  # Options that are not a keyword list are the client's error to name; the span reads none.
  defp option(opts, key) do
    if Options.keyword?(opts), do: Keyword.get(opts, key)
  end

  # ---------- Query — v3 SQL ----------

  @doc """
  Executes a SQL query against InfluxDB v3.

  Supports `transport: :http | :flight` option for transport selection
  (`InfluxElixir.Client.HTTP` only; `Client.Local` is in-memory and ignores it).

  ## Common Options

    * `:database` — overrides the connection-level default database.
    * `:timeout` — per-call timeout in milliseconds, else the connection's `:timeout`, else
      `30_000`. Over HTTP it is Finch's receive timeout; over Flight it is a wall-clock
      bound on the call and the streaming of the whole result (`{:error, :timeout}` past it).
    * `:pool_timeout` — per-call Finch pool checkout timeout in milliseconds
      (HTTP transport; default `5_000`). Applies before `:timeout`.
    * `:params` — map of `$name => value` placeholder substitutions
      (HTTP transport only; Flight returns `{:error, :params_unsupported_over_flight}`).
    * `:transport` — `:http` (default) or `:flight` (Arrow Flight gRPC).
    * `:flight_port` — gRPC port for `:flight`; falls back to the connection's
      `:flight_port`, then `443`. Pass `tls: false` for plaintext ports.

  ## Errors

  A connection that is neither a keyword list nor a map is
  `{:error, {:invalid_connection, connection}}`. A refused query is
  `{:error, %{status: http_status, body: message}}` on both transports: Flight's gRPC
  status is turned into the nearest HTTP one (see `InfluxElixir.Flight.Client.query/3`), but
  the two do not always agree on the status (a schema error is 500 over HTTP and 400 over
  Flight; a missing database is 404 and 500) and Flight's message keeps the engine's
  prefix (`Error while logically planning query: ...`).
  """
  @spec query_sql(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  def query_sql(connection, sql, opts \\ []) do
    connection = resolve_connection(connection)
    query_span(connection, opts, fn -> client().query_sql(connection, sql, opts) end)
  end

  @doc """
  Executes a streaming SQL query, returning a lazy Stream.

  Use for large result sets to avoid loading all rows into memory. On the HTTP
  transport the JSONL response is decoded incrementally with back-pressure, so
  only one chunk plus a partial line is held in memory regardless of result
  size.

  Because the return value is an `Enumerable.t()`, errors cannot be returned as
  an `{:error, reason}` tuple. Instead, failure classes — a missing database, a
  request its arguments cannot make, a non-success HTTP status, or a transport
  error — are raised as an `InfluxElixir.StreamError` when the stream is
  enumerated. This mirrors the
  `{:error, reason}` contract of `query_sql/3`: an outage surfaces as an
  exception, never as a silent empty result.

  ## Options

    * `:database` — overrides the connection-level default database.
    * `:params` — map of `$name => value` placeholder substitutions.
    * `:timeout` — per-call receive timeout in milliseconds.
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
  Sends a SQL statement to `/api/v3/query_sql` as it is.

  InfluxDB 3 Core refuses every statement that changes data (verified):
  `DELETE`, `INSERT` and `UPDATE` are `{:error, %{status: 400, body:
  "Error during planning: DML not supported: ..."}}`, `CREATE` and `DROP`
  are `... DDL not supported: ...`, anything else is a 405. A `SELECT`
  returns `{:ok, rows}` typed like `query_sql/3` rows. Remove data with
  `delete_database/2` instead. `Client.Local` answers the same way; under
  its `:v3_enterprise` profile it also runs `DELETE FROM m [WHERE ...]`
  and returns `{:ok, %{"rows_affected" => n}}`.
  """
  @spec execute_sql(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: {:ok, map() | [map()]} | {:error, term()}
  def execute_sql(connection, sql, opts \\ []) do
    connection = resolve_connection(connection)
    query_span(connection, opts, fn -> client().execute_sql(connection, sql, opts) end)
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
    connection = resolve_connection(connection)
    query_span(connection, opts, fn -> client().query_influxql(connection, influxql, opts) end)
  end

  # ---------- Query — v2 Flux (compat) ----------

  @doc """
  Executes a Flux query against InfluxDB v2 (backwards compatibility).
  """
  @spec query_flux(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  def query_flux(connection, flux, opts \\ []) do
    connection = resolve_connection(connection)
    query_span(connection, opts, fn -> client().query_flux(connection, flux, opts) end)
  end

  # ---------- Admin — v3 databases ----------

  @doc """
  Creates a database in InfluxDB v3. `opts` may carry `retention:` as a
  duration string such as `"30d"`; see `InfluxElixir.Admin.Databases.create/3`.
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
  Creates a bucket in InfluxDB v2 (backwards compatibility). `opts` may carry
  `retention:` in seconds and `org_id:`; see `InfluxElixir.Admin.Buckets.create/3`.
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
  Creates a named InfluxDB 3 token; see `InfluxElixir.Admin.Tokens.create/3`.
  """
  @spec create_token(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def create_token(connection, name, opts \\ []) do
    client().create_token(resolve_connection(connection), name, opts)
  end

  @doc """
  Deletes an InfluxDB 3 token by name; see `InfluxElixir.Admin.Tokens.delete/2`.
  """
  @spec delete_token(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_token(connection, name) do
    client().delete_token(resolve_connection(connection), name)
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
  Buffers a write on the batch writer of a connection.

  `connection_name` is a connection with a `batch_writer:` option (see
  `InfluxElixir.Config`). The payload is a `InfluxElixir.Write.Point`, a list of
  them, or line protocol (a binary or iodata); Points are encoded for the writer's
  `:precision` and the connection's `:api_version`, and one without a timestamp is
  stamped with the time of this call. See `InfluxElixir.Write.BatchWriter.write/3`
  for the buffering, the flush triggers and the backpressure.

  Returns `:ok` once the payload is buffered. Other results:

    * `{:error, :no_batch_writer}` - the connection has no writer running, or its writer
      stopped (the connection was removed) before it took this call
    * `{:error, :buffer_full}` - the writer holds as much as it admits while a
      batch is being retried
    * `{:error, reason}` - a point that cannot be encoded, a payload that is
      none of the forms above (`{:invalid_payload, payload}`), or, with
      `sync: true`, the write's own failure

  ## Options

    * `:sync` - `true` waits until the batch holding the payload has been written (or
      has failed all its retries) and returns that result, as
      `InfluxElixir.Write.BatchWriter.write_sync/3` does. Default `false`.
    * `:timeout` - bound on the call in milliseconds (default `60_000`; `300_000`
      with `sync: true`).

  ## Examples

      point = InfluxElixir.point("cpu", %{"value" => 0.64}, tags: %{"host" => "web01"})
      :ok = InfluxElixir.write_batched(:default, point)
      :ok = InfluxElixir.write_batched(:default, "cpu value=0.64", sync: true)
      :ok = InfluxElixir.flush(:default)
  """
  @spec write_batched(atom(), iodata() | Point.t() | [Point.t()], keyword()) ::
          :ok | {:error, term()}
  def write_batched(connection_name, payload, opts \\ []) when is_atom(connection_name) do
    if Options.keyword?(opts) do
      sync = Keyword.get(opts, :sync, false)
      timeout = Keyword.get(opts, :timeout) || if(sync, do: 300_000, else: 60_000)

      with_batch_writer(connection_name, fn writer ->
        if sync,
          do: BatchWriter.write_sync(writer, payload, timeout),
          else: BatchWriter.write(writer, payload, timeout)
      end)
    else
      {:error, {:invalid_options, opts}}
    end
  end

  @doc """
  Forces an immediate flush of the batch writer for a connection.

  Returns `:ok` on success or `{:error, :no_batch_writer}` if no
  batch writer is configured for the given connection.

  The optional `timeout` is forwarded to `BatchWriter.flush/2` and
  bounds the underlying `GenServer.call`. See `BatchWriter.flush/2`
  for the default and semantics.
  """
  @spec flush(atom(), timeout()) :: :ok | {:error, :no_batch_writer}
  def flush(connection_name, timeout \\ 60_000) do
    with_batch_writer(connection_name, &BatchWriter.flush(&1, timeout))
  end

  @doc """
  Returns batch writer statistics for a connection.

  Returns `{:ok, stats_map}` or `{:error, :no_batch_writer}` if no
  batch writer is configured for the given connection. The optional `timeout`
  (default `5_000` ms) bounds the call.
  """
  @spec stats(atom(), timeout()) :: {:ok, map()} | {:error, :no_batch_writer}
  def stats(connection_name, timeout \\ 5_000) do
    with_batch_writer(connection_name, &BatchWriter.stats(&1, timeout))
  end

  # A process that is gone, or stopped as a supervisor stops it, rather than one that crashed.
  defguardp stopped(reason)
            when reason in [:noproc, :normal, :shutdown] or
                   (is_tuple(reason) and tuple_size(reason) == 2 and elem(reason, 0) == :shutdown)

  # Runs `fun` with the connection's batch writer, if it has one. A writer that stops between
  # the lookup and the call, or with the call in its mailbox (it answers the calls it has taken
  # before it stops), is no writer. A timeout is the caller's bound, and exits as documented.
  @spec with_batch_writer(atom(), (atom() -> result)) :: result | {:error, :no_batch_writer}
        when result: term()
  defp with_batch_writer(connection_name, fun) do
    writer = InfluxElixir.ConnectionSupervisor.batch_writer_name(connection_name)

    if Process.whereis(writer) do
      try do
        fun.(writer)
      catch
        :exit, {reason, {GenServer, :call, _args}} when stopped(reason) ->
          {:error, :no_batch_writer}
      end
    else
      {:error, :no_batch_writer}
    end
  end

  # ---------- Dynamic Connections ----------

  @doc """
  Adds a new named connection dynamically at runtime.

  If the connection does not start — a `batch_writer:` option that
  `InfluxElixir.Write.BatchWriter` refuses, say — the error is returned
  and nothing is left behind: the name does not resolve and the client's
  connection state is released. The error never holds the `:token`.

  A config the client refuses is `{:error, {reason, child_spec}}`, never a
  raise: under `InfluxElixir.Client.HTTP` the `%NimbleOptions.ValidationError{}`
  of `InfluxElixir.Config.validate/1` (an unknown option such as
  `default_database:`, say), under `InfluxElixir.Client.Local` the
  `%ArgumentError{}` of `InfluxElixir.Client.Local.start/1`.
  """
  @spec add_connection(atom(), keyword()) :: Supervisor.on_start_child()
  def add_connection(name, opts) do
    if Options.keyword?(opts),
      do: start_connection(name, opts),
      else: {:error, {:invalid_options, opts}}
  end

  @spec start_connection(atom(), keyword()) :: Supervisor.on_start_child()
  defp start_connection(name, opts) do
    config = Keyword.put(opts, :name, name)

    child_spec =
      Supervisor.child_spec(
        {InfluxElixir.ConnectionSupervisor, config},
        id: {InfluxElixir.ConnectionSupervisor, name}
      )

    # A connection that fails to start has released what it set up: the client's error
    # registered nothing, and the registration a child's failure stopped took itself down.
    # Erasing the name here as well could erase another call's connection, started under the
    # same name in the meantime.
    Supervisor.start_child(InfluxElixir.Supervisor, child_spec)
  end

  @doc """
  Removes a named connection dynamically at runtime.

  The connection's batch writer, if any, writes what it still holds
  before it stops (see "Shutdown" in `InfluxElixir.Write.BatchWriter`).
  """
  @spec remove_connection(atom()) :: :ok | {:error, term()}
  def remove_connection(name) do
    child_id = {InfluxElixir.ConnectionSupervisor, name}

    case Supervisor.terminate_child(InfluxElixir.Supervisor, child_id) do
      # The supervisor's first child erased the name and released the client's state (the ETS
      # store of `Client.Local`) as the supervisor stopped.
      :ok -> Supervisor.delete_child(InfluxElixir.Supervisor, child_id)
      {:error, reason} -> {:error, reason}
    end
  end
end
