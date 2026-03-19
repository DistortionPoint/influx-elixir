defmodule InfluxElixir.Client.Local do
  @moduledoc """
  In-memory InfluxDB client for fast, isolated testing.

  Stores data in ETS tables, enabling safe `async: true` tests with full
  isolation between test instances. Each call to `start/1` creates an
  independent ETS table.

  Parses real line protocol on write, stores points as maps, and responds
  with realistic InfluxDB response formats on query.

  ## Profiles

  LocalClient enforces an InfluxDB **version profile** that determines
  which operations are available. This prevents tests from accidentally
  using operations that the real InfluxDB backend doesn't support.

  | Profile | Write | SQL | InfluxQL | Flux | DB CRUD | Bucket CRUD | Tokens |
  |---|---|---|---|---|---|---|---|
  | `:v3_core` | yes | yes | yes | no | yes | no | no |
  | `:v3_enterprise` | yes | yes | yes | no | yes | no | yes |
  | `:v2` | yes | no | no | yes | no | yes | no |

  Operations outside the configured profile return
  `{:error, :unsupported_operation}`.

  ## Usage

      # Match your production InfluxDB version
      setup do
        {:ok, conn} = InfluxElixir.Client.Local.start(
          databases: ["test_db"],
          profile: :v3_core
        )
        on_exit(fn -> InfluxElixir.Client.Local.stop(conn) end)
        {:ok, conn: conn}
      end

  ## Checking Profile Support

  Use `supports?/2` to check if an operation is available:

      if Local.supports?(conn, :query_sql) do
        Local.query_sql(conn, "SELECT * FROM cpu", database: "test_db")
      end

  ## ETS Key Layout

    * `:databases` => `MapSet.t(binary())` — set of created database names
    * `:buckets` => `MapSet.t(binary())` — set of created bucket names
    * `:tokens` => `[map()]` — list of token maps
    * `{:points, database, measurement}` => `[point_map()]` — stored points

  ## SQL Query Support

  `query_sql/3` understands a subset of SQL:

    * `SELECT * FROM measurement`
    * `WHERE tag = 'value'` or `WHERE field > N` (supports AND)
    * `ORDER BY time ASC|DESC`
    * `LIMIT N`
    * `$param` placeholders via `params: %{"$name" => value}` in opts
    * `DATE_BIN(INTERVAL 'N unit', time)` time bucketing
    * Aggregate functions: `AVG`, `SUM`, `COUNT`, `MIN`, `MAX`
    * Ordered aggregates: `first(field, time)`, `last(field, time)`
    * `GROUP BY DATE_BIN(INTERVAL 'N unit', time)`
    * Interval units: `seconds`, `minutes`, `hours`, `days`

  ## Gzip Decompression

  If a write payload begins with gzip magic bytes (0x1F 0x8B) it is
  automatically decompressed before line protocol parsing.

  ## Timestamp Precision

  Pass `precision: :nanosecond | :microsecond | :millisecond | :second`
  in opts to normalise stored timestamps to nanoseconds.
  """

  @behaviour InfluxElixir.Client

  @type point_map :: %{
          measurement: binary(),
          tags: %{binary() => binary()},
          fields: %{binary() => term()},
          timestamp: integer() | nil
        }

  @type profile :: :v3_core | :v3_enterprise | :v2

  @type conn :: %{
          table: :ets.table(),
          databases: MapSet.t(binary()),
          profile: profile()
        }

  # Operations supported by each profile.
  # An operation not in the list returns {:error, :unsupported_operation}.
  @profile_capabilities %{
    v3_core: [
      :health,
      :write,
      :query_sql,
      :query_sql_stream,
      :execute_sql,
      :query_influxql,
      :create_database,
      :list_databases,
      :delete_database
    ],
    v3_enterprise: [
      :health,
      :write,
      :query_sql,
      :query_sql_stream,
      :execute_sql,
      :query_influxql,
      :create_database,
      :list_databases,
      :delete_database,
      :create_token,
      :delete_token
    ],
    v2: [
      :health,
      :write,
      :query_flux,
      :create_bucket,
      :list_buckets,
      :delete_bucket
    ]
  }

  # Gzip magic bytes
  @gzip_magic <<0x1F, 0x8B>>

  # Measurement names may contain escaped spaces (e.g. "my\ measurement").
  # This captures everything up to the first unescaped space or end-of-line.
  @measurement_pattern ~r/(?i)SELECT\s+\*\s+FROM\s+(?:"([^"]+)"|((?:[^\s\\]|\\.)+))(.*)/s

  # ---------------------------------------------------------------------------
  # Connection lifecycle (behaviour callbacks)
  # ---------------------------------------------------------------------------

  @impl true
  @spec init_connection(keyword()) :: {:ok, conn()}
  def init_connection(config) do
    databases = Keyword.get(config, :databases, [])
    profile = Keyword.get(config, :profile, :v3_core)
    start(databases: databases, profile: profile)
  end

  @impl true
  @spec shutdown_connection(conn()) :: :ok
  def shutdown_connection(conn), do: stop(conn)

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Starts a new LocalClient instance with isolated ETS storage.

  ## Options

    * `:databases` - list of database names to pre-create (default: `[]`)
    * `:profile` - InfluxDB version profile to emulate. Determines which
      operations are available. Operations outside the profile return
      `{:error, :unsupported_operation}`. Valid values:
      - `:v3_core` (default) — write, SQL, InfluxQL, database CRUD
      - `:v3_enterprise` — everything in v3_core plus token management
      - `:v2` — write, Flux, bucket CRUD

  ## Examples

      iex> {:ok, conn} = InfluxElixir.Client.Local.start(databases: ["mydb"])
      iex> conn.profile
      :v3_core

      iex> {:ok, conn} = InfluxElixir.Client.Local.start(profile: :v2)
      iex> conn.profile
      :v2
  """
  @spec start(keyword()) :: {:ok, conn()}
  def start(opts \\ []) do
    profile = Keyword.get(opts, :profile, :v3_core)

    unless Map.has_key?(@profile_capabilities, profile) do
      raise ArgumentError,
            "invalid profile: #{inspect(profile)}. " <>
              "Must be one of: :v3_core, :v3_enterprise, :v2"
    end

    # :public access is intentional — allows async: true tests where
    # the test process and the LocalClient caller are different processes.
    # A GenServer wrapper would be correct for production but adds latency
    # and complexity to a test-only client.
    table = :ets.new(:influx_local, [:set, :public])
    # Always include "default" so writes without an explicit database: opt succeed.
    databases =
      opts
      |> Keyword.get(:databases, [])
      |> then(&["default" | &1])
      |> MapSet.new()

    :ets.insert(table, {:databases, databases})
    :ets.insert(table, {:buckets, MapSet.new()})
    :ets.insert(table, {:tokens, []})

    conn = %{table: table, databases: databases, profile: profile}
    {:ok, conn}
  end

  @doc """
  Returns `true` if the given operation is supported by the connection's profile.
  """
  @spec supports?(conn(), atom()) :: boolean()
  def supports?(%{profile: profile}, operation) do
    operation in Map.fetch!(@profile_capabilities, profile)
  end

  @spec require_capability(conn(), atom()) ::
          :ok | {:error, :unsupported_operation}
  defp require_capability(conn, operation) do
    if supports?(conn, operation), do: :ok, else: {:error, :unsupported_operation}
  end

  @doc """
  Stops a LocalClient instance and cleans up its ETS table.

  Safe to call multiple times; a no-op if the table is already deleted.
  """
  @spec stop(conn()) :: :ok
  def stop(%{table: table}) do
    if :ets.info(table) != :undefined do
      :ets.delete(table)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Write
  # ---------------------------------------------------------------------------

  @doc """
  Parses line protocol binary and stores the resulting points in ETS.

  The `database` is read from `opts[:database]`. If the database does not
  exist an `{:error, %{status: 404, body: ...}}` is returned. If line protocol
  cannot be parsed an `{:error, %{status: 400, body: ...}}` is returned.

  Payloads beginning with gzip magic bytes are automatically decompressed.
  Pass `precision: :nanosecond | :microsecond | :millisecond | :second` to
  control how numeric timestamps are interpreted (default: `:nanosecond`).
  """
  @impl true
  @spec write(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.write_result()
  def write(%{table: table, profile: profile} = conn, payload, opts \\ []) do
    database = Keyword.get(opts, :database, "default")
    precision = Keyword.get(opts, :precision, :nanosecond)

    with :ok <- require_capability(conn, :write),
         {:ok, text} <- maybe_decompress(payload),
         :ok <- ensure_database(table, database, profile),
         {:ok, points} <- parse_line_protocol(text, precision) do
      Enum.each(points, &store_point(table, database, &1))
      {:ok, :written}
    end
  end

  # ---------------------------------------------------------------------------
  # SQL Query
  # ---------------------------------------------------------------------------

  @doc """
  Executes a SQL-like query against stored ETS points and returns rows.

  Supports:

    * `SELECT * FROM measurement`
    * `SELECT DISTINCT column FROM measurement`
    * `WHERE key = 'value'` / `WHERE key > N` / `WHERE key < N`
    * `ORDER BY time ASC|DESC`
    * `LIMIT N`
    * `$param` placeholder substitution via `params: %{"$name" => value}`
  """
  @impl true
  @spec query_sql(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  def query_sql(%{table: table} = conn, sql, opts \\ []) do
    with :ok <- require_capability(conn, :query_sql) do
      params = Keyword.get(opts, :params, %{})
      database = Keyword.get(opts, :database, "default")
      resolved_sql = resolve_params(sql, params)

      case parse_select(resolved_sql) do
        {:ok, query} ->
          case execute_query(table, query, database) do
            {:error, _reason} = err -> err
            rows -> {:ok, rows}
          end

        {:error, _reason} = err ->
          err
      end
    end
  end

  @doc """
  Executes a SQL query and returns results as a lazy `Stream`.

  Delegates to `query_sql/3` then wraps the list in a stream.
  """
  @impl true
  @spec query_sql_stream(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: Enumerable.t()
  def query_sql_stream(conn, sql, opts \\ []) do
    case require_capability(conn, :query_sql_stream) do
      :ok ->
        case query_sql(conn, sql, opts) do
          {:ok, rows} -> Stream.map(rows, & &1)
          {:error, _reason} -> Stream.map([], & &1)
        end

      {:error, :unsupported_operation} ->
        Stream.map([], & &1)
    end
  end

  @doc """
  Executes a SQL statement and returns a summary map.

  Supports `DELETE FROM <measurement>` and
  `DELETE FROM <measurement> WHERE ...` — matching points are removed
  from ETS and the count is returned in `%{"rows_affected" => N}`.

  On `:v3_core` profile, DELETE is not supported (matches real InfluxDB v3
  Core behavior) and returns `{:error, :delete_not_supported}`.

  On `:v3_enterprise` profile, DELETE is supported.

  Unknown statements return `%{"rows_affected" => 0}`.
  """
  @impl true
  @spec execute_sql(InfluxElixir.Client.connection(), binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_sql(%{table: table, profile: profile} = conn, sql, opts \\ []) do
    with :ok <- require_capability(conn, :execute_sql) do
      database = Keyword.get(opts, :database, "default")
      trimmed = String.trim(sql)

      case Regex.run(~r/^(?i)DELETE\s+FROM\s+((?:[^\s\\]|\\.)+)(.*)$/s, trimmed) do
        [_full, measurement_raw, rest] ->
          if profile == :v3_core do
            {:error, :delete_not_supported}
          else
            measurement = unescape_measurement(measurement_raw)
            where = parse_where(rest)
            count = delete_points(table, database, measurement, where)
            {:ok, %{"rows_affected" => count}}
          end

        _no_match ->
          {:ok, %{"rows_affected" => 0}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxQL / Flux queries (delegate to SQL engine)
  # ---------------------------------------------------------------------------

  @doc """
  Executes an InfluxQL query.

  Supports InfluxQL-specific commands:

    * `SHOW DATABASES` — returns all databases
    * `SHOW MEASUREMENTS` — returns all measurement names
    * `SHOW TAG KEYS FROM <measurement>` — returns distinct tag keys
    * `SELECT ...` — delegates to the SQL engine
  """
  @impl true
  @spec query_influxql(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  def query_influxql(%{table: table} = conn, influxql, opts \\ []) do
    with :ok <- require_capability(conn, :query_influxql) do
      do_query_influxql(table, conn, influxql, opts)
    end
  end

  defp do_query_influxql(table, conn, influxql, opts) do
    trimmed = String.trim(influxql)
    database = Keyword.get(opts, :database, "default")

    cond do
      String.match?(trimmed, ~r/^(?i)SHOW\s+DATABASES\s*$/) ->
        dbs =
          table
          |> get_databases()
          |> Enum.map(&%{"iox::database" => &1})

        {:ok, dbs}

      String.match?(trimmed, ~r/^(?i)SHOW\s+MEASUREMENTS\s*$/) ->
        measurements =
          :ets.match_object(table, {{:points, database, :_}, :_})
          |> Enum.map(fn {{:points, _db, m}, _pts} -> m end)
          |> Enum.uniq()
          |> Enum.map(&%{"iox::measurement" => "measurements", "name" => &1})

        {:ok, measurements}

      match?(
        [_full, _capture],
        Regex.run(~r/^(?i)SHOW\s+TAG\s+KEYS\s+FROM\s+(\S+)\s*$/, trimmed)
      ) ->
        [_full, measurement_raw] =
          Regex.run(~r/^(?i)SHOW\s+TAG\s+KEYS\s+FROM\s+(\S+)\s*$/, trimmed)

        measurement = unescape_measurement(measurement_raw)
        points = fetch_points(table, database, measurement)

        tag_keys =
          points
          |> Enum.flat_map(&Map.keys(&1.tags))
          |> Enum.uniq()
          |> Enum.map(&%{"iox::measurement" => measurement, "tagKey" => &1})

        {:ok, tag_keys}

      true ->
        query_sql(conn, influxql, opts)
    end
  end

  @doc """
  Executes a Flux query with support for common predicates.

  Parses and applies:

    * `from(bucket: "...")` — scopes to a database
    * `range(start: -1h)` — filters by timestamp (supports `-Nh`, `-Nd`, `-Nm`)
    * `filter(fn: (r) => r._measurement == "...")` — filters by measurement
    * `filter(fn: (r) => r.<key> == "...")` — filters by any tag/field equality
  """
  @impl true
  @spec query_flux(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  def query_flux(%{table: table} = conn, flux, _opts \\ []) do
    with :ok <- require_capability(conn, :query_flux) do
      database = extract_flux_bucket(flux)
      measurement = extract_flux_measurement(flux)

      points =
        case {database, measurement} do
          {nil, _any} -> all_points(table)
          {db, nil} -> all_points_in_db(table, db)
          {db, m} -> fetch_points(table, db, m)
        end

      points
      |> apply_flux_range(flux)
      |> apply_flux_filters(flux)
      |> Enum.map(&flux_point_to_row/1)
      |> then(&{:ok, &1})
    end
  end

  # ---------------------------------------------------------------------------
  # Database admin
  # ---------------------------------------------------------------------------

  @doc """
  Creates a named database in this local instance.

  Always succeeds — creating an already-existing database is idempotent.
  """
  @impl true
  @spec create_database(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_database(%{table: table} = conn, name, _opts \\ []) do
    with :ok <- require_capability(conn, :create_database) do
      databases = get_databases(table)
      :ets.insert(table, {:databases, MapSet.put(databases, name)})
      :ok
    end
  end

  @doc """
  Returns all databases created in this local instance as a list of maps
  with a single `:name` key.
  """
  @impl true
  @spec list_databases(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_databases(%{table: table} = conn) do
    with :ok <- require_capability(conn, :list_databases) do
      dbs =
        table
        |> get_databases()
        |> Enum.map(&%{"name" => &1})

      {:ok, dbs}
    end
  end

  @doc """
  Deletes a database from this local instance.

  Returns `{:error, %{status: 404, body: "database not found: name"}}` if
  the database does not exist.
  """
  @impl true
  @spec delete_database(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_database(%{table: table} = conn, name) do
    with :ok <- require_capability(conn, :delete_database) do
      databases = get_databases(table)

      if MapSet.member?(databases, name) do
        :ets.insert(table, {:databases, MapSet.delete(databases, name)})
        :ok
      else
        {:error, %{status: 404, body: "database not found: #{name}"}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Bucket admin (v2 compat)
  # ---------------------------------------------------------------------------

  @doc """
  Creates a named bucket in this local instance.

  Creating an already-existing bucket is idempotent.
  """
  @impl true
  @spec create_bucket(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_bucket(%{table: table} = conn, name, _opts \\ []) do
    with :ok <- require_capability(conn, :create_bucket) do
      buckets = get_buckets(table)
      :ets.insert(table, {:buckets, MapSet.put(buckets, name)})
      :ok
    end
  end

  @doc """
  Returns all buckets in this local instance as a list of maps with a
  single `:name` key.
  """
  @impl true
  @spec list_buckets(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_buckets(%{table: table} = conn) do
    with :ok <- require_capability(conn, :list_buckets) do
      bkts =
        table
        |> get_buckets()
        |> Enum.map(fn name ->
          %{"id" => bucket_id(name), "name" => name}
        end)

      {:ok, bkts}
    end
  end

  @doc """
  Deletes a bucket from this local instance.

  Returns `:ok` whether or not the bucket exists, matching the idempotent
  delete semantics of the v2 API.
  """
  @impl true
  @spec delete_bucket(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_bucket(%{table: table} = conn, name) do
    with :ok <- require_capability(conn, :delete_bucket) do
      buckets = get_buckets(table)
      :ets.insert(table, {:buckets, MapSet.delete(buckets, name)})
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Token admin
  # ---------------------------------------------------------------------------

  @doc """
  Creates a synthetic API token and stores it in ETS.

  Returns `{:ok, %{id: id, token: token_string, description: desc}}`.
  """
  @impl true
  @spec create_token(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def create_token(%{table: table} = conn, description, _opts \\ []) do
    with :ok <- require_capability(conn, :create_token) do
      id = generate_id()
      token_string = "local-token-#{id}"

      token = %{
        "id" => id,
        "token" => token_string,
        "description" => description
      }

      tokens = get_tokens(table)
      :ets.insert(table, {:tokens, [token | tokens]})
      {:ok, token}
    end
  end

  @doc """
  Deletes a token by its `id` field. Returns `:ok` even if the token was
  not found, matching real InfluxDB delete semantics.
  """
  @impl true
  @spec delete_token(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_token(%{table: table} = conn, token_id) do
    with :ok <- require_capability(conn, :delete_token) do
      tokens = get_tokens(table)
      updated = Enum.reject(tokens, &(&1["id"] == token_id))
      :ets.insert(table, {:tokens, updated})
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Health
  # ---------------------------------------------------------------------------

  @doc """
  Returns a passing health status map with string keys, matching the
  JSON-decoded shape returned by the HTTP client.
  """
  @impl true
  @spec health(InfluxElixir.Client.connection()) ::
          {:ok, map()} | {:error, term()}
  def health(conn) do
    with :ok <- require_capability(conn, :health) do
      {:ok, %{"status" => "pass", "version" => "local"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — ETS helpers
  # ---------------------------------------------------------------------------

  @spec get_databases(:ets.table()) :: MapSet.t(binary())
  defp get_databases(table) do
    case :ets.lookup(table, :databases) do
      [{:databases, dbs}] -> dbs
      [] -> MapSet.new()
    end
  end

  @spec get_buckets(:ets.table()) :: MapSet.t(binary())
  defp get_buckets(table) do
    case :ets.lookup(table, :buckets) do
      [{:buckets, bkts}] -> bkts
      [] -> MapSet.new()
    end
  end

  @spec get_tokens(:ets.table()) :: [map()]
  defp get_tokens(table) do
    case :ets.lookup(table, :tokens) do
      [{:tokens, ts}] -> ts
      [] -> []
    end
  end

  @spec assert_database_exists(:ets.table(), binary()) :: :ok | {:error, map()}
  defp assert_database_exists(table, database) do
    databases = get_databases(table)

    if MapSet.member?(databases, database) do
      :ok
    else
      {:error, %{status: 404, body: "database not found: #{database}"}}
    end
  end

  # v3 Core/Enterprise auto-create databases on write; v2 requires pre-existing
  @spec ensure_database(:ets.table(), binary(), profile()) :: :ok | {:error, term()}
  defp ensure_database(table, database, profile) when profile in [:v3_core, :v3_enterprise] do
    databases = get_databases(table)

    unless MapSet.member?(databases, database) do
      :ets.insert(table, {:databases, MapSet.put(databases, database)})
    end

    :ok
  end

  defp ensure_database(table, database, _profile) do
    assert_database_exists(table, database)
  end

  @spec store_point(:ets.table(), binary(), point_map()) :: true
  defp store_point(table, database, point) do
    # Real InfluxDB assigns a server timestamp when none is provided.
    point = assign_default_timestamp(point)
    key = {:points, database, point.measurement}

    existing =
      case :ets.lookup(table, key) do
        [{^key, pts}] -> pts
        [] -> []
      end

    :ets.insert(table, {key, [point | existing]})
  end

  @spec assign_default_timestamp(point_map()) :: point_map()
  defp assign_default_timestamp(%{timestamp: nil} = point) do
    %{point | timestamp: System.system_time(:nanosecond)}
  end

  defp assign_default_timestamp(point), do: point

  @spec fetch_points(:ets.table(), binary(), binary()) :: [point_map()]
  @spec measurement_exists?(:ets.table(), binary(), binary()) :: boolean()
  defp measurement_exists?(table, database, measurement) do
    key = {:points, database, measurement}
    :ets.lookup(table, key) != []
  end

  defp fetch_points(table, database, measurement) do
    key = {:points, database, measurement}

    case :ets.lookup(table, key) do
      [{^key, pts}] -> pts
      [] -> []
    end
  end

  @spec all_points_in_db(:ets.table(), binary()) :: [point_map()]
  defp all_points_in_db(table, database) do
    :ets.match_object(table, {{:points, database, :_}, :_})
    |> Enum.flat_map(fn {_key, pts} -> pts end)
  end

  @spec all_points(:ets.table()) :: [point_map()]
  defp all_points(table) do
    :ets.match_object(table, {{:points, :_, :_}, :_})
    |> Enum.flat_map(fn {_key, pts} -> pts end)
  end

  # ---------------------------------------------------------------------------
  # Private — gzip decompression
  # ---------------------------------------------------------------------------

  @spec maybe_decompress(binary()) :: {:ok, binary()} | {:error, map()}
  defp maybe_decompress(<<@gzip_magic, _rest::binary>> = compressed) do
    {:ok, :zlib.gunzip(compressed)}
  rescue
    _err -> {:error, %{status: 400, body: "invalid gzip payload"}}
  end

  defp maybe_decompress(plain), do: {:ok, plain}

  # ---------------------------------------------------------------------------
  # Private — line protocol parser
  # ---------------------------------------------------------------------------

  @spec parse_line_protocol(binary(), atom()) ::
          {:ok, [point_map()]} | {:error, map()}
  defp parse_line_protocol(text, precision) do
    lines =
      text
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(&1, "#")))

    lines
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case parse_line(line, precision) do
        {:ok, point} -> {:cont, {:ok, [point | acc]}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, pts} -> {:ok, Enum.reverse(pts)}
      {:error, _reason} = err -> err
    end
  end

  # Parses a single line protocol line into a point map.
  #
  # Format: measurement[,tag=val...] field=val[,...] [timestamp]
  @spec parse_line(binary(), atom()) :: {:ok, point_map()} | {:error, map()}
  defp parse_line(line, precision) do
    case split_line_parts(line) do
      [key_part, fields_part | rest] ->
        ts_raw = List.first(rest)

        with {:ok, {measurement, tags}} <- parse_key_part(key_part),
             {:ok, fields} <- parse_fields_part(fields_part),
             {:ok, timestamp} <- parse_timestamp(ts_raw, precision) do
          {:ok,
           %{
             measurement: measurement,
             tags: tags,
             fields: fields,
             timestamp: timestamp
           }}
        end

      _parts ->
        {:error, %{status: 400, body: "invalid line protocol: #{line}"}}
    end
  end

  # Splits a line into [key_part, fields_part, optional_timestamp] by
  # unescaped spaces that are not inside double-quoted strings.
  @spec split_line_parts(binary()) :: [binary()]
  defp split_line_parts(line) do
    do_lp_split(line, [], [], false)
  end

  # End of input — flush remaining token.
  defp do_lp_split(<<>>, current, acc, _in_quotes) do
    token = current |> Enum.reverse() |> IO.iodata_to_binary()
    Enum.reverse([token | acc])
  end

  # Escaped backslash — keep both chars, quote state unchanged.
  defp do_lp_split(<<"\\\\", rest::binary>>, current, acc, in_quotes) do
    do_lp_split(rest, ["\\", "\\" | current], acc, in_quotes)
  end

  # Escaped double-quote — keep both chars, do not toggle quote state.
  defp do_lp_split(<<"\\\"", rest::binary>>, current, acc, in_quotes) do
    do_lp_split(rest, ["\"", "\\" | current], acc, in_quotes)
  end

  # Escaped space outside quotes — keep both chars, no split.
  defp do_lp_split(<<"\\ ", rest::binary>>, current, acc, false) do
    do_lp_split(rest, [" ", "\\" | current], acc, false)
  end

  # Unescaped double-quote — toggle in_quotes flag.
  defp do_lp_split(<<"\"", rest::binary>>, current, acc, in_quotes) do
    do_lp_split(rest, ["\"" | current], acc, !in_quotes)
  end

  # Unescaped space outside a quoted string — emit token.
  defp do_lp_split(<<" ", rest::binary>>, current, acc, false) do
    token = current |> Enum.reverse() |> IO.iodata_to_binary()
    do_lp_split(rest, [], [token | acc], false)
  end

  # All other characters — accumulate.
  defp do_lp_split(<<c::binary-size(1), rest::binary>>, current, acc, in_quotes) do
    do_lp_split(rest, [c | current], acc, in_quotes)
  end

  # Parses the "measurement[,tag=val...]" part.
  @spec parse_key_part(binary()) :: {:ok, {binary(), map()}} | {:error, map()}
  defp parse_key_part(key_part) do
    case split_first_unescaped_comma(key_part) do
      {measurement_raw, ""} ->
        {:ok, {unescape_measurement(measurement_raw), %{}}}

      {measurement_raw, tags_raw} ->
        with {:ok, tags} <- parse_tags(tags_raw) do
          {:ok, {unescape_measurement(measurement_raw), tags}}
        end
    end
  end

  # Splits at the first unescaped comma.
  @spec split_first_unescaped_comma(binary()) :: {binary(), binary()}
  defp split_first_unescaped_comma(str) do
    do_split_comma(str, [])
  end

  defp do_split_comma(<<>>, acc) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}
  end

  defp do_split_comma(<<"\\,", rest::binary>>, acc) do
    do_split_comma(rest, [",", "\\" | acc])
  end

  defp do_split_comma(<<",", rest::binary>>, acc) do
    left = acc |> Enum.reverse() |> IO.iodata_to_binary()
    {left, rest}
  end

  defp do_split_comma(<<c::binary-size(1), rest::binary>>, acc) do
    do_split_comma(rest, [c | acc])
  end

  # Parses "tag1=v1,tag2=v2,..." into a map.
  @spec parse_tags(binary()) :: {:ok, map()} | {:error, map()}
  defp parse_tags(tags_str) do
    pairs = split_unescaped_comma(tags_str)

    Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
      case split_first_unescaped_equals(pair) do
        {k, v} when k != "" and v != "" ->
          {:cont, {:ok, Map.put(acc, unescape_tag(k), unescape_tag(v))}}

        _invalid ->
          {:halt, {:error, %{status: 400, body: "invalid tag pair: #{pair}"}}}
      end
    end)
  end

  # Parses the "field=val[,...]" section.
  @spec parse_fields_part(binary()) :: {:ok, map()} | {:error, map()}
  defp parse_fields_part(fields_str) do
    pairs = split_unescaped_comma(fields_str)

    Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
      case split_first_unescaped_equals(pair) do
        {k, v} when k != "" and v != "" ->
          case parse_field_value(v) do
            {:ok, typed} -> {:cont, {:ok, Map.put(acc, unescape_tag(k), typed)}}
            {:error, _reason} = err -> {:halt, err}
          end

        _invalid ->
          {:halt, {:error, %{status: 400, body: "invalid field pair: #{pair}"}}}
      end
    end)
  end

  # Splits a CSV-like string on unescaped commas, respecting quoted strings.
  @spec split_unescaped_comma(binary()) :: [binary()]
  defp split_unescaped_comma(str) do
    do_csv_split(str, [], [], false)
  end

  defp do_csv_split(<<>>, current, acc, _in_quotes) do
    token = current |> Enum.reverse() |> IO.iodata_to_binary()
    Enum.reverse([token | acc])
  end

  defp do_csv_split(<<"\\\"", rest::binary>>, current, acc, in_quotes) do
    do_csv_split(rest, ["\"", "\\" | current], acc, in_quotes)
  end

  defp do_csv_split(<<"\"", rest::binary>>, current, acc, in_quotes) do
    do_csv_split(rest, ["\"" | current], acc, !in_quotes)
  end

  defp do_csv_split(<<"\\,", rest::binary>>, current, acc, in_quotes) do
    do_csv_split(rest, [",", "\\" | current], acc, in_quotes)
  end

  defp do_csv_split(<<",", rest::binary>>, current, acc, false) do
    token = current |> Enum.reverse() |> IO.iodata_to_binary()
    do_csv_split(rest, [], [token | acc], false)
  end

  defp do_csv_split(<<c::binary-size(1), rest::binary>>, current, acc, in_quotes) do
    do_csv_split(rest, [c | current], acc, in_quotes)
  end

  # Splits at the first unescaped = sign.
  @spec split_first_unescaped_equals(binary()) :: {binary(), binary()}
  defp split_first_unescaped_equals(str) do
    do_split_eq(str, [])
  end

  defp do_split_eq(<<>>, acc) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}
  end

  defp do_split_eq(<<"\\=", rest::binary>>, acc) do
    do_split_eq(rest, ["=", "\\" | acc])
  end

  defp do_split_eq(<<"=", rest::binary>>, acc) do
    left = acc |> Enum.reverse() |> IO.iodata_to_binary()
    {left, rest}
  end

  defp do_split_eq(<<c::binary-size(1), rest::binary>>, acc) do
    do_split_eq(rest, [c | acc])
  end

  # Parses a field value string into its typed Elixir equivalent.
  @spec parse_field_value(binary()) :: {:ok, term()} | {:error, map()}
  defp parse_field_value(str) do
    cond do
      String.ends_with?(str, "i") ->
        case Integer.parse(String.slice(str, 0..-2//1)) do
          {n, ""} -> {:ok, n}
          _err -> {:error, %{status: 400, body: "invalid integer field: #{str}"}}
        end

      String.starts_with?(str, "\"") and String.ends_with?(str, "\"") ->
        inner =
          str
          |> String.slice(1..-2//1)
          |> String.replace("\\\"", "\"")
          |> String.replace("\\\\", "\\")

        {:ok, inner}

      str in ["true", "True", "TRUE"] ->
        {:ok, true}

      str in ["false", "False", "FALSE"] ->
        {:ok, false}

      true ->
        case Float.parse(str) do
          {f, ""} -> {:ok, f}
          _err -> {:error, %{status: 400, body: "invalid field value: #{str}"}}
        end
    end
  end

  # Parses a raw timestamp string, normalising to nanoseconds.
  @spec parse_timestamp(binary() | nil, atom()) ::
          {:ok, integer() | nil} | {:error, map()}
  defp parse_timestamp(nil, _prec), do: {:ok, nil}
  defp parse_timestamp("", _prec), do: {:ok, nil}

  defp parse_timestamp(ts_str, precision) do
    case Integer.parse(ts_str) do
      {ts, ""} -> {:ok, to_nanoseconds(ts, precision)}
      _err -> {:error, %{status: 400, body: "invalid timestamp: #{ts_str}"}}
    end
  end

  @spec to_nanoseconds(integer(), atom()) :: integer()
  defp to_nanoseconds(ts, :nanosecond), do: ts
  defp to_nanoseconds(ts, :microsecond), do: ts * 1_000
  defp to_nanoseconds(ts, :millisecond), do: ts * 1_000_000
  defp to_nanoseconds(ts, :second), do: ts * 1_000_000_000

  # Unescape a measurement name (backslash, comma, space).
  @spec unescape_measurement(binary()) :: binary()
  defp unescape_measurement(str) do
    str
    |> String.trim("\"")
    |> String.replace("\\ ", " ")
    |> String.replace("\\,", ",")
    |> String.replace("\\\\", "\\")
  end

  # Unescape a tag key or value (backslash, comma, equals, space).
  @spec unescape_tag(binary()) :: binary()
  defp unescape_tag(str) do
    str
    |> String.replace("\\ ", " ")
    |> String.replace("\\,", ",")
    |> String.replace("\\=", "=")
    |> String.replace("\\\\", "\\")
  end

  # ---------------------------------------------------------------------------
  # Private — SQL query engine
  # ---------------------------------------------------------------------------

  @type select_column ::
          {:time_bucket, binary()}
          | {:aggregate, :avg | :sum | :count | :min | :max, binary(), binary()}
          | {:ordered_aggregate, :first | :last, binary(), binary(), binary()}

  @type parsed_query :: %{
          measurement: binary(),
          where: [{:eq | :gt | :lt | :gte | :lte | :ne, binary(), term()}],
          order_by: {:time, :asc | :desc} | nil,
          limit: pos_integer() | nil,
          group_by_interval: pos_integer() | nil,
          select_columns: [select_column()] | nil,
          distinct_column: binary() | nil
        }

  # Aggregate function names recognised by the parser.
  @aggregate_functions ~w(AVG SUM COUNT MIN MAX FIRST LAST)

  @spec parse_select(binary()) :: {:ok, parsed_query()} | {:error, term()}
  defp parse_select(sql) do
    normalised = String.trim(sql)

    cond do
      distinct_query?(normalised) -> parse_distinct_select(normalised)
      aggregate_query?(normalised) -> parse_aggregate_select(normalised)
      true -> parse_star_select(normalised)
    end
  end

  @spec distinct_query?(binary()) :: boolean()
  defp distinct_query?(sql) do
    String.match?(sql, ~r/(?i)^\s*SELECT\s+DISTINCT\s+/)
  end

  @spec aggregate_query?(binary()) :: boolean()
  defp aggregate_query?(sql) do
    upper = String.upcase(sql)

    String.contains?(upper, "DATE_BIN") or
      Enum.any?(@aggregate_functions, &String.contains?(upper, &1 <> "("))
  end

  @spec parse_aggregate_select(binary()) ::
          {:ok, parsed_query()} | {:error, term()}
  defp parse_aggregate_select(sql) do
    with {:ok, columns} <- parse_select_columns(sql),
         {:ok, measurement} <- parse_aggregate_from(sql),
         {:ok, interval_ns} <- parse_group_by_interval(sql) do
      rest = extract_after_from(sql)

      {:ok,
       %{
         measurement: measurement,
         where: parse_where(rest),
         order_by: parse_order_by(rest),
         limit: parse_limit(rest),
         group_by_interval: interval_ns,
         select_columns: columns,
         distinct_column: nil
       }}
    end
  end

  # Extract the measurement name from: FROM "name" or FROM name
  @spec parse_aggregate_from(binary()) :: {:ok, binary()} | {:error, term()}
  defp parse_aggregate_from(sql) do
    pattern = ~r/(?i)FROM\s+(?:"([^"]+)"|(\S+?))\s*(?:WHERE|GROUP|ORDER|LIMIT|$)/

    case Regex.run(pattern, sql) do
      [_full, quoted, ""] -> {:ok, quoted}
      [_full, "", unquoted] -> {:ok, unescape_measurement(unquoted)}
      [_full, quoted] when quoted != "" -> {:ok, quoted}
      _no_match -> {:error, %{status: 400, body: "unsupported SQL: #{sql}"}}
    end
  end

  # Extract everything after FROM <measurement> for WHERE/ORDER/LIMIT parsing
  @spec extract_after_from(binary()) :: binary()
  defp extract_after_from(sql) do
    case Regex.run(~r/(?i)FROM\s+(?:"[^"]+"|[^\s]+)\s*(.*)/s, sql) do
      [_full, rest] -> rest
      _no_match -> ""
    end
  end

  # Parse SELECT columns: DATE_BIN(...) AS alias, AGG(field) AS alias
  @spec parse_select_columns(binary()) ::
          {:ok, [select_column()]} | {:error, term()}
  defp parse_select_columns(sql) do
    case Regex.run(~r/(?i)SELECT\s+(.+?)\s+FROM\s/s, sql) do
      [_full, columns_str] ->
        columns =
          columns_str
          |> split_top_level_commas()
          |> Enum.map(&String.trim/1)
          |> Enum.map(&parse_single_column/1)

        if Enum.any?(columns, &match?({:error, _}, &1)) do
          Enum.find(columns, &match?({:error, _}, &1))
        else
          {:ok, Enum.map(columns, fn {:ok, col} -> col end)}
        end

      _no_match ->
        {:error, %{status: 400, body: "unsupported SQL: #{sql}"}}
    end
  end

  # Split column list by commas, respecting parentheses nesting
  @spec split_top_level_commas(binary()) :: [binary()]
  defp split_top_level_commas(str) do
    {last, acc} =
      str
      |> String.graphemes()
      |> Enum.reduce({[], [], 0}, fn
        ",", {current, acc, 0} ->
          token = current |> Enum.reverse() |> Enum.join()
          {[], [token | acc], 0}

        "(", {current, acc, depth} ->
          {["(" | current], acc, depth + 1}

        ")", {current, acc, depth} ->
          {[")" | current], acc, max(depth - 1, 0)}

        char, {current, acc, depth} ->
          {[char | current], acc, depth}
      end)
      |> then(fn {current, acc, _depth} ->
        token = current |> Enum.reverse() |> Enum.join()
        {token, acc}
      end)

    Enum.reverse([last | acc])
  end

  # Parse a single SELECT column expression
  @spec parse_single_column(binary()) ::
          {:ok, select_column()} | {:error, term()}
  defp parse_single_column(col) do
    cond do
      String.match?(col, ~r/(?i)DATE_BIN\s*\(/) ->
        parse_date_bin_column(col)

      String.match?(col, ~r/(?i)(AVG|SUM|COUNT|MIN|MAX|FIRST|LAST)\s*\(/) ->
        parse_agg_column(col)

      true ->
        {:error, %{status: 400, body: "unsupported column expression: #{col}"}}
    end
  end

  # Parse: DATE_BIN(INTERVAL 'N unit', time) AS alias
  @spec parse_date_bin_column(binary()) ::
          {:ok, select_column()} | {:error, term()}
  defp parse_date_bin_column(col) do
    pattern =
      ~r/(?i)DATE_BIN\s*\(\s*INTERVAL\s+'([^']+)'\s*,\s*time\s*\)\s+AS\s+(\w+)/

    case Regex.run(pattern, col) do
      [_full, _interval, alias_name] ->
        {:ok, {:time_bucket, alias_name}}

      _no_match ->
        {:error, %{status: 400, body: "invalid DATE_BIN: #{col}"}}
    end
  end

  # Parse: AGG(field) AS alias  or  AGG(field, ordering) AS alias
  @spec parse_agg_column(binary()) ::
          {:ok, select_column()} | {:error, term()}
  defp parse_agg_column(col) do
    two_arg =
      ~r/(?i)(AVG|SUM|COUNT|MIN|MAX|FIRST|LAST)\s*\(\s*(\w+)\s*,\s*(\w+)\s*\)\s+AS\s+(\w+)/

    one_arg =
      ~r/(?i)(AVG|SUM|COUNT|MIN|MAX|FIRST|LAST)\s*\(\s*(\w+)\s*\)\s+AS\s+(\w+)/

    case Regex.run(two_arg, col) do
      [_full, func, field, ordering, alias_name] ->
        agg_atom = func |> String.downcase() |> String.to_existing_atom()

        if agg_atom in [:first, :last] do
          {:ok, {:ordered_aggregate, agg_atom, field, ordering, alias_name}}
        else
          # Non-ordered aggregates ignore the second arg (not standard SQL)
          {:ok, {:aggregate, agg_atom, field, alias_name}}
        end

      _no_two_arg ->
        case Regex.run(one_arg, col) do
          [_full, func, field, alias_name] ->
            agg_atom = func |> String.downcase() |> String.to_existing_atom()

            if agg_atom in [:first, :last] do
              # Single-arg first/last defaults ordering to "time"
              {:ok, {:ordered_aggregate, agg_atom, field, "time", alias_name}}
            else
              {:ok, {:aggregate, agg_atom, field, alias_name}}
            end

          _no_match ->
            {:error, %{status: 400, body: "invalid aggregate: #{col}"}}
        end
    end
  end

  # Parse GROUP BY DATE_BIN(INTERVAL 'N unit', time) → interval in nanoseconds
  @spec parse_group_by_interval(binary()) ::
          {:ok, pos_integer()} | {:error, term()}
  defp parse_group_by_interval(sql) do
    pattern =
      ~r/(?i)GROUP\s+BY\s+DATE_BIN\s*\(\s*INTERVAL\s+'([^']+)'\s*,\s*time\s*\)/

    case Regex.run(pattern, sql) do
      [_full, interval_str] -> parse_interval(interval_str)
      _no_match -> {:error, %{status: 400, body: "missing GROUP BY DATE_BIN"}}
    end
  end

  # Convert "N unit" → nanoseconds
  @spec parse_interval(binary()) :: {:ok, pos_integer()} | {:error, term()}
  defp parse_interval(interval_str) do
    case Regex.run(~r/^\s*(\d+)\s+(\w+)\s*$/, interval_str) do
      [_full, n_str, unit] ->
        {n, ""} = Integer.parse(n_str)
        multiplier = interval_unit_to_ns(String.downcase(unit))

        if multiplier do
          {:ok, n * multiplier}
        else
          {:error, %{status: 400, body: "unknown interval unit: #{unit}"}}
        end

      _no_match ->
        {:error, %{status: 400, body: "invalid interval: #{interval_str}"}}
    end
  end

  @spec interval_unit_to_ns(binary()) :: pos_integer() | nil
  defp interval_unit_to_ns(unit) when unit in ["second", "seconds"],
    do: 1_000_000_000

  defp interval_unit_to_ns(unit) when unit in ["minute", "minutes"],
    do: 60_000_000_000

  defp interval_unit_to_ns(unit) when unit in ["hour", "hours"],
    do: 3_600_000_000_000

  defp interval_unit_to_ns(unit) when unit in ["day", "days"],
    do: 86_400_000_000_000

  defp interval_unit_to_ns(_unknown), do: nil

  @distinct_pattern ~r/(?i)SELECT\s+DISTINCT\s+(\w+)\s+FROM\s+(?:"([^"]+)"|(\S+))\s*(.*)/s

  @spec parse_distinct_select(binary()) ::
          {:ok, parsed_query()} | {:error, term()}
  defp parse_distinct_select(sql) do
    case Regex.run(@distinct_pattern, sql) do
      [_full, column, quoted, "", rest] ->
        {:ok,
         %{
           measurement: quoted,
           where: parse_where(rest),
           order_by: nil,
           limit: parse_limit(rest),
           group_by_interval: nil,
           select_columns: nil,
           distinct_column: column
         }}

      [_full, column, "", unquoted, rest] ->
        {:ok,
         %{
           measurement: unescape_measurement(unquoted),
           where: parse_where(rest),
           order_by: nil,
           limit: parse_limit(rest),
           group_by_interval: nil,
           select_columns: nil,
           distinct_column: column
         }}

      _no_match ->
        {:error, %{status: 400, body: "unsupported DISTINCT query: #{sql}"}}
    end
  end

  @spec parse_star_select(binary()) :: {:ok, parsed_query()} | {:error, term()}
  defp parse_star_select(sql) do
    case Regex.run(@measurement_pattern, sql) do
      [_full_match, quoted, "", rest] when quoted != "" ->
        {:ok, build_star_query(quoted, rest)}

      [_full_match, "", unquoted, rest] ->
        {:ok, build_star_query(unescape_measurement(unquoted), rest)}

      [_full_match, quoted, rest] when quoted != "" ->
        {:ok, build_star_query(quoted, rest)}

      _no_match ->
        {:error, %{status: 400, body: "unsupported SQL: #{sql}"}}
    end
  end

  @spec build_star_query(binary(), binary()) :: parsed_query()
  defp build_star_query(measurement, rest) do
    %{
      measurement: measurement,
      where: parse_where(rest),
      order_by: parse_order_by(rest),
      limit: parse_limit(rest),
      group_by_interval: nil,
      select_columns: nil,
      distinct_column: nil
    }
  end

  @spec parse_where(binary()) :: [{atom(), binary(), term()}]
  defp parse_where(rest) do
    case Regex.run(~r/(?i)WHERE\s+(.+?)(?:\s+GROUP|\s+ORDER|\s+LIMIT|$)/s, rest) do
      [_full_match, clauses_str] -> parse_where_clauses(clauses_str)
      _no_match -> []
    end
  end

  @spec parse_where_clauses(binary()) :: [{atom(), binary(), term()}]
  defp parse_where_clauses(str) do
    str
    |> String.split(~r/\s+AND\s+/i)
    |> Enum.flat_map(&parse_single_where_clause/1)
  end

  @spec parse_single_where_clause(binary()) :: [{atom(), binary(), term()}]
  defp parse_single_where_clause(clause) do
    trimmed = String.trim(clause)

    # Multi-char operators must be tried before their single-char prefixes.
    operators = [{">=", :gte}, {"<=", :lte}, {"!=", :ne}, {">", :gt}, {"<", :lt}, {"=", :eq}]

    result =
      Enum.find_value(operators, fn {op_str, op_atom} ->
        case String.split(trimmed, op_str, parts: 2) do
          [left, right] when left != trimmed ->
            k = String.trim(left)
            v = parse_where_value(String.trim(right))
            {op_atom, k, v}

          _no_match ->
            nil
        end
      end)

    case result do
      nil -> []
      condition -> [condition]
    end
  end

  @spec parse_where_value(binary()) :: term()
  defp parse_where_value(str) do
    cond do
      String.starts_with?(str, "'") and String.ends_with?(str, "'") ->
        String.slice(str, 1..-2//1)

      String.starts_with?(str, "\"") and String.ends_with?(str, "\"") ->
        String.slice(str, 1..-2//1)

      str == "true" ->
        true

      str == "false" ->
        false

      true ->
        case Integer.parse(str) do
          {n, ""} ->
            n

          _no_int ->
            case Float.parse(str) do
              {f, ""} -> f
              _no_parse -> str
            end
        end
    end
  end

  @spec parse_order_by(binary()) :: {:time, :asc | :desc} | nil
  defp parse_order_by(rest) do
    case Regex.run(~r/(?i)ORDER\s+BY\s+time\s+(ASC|DESC)/s, rest) do
      [_full_match, direction] ->
        case String.upcase(direction) do
          "ASC" -> {:time, :asc}
          "DESC" -> {:time, :desc}
          _other -> nil
        end

      _no_match ->
        nil
    end
  end

  @spec parse_limit(binary()) :: pos_integer() | nil
  defp parse_limit(rest) do
    case Regex.run(~r/(?i)LIMIT\s+(\d+)/s, rest) do
      [_full_match, n_str] ->
        case Integer.parse(n_str) do
          {n, ""} when n > 0 -> n
          _bad_n -> nil
        end

      _no_match ->
        nil
    end
  end

  @spec execute_query(:ets.table(), parsed_query(), binary()) ::
          [map()] | {:error, term()}
  defp execute_query(table, %{measurement: m} = query, database) do
    if measurement_exists?(table, database, m) do
      points = fetch_points(table, database, m)
      filtered = apply_where(points, query.where)

      cond do
        query.distinct_column ->
          execute_distinct_query(filtered, query)

        query.select_columns ->
          execute_aggregate_query(filtered, query)

        true ->
          filtered
          |> apply_order_by(query.order_by)
          |> apply_limit(query.limit)
          |> Enum.map(&point_to_row/1)
      end
    else
      {:error, {:table_not_found, m}}
    end
  end

  @spec execute_distinct_query([point_map()], parsed_query()) :: [map()]
  defp execute_distinct_query(points, query) do
    col = query.distinct_column

    points
    |> Enum.map(fn point ->
      Map.get(point.fields, col) || Map.get(point.tags, col)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> then(fn values ->
      case query.limit do
        nil -> values
        n -> Enum.take(values, n)
      end
    end)
    |> Enum.map(fn value -> %{col => value} end)
  end

  @spec execute_aggregate_query([point_map()], parsed_query()) :: [map()]
  defp execute_aggregate_query(points, query) do
    interval_ns = query.group_by_interval

    time_alias = find_time_bucket_alias(query.select_columns)

    points
    |> bucket_by_interval(interval_ns)
    |> aggregate_per_bucket(query.select_columns)
    |> apply_order_by_rows(query.order_by, time_alias)
    |> apply_limit(query.limit)
  end

  # Group points into buckets by flooring timestamp to interval boundary
  @spec bucket_by_interval([point_map()], pos_integer()) :: %{
          integer() => [point_map()]
        }
  defp bucket_by_interval(points, interval_ns) do
    Enum.group_by(points, fn point ->
      case point.timestamp do
        nil -> 0
        ts -> div(ts, interval_ns) * interval_ns
      end
    end)
  end

  # Compute aggregates for each bucket and return result rows
  @spec aggregate_per_bucket(
          %{integer() => [point_map()]},
          [select_column()]
        ) :: [map()]
  defp aggregate_per_bucket(buckets, columns) do
    Enum.map(buckets, fn {bucket_ts, bucket_points} ->
      Enum.reduce(columns, %{}, fn
        {:time_bucket, alias_name}, row ->
          Map.put(row, alias_name, nanoseconds_to_iso8601(bucket_ts))

        {:aggregate, agg, field, alias_name}, row ->
          values =
            bucket_points
            |> Enum.map(fn p -> Map.get(p.fields, field) end)
            |> Enum.reject(&is_nil/1)

          Map.put(row, alias_name, compute_aggregate(agg, values))

        {:ordered_aggregate, agg, field, ordering, alias_name}, row ->
          value =
            compute_ordered_aggregate(agg, field, ordering, bucket_points)

          Map.put(row, alias_name, value)
      end)
    end)
  end

  @spec compute_aggregate(atom(), [number()]) :: number() | nil
  defp compute_aggregate(_agg, []), do: nil
  defp compute_aggregate(:avg, vals), do: Enum.sum(vals) / length(vals)
  defp compute_aggregate(:sum, vals), do: Enum.sum(vals)
  defp compute_aggregate(:count, vals), do: length(vals)
  defp compute_aggregate(:min, vals), do: Enum.min(vals)
  defp compute_aggregate(:max, vals), do: Enum.max(vals)

  # Ordered aggregates: return the field value from the point with
  # the min (first) or max (last) ordering column value.
  @spec compute_ordered_aggregate(
          :first | :last,
          binary(),
          binary(),
          [point_map()]
        ) :: term() | nil
  defp compute_ordered_aggregate(_agg, _field, _ordering, []), do: nil

  defp compute_ordered_aggregate(agg, field, ordering, points) do
    sorter = if agg == :first, do: :asc, else: :desc

    points
    |> Enum.sort_by(&ordering_value(&1, ordering), sorter)
    |> hd()
    |> then(fn p -> Map.get(p.fields, field) || Map.get(p.tags, field) end)
  end

  # Resolve the ordering column value from a point.
  # "time" maps to the point's timestamp; anything else is a field/tag.
  @spec ordering_value(point_map(), binary()) :: term()
  defp ordering_value(point, "time"), do: point.timestamp || 0

  defp ordering_value(point, col) do
    Map.get(point.fields, col) || Map.get(point.tags, col) || 0
  end

  # Find the alias of the time_bucket column from select_columns
  @spec find_time_bucket_alias([select_column()]) :: binary() | nil
  defp find_time_bucket_alias(columns) do
    Enum.find_value(columns, fn
      {:time_bucket, alias_name} -> alias_name
      _other -> nil
    end)
  end

  # Order aggregate result rows by the time bucket column
  @spec apply_order_by_rows([map()], {:time, :asc | :desc} | nil, binary() | nil) ::
          [map()]
  defp apply_order_by_rows(rows, nil, _time_alias), do: rows
  defp apply_order_by_rows(rows, _order, nil), do: rows

  defp apply_order_by_rows(rows, {:time, :asc}, time_alias) do
    Enum.sort_by(rows, &Map.get(&1, time_alias))
  end

  defp apply_order_by_rows(rows, {:time, :desc}, time_alias) do
    Enum.sort_by(rows, &Map.get(&1, time_alias), :desc)
  end

  @spec apply_where([point_map()], [{atom(), binary(), term()}]) :: [point_map()]
  defp apply_where(points, []), do: points

  defp apply_where(points, conditions) do
    Enum.filter(points, fn point ->
      Enum.all?(conditions, &matches_condition?(point, &1))
    end)
  end

  @spec matches_condition?(point_map(), {atom(), binary(), term()}) :: boolean()
  defp matches_condition?(point, {op, "time", value}) do
    compare(point.timestamp, op, to_nanoseconds(value))
  end

  defp matches_condition?(point, {op, key, value}) do
    actual = Map.get(point.tags, key) || Map.get(point.fields, key)
    compare(actual, op, value)
  end

  # Convert various time representations to nanosecond integers.
  @spec to_nanoseconds(term()) :: integer() | nil
  defp to_nanoseconds(value) when is_integer(value), do: value

  defp to_nanoseconds(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        DateTime.to_unix(dt, :nanosecond)

      {:error, _reason} ->
        case Integer.parse(value) do
          {n, ""} -> n
          _not_int -> nil
        end
    end
  end

  defp to_nanoseconds(_other), do: nil

  @spec compare(term(), atom(), term()) :: boolean()
  defp compare(nil, _op, _value), do: false
  defp compare(actual, :eq, value), do: actual == value
  defp compare(actual, :ne, value), do: actual != value
  defp compare(actual, :gt, value), do: actual > value
  defp compare(actual, :lt, value), do: actual < value
  defp compare(actual, :gte, value), do: actual >= value
  defp compare(actual, :lte, value), do: actual <= value

  @spec apply_order_by([point_map()], {:time, :asc | :desc} | nil) :: [point_map()]
  defp apply_order_by(points, nil), do: points

  defp apply_order_by(points, {:time, :asc}) do
    Enum.sort_by(points, & &1.timestamp)
  end

  defp apply_order_by(points, {:time, :desc}) do
    Enum.sort_by(points, & &1.timestamp, :desc)
  end

  @spec apply_limit([point_map()], pos_integer() | nil) :: [point_map()]
  defp apply_limit(points, nil), do: points
  defp apply_limit(points, n), do: Enum.take(points, n)

  @spec point_to_row(point_map()) :: map()
  defp point_to_row(point) do
    point.fields
    |> Map.merge(point.tags)
    |> Map.put("time", nanoseconds_to_iso8601(point.timestamp))
  end

  # Flux responses include _measurement (v2 compatibility format)
  defp flux_point_to_row(point) do
    point
    |> point_to_row()
    |> Map.put("_measurement", point.measurement)
  end

  @spec nanoseconds_to_iso8601(integer() | nil) :: binary() | nil
  defp nanoseconds_to_iso8601(nil), do: nil

  defp nanoseconds_to_iso8601(ns) when is_integer(ns) do
    seconds = div(ns, 1_000_000_000)
    nanos = rem(ns, 1_000_000_000)

    dt = DateTime.from_unix!(seconds)
    base = Calendar.strftime(dt, "%Y-%m-%dT%H:%M:%S")

    if nanos == 0 do
      base
    else
      frac = nanos |> Integer.to_string() |> String.pad_leading(9, "0")
      "#{base}.#{frac}"
    end
  end

  # ---------------------------------------------------------------------------
  # Private — Flux helpers
  # ---------------------------------------------------------------------------

  @spec extract_flux_bucket(binary()) :: binary() | nil
  defp extract_flux_bucket(flux) do
    case Regex.run(~r/from\s*\(\s*bucket\s*:\s*"([^"]+)"/, flux) do
      [_full_match, bucket] -> bucket
      _no_match -> nil
    end
  end

  @spec extract_flux_measurement(binary()) :: binary() | nil
  defp extract_flux_measurement(flux) do
    pattern = ~r/filter\s*\(\s*fn\s*:\s*\(r\)\s*=>\s*r\._measurement\s*==\s*"([^"]+)"/

    case Regex.run(pattern, flux) do
      [_full_match, m] -> m
      _no_match -> nil
    end
  end

  @spec apply_flux_range([point_map()], binary()) :: [point_map()]
  defp apply_flux_range(points, flux) do
    case Regex.run(~r/range\s*\(\s*start\s*:\s*(-?\d+)([smhd])/, flux) do
      [_full, amount_str, unit] ->
        {amount, ""} = Integer.parse(amount_str)
        now_ns = System.os_time(:nanosecond)
        offset_ns = duration_to_ns(amount, unit)
        cutoff = now_ns + offset_ns

        Enum.filter(points, fn point ->
          case point.timestamp do
            nil -> true
            ts -> ts >= cutoff
          end
        end)

      _no_match ->
        points
    end
  end

  @spec duration_to_ns(integer(), binary()) :: integer()
  defp duration_to_ns(amount, "s"), do: amount * 1_000_000_000
  defp duration_to_ns(amount, "m"), do: amount * 60 * 1_000_000_000
  defp duration_to_ns(amount, "h"), do: amount * 3_600 * 1_000_000_000
  defp duration_to_ns(amount, "d"), do: amount * 86_400 * 1_000_000_000

  @spec apply_flux_filters([point_map()], binary()) :: [point_map()]
  defp apply_flux_filters(points, flux) do
    # Extract all filter predicates of the form r.<key> == "<value>"
    # (excluding _measurement which is handled separately)
    pattern = ~r/filter\s*\(\s*fn\s*:\s*\(r\)\s*=>\s*r\.(\w+)\s*==\s*"([^"]+)"/

    Regex.scan(pattern, flux)
    |> Enum.reject(fn [_full, key, _val] -> key == "_measurement" end)
    |> Enum.reduce(points, fn [_full, key, value], acc ->
      Enum.filter(acc, fn point ->
        Map.get(point.tags, key) == value or
          Map.get(point.fields, key) == value
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private — param substitution
  # ---------------------------------------------------------------------------

  @spec resolve_params(binary(), map()) :: binary()
  defp resolve_params(sql, params) when map_size(params) == 0, do: sql

  defp resolve_params(sql, params) do
    Enum.reduce(params, sql, fn {key, value}, acc ->
      placeholder = normalize_param_key(key)
      String.replace(acc, placeholder, to_sql_literal(value))
    end)
  end

  @spec normalize_param_key(atom() | binary()) :: binary()
  defp normalize_param_key(key) when is_atom(key), do: "$#{key}"
  defp normalize_param_key("$" <> _rest = key), do: key
  defp normalize_param_key(key) when is_binary(key), do: "$#{key}"

  @spec to_sql_literal(term()) :: binary()
  defp to_sql_literal(value) when is_binary(value), do: "'#{value}'"
  defp to_sql_literal(value) when is_integer(value), do: Integer.to_string(value)
  defp to_sql_literal(value) when is_float(value), do: Float.to_string(value)
  defp to_sql_literal(true), do: "true"
  defp to_sql_literal(false), do: "false"
  defp to_sql_literal(value), do: inspect(value)

  # ---------------------------------------------------------------------------
  # Private — utilities
  # ---------------------------------------------------------------------------

  @spec delete_points(:ets.table(), binary(), binary(), [{atom(), binary(), term()}]) ::
          non_neg_integer()
  defp delete_points(table, database, measurement, where) do
    key = {:points, database, measurement}

    case :ets.lookup(table, key) do
      [{^key, pts}] ->
        {to_keep, to_delete} =
          if where == [] do
            {[], pts}
          else
            Enum.split_with(pts, fn point ->
              not Enum.all?(where, &matches_condition?(point, &1))
            end)
          end

        count = length(to_delete)

        if to_keep == [] do
          :ets.delete(table, key)
        else
          :ets.insert(table, {key, to_keep})
        end

        count

      [] ->
        0
    end
  end

  @spec generate_id() :: binary()
  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @spec bucket_id(binary()) :: binary()
  defp bucket_id(name) do
    :crypto.hash(:sha256, name) |> binary_part(0, 8) |> Base.encode16(case: :lower)
  end
end
