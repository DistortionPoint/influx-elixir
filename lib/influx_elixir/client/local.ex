defmodule InfluxElixir.Client.Local do
  @moduledoc """
  In-memory InfluxDB client for fast, isolated testing.

  Stores data in ETS tables, enabling safe `async: true` tests with full
  isolation between test instances. Each call to `start/1` creates an
  independent ETS table.

  Parses real line protocol on write, stores points as maps, and responds
  with realistic InfluxDB response formats on query. Parsing is split out:
  `InfluxElixir.Client.Local.LineProtocolParser` handles writes and
  `InfluxElixir.Client.Local.SQLParser` handles the SQL subset; this module
  owns storage, capability checks and query execution.

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

  One `:ordered_set` per instance. Every mutation is a single insert or
  delete of its own key, so concurrent writers — `async: true` tests sharing
  one database, `BatchWriter` flushes racing direct writes — never
  read-modify-write a shared value and no write is ever lost:

    * `{:database, name}` => `true`
    * `{:bucket, name}` => `true`
    * `{:token, id}` => `map()` — the token map
    * `{:point, database, measurement, seq}` => `point_map()` — `seq` is a
      monotonic integer, so points scan in insertion order

  ## SQL Query Support

  `query_sql/3` understands a subset of SQL:

    * `SELECT * FROM measurement`
    * `SELECT col1, col2 [, ...] FROM measurement` with optional `AS alias`
      (projects fields and tags; `time` is selectable). `time` and
      `DATE_BIN` buckets are `DateTime` values with microsecond precision,
      the same as the HTTP and Flight transports return; compare them with
      `DateTime.compare/2` or a six-digit sigil (`~U[... .000000Z]`).
      A projected column may be an arithmetic expression with an alias
      (`(bid + ask) / 2 AS mid`); a null operand makes the column null
      (omitted). `ORDER BY` may name a projected alias.
    * `WITH name AS (<select>)[, name AS (<select>)] <select>` — non-recursive
      CTEs. Each body is a query in this subset, run in order over the store
      or an earlier CTE; the final `SELECT` may read from any of them
      (`FROM w`). A CTE's output columns are its fields (`time` stays
      `time`).
    * `FROM a CROSS JOIN b` — every row of `a` paired with every row of `b`
      (the usual use is broadcasting a one-row CTE such as a median across
      the rows it screens). A column present on both sides is refused as
      ambiguous, because qualifiers are dropped and the two could not be
      told apart; the engine refuses the unqualified reference too. Other
      joins, set operations, `HAVING`, `OFFSET` and window functions are
      rejected by name rather than silently ignored.
    * Table qualifiers and aliases: `FROM q AS w` / `FROM q w`, and
      `w.time`, `q.bid` in any clause — one table per query, so the prefix
      is dropped.
    * `WHERE` with `=`, `!=` / `<>`, `<`, `<=`, `>`, `>=`, combined with
      `AND`, `OR`, `NOT` and parentheses (`AND` binds tighter than `OR`, as
      in SQL). A quoted literal is always a **string**, exactly as in
      InfluxDB v3: `'08338636'` keeps its leading zero and matches a string
      tag, and comparing it against a numeric field compares the field's
      text rendering (so `amount >= '1000.00'` is a lexical comparison —
      DataFusion casts the numeric side to Utf8). The other way round, a
      string column against a bare number compares the number's text
      rendering, also lexically (`rack = 2` matches the tag `"2"`; `rack > 3`
      does not match `"10"`). Bare literals (`42`, `1.5`, `true`) are typed
      and compare numerically against numeric fields. Either side may be an
      arithmetic expression over columns (`price <= med * 3`,
      `2 * price > volume`); a bare word is a column reference, as in SQL.
      A column that no row has — named anywhere: `SELECT`, an aggregate,
      `WHERE`, `GROUP BY`, `ORDER BY`, `DISTINCT` — is the engine's schema
      error ("No field named prod", HTTP 500), which is what a typo or a
      forgotten pair of quotes produces in production. With no rows the
      schema is unknown and nothing is checked. `col = NULL` (a `nil`
      param) is never true.
    * `WHERE col IN (v1, v2, ...)` and `WHERE col NOT IN (v1, v2, ...)`
    * `WHERE col IS NULL` and `WHERE col IS NOT NULL`
    * `WHERE col [NOT] BETWEEN low AND high` (inclusive; `time` too)
    * `WHERE col [NOT] LIKE 'pattern'` and `ILIKE` (`%` any run, `_` one
      character; `LIKE` is case-sensitive, `ILIKE` is not). `LIKE` over a
      numeric column is the engine's planning error, reproduced.
    * `WHERE time <op> <comparand>` — exactly what InfluxDB 3 accepts against
      a Timestamp: a quoted ISO-8601 datetime (`'2026-03-31T12:00:00Z'`,
      zone-less or fractional forms too), a quoted date (`'2026-03-31'`,
      midnight UTC), or `now()` offset by `+`/`-` `INTERVAL 'N unit'` terms
      (`now() - INTERVAL '5 minutes'`). A bare integer (`time > 1700000000`)
      and an integer-as-string are **rejected**, as DataFusion rejects them
      ("Cannot infer common argument type for comparison operation
      Timestamp(ns) > Int64"), rather than silently matching nothing.
    * `SELECT DISTINCT col[, col ...] FROM measurement` (sorted combinations;
      `ORDER BY` must name a selected column, as in DataFusion)
    * `ORDER BY <column> [ASC|DESC]` — `time` or any output column/alias
    * `LIMIT N` — `LIMIT 0` returns no rows; a negative or non-numeric
      limit is rejected, as the engine rejects it
    * `$param` placeholders via `params: %{"$name" => value}` in opts. A
      `DateTime`, `NaiveDateTime` or `Date` param renders as the ISO-8601
      string Jason sends over HTTP, so `time >= $start` works the same on
      both clients; an integer param against `time` is rejected on both.
    * `DATE_BIN(INTERVAL 'N unit', time)` time bucketing
    * Aggregate functions: `AVG`, `SUM`, `COUNT`, `MIN`, `MAX`, `MEDIAN`
      (the middle value; for an even count the mean of the two middle
      values in the column's type, so two integers average with integer
      division), `STDDEV` / `STDDEV_SAMP` (sample), `STDDEV_POP`, `VAR` /
      `VAR_SAMP` (sample), `VAR_POP`. The argument may be an arithmetic
      expression over fields
      and numeric literals (`SUM(value * value)`, `AVG(bid + ask)`); two
      integer operands divide as integers (`3 / 2 = 1`), as in DataFusion.
      Division by zero is null in the double, where InfluxDB returns IEEE
      infinity for floats (serialised as JSON `null` but counted by
      `COUNT`) and fails the query for integers. A sample
      statistic over one value is null. `COUNT(DISTINCT col)` counts
      distinct non-null values. `MIN(time)`, `MAX(time)` and `COUNT(time)`
      work (a `DateTime` result); every other aggregate over `time`, and
      any arithmetic on it, is rejected as DataFusion rejects it.
    * Selector functions: `selector_first|last|min|max(field, time)['value']`
      and `['time']`
    * Ordered aggregates: `first_value(field ORDER BY col [ASC|DESC])` and
      `last_value(field ORDER BY col [ASC|DESC])` — the InfluxDB v3 SQL
      (DataFusion) spelling. The `ORDER BY` is required: without it the real
      engine returns an arbitrary row from the group, which the double cannot
      reproduce, so it rejects the query rather than certify a
      non-deterministic result. InfluxQL-style `FIRST(f, t)` / `LAST(f, t)`
      are rejected because InfluxDB v3 SQL has no such functions.
    * `GROUP BY DATE_BIN(INTERVAL 'N unit', time)` — optional. When omitted,
      aggregate queries return a single scalar row (`COUNT` over an empty
      result set is `0`; other aggregates return `nil`).
    * `GROUP BY <col>[, <col>...]` — bucket points by tag/field values,
      with or without an aggregate (`SELECT host FROM m GROUP BY host` is
      one row per host). Bare column names (with optional `AS alias`) are
      valid in the `SELECT` list only when grouped; a projected column that
      is neither grouped nor aggregated is the engine's planning error
      ("must appear in the GROUP BY clause or must be part of an aggregate
      function"). `ORDER BY` applies to grouped rows too.
    * Interval units: `seconds`, `minutes`, `hours`, `days`

  A null column is omitted from the row rather than present as `nil`,
  exactly as InfluxDB 3's JSON and JSONL responses do (`COUNT` is `0`, never
  null).

  Anything outside this subset is rejected with
  `{:error, %{status: 400, body: "Client.Local: ..."}}`. The `Client.Local:`
  prefix marks the rejection as a limitation of the test double rather than
  of InfluxDB — the real engine may well accept the query. `check_sql/1`
  answers the same question without executing, so a test can skip with a
  reason and the query can be covered in the integration tier instead.

  ## SQL Param Types

  `params:` values are serialised to SQL literals before query execution.
  Supported types: `binary`, `integer`, `float`, `boolean`, and `Decimal`
  (when the optional `:decimal` dependency is loaded — `Decimal` values
  are emitted as bare numeric literals via `Decimal.to_string(:normal)`).

  ## Gzip Decompression

  If a write payload begins with gzip magic bytes (0x1F 0x8B) it is
  automatically decompressed before line protocol parsing.

  ## Timestamp Precision

  Pass `precision: :nanosecond | :microsecond | :millisecond | :second`
  in opts to normalise stored timestamps to nanoseconds.
  """

  @behaviour InfluxElixir.Client

  alias InfluxElixir.Client.Local.{LineProtocolParser, SQLParser}

  @type point_map :: LineProtocolParser.point()

  @type profile :: :v3_core | :v3_enterprise | :v2

  @type conn :: %{
          table: :ets.table(),
          databases: MapSet.t(binary()),
          database: binary() | nil,
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

  # ---------------------------------------------------------------------------
  # Connection lifecycle (behaviour callbacks)
  # ---------------------------------------------------------------------------

  @impl true
  @spec init_connection(keyword()) :: {:ok, conn()}
  def init_connection(config) do
    start(
      database: Keyword.get(config, :database),
      databases: Keyword.get(config, :databases, []),
      profile: Keyword.get(config, :profile, :v3_core)
    )
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

    * `:database` - connection-level default database name. Used when the
      caller does not pass `database:` in opts. Pre-created automatically.
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

      iex> {:ok, conn} = InfluxElixir.Client.Local.start(database: "metrics")
      iex> conn.database
      "metrics"
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
    # Every mutation is a single :ets.insert/2 or :ets.delete/2 on its own
    # key (see "ETS Key Layout"), so no GenServer is needed to make
    # concurrent writers safe. :ordered_set keeps points in insertion order.
    table = :ets.new(:influx_local, [:ordered_set, :public])

    # "default" is always pre-created so writes without an explicit
    # database: opt succeed. The connection-level :database (if given)
    # is also pre-created so it can be used as a query target.
    database = Keyword.get(opts, :database)

    databases =
      [Keyword.get(opts, :databases, []), List.wrap(database), ["default"]]
      |> Enum.concat()
      |> MapSet.new()

    Enum.each(databases, &:ets.insert(table, {{:database, &1}, true}))

    conn = %{
      table: table,
      databases: databases,
      database: database,
      profile: profile
    }

    {:ok, conn}
  end

  @doc """
  Reports whether the SQL subset can express `sql`, without executing it.

  Returns `:ok` or the same `{:error, %{status: 400, body: "Client.Local: ..."}}`
  that `query_sql/3` would return. Use it to skip a test *with a reason*
  instead of tagging it excluded:

      case InfluxElixir.Client.Local.check_sql(sql) do
        :ok -> run_against_local(sql)
        {:error, %{body: why}} -> ExUnit.Callbacks.on_exit(fn -> :ok end); flunk(why)
      end

  Queries outside the subset (CTEs, joins, window functions, `median`, ...)
  belong in an integration test against a real InfluxDB; see the testing
  guide.
  """
  @spec check_sql(binary()) :: :ok | {:error, %{status: 400, body: binary()}}
  def check_sql(sql) do
    case SQLParser.parse_select(sql) do
      {:ok, _query} -> :ok
      {:error, _reason} = error -> error
    end
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

  # Mirrors HTTP's resolve_database/2: prefer opts[:database], then the
  # connection-level default, then "default" (which is always pre-created).
  @spec resolve_database(keyword(), conn()) :: binary()
  defp resolve_database(opts, conn) do
    Keyword.get(opts, :database) || Map.get(conn, :database) || "default"
  end

  @doc """
  Stops a LocalClient instance and cleans up its ETS table.

  Safe to call multiple times; a no-op if the table is already deleted.
  """
  @spec stop(conn()) :: :ok
  def stop(%{table: table}) do
    # The table dies with its owner process. An `on_exit` callback runs after
    # the test process has exited, so checking `:ets.info/1` first still
    # races the owner's cleanup; `:ets.delete/1` raising ArgumentError means
    # the table is already gone, which is the outcome we want.
    :ets.delete(table)
    :ok
  rescue
    ArgumentError -> :ok
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
    database = resolve_database(opts, conn)
    precision = Keyword.get(opts, :precision, :nanosecond)

    with :ok <- require_capability(conn, :write),
         {:ok, text} <- maybe_decompress(payload),
         :ok <- ensure_database(table, database, profile),
         {:ok, points} <- LineProtocolParser.parse(text, precision) do
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
      database = resolve_database(opts, conn)
      resolved_sql = SQLParser.resolve_params(sql, params)

      with nil <- SQLParser.unbound_placeholder(resolved_sql),
           {:ok, query} <- SQLParser.parse_select(resolved_sql) do
        case execute_query(table, query, database) do
          {:error, _reason} = err -> err
          rows -> {:ok, rows}
        end
      else
        {:error, _reason} = err -> err
        name when is_binary(name) -> {:error, unbound_placeholder_error(name)}
      end
    end
  end

  @doc """
  Executes a SQL query and returns results as a lazy `Stream`.

  Delegates to `query_sql/3` then wraps the list in a stream.

  Mirrors the error semantics of the HTTP client's streaming query:
  because the return type is an `Enumerable.t()`, errors cannot be returned as a
  tuple. Instead a failure — an underlying query error or an operation the
  connection's profile does not support — is raised as an
  `InfluxElixir.StreamError` when the stream is enumerated, never swallowed as an
  empty result. This keeps `Client.Local` a faithful drop-in test double for
  `Client.HTTP`, so consumer code that rescues `InfluxElixir.StreamError` can be
  exercised against it.
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
          {:error, reason} -> InfluxElixir.StreamError.stream(stream_error_opts(reason))
        end

      {:error, :unsupported_operation} ->
        InfluxElixir.StreamError.stream(kind: :unsupported, reason: :unsupported_operation)
    end
  end

  # Maps a `query_sql/3` error reason to `InfluxElixir.StreamError` options,
  # mirroring how `Client.HTTP` classifies the same failures. Query errors that
  # a real InfluxDB surfaces as an HTTP status (bad SQL, missing table) map to
  # `:http_status`; a missing database maps to `:no_database`.
  @spec stream_error_opts(term()) :: keyword()
  defp stream_error_opts(%{status: status, body: body}),
    do: [kind: :http_status, status: status, body: body]

  defp stream_error_opts(:no_database_specified), do: [kind: :no_database]

  defp stream_error_opts(reason), do: [kind: :transport, reason: reason]

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
      database = resolve_database(opts, conn)
      trimmed = String.trim(sql)

      case Regex.run(~r/^(?i)DELETE\s+FROM\s+((?:[^\s\\]|\\.)+)(.*)$/s, trimmed) do
        [_full, measurement_raw, rest] ->
          execute_delete(table, database, profile, measurement_raw, rest)

        _no_match ->
          {:ok, %{"rows_affected" => 0}}
      end
    end
  end

  @spec execute_delete(
          :ets.table(),
          binary(),
          profile(),
          binary(),
          binary()
        ) :: {:ok, map()} | {:error, term()}
  defp execute_delete(_table, _database, :v3_core, _measurement_raw, _rest),
    do: {:error, :delete_not_supported}

  defp execute_delete(table, database, _profile, measurement_raw, rest) do
    measurement = LineProtocolParser.unescape_measurement(measurement_raw)

    with {:ok, where} <- SQLParser.parse_where(rest) do
      count = delete_points(table, database, measurement, where)
      {:ok, %{"rows_affected" => count}}
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

  @show_databases ~r/^(?i)SHOW\s+DATABASES\s*$/
  @show_measurements ~r/^(?i)SHOW\s+MEASUREMENTS\s*$/
  @show_tag_keys ~r/^(?i)SHOW\s+TAG\s+KEYS\s+FROM\s+(\S+)\s*$/

  # The SHOW commands are InfluxQL-only; any other statement is handed to the
  # SQL engine. Each pattern is matched once.
  defp do_query_influxql(table, conn, influxql, opts) do
    trimmed = String.trim(influxql)
    database = resolve_database(opts, conn)

    cond do
      String.match?(trimmed, @show_databases) ->
        {:ok, table |> get_databases() |> Enum.map(&%{"iox::database" => &1})}

      String.match?(trimmed, @show_measurements) ->
        {:ok, show_measurements(table, database)}

      match = Regex.run(@show_tag_keys, trimmed) ->
        [_full, measurement_raw] = match

        {:ok,
         show_tag_keys(table, database, LineProtocolParser.unescape_measurement(measurement_raw))}

      true ->
        query_sql(conn, influxql, opts)
    end
  end

  @spec show_measurements(:ets.table(), binary()) :: [map()]
  defp show_measurements(table, database) do
    table
    |> :ets.select([{{{:point, database, :"$1", :_}, :_}, [], [:"$1"]}])
    |> Enum.uniq()
    |> Enum.map(&%{"iox::measurement" => "measurements", "name" => &1})
  end

  @spec show_tag_keys(:ets.table(), binary(), binary()) :: [map()]
  defp show_tag_keys(table, database, measurement) do
    table
    |> fetch_points(database, measurement)
    |> Enum.flat_map(&Map.keys(&1.tags))
    |> Enum.uniq()
    |> Enum.map(&%{"iox::measurement" => measurement, "tagKey" => &1})
  end

  @doc """
  Executes a Flux query with support for common predicates.

  Parses and applies:

    * `from(bucket: "...")` — scopes to a database
    * `range(start: -1h)` — filters by timestamp (supports `-Nh`, `-Nd`, `-Nm`)
    * `filter(fn: (r) => r._measurement == "...")` — filters by measurement
    * `filter(fn: (r) => r._field == "...")` — keeps only that field
    * `filter(fn: (r) => r.<key> == "...")` — filters by any tag/field equality

  Rows use the same **long** shape real Flux returns — one row per field,
  ordered by `table` then `_time`:

      %{"result" => "_result", "table" => 0, "_time" => %DateTime{},
        "_measurement" => "cpu", "_field" => "value", "_value" => 1.0,
        "host" => "web01"}

  `table` numbers each series (measurement + tags + field) from `0`.
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
      |> flux_rows(extract_flux_field(flux))
      |> then(&{:ok, &1})
    end
  end

  # Real Flux output is long: one row per field carrying `_field`/`_value`,
  # `_measurement`, `_time`, the tags, and a `table` index per series.
  # Emitting the same shape means a consumer's Flux handling can be
  # exercised against the double.
  @spec flux_rows([point_map()], binary() | nil) :: [map()]
  defp flux_rows(points, only_field) do
    {rows, _tables} =
      points
      |> Enum.flat_map(fn point ->
        for {field, value} <- point.fields,
            only_field in [nil, field],
            do: {point, field, value}
      end)
      |> Enum.map_reduce(%{}, fn {point, field, value}, tables ->
        series = {point.measurement, point.tags, field}

        {table, tables} =
          Map.get_and_update(tables, series, &{&1 || map_size(tables), &1 || map_size(tables)})

        row =
          Map.merge(point.tags, %{
            "result" => "_result",
            "table" => table,
            "_time" => nanoseconds_to_datetime(point.timestamp),
            "_value" => value,
            "_field" => field,
            "_measurement" => point.measurement
          })

        {row, tables}
      end)

    Enum.sort_by(rows, &{&1["table"], &1["_time"]}, fn
      {t1, %DateTime{} = a}, {t2, %DateTime{} = b} when t1 == t2 -> DateTime.compare(a, b) != :gt
      {t1, _a}, {t2, _b} -> t1 <= t2
    end)
  end

  @spec nanoseconds_to_datetime(integer() | nil) :: DateTime.t() | nil
  defp nanoseconds_to_datetime(nil), do: nil
  defp nanoseconds_to_datetime(ns), do: DateTime.from_unix!(ns, :nanosecond)

  @spec extract_flux_field(binary()) :: binary() | nil
  defp extract_flux_field(flux) do
    case Regex.run(~r/filter\s*\(\s*fn\s*:\s*\(r\)\s*=>\s*r\._field\s*==\s*"([^"]+)"/, flux) do
      [_full, field] -> field
      _no_match -> nil
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
      :ets.insert(table, {{:database, name}, true})
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
      if :ets.member(table, {:database, name}) do
        :ets.delete(table, {:database, name})
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
      :ets.insert(table, {{:bucket, name}, true})
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
      :ets.delete(table, {:bucket, name})
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

      :ets.insert(table, {{:token, id}, token})
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
      :ets.delete(table, {:token, token_id})
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
  # Every registry below is one ETS object per entry, so registering and
  # removing are single atomic operations; there is no shared set to
  # read-modify-write.
  defp get_databases(table) do
    table
    |> :ets.select([{{{:database, :"$1"}, :_}, [], [:"$1"]}])
    |> MapSet.new()
  end

  @spec get_buckets(:ets.table()) :: MapSet.t(binary())
  defp get_buckets(table) do
    table
    |> :ets.select([{{{:bucket, :"$1"}, :_}, [], [:"$1"]}])
    |> MapSet.new()
  end

  @spec assert_database_exists(:ets.table(), binary()) :: :ok | {:error, map()}
  defp assert_database_exists(table, database) do
    if :ets.member(table, {:database, database}) do
      :ok
    else
      {:error, %{status: 404, body: "database not found: #{database}"}}
    end
  end

  # v3 Core/Enterprise auto-create databases on write; v2 requires pre-existing
  @spec ensure_database(:ets.table(), binary(), profile()) :: :ok | {:error, term()}
  defp ensure_database(table, database, profile) when profile in [:v3_core, :v3_enterprise] do
    :ets.insert(table, {{:database, database}, true})
    :ok
  end

  # v2 writes target buckets, so anything registered via `create_bucket/3` is a
  # valid target. Names seeded through `databases:` at start are accepted too,
  # so a v2 connection can be prepared either way.
  defp ensure_database(table, bucket, :v2) do
    if :ets.member(table, {:bucket, bucket}) do
      :ok
    else
      assert_database_exists(table, bucket)
    end
  end

  # One ETS object per point, keyed by a monotonic sequence number. Storing
  # a measurement's points as one list meant every write read the list,
  # prepended and wrote it back: concurrent writers overwrote each other
  # (#15: 159 of 480 writes survived) and each insert copied the whole
  # list, making a bulk write quadratic. A plain insert is atomic and O(log n).
  @spec store_point(:ets.table(), binary(), point_map()) :: true
  defp store_point(table, database, point) do
    # Real InfluxDB assigns a server timestamp when none is provided.
    point = assign_default_timestamp(point)
    seq = :erlang.unique_integer([:monotonic, :positive])
    :ets.insert(table, {{:point, database, point.measurement, seq}, point})
  end

  @spec assign_default_timestamp(point_map()) :: point_map()
  defp assign_default_timestamp(%{timestamp: nil} = point) do
    %{point | timestamp: System.system_time(:nanosecond)}
  end

  defp assign_default_timestamp(point), do: point

  @spec measurement_exists?(:ets.table(), binary(), binary()) :: boolean()
  defp measurement_exists?(table, database, measurement) do
    spec = [{{{:point, database, measurement, :_}, :_}, [], [true]}]
    :ets.select(table, spec, 1) != :"$end_of_table"
  end

  # Points come back in key (= insertion) order.
  @spec fetch_points(:ets.table(), binary(), binary()) :: [point_map()]
  defp fetch_points(table, database, measurement) do
    :ets.select(table, [{{{:point, database, measurement, :_}, :"$1"}, [], [:"$1"]}])
  end

  @spec all_points_in_db(:ets.table(), binary()) :: [point_map()]
  defp all_points_in_db(table, database) do
    :ets.select(table, [{{{:point, database, :_, :_}, :"$1"}, [], [:"$1"]}])
  end

  @spec all_points(:ets.table()) :: [point_map()]
  defp all_points(table) do
    :ets.select(table, [{{{:point, :_, :_, :_}, :"$1"}, [], [:"$1"]}])
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
  # Private — SQL query executor (parsing lives in SQLParser)
  # ---------------------------------------------------------------------------

  # CTEs run first, in order, each over the store or an earlier CTE; their
  # rows become the points the next query reads (a CTE shadows a measurement
  # of the same name, as in SQL).
  @spec execute_query(:ets.table(), SQLParser.parsed_query(), binary()) ::
          [map()] | {:error, term()}
  defp execute_query(table, query, database) do
    query.ctes
    |> Enum.reduce_while({:ok, %{}}, fn {name, cte_query}, {:ok, sources} ->
      case execute_select(table, cte_query, database, sources) do
        {:error, _reason} = error -> {:halt, error}
        rows -> {:cont, {:ok, Map.put(sources, name, rows_to_points(name, rows))}}
      end
    end)
    |> case do
      {:ok, sources} -> execute_select(table, query, database, sources)
      {:error, _reason} = error -> error
    end
  end

  @spec execute_select(:ets.table(), SQLParser.parsed_query(), binary(), %{
          binary() => [point_map()]
        }) :: [map()] | {:error, term()}
  defp execute_select(table, %{measurement: m} = query, database, cte_sources) do
    with {:ok, points} <- source_points(table, database, m, cte_sources),
         {:ok, joined} <- cross_join(table, database, points, query.cross_join, cte_sources),
         :ok <- check_query_columns(joined, query),
         :ok <- check_grouping_columns(query),
         {:ok, filtered} <- apply_where(joined, query.where) do
      cond do
        query.distinct_columns ->
          execute_distinct_query(filtered, query)

        query.select_columns ->
          execute_aggregate_query(filtered, query)

        query.projection_columns ->
          execute_projection_query(filtered, query)

        true ->
          filtered
          |> apply_order_by(query.order_by)
          |> apply_limit(query.limit)
          |> Enum.map(&point_to_row/1)
      end
    else
      :error -> {:error, table_not_found(m)}
      {:error, _reason} = error -> error
    end
  end

  @spec source_points(:ets.table(), binary(), binary(), %{binary() => [point_map()]}) ::
          {:ok, [point_map()]} | :error
  defp source_points(table, database, measurement, cte_sources) do
    cond do
      Map.has_key?(cte_sources, measurement) ->
        {:ok, Map.fetch!(cte_sources, measurement)}

      measurement_exists?(table, database, measurement) ->
        {:ok, fetch_points(table, database, measurement)}

      true ->
        :error
    end
  end

  # `FROM w CROSS JOIN ref`: every left point paired with every right point,
  # the right side's columns merged in as fields. Qualifiers were dropped
  # at parse time, so a column present on both sides cannot be told apart
  # any more; the engine refuses an unqualified ambiguous reference and the
  # double refuses the join. A right side that carries `time` is a
  # collision too. Rows are the left side's measurement and timestamp.
  @spec cross_join(
          :ets.table(),
          binary(),
          [point_map()],
          {binary(), [binary()]} | nil,
          %{binary() => [point_map()]}
        ) :: {:ok, [point_map()]} | {:error, term()}
  defp cross_join(_table, _database, points, nil, _cte_sources), do: {:ok, points}

  defp cross_join(table, database, points, {right_name, _aliases}, cte_sources) do
    with {:ok, right_points} <- fetch_source(table, database, right_name, cte_sources),
         :ok <- check_join_collisions(points, right_points, right_name) do
      {:ok,
       for left <- points, right <- right_points do
         %{
           left
           | tags: Map.merge(left.tags, right.tags),
             fields: Map.merge(left.fields, right.fields)
         }
       end}
    end
  end

  @spec fetch_source(:ets.table(), binary(), binary(), %{binary() => [point_map()]}) ::
          {:ok, [point_map()]} | {:error, term()}
  defp fetch_source(table, database, name, cte_sources) do
    case source_points(table, database, name, cte_sources) do
      {:ok, points} -> {:ok, points}
      :error -> {:error, table_not_found(name)}
    end
  end

  @spec check_join_collisions([point_map()], [point_map()], binary()) :: :ok | {:error, term()}
  defp check_join_collisions(left, right, right_name) do
    right_columns = point_columns(right) |> maybe_add_time(right)
    shared = MapSet.intersection(point_columns(left) |> maybe_add_time(left), right_columns)

    if MapSet.size(shared) == 0 do
      :ok
    else
      {:error,
       %{
         status: 500,
         body:
           "Schema error: Ambiguous reference to unqualified field " <>
             "#{Enum.join(Enum.sort(shared), ", ")} (present on both sides of CROSS JOIN #{right_name})"
       }}
    end
  end

  @spec point_columns([point_map()]) :: MapSet.t(binary())
  defp point_columns(points) do
    Enum.reduce(points, MapSet.new(), fn point, acc ->
      acc
      |> MapSet.union(MapSet.new(Map.keys(point.tags)))
      |> MapSet.union(MapSet.new(Map.keys(point.fields)))
    end)
  end

  @spec maybe_add_time(MapSet.t(binary()), [point_map()]) :: MapSet.t(binary())
  defp maybe_add_time(columns, points) do
    if Enum.any?(points, &(not is_nil(&1.timestamp))),
      do: MapSet.put(columns, "time"),
      else: columns
  end

  # A column the query names that no row has — in SELECT, an aggregate,
  # WHERE, GROUP BY, ORDER BY or DISTINCT — is the engine's schema error
  # ("No field named prod"), not an empty or unsorted result. The usual
  # cause is a typo or a forgotten pair of quotes around a string literal.
  # With no rows the schema is unknown, so nothing is checked.
  @spec check_query_columns([point_map()], SQLParser.parsed_query()) :: :ok | {:error, term()}
  defp check_query_columns([], _query), do: :ok

  defp check_query_columns(points, query) do
    known = points |> point_columns() |> MapSet.put("time")

    case Enum.reject(referenced_columns(query), &MapSet.member?(known, &1)) do
      [] ->
        :ok

      [missing | _rest] ->
        {:error,
         %{
           status: 500,
           body:
             "Schema error: No field named #{missing}. Valid fields are " <>
               Enum.join(Enum.sort(known), ", ") <> "."
         }}
    end
  end

  # A projected plain column in an aggregate query must be grouped: the
  # engine fails planning otherwise ("must appear in the GROUP BY clause or
  # must be part of an aggregate function"). Before, the double sampled the
  # group's first row, which is a wrong answer, not a refusal.
  @spec check_grouping_columns(SQLParser.parsed_query()) :: :ok | {:error, term()}
  defp check_grouping_columns(%{select_columns: nil}), do: :ok

  defp check_grouping_columns(query) do
    grouped = query.group_by_columns || []

    ungrouped =
      Enum.find_value(query.select_columns, fn
        {:grouping_column, source, _alias} -> if source in grouped, do: nil, else: source
        _other -> nil
      end)

    case ungrouped do
      nil ->
        :ok

      column ->
        {:error,
         %{
           status: 400,
           body:
             "Error during planning: Column in SELECT must be in GROUP BY or an aggregate " <>
               "function: column \"#{column}\" must appear in the GROUP BY clause or must be " <>
               "part of an aggregate function"
         }}
    end
  end

  # Every source column the query refers to. ORDER BY may name an output
  # alias instead, which is not a source column.
  @spec referenced_columns(SQLParser.parsed_query()) :: [binary()]
  defp referenced_columns(query) do
    order_by_refs =
      case query.order_by do
        {column, _direction} -> if column in output_aliases(query), do: [], else: [column]
        nil -> []
      end

    Enum.flat_map(query.projection_columns || [], &projection_refs/1) ++
      Enum.flat_map(query.select_columns || [], &select_column_refs/1) ++
      where_refs(query.where) ++
      (query.group_by_columns || []) ++
      (query.distinct_columns || []) ++
      order_by_refs
  end

  @spec output_aliases(SQLParser.parsed_query()) :: [binary()]
  defp output_aliases(query) do
    Enum.map(query.projection_columns || [], fn {_source, output} -> output end) ++
      Enum.map(query.select_columns || [], &elem(&1, tuple_size(&1) - 1)) ++
      (query.distinct_columns || [])
  end

  @spec projection_refs(SQLParser.projection()) :: [binary()]
  defp projection_refs({source, _output}) when is_binary(source), do: [source]
  defp projection_refs({expr, _output}), do: expr_fields(expr)

  @spec select_column_refs(SQLParser.select_column()) :: [binary()]
  defp select_column_refs({:time_bucket, _alias}), do: ["time"]
  defp select_column_refs({:aggregate, _agg, expr, _alias}), do: expr_fields(expr)
  defp select_column_refs({:count_star, _alias}), do: []
  defp select_column_refs({:count_distinct, column, _alias}), do: [column]

  defp select_column_refs({:ordered_aggregate, _agg, field, ordering, _alias}),
    do: [field, ordering]

  defp select_column_refs({:selector, _kind, field, ordering, _access, _alias}),
    do: [field, ordering]

  defp select_column_refs({:grouping_column, source, _alias}), do: [source]

  @spec where_refs([SQLParser.where_node()]) :: [binary()]
  defp where_refs(nodes) do
    Enum.flat_map(nodes, fn
      {:or, branches} -> Enum.flat_map(branches, &where_refs/1)
      {:not, conjunction} -> where_refs(conjunction)
      {_op, left, right} when is_binary(left) -> [left | expr_fields(right)]
      {_op, left, right} -> expr_fields(left) ++ expr_fields(right)
    end)
  end

  @spec expr_fields(term()) :: [binary()]
  defp expr_fields({:expr, expr}), do: expr_fields(expr)
  defp expr_fields({:field, name}), do: [name]
  defp expr_fields({:op, _op, left, right}), do: expr_fields(left) ++ expr_fields(right)
  defp expr_fields(_other), do: []

  # A CTE's output rows, read back as points: every column but `time` is a
  # field (tag/field is a storage distinction the next query cannot see).
  @spec rows_to_points(binary(), [map()]) :: [point_map()]
  defp rows_to_points(name, rows) do
    Enum.map(rows, fn row ->
      timestamp =
        case Map.get(row, "time") do
          %DateTime{} = dt -> DateTime.to_unix(dt, :nanosecond)
          nil -> nil
        end

      %{measurement: name, tags: %{}, fields: Map.delete(row, "time"), timestamp: timestamp}
    end)
  end

  # SELECT col, expr AS alias, ...: rows are projected first so ORDER BY can
  # name a projected alias (`ORDER BY mid DESC`) as well as any source column.
  @spec execute_projection_query([point_map()], SQLParser.parsed_query()) :: [map()]
  defp execute_projection_query(points, query) do
    projection = query.projection_columns
    outputs = Enum.map(projection, fn {_source, output} -> output end)

    points
    |> Enum.map(fn point -> {point, project_point(point, projection)} end)
    |> order_projected(query.order_by, outputs)
    |> apply_limit(query.limit)
    |> Enum.map(fn {_point, row} -> row end)
  end

  @spec order_projected([{point_map(), map()}], SQLParser.order_by(), [binary()]) ::
          [{point_map(), map()}]
  defp order_projected(pairs, nil, _outputs), do: pairs

  defp order_projected(pairs, {column, direction}, outputs) do
    key =
      if column in outputs,
        do: fn {_point, row} -> Map.get(row, column) end,
        else: fn {point, _row} -> point_value(point, column) end

    Enum.sort_by(pairs, key, sorter(direction))
  end

  # The same shape and wording the real engine returns for a missing table
  # (HTTP 400, planning error), so consumer code matching `%{status: 400}`
  # can be exercised against the double.
  @spec table_not_found(binary()) :: %{status: 400, body: binary()}
  defp table_not_found(measurement) do
    %{
      status: 400,
      body: "Error during planning: table 'public.iox.#{measurement}' not found"
    }
  end

  @spec project_point(point_map(), [SQLParser.projection()]) :: map()
  defp project_point(point, projection) do
    Enum.reduce(projection, %{}, fn
      {source, output}, acc when is_binary(source) ->
        put_column(acc, output, point_value(point, source))

      {expr, output}, acc ->
        put_column(acc, output, eval_expr(expr, point))
    end)
  end

  # InfluxDB 3 omits a null column from the row entirely (verified on both
  # the JSON and JSONL formats), so a nil never becomes a key here.
  @spec put_column(map(), binary(), term()) :: map()
  defp put_column(row, _key, nil), do: row
  defp put_column(row, key, value), do: Map.put(row, key, value)

  # SELECT DISTINCT a[, b ...]: one row per distinct combination, sorted
  # unless ORDER BY (one of the selected columns) says otherwise. A row
  # whose columns are all null is dropped, as the real engine does.
  @spec execute_distinct_query([point_map()], SQLParser.parsed_query()) :: [map()]
  defp execute_distinct_query(points, query) do
    columns = query.distinct_columns

    points
    |> Enum.map(fn point -> Enum.map(columns, &point_value(point, &1)) end)
    |> Enum.reject(&Enum.all?(&1, fn value -> is_nil(value) end))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn values ->
      columns
      |> Enum.zip(values)
      |> Enum.reduce(%{}, fn {column, value}, row -> put_column(row, column, value) end)
    end)
    |> apply_order_by_rows(query.order_by, nil)
    |> apply_limit(query.limit)
  end

  @spec point_value(point_map(), binary()) :: term()
  defp point_value(point, "time"), do: nanoseconds_to_datetime(point.timestamp)

  defp point_value(point, column),
    do: Map.get(point.tags, column) || Map.get(point.fields, column)

  @spec execute_aggregate_query([point_map()], SQLParser.parsed_query()) :: [map()]
  defp execute_aggregate_query(points, %{group_by_columns: cols} = query)
       when is_list(cols) and cols != [] do
    # GROUP BY <col, ...>: bucket points by the tuple of grouping-column
    # values (mirroring how real InfluxDB v3 partitions by tags/fields).
    points
    |> bucket_by_columns(cols)
    |> aggregate_per_column_bucket(query.select_columns)
    |> apply_order_by_rows(query.order_by, nil)
    |> apply_limit(query.limit)
  end

  defp execute_aggregate_query(points, %{group_by_interval: nil} = query) do
    # Scalar aggregate: all filtered points form a single bucket. Always
    # produce one row, even when no points matched (so COUNT returns 0).
    [aggregate_one_bucket(points, query.select_columns)]
  end

  defp execute_aggregate_query(points, query) do
    interval_ns = query.group_by_interval

    time_alias = find_time_bucket_alias(query.select_columns)

    points
    |> bucket_by_interval(interval_ns)
    |> aggregate_per_bucket(query.select_columns)
    |> apply_order_by_rows(query.order_by, time_alias)
    |> apply_limit(query.limit)
  end

  # Group points by the tuple of values for the GROUP BY columns. Each
  # column is resolved against tags first, then fields.
  @spec bucket_by_columns([point_map()], [binary()]) :: %{[term()] => [point_map()]}
  defp bucket_by_columns(points, columns) do
    Enum.group_by(points, fn point ->
      Enum.map(columns, fn col ->
        Map.get(point.tags, col) || Map.get(point.fields, col)
      end)
    end)
  end

  @spec aggregate_per_column_bucket(
          %{[term()] => [point_map()]},
          [SQLParser.select_column()]
        ) :: [map()]
  defp aggregate_per_column_bucket(buckets, columns) do
    Enum.map(buckets, fn {_key, bucket_points} ->
      reduce_aggregate_columns(columns, bucket_points, nil)
    end)
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
          [SQLParser.select_column()]
        ) :: [map()]
  defp aggregate_per_bucket(buckets, columns) do
    Enum.map(buckets, fn {bucket_ts, bucket_points} ->
      reduce_aggregate_columns(columns, bucket_points, bucket_ts)
    end)
  end

  # Compute aggregates over a single (un-bucketed) set of points. Used for
  # scalar aggregates (no GROUP BY DATE_BIN) — always yields exactly one row.
  @spec aggregate_one_bucket([point_map()], [SQLParser.select_column()]) :: map()
  defp aggregate_one_bucket(points, columns) do
    reduce_aggregate_columns(columns, points, nil)
  end

  @spec reduce_aggregate_columns(
          [SQLParser.select_column()],
          [point_map()],
          integer() | nil
        ) :: map()
  # Null results (an aggregate over no values, a sample statistic of one
  # value, a missing grouping value) are omitted from the row, as the real
  # engine does; COUNT is 0, never null.
  defp reduce_aggregate_columns(columns, points, bucket_ts) do
    Enum.reduce(columns, %{}, fn
      {:time_bucket, alias_name}, row ->
        put_column(row, alias_name, nanoseconds_to_datetime(bucket_ts))

      {:grouping_column, source, alias_name}, row ->
        # All points in a column-grouped bucket share the same value for
        # this column; sample from the first point.
        value =
          case points do
            [first | _rest] -> point_value(first, source)
            [] -> nil
          end

        put_column(row, alias_name, value)

      {:aggregate, agg, expr, alias_name}, row ->
        values = points |> Enum.map(&eval_expr(expr, &1)) |> Enum.reject(&is_nil/1)
        put_column(row, alias_name, compute_aggregate(agg, values))

      {:count_star, alias_name}, row ->
        # COUNT(*) — every matching row counts, regardless of field nullity.
        put_column(row, alias_name, length(points))

      {:count_distinct, column, alias_name}, row ->
        distinct =
          points
          |> Enum.map(&point_value(&1, column))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        put_column(row, alias_name, length(distinct))

      {:ordered_aggregate, agg, field, ordering, alias_name}, row ->
        put_column(row, alias_name, compute_ordered_aggregate(agg, field, ordering, points))

      {:selector, kind, field, ordering, access, alias_name}, row ->
        put_column(row, alias_name, compute_selector(kind, field, ordering, access, points))
    end)
  end

  # Evaluates an aggregate argument for one point. A missing field or a
  # non-numeric operand makes the value null, which the aggregate skips.
  # `time` is the point's timestamp; the parser only lets it reach MIN, MAX
  # and COUNT, the aggregates DataFusion accepts over a Timestamp.
  @spec eval_expr(SQLParser.expr(), point_map()) :: number() | DateTime.t() | nil
  defp eval_expr({:field, "time"}, point), do: nanoseconds_to_datetime(point.timestamp)
  defp eval_expr({:field, name}, point), do: Map.get(point.fields, name)
  defp eval_expr({:lit, value}, _point), do: value

  defp eval_expr({:op, op, left, right}, point) do
    with l when is_number(l) <- eval_expr(left, point),
         r when is_number(r) <- eval_expr(right, point) do
      arithmetic(op, l, r)
    else
      _non_number -> nil
    end
  end

  @spec arithmetic(:+ | :- | :* | :/, number(), number()) :: number() | nil
  defp arithmetic(:+, l, r), do: l + r
  defp arithmetic(:-, l, r), do: l - r
  defp arithmetic(:*, l, r), do: l * r
  # DataFusion divides two integers as integers (3 / 2 = 1), so the double
  # must not promote to float. Division by zero is null here; the real
  # engine's behaviour differs and is documented in the moduledoc.
  defp arithmetic(:/, _l, 0), do: nil
  defp arithmetic(:/, _l, +0.0), do: nil
  defp arithmetic(:/, l, r) when is_integer(l) and is_integer(r), do: div(l, r)
  defp arithmetic(:/, l, r), do: l / r

  @spec compute_aggregate(SQLParser.aggregate(), [number() | DateTime.t()]) ::
          number() | DateTime.t() | nil
  defp compute_aggregate(:count, vals), do: length(vals)
  defp compute_aggregate(_agg, []), do: nil
  defp compute_aggregate(:avg, vals), do: Enum.sum(vals) / length(vals)
  defp compute_aggregate(:sum, vals), do: Enum.sum(vals)
  # MIN/MAX also run over `time`, so the comparison must be DateTime-aware.
  defp compute_aggregate(:min, vals), do: Enum.min(vals, &value_order/2)
  defp compute_aggregate(:max, vals), do: Enum.max(vals, sorter(:desc))
  defp compute_aggregate(:median, vals), do: median(vals)
  # Sample forms need at least two values, exactly as the real engine
  # (STDDEV of one row is null); population forms are defined for one.
  defp compute_aggregate(:var, [_one]), do: nil
  defp compute_aggregate(:stddev, [_one]), do: nil
  defp compute_aggregate(:var, vals), do: sum_of_squares(vals) / (length(vals) - 1)
  defp compute_aggregate(:stddev, vals), do: :math.sqrt(compute_aggregate(:var, vals))
  defp compute_aggregate(:var_pop, vals), do: sum_of_squares(vals) / length(vals)
  defp compute_aggregate(:stddev_pop, vals), do: :math.sqrt(compute_aggregate(:var_pop, vals))

  # DataFusion's median: the middle value, or for an even count the mean of
  # the two middle values — computed in the column's type, so two integers
  # average with integer division (median of 1 and 4 is 2, not 2.5).
  @spec median([number()]) :: number()
  defp median(vals) do
    sorted = Enum.sort(vals)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      low = Enum.at(sorted, mid - 1)
      high = Enum.at(sorted, mid)
      if is_integer(low) and is_integer(high), do: div(low + high, 2), else: (low + high) / 2
    end
  end

  @spec sum_of_squares([number()]) :: float()
  defp sum_of_squares(vals) do
    mean = Enum.sum(vals) / length(vals)
    Enum.reduce(vals, 0.0, fn v, acc -> acc + (v - mean) * (v - mean) end)
  end

  # selector_first/last pick by the ordering column, selector_min/max by the
  # field itself; `['value']` returns the field, `['time']` the row's time.
  @spec compute_selector(
          :first | :last | :min | :max,
          binary(),
          binary(),
          :value | :time,
          [point_map()]
        ) :: term() | nil
  defp compute_selector(kind, field, ordering, access, points) do
    candidates = Enum.reject(points, &is_nil(Map.get(&1.fields, field)))

    picked =
      case {kind, candidates} do
        {_kind, []} -> nil
        {:first, pts} -> Enum.min_by(pts, &ordering_value(&1, ordering))
        {:last, pts} -> Enum.max_by(pts, &ordering_value(&1, ordering))
        {:min, pts} -> Enum.min_by(pts, &Map.get(&1.fields, field))
        {:max, pts} -> Enum.max_by(pts, &Map.get(&1.fields, field))
      end

    case {picked, access} do
      {nil, _access} -> nil
      {point, :value} -> Map.get(point.fields, field)
      {point, :time} -> nanoseconds_to_datetime(point.timestamp)
    end
  end

  # Ordered aggregates: return the field value from the point with
  # the min (first) or max (last) ordering column value.
  @spec compute_ordered_aggregate(
          :first | :last,
          binary(),
          binary(),
          [point_map()]
        ) :: term() | nil
  defp compute_ordered_aggregate(_agg, _field, _ordering, []), do: nil

  # A single pass for the extreme element; sorting the whole bucket to take
  # its head was O(n log n) per aggregate column. Ties resolve to the first
  # point in scan (insertion) order, as the stable sort did.
  defp compute_ordered_aggregate(agg, field, ordering, points) do
    picked =
      case agg do
        :first -> Enum.min_by(points, &ordering_value(&1, ordering))
        :last -> Enum.max_by(points, &ordering_value(&1, ordering))
      end

    Map.get(picked.fields, field) || Map.get(picked.tags, field)
  end

  # Resolve the ordering column value from a point.
  # "time" maps to the point's timestamp; anything else is a field/tag.
  @spec ordering_value(point_map(), binary()) :: term()
  defp ordering_value(point, "time"), do: point.timestamp || 0

  defp ordering_value(point, col) do
    Map.get(point.fields, col) || Map.get(point.tags, col) || 0
  end

  # Find the alias of the time_bucket column from select_columns
  @spec find_time_bucket_alias([SQLParser.select_column()]) :: binary() | nil
  defp find_time_bucket_alias(columns) do
    Enum.find_value(columns, fn
      {:time_bucket, alias_name} -> alias_name
      _other -> nil
    end)
  end

  # Order aggregate result rows by any output column. `ORDER BY time` on a
  # DATE_BIN query refers to the bucket, whatever its alias.
  @spec apply_order_by_rows([map()], SQLParser.order_by(), binary() | nil) :: [map()]
  defp apply_order_by_rows(rows, nil, _time_alias), do: rows

  defp apply_order_by_rows(rows, {column, direction}, time_alias) do
    key = if column == "time" and time_alias, do: time_alias, else: column
    Enum.sort_by(rows, &Map.get(&1, key), sorter(direction))
  end

  # DateTime structs must be compared chronologically; everything else uses
  # term order (nil, an omitted column, sorts first).
  @spec value_order(term(), term()) :: boolean()
  defp value_order(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) != :gt
  defp value_order(a, b), do: a <= b

  @spec sorter(:asc | :desc) :: (term(), term() -> boolean())
  defp sorter(:asc), do: &value_order/2
  defp sorter(:desc), do: fn a, b -> value_order(b, a) end

  # A predicate the engine refuses at planning time (LIKE over a number) is
  # only discoverable here, per value, so it is thrown out of the filter and
  # turned into the same 400 the engine returns.
  @spec apply_where([point_map()], [SQLParser.where_node()]) ::
          {:ok, [point_map()]} | {:error, %{status: 400, body: binary()}}
  defp apply_where(points, []), do: {:ok, points}

  defp apply_where(points, conjunction) do
    {:ok, Enum.filter(points, &matches_all?(&1, conjunction))}
  catch
    {:where_error, message} -> {:error, %{status: 400, body: message}}
  end

  @spec matches_all?(point_map(), [SQLParser.where_node()]) :: boolean()
  defp matches_all?(point, conjunction), do: Enum.all?(conjunction, &node_matches?(point, &1))

  @spec node_matches?(point_map(), SQLParser.where_node()) :: boolean()
  defp node_matches?(point, {:or, branches}), do: Enum.any?(branches, &matches_all?(point, &1))
  defp node_matches?(point, {:not, conjunction}), do: not matches_all?(point, conjunction)
  defp node_matches?(point, clause), do: matches_condition?(point, clause)

  @spec matches_condition?(point_map(), SQLParser.where_clause()) :: boolean()
  defp matches_condition?(point, {:between, "time", {low, high}}) do
    ts = point.timestamp
    not is_nil(ts) and ts >= to_nanoseconds(low) and ts <= to_nanoseconds(high)
  end

  defp matches_condition?(point, {:not_between, "time", range}),
    do: not matches_condition?(point, {:between, "time", range})

  defp matches_condition?(point, {:between, key, {low, high}}) do
    actual = point_value(point, key)
    compare(actual, :gte, low) and compare(actual, :lte, high)
  end

  defp matches_condition?(point, {:not_between, key, range}),
    do: not matches_condition?(point, {:between, key, range})

  defp matches_condition?(point, {:like, key, regex}) do
    case point_value(point, key) do
      nil -> false
      text when is_binary(text) -> Regex.match?(regex, text)
      _number -> throw({:where_error, like_type_error(key)})
    end
  end

  defp matches_condition?(point, {:not_like, key, regex}) do
    case point_value(point, key) do
      nil -> false
      text when is_binary(text) -> not Regex.match?(regex, text)
      _number -> throw({:where_error, like_type_error(key)})
    end
  end

  defp matches_condition?(point, {:in, "time", values}) do
    point_in_time_set?(point, values)
  end

  defp matches_condition?(point, {:not_in, "time", values}) do
    not point_in_time_set?(point, values)
  end

  defp matches_condition?(point, {:in, key, values}) do
    actual = Map.get(point.tags, key) || Map.get(point.fields, key)
    Enum.any?(values, &compare(actual, :eq, &1))
  end

  defp matches_condition?(point, {:not_in, key, values}) do
    actual = Map.get(point.tags, key) || Map.get(point.fields, key)
    not Enum.any?(values, &compare(actual, :eq, &1))
  end

  defp matches_condition?(point, {:is_null, key, _nil}), do: is_nil(point_value(point, key))

  defp matches_condition?(point, {:is_not_null, key, _nil}),
    do: not is_nil(point_value(point, key))

  defp matches_condition?(point, {op, "time", value}) do
    compare(point.timestamp, op, to_nanoseconds(value))
  end

  defp matches_condition?(point, {op, left, right}) do
    compare(left_value(point, left), op, right_value(point, right))
  end

  # The left operand is a column name or an arithmetic expression; the right
  # one is a literal unless the parser tagged it as an expression.
  @spec left_value(point_map(), SQLParser.operand()) :: term()
  defp left_value(point, {:expr, expr}), do: eval_expr(expr, point)
  defp left_value(point, key), do: point_value(point, key)

  @spec right_value(point_map(), term()) :: term()
  defp right_value(point, {:expr, expr}), do: eval_expr(expr, point)
  defp right_value(_point, literal), do: literal

  @spec point_in_time_set?(point_map(), [term()]) :: boolean()
  defp point_in_time_set?(point, values) do
    ts = point.timestamp
    Enum.any?(values, fn v -> ts == to_nanoseconds(v) end)
  end

  # The parser has already turned every `time` comparand into nanoseconds or
  # a `now()` offset; `now()` is resolved here, at execution, as the engine
  # does.
  @spec to_nanoseconds(SQLParser.time_value()) :: integer()
  defp to_nanoseconds(value) when is_integer(value), do: value
  defp to_nanoseconds({:now, offset_ns}), do: System.os_time(:nanosecond) + offset_ns

  # The engine's exact wording; a placeholder with no binding is a planning
  # error there, never an empty result.
  @spec unbound_placeholder_error(binary()) :: %{status: 400, body: binary()}
  defp unbound_placeholder_error(name) do
    %{
      status: 400,
      body: "Error during planning: No value found for placeholder with name #{name}"
    }
  end

  # DataFusion: "There isn't a common type to coerce Float64 and Utf8 in
  # LIKE expression".
  @spec like_type_error(binary()) :: binary()
  defp like_type_error(key) do
    "Error during planning: There isn't a common type to coerce a numeric column and " <>
      "Utf8 in LIKE expression: #{key}"
  end

  # Both nil-actual (missing column) and nil-value (unparseable comparand)
  # short-circuit to false. Without this guard, Elixir term ordering would
  # silently produce wrong results (e.g. `5 > nil` is `true`).
  #
  # A string literal against a non-string column compares the column's text
  # rendering, which is what DataFusion does (it casts the numeric side to
  # Utf8): `amount >= '1000.00'` is lexical, so 500.0 matches. The double
  # reproduces that so a test written against it fails the same way
  # production would.
  #
  # The other way round — a string column against a numeric literal — the
  # engine keeps the column as text and renders the literal (`rack = 2`
  # matches the tag "2"; `rack > 3` is lexical, so "10" does not match), so
  # the literal is rendered here too.
  @spec compare(term(), atom(), term()) :: boolean()
  defp compare(nil, _op, _value), do: false
  defp compare(_actual, _op, nil), do: false

  defp compare(actual, op, value) when is_binary(value) and not is_binary(actual),
    do: compare(to_string(actual), op, value)

  defp compare(actual, op, value) when is_binary(actual) and is_number(value),
    do: compare(actual, op, to_string(value))

  defp compare(actual, :eq, value), do: actual == value
  defp compare(actual, :ne, value), do: actual != value
  defp compare(actual, :gt, value), do: actual > value
  defp compare(actual, :lt, value), do: actual < value
  defp compare(actual, :gte, value), do: actual >= value
  defp compare(actual, :lte, value), do: actual <= value

  # ORDER BY any column on raw rows: `time` sorts by timestamp, anything
  # else by the tag/field value (nil first, as the real engine sorts nulls).
  @spec apply_order_by([point_map()], SQLParser.order_by()) :: [point_map()]
  defp apply_order_by(points, nil), do: points

  defp apply_order_by(points, {"time", direction}) do
    Enum.sort_by(points, & &1.timestamp, direction)
  end

  defp apply_order_by(points, {column, direction}) do
    Enum.sort_by(points, &point_value(&1, column), sorter(direction))
  end

  @spec apply_limit([point_map()], pos_integer() | nil) :: [point_map()]
  defp apply_limit(points, nil), do: points
  defp apply_limit(points, n), do: Enum.take(points, n)

  @spec point_to_row(point_map()) :: map()
  # `time` is a DateTime (microsecond precision), as on the HTTP and Flight
  # transports, so consumer code sees one type whichever client is configured.
  defp point_to_row(point) do
    point.fields
    |> Map.merge(point.tags)
    |> put_column("time", nanoseconds_to_datetime(point.timestamp))
  end

  # Flux responses include _measurement (v2 compatibility format)

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
    |> Enum.reject(fn [_full, key, _val] -> key in ["_measurement", "_field"] end)
    |> Enum.reduce(points, fn [_full, key, value], acc ->
      Enum.filter(acc, fn point ->
        Map.get(point.tags, key) == value or
          Map.get(point.fields, key) == value
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private — utilities
  # ---------------------------------------------------------------------------

  @spec delete_points(:ets.table(), binary(), binary(), [SQLParser.where_clause()]) ::
          non_neg_integer()
  # Each matching point is deleted by its own key, so a concurrent write to
  # the same measurement is never lost to a rewrite of the whole list.
  defp delete_points(table, database, measurement, where) do
    table
    |> :ets.select([{{{:point, database, measurement, :_}, :_}, [], [:"$_"]}])
    |> Enum.filter(fn {_key, point} ->
      where == [] or Enum.all?(where, &matches_condition?(point, &1))
    end)
    |> Enum.map(fn {key, _point} -> :ets.delete(table, key) end)
    |> length()
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
