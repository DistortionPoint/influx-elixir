defmodule InfluxElixir.Client.Local do
  @moduledoc """
  In-memory InfluxDB client for fast, isolated testing.

  Stores data in ETS tables, enabling safe `async: true` tests with full
  isolation between test instances. Each call to `start/1` creates an
  independent ETS table.

  Parses real line protocol on write, stores points as maps, and responds
  with realistic InfluxDB response formats on query. Parsing is split out:
  `InfluxElixir.Client.Local.LineProtocolParser` handles writes and
  `InfluxElixir.Client.Local.SQLParser` handles the SQL subset;
  `InfluxElixir.Client.Local.Store` owns the ETS table; this module
  owns profiles, the write rules and the InfluxQL and Flux paths; SQL execution is
  `InfluxElixir.Client.Local.SQLExecutor`.

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

  ## Storage

  Each instance is one ETS table owned by `InfluxElixir.Client.Local.Store`,
  which alone knows the key layout. Every mutation is a single insert or
  delete of its own key, so concurrent writers — `async: true` tests sharing
  one database, `BatchWriter` flushes racing direct writes — never
  read-modify-write a shared value and no write is ever lost.

  ## Write Rules

  What a write accepts is what InfluxDB 3 accepts, verified against the
  engine:

    * A payload is applied line by line. A line with a syntax error, or a
      column whose kind conflicts with the measurement's schema, is dropped
      and reported; the other lines are stored. The result is then
      `{:error, %{status: 400, body: json}}` with the engine's body —
      `"partial write of line protocol occurred"` and one `data` entry per
      bad line (`error_message`, `line_number`, `original_line`).
    * A column's kind is fixed by the first write that names it, per
      database and measurement: a tag stays a tag, an integer field stays
      an integer (`v=1i` then `v=2.0` is "invalid column type for column
      'v', expected iox::column_type::field::integer, got
      iox::column_type::field::float"). Deleting the database drops the
      schema with the data.
    * `time` is a reserved column ("'time' is a reserved column" on a new table;
      on an existing one the engine words it as a column-type conflict with
      `iox::column_type::timestamp`); a key cannot be both a tag and a field on
      one line; an integer must fit in 64 bits (`7u` is unsigned); a newline
      inside a quoted string value is part of the value; a measurement, tag
      key, tag value or field key ending in a backslash is refused ("... may
      not end with a backslash"); an empty payload is
      "incoming write was empty".
    * Points with the same measurement, tag set and timestamp are one point,
      on both versions (verified): their fields merge and the later write
      wins per field — `v=1i,w=1i` then `v=2i` at the same instant reads
      back as `v=2, w=1`, and the last of two such lines in one payload
      wins. A different tag value is a different point. `DELETE` removes
      the merged point.
    * `accept_partial: false` makes a write all-or-nothing: the first bad
      line in line order — a parse error or a schema conflict, also against
      an earlier line of the same payload — rejects it, nothing is stored
      (not even schema), and the body is `{"error": "line protocol parsing
      error", "data": {...}}` with that one line. `no_sync:` is accepted
      and changes nothing (the double has no write-ahead log; on the
      engine a `no_sync` write may not be visible to a query right away).
      Either one that is not a boolean is the engine's 400.
    * A schema error's `original_line` is the line as the engine renders
      it, not as it was sent: single spaces, floats shortest and without an
      exponent (`2.0` → `2`), strings unquoted. Runs of spaces between a
      line's sections are one separator.
    * Under the `:v2` profile the rules are InfluxDB 2's, verified against
      2.7: a field type conflict is HTTP 422 (`{"code":"unprocessable
      entity","message":"... field type conflict: input field \"v\" on
      measurement \"m\" is type float, already exists as type integer
      dropped=N"}`) with the other lines stored; a line that fails to parse
      rejects the whole payload with HTTP 400 (`{"code":"invalid","message":
      "unable to parse '<line>': ..."}`) and nothing is stored; `time` as a
      field is dropped silently and as a tag is a 400; a tag and a field may
      share a name; an empty payload is accepted.

  ## SQL Query Support

  `query_sql/3` understands a subset of SQL:

    * `SELECT * FROM measurement`
    * `SELECT col1, col2 [, ...] FROM measurement` with optional `AS alias`
      (projects fields and tags; `time` is selectable). `time` and
      `DATE_BIN` buckets are `DateTime` values with microsecond precision,
      the same as the HTTP and Flight transports return; compare them with
      `DateTime.compare/2` or a six-digit sigil (`~U[... .000000Z]`).
      A projected column may be an arithmetic expression with an alias
      (`(bid + ask) / 2 AS mid`; `+ - * / %` and unary minus, `%` taking the
      dividend's sign); a null operand makes the column null
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
      joins, set operations, `HAVING` and window functions are
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
      param) is never true. Logic is SQL's three-valued logic: a comparison
      with a null operand is unknown, `NOT` keeps it unknown, and only a true
      predicate keeps the row, so `NOT (rack = '1')` does not return rows
      without a `rack`. A boolean column is itself a predicate (`WHERE b`,
      `NOT b`); any other bare column is the engine's planning error
      ("Cannot create filter with non-boolean predicate 't.n' returning
      Int64").
    * `WHERE col IN (v1, v2, ...)` and `WHERE col NOT IN (v1, v2, ...)` — each
      item a literal, a column or an expression, as in SQL (a bare word is
      a column reference, never a string)
    * A constant with an alias in any select list (`0.0 AS volume`,
      `'x' AS label`); an unaliased constant is refused because DataFusion
      names it after its own rendering
    * `WHERE col IS NULL` and `WHERE col IS NOT NULL`
    * `WHERE col [NOT] BETWEEN low AND high` (inclusive; `time` too)
    * `WHERE col [NOT] LIKE 'pattern'` and `ILIKE` (`%` any run, `_` one
      character, a backslash makes the next character literal — `'al\\%%'`; `LIKE` is
      case-sensitive, `ILIKE` is not). `LIKE` over a
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
      `ORDER BY` must name a selected column, as in DataFusion). An all-null
      combination is a row too (`%{}`).
    * `ORDER BY a [ASC|DESC][, b [ASC|DESC] ...]` — each term `time`, a
      column, an output alias, or (on raw and projected rows) an expression
      such as `CAST(level AS INTEGER) DESC`; every term applies, each with
      its own direction. Nulls sort last ascending and first descending,
      unless a term says `NULLS FIRST` / `NULLS LAST`.
    * `CAST(expr AS INTEGER | INT | BIGINT | DOUBLE | FLOAT | VARCHAR | STRING)`
      and DataFusion's `col::TYPE` shorthand, wherever an expression is
      allowed: `WHERE` (`CAST(level AS INTEGER) <= 20` compares a numeric tag
      numerically), `BETWEEN`, `LIKE`, projections, aggregates, arithmetic
      and `ORDER BY`. Text converts only when the whole string is a number,
      a float truncates to an integer, a number renders to text, null stays
      null. A cast that cannot be performed (`'abc'` to `INTEGER`, `time` to
      `INTEGER`) makes InfluxDB 3 Core drop the connection mid-response,
      which `Client.HTTP` reports as `{:error, {:connection_error,
      %Mint.TransportError{reason: :closed}}}`; the double reports
      `{:error, {:connection_error, :closed}}`. `BOOLEAN` and `TIMESTAMP`
      targets are outside the subset.
    * `LIMIT n` and `OFFSET m`, in either order — `OFFSET` skips rows before
      `LIMIT` takes them, on plain, projected, grouped and `DISTINCT` rows
      alike; `LIMIT 0` returns no rows; a negative or non-numeric
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
      and `['time']`; without a subscript, the engine's struct
      `%{"time" => %DateTime{}, "value" => v}`
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
      function"). `ORDER BY` applies to grouped rows too. Grouping columns
      combine with `DATE_BIN` (a row per bucket per value).
    * A `GROUP BY` item may be a select alias (`GROUP BY bucket`) or a
      1-based position (`GROUP BY 1, 2`), and an `ORDER BY` item a position
      (`ORDER BY 2 DESC`), as DataFusion resolves them; a position outside
      the select list is the engine's planning error.
    * Interval units: `seconds`, `minutes`, `hours`, `days`

  A null column is omitted from the row rather than present as `nil`,
  exactly as InfluxDB 3's JSON and JSONL responses do (`COUNT` is `0`, never
  null).

  `format:` is answered as `Client.HTTP` answers it — `:csv` rows carry
  the engine's CSV strings, `:parquet` is refused by name, an unknown
  format is the engine's 400: see `InfluxElixir.Client.Local.Format`.

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

  Pass `precision:` in opts to say what unit numeric timestamps are in.
  The spellings are the engine's, verified: InfluxDB 3 (`:v3_core`,
  `:v3_enterprise`) takes `ns | n | nanosecond | us | u | microsecond |
  ms | millisecond | s | second | auto` as an atom or a string, where
  `auto` guesses the unit from the magnitude (below 5e9 seconds, 5e12
  milliseconds, 5e15 microseconds, else nanoseconds); anything else is the
  engine's 400 `serde error: unknown variant`. InfluxDB 2 (`:v2`) takes
  `ns | us | ms | s` and the long names `HTTP.write/3` maps onto them, and
  answers 400 `invalid precision` to the rest. Default: nanoseconds.
  """

  @behaviour InfluxElixir.Client

  alias InfluxElixir.Client.Local.{
    DatabaseRules,
    Flux,
    Format,
    InfluxQL,
    LineProtocolParser,
    SQLExecutor,
    SQLParser,
    Store
  }

  @type point_map :: LineProtocolParser.point()

  @type profile :: :v3_core | :v3_enterprise | :v2

  @type conn :: %{
          table: Store.t(),
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
    * `:databases` - list of database names to pre-create (default: `[]`).
      Without `:database`, the first is the default, as in `Client.HTTP`.
      With neither there is no default: an operation that needs a database
      is `{:error, :no_database_specified}`, as over HTTP.

  On the v3 profiles each name must be one InfluxDB 3 accepts, and
  `:v3_core` holds at most 5; `start/1` raises `ArgumentError` with the
  engine's message otherwise (see `InfluxElixir.Client.Local.DatabaseRules`).
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

    # As `Client.HTTP.init_connection/1`: without `:database` the first of
    # `:databases` is the default. With neither there is none, and an
    # operation that needs one is `{:error, :no_database_specified}` — no
    # "default" database the server does not have.
    listed = Keyword.get(opts, :databases, [])
    database = Keyword.get(opts, :database) || List.first(listed)
    databases = Enum.uniq(listed ++ List.wrap(database))

    if profile != :v2, do: DatabaseRules.check_start!(databases, profile)

    # A public ETS store (see `InfluxElixir.Client.Local.Store`): every
    # mutation is one insert or delete of its own key, so no process is
    # needed to make concurrent writers safe.
    {:ok, %{table: Store.new(databases), database: database, profile: profile}}
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

  # Mirrors HTTP's resolve_database/2: opts[:database], then the
  # connection-level default; neither is the HTTP client's error.
  @spec resolve_database(keyword(), conn()) ::
          {:ok, binary()} | {:error, :no_database_specified}
  defp resolve_database(opts, conn) do
    case Keyword.get(opts, :database) || Map.get(conn, :database) do
      nil -> {:error, :no_database_specified}
      database -> {:ok, database}
    end
  end

  # A query names a database the engine has (verified: SQL of any kind and
  # InfluxQL other than SHOW DATABASES answer 404 otherwise). `_internal`
  # exists on the engine, but its system tables are not modelled.
  @spec database_exists(Store.t(), binary()) :: :ok | {:error, map()}
  defp database_exists(table, database) do
    cond do
      Store.database?(table, database) ->
        :ok

      database == DatabaseRules.internal() ->
        {:error,
         %{
           status: 400,
           body: "Client.Local: the _internal database's system tables are not modelled"
         }}

      true ->
        {:error,
         %{
           status: 404,
           body: Jason.encode!(%{"error" => "query error: database not found: #{database}"})
         }}
    end
  end

  @doc """
  Stops a LocalClient instance and cleans up its ETS table.

  Safe to call multiple times; a no-op if the table is already deleted.
  """
  @spec stop(conn()) :: :ok
  def stop(%{table: table}), do: Store.drop(table)

  # ---------------------------------------------------------------------------
  # Write
  # ---------------------------------------------------------------------------

  @doc """
  Parses line protocol binary and stores the resulting points in ETS.

  The `database` is read from `opts[:database]`. If the database does not
  exist an `{:error, %{status: 404, body: ...}}` is returned. If line protocol
  cannot be parsed an `{:error, %{status: 400, body: ...}}` is returned.

  Payloads beginning with gzip magic bytes are automatically decompressed.
  Pass `precision:` to say what unit numeric timestamps are in (default
  nanoseconds); see "Timestamp Precision" in the moduledoc for the
  spellings each profile accepts and `auto`.
  """
  @impl true
  @spec write(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.write_result()
  def write(%{table: table, profile: profile} = conn, payload, opts \\ []) do
    with :ok <- require_capability(conn, :write),
         {:ok, database} <- resolve_database(opts, conn),
         {:ok, text} <- maybe_decompress(payload),
         {:ok, precision} <- normalize_precision(Keyword.get(opts, :precision), profile),
         {:ok, accept_partial} <- write_flag(opts, :accept_partial, true, profile),
         {:ok, _no_sync} <- write_flag(opts, :no_sync, false, profile),
         :ok <- ensure_database(table, database, profile) do
      case LineProtocolParser.parse_lines(text, precision, dialect(profile)) do
        {:ok, lines} when profile != :v2 and not accept_partial ->
          store_lines_atomically(table, database, lines)

        {:ok, lines} ->
          store_lines(table, database, lines, profile)

        # InfluxDB 2 answers 204 to an empty payload; InfluxDB 3 refuses it.
        {:error, _empty} when profile == :v2 ->
          {:ok, :written}

        {:error, _reason} = error ->
          error
      end
    end
  end

  # What `HTTP.write/3` plus the engine accept for `:precision`, verified:
  # InfluxDB 3 takes the spellings below verbatim (case-sensitive) and
  # answers 400 to anything else; InfluxDB 2 takes only `ns|us|ms|s`, which
  # `HTTP.write/3` maps the long names onto, and answers 400 to the rest.
  @v3_precisions %{
    "auto" => :auto,
    "s" => :second,
    "second" => :second,
    "ms" => :millisecond,
    "millisecond" => :millisecond,
    "u" => :microsecond,
    "us" => :microsecond,
    "microsecond" => :microsecond,
    "n" => :nanosecond,
    "ns" => :nanosecond,
    "nanosecond" => :nanosecond
  }

  @v2_precisions Map.take(
                   @v3_precisions,
                   ~w(ns nanosecond us microsecond ms millisecond s second)
                 )

  @spec normalize_precision(atom() | binary() | nil, profile()) ::
          {:ok, LineProtocolParser.precision()} | {:error, map()}
  defp normalize_precision(nil, _profile), do: {:ok, :nanosecond}

  defp normalize_precision(precision, :v2) do
    case Map.fetch(@v2_precisions, to_string(precision)) do
      {:ok, unit} ->
        {:ok, unit}

      :error ->
        {:error,
         %{
           status: 400,
           body:
             Jason.encode!(%{
               "code" => "invalid",
               "message" => "invalid precision; valid precision units are ns, us, ms, and s"
             })
         }}
    end
  end

  defp normalize_precision(precision, _v3) do
    case Map.fetch(@v3_precisions, to_string(precision)) do
      {:ok, unit} ->
        {:ok, unit}

      :error ->
        {:error,
         %{
           status: 400,
           body:
             "serde error: unknown variant `#{precision}`, expected one of `auto`, `s`, " <>
               "`second`, `millisecond`, `ms`, `microsecond`, `u`, `us`, `n`, `nanosecond`, `ns`"
         }}
    end
  end

  @spec dialect(profile()) :: LineProtocolParser.dialect()
  defp dialect(:v2), do: :v2
  defp dialect(_v3), do: :v3

  # InfluxDB 3: every accepted line is stored and every rejected one
  # reported ("partial write of line protocol occurred", HTTP 400, one entry
  # per bad line) — a syntax error or a column whose kind conflicts with the
  # measurement's schema drops that line only.
  #
  # InfluxDB 2: a line that fails to parse rejects the whole payload (HTTP
  # 400 `{"code":"invalid","message":"unable to parse '<line>': ..."}`,
  # nothing stored); a field type conflict drops the conflicting lines and
  # answers 422 with the first conflict and `dropped=N`.
  #
  # Both bodies are the engine's JSON so consumer code that reads them can
  # be exercised.
  @spec store_lines(Store.t(), binary(), [LineProtocolParser.line_result()], profile()) ::
          InfluxElixir.Client.write_result()
  defp store_lines(table, database, lines, :v2) do
    case Enum.find(lines, &match?({:error, _line_error}, &1)) do
      {:error, %{error_message: message, line: line}} ->
        {:error,
         %{
           status: 400,
           body:
             Jason.encode!(%{
               "code" => "invalid",
               "message" => "unable to parse '#{line}': #{message}"
             })
         }}

      nil ->
        conflicts =
          Enum.reduce(lines, [], fn {:ok, point, _number, _line}, conflicts ->
            case check_schema(table, database, point, :v2) do
              :ok ->
                Store.store_point(table, database, strip_uint_markers(point))
                conflicts

              {:error, conflict} ->
                [conflict | conflicts]
            end
          end)

        case Enum.reverse(conflicts) do
          [] ->
            {:ok, :written}

          [{field, measurement, existing, got} | _rest] = dropped ->
            message =
              "failure writing points to database: partial write: field type conflict: " <>
                ~s|input field "#{field}" on measurement "#{measurement}" is type #{got}, | <>
                "already exists as type #{existing} dropped=#{length(dropped)}"

            {:error,
             %{
               status: 422,
               body: Jason.encode!(%{"code" => "unprocessable entity", "message" => message})
             }}
        end
    end
  end

  defp store_lines(table, database, lines, _v3) do
    errors =
      Enum.reduce(lines, [], fn
        {:error, line_error}, errors ->
          [line_error | errors]

        {:ok, point, number, line}, errors ->
          case check_schema(table, database, point, :v3) do
            :ok ->
              Store.store_point(table, database, strip_uint_markers(point))
              errors

            {:error, message} ->
              [LineProtocolParser.schema_error(message, number, line) | errors]
          end
      end)

    case errors do
      [] ->
        {:ok, :written}

      errors ->
        {:error,
         %{
           status: 400,
           body:
             Jason.encode!(%{
               "error" => "partial write of line protocol occurred",
               "data" => errors |> Enum.reverse() |> Enum.map(&Map.delete(&1, :line))
             })
         }}
    end
  end

  # `accept_partial: false` and `no_sync:` are InfluxDB 3 write parameters
  # (`HTTP.write/3` sends them as `&accept_partial=false`, `&no_sync=true`);
  # the engine refuses anything but `true` / `false` (verified). `no_sync`
  # changes durability only, which the double does not have, so it is
  # accepted and changes nothing. InfluxDB 2's endpoint has neither.
  @spec write_flag(keyword(), atom(), boolean(), profile()) :: {:ok, boolean()} | {:error, map()}
  defp write_flag(_opts, _key, default, :v2), do: {:ok, default}

  defp write_flag(opts, key, default, _v3) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) ->
        {:ok, value}

      _other ->
        {:error, %{status: 400, body: "serde error: provided string was not `true` or `false`"}}
    end
  end

  # `accept_partial: false` (verified against InfluxDB 3): the first bad
  # line in line order — a parse error or a schema conflict, including one
  # against an earlier line of the same payload — rejects the whole payload
  # and nothing is stored, not even the schema; the body is
  # `{"error": "line protocol parsing error", "data": {one line error}}`.
  # Every line is checked against the stored schema plus the payload's
  # pending columns before anything is written.
  @spec store_lines_atomically(Store.t(), binary(), [LineProtocolParser.line_result()]) ::
          InfluxElixir.Client.write_result()
  defp store_lines_atomically(table, database, lines) do
    case first_line_error(table, database, lines) do
      nil ->
        store_lines(table, database, lines, :v3_core)

      line_error ->
        {:error,
         %{
           status: 400,
           body:
             Jason.encode!(%{
               "error" => "line protocol parsing error",
               "data" => Map.delete(line_error, :line)
             })
         }}
    end
  end

  @spec first_line_error(Store.t(), binary(), [LineProtocolParser.line_result()]) ::
          LineProtocolParser.line_error() | nil
  defp first_line_error(table, database, lines) do
    Enum.reduce_while(lines, {:ok, %{}}, fn
      {:error, line_error}, _pending ->
        {:halt, {:error, line_error}}

      {:ok, point, number, line}, {:ok, pending} ->
        case dry_check(table, database, point, pending) do
          {:ok, pending} ->
            {:cont, {:ok, pending}}

          {:error, message} ->
            {:halt, {:error, LineProtocolParser.schema_error(message, number, line)}}
        end
    end)
    |> case do
      {:error, line_error} -> line_error
      {:ok, _pending} -> nil
    end
  end

  # The v3 schema checks without registering anything; `pending` holds the
  # kinds the payload's earlier lines would register.
  @spec dry_check(Store.t(), binary(), point_map(), map()) :: {:ok, map()} | {:error, binary()}
  defp dry_check(table, database, point, pending) do
    m = point.measurement

    exists? =
      Store.table?(table, database, m) or Enum.any?(Map.keys(pending), &match?({^m, _column}, &1))

    with :ok <- reserved_time(point, exists?) do
      point
      |> point_columns(:v3)
      |> Enum.reduce_while({:ok, pending}, fn {column, type}, {:ok, pending} ->
        existing = Map.get(pending, {m, column}) || Store.column_kind(table, database, m, column)

        if existing in [nil, type],
          do: {:cont, {:ok, Map.put(pending, {m, column}, type)}},
          else: {:halt, {:error, conflict(:v3, column, point, existing, type)}}
      end)
    end
  end

  # InfluxDB 3 reserves `time` for the timestamp column. The wording
  # depends on whether the table exists (verified): a new table refuses
  # the line outright, an existing one reports a column-type conflict.
  @spec check_schema(Store.t(), binary(), point_map(), LineProtocolParser.dialect()) ::
          :ok | {:error, binary() | {binary(), binary(), binary(), binary()}}
  defp check_schema(table, database, point, :v3) do
    case reserved_time(point, Store.table?(table, database, point.measurement)) do
      :ok -> check_column_types(table, database, point, :v3)
      {:error, _message} = error -> error
    end
  end

  defp check_schema(table, database, point, :v2),
    do: check_column_types(table, database, point, :v2)

  @spec reserved_time(point_map(), boolean()) :: :ok | {:error, binary()}
  defp reserved_time(%{tags: tags, fields: fields}, table_exists?) do
    cond do
      Map.has_key?(tags, "time") ->
        reserved_time_error(table_exists?, "iox::column_type::tag")

      Map.has_key?(fields, "time") ->
        reserved_time_error(
          table_exists?,
          LineProtocolParser.column_type(:field, Map.fetch!(fields, "time"))
        )

      true ->
        :ok
    end
  end

  @spec reserved_time_error(boolean(), binary()) :: {:error, binary()}
  defp reserved_time_error(table_exists?, got) do
    if table_exists? do
      {:error,
       "invalid column type for column 'time', expected iox::column_type::timestamp, got " <>
         got}
    else
      {:error, "'time' is a reserved column"}
    end
  end

  # The measurement's schema, one ETS object per column so the first writer
  # of a column fixes its kind atomically (`insert_new`) and a concurrent
  # writer never loses a column. InfluxDB 3 types tags and fields in one
  # namespace and reports a conflict with its column-type wording; InfluxDB
  # 2 types fields only and reports `{field, measurement, existing, got}`.
  @spec check_column_types(Store.t(), binary(), point_map(), LineProtocolParser.dialect()) ::
          :ok | {:error, binary() | {binary(), binary(), binary(), binary()}}
  defp check_column_types(table, database, point, dialect) do
    point
    |> point_columns(dialect)
    |> Enum.find_value(:ok, fn {column, type} ->
      case Store.register_column(table, database, point.measurement, column, type) do
        :ok -> nil
        {:conflict, existing} -> {:error, conflict(dialect, column, point, existing, type)}
      end
    end)
  end

  # The columns a point types, as `{column, kind}`: InfluxDB 3 types tags
  # and fields in one namespace, InfluxDB 2 types fields only.
  @spec point_columns(point_map(), LineProtocolParser.dialect()) :: [{binary(), binary()}]
  defp point_columns(point, dialect) do
    tags =
      if dialect == :v3,
        do:
          Enum.map(point.tags, fn {k, _v} -> {k, LineProtocolParser.column_type(:tag, nil)} end),
        else: []

    tags ++
      Enum.map(point.fields, fn {k, v} -> {k, LineProtocolParser.column_type(:field, v)} end)
  end

  @spec conflict(LineProtocolParser.dialect(), binary(), point_map(), binary(), binary()) ::
          binary() | {binary(), binary(), binary(), binary()}
  defp conflict(:v3, column, _point, existing, type),
    do: "invalid column type for column '#{column}', expected #{existing}, got #{type}"

  defp conflict(:v2, column, point, existing, type) do
    {column, point.measurement, LineProtocolParser.v2_field_type(existing),
     LineProtocolParser.v2_field_type(type)}
  end

  # An unsigned integer is stored as the integer; the marker only served
  # the schema check.
  @spec strip_uint_markers(point_map()) :: point_map()
  defp strip_uint_markers(point) do
    fields =
      Map.new(point.fields, fn
        {k, {:uint, n}} -> {k, n}
        {k, v} -> {k, v}
      end)

    %{point | fields: fields}
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
    with :ok <- require_capability(conn, :query_sql),
         {:ok, database} <- resolve_database(opts, conn) do
      # The engine answers query_sql and execute_sql from the same endpoint:
      # a statement that is not a query gets execute_sql's answer.
      if statement_kind(String.trim(sql)) == :query,
        do:
          Format.answer(query_format(opts), fn -> query_database(table, database, sql, opts) end),
        else: execute_sql(conn, sql, opts)
    end
  end

  @spec query_database(Store.t(), binary(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  defp query_database(table, database, sql, opts) do
    with :ok <- database_exists(table, database), do: run_query(table, database, sql, opts)
  end

  @spec run_query(Store.t(), binary(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  defp run_query(table, database, sql, opts) do
    resolved_sql = SQLParser.resolve_params(sql, Keyword.get(opts, :params, %{}))

    with nil <- SQLParser.unbound_placeholder(resolved_sql),
         {:ok, query} <- SQLParser.parse_select(resolved_sql) do
      case SQLExecutor.run(query, &point_source(table, database, &1)) do
        {:error, _reason} = err -> err
        rows -> {:ok, rows}
      end
    else
      {:error, _reason} = err -> err
      name when is_binary(name) -> {:error, unbound_placeholder_error(name)}
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
        case query_sql(conn, sql, Keyword.delete(opts, :format)) do
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
  @doc \"""
  Executes a SQL statement as InfluxDB 3 does (verified against Core).

    * `SELECT` / `WITH ... SELECT` run as `query_sql/3` and return
      `{:ok, rows}`.
    * `DELETE FROM m [WHERE ...]` on `:v3_enterprise` removes the matching
      points and returns `{:ok, %{"rows_affected" => n}}`. (Not verified:
      no Enterprise server was available.)
    * Everything else is refused with the engine's answer: `DELETE`,
      `INSERT` and `UPDATE` are 400 `Error during planning: DML not
      supported: Delete | Insert Into | Update`; `CREATE TABLE | VIEW |
      DATABASE` and `DROP TABLE | VIEW` are 400 `Error during planning: DDL
      not supported: CreateMemoryTable | CreateView | CreateCatalog |
      DropTable | DropView`; any other statement (`ALTER`, `TRUNCATE`, ...)
      is 405 `This feature is not implemented: Unsupported SQL statement:
      <sql>`.
  """
  @impl true
  @spec execute_sql(InfluxElixir.Client.connection(), binary(), keyword()) ::
          {:ok, map() | [map()]} | {:error, term()}
  def execute_sql(%{table: table, profile: profile} = conn, sql, opts \\ []) do
    with :ok <- require_capability(conn, :execute_sql),
         {:ok, database} <- resolve_database(opts, conn),
         :ok <- database_exists(table, database) do
      trimmed = String.trim(sql)

      case statement_kind(trimmed) do
        :query ->
          query_sql(conn, sql, opts)

        :delete when profile == :v3_enterprise ->
          case Regex.run(~r/^(?i)DELETE\s+FROM\s+((?:[^\s\\]|\\.)+)(.*)$/s, trimmed) do
            [_full, measurement_raw, rest] ->
              execute_delete(table, database, measurement_raw, rest)

            nil ->
              {:error, %{status: 400, body: "Error during planning: DML not supported: Delete"}}
          end

        :delete ->
          {:error, %{status: 400, body: "Error during planning: DML not supported: Delete"}}

        {:planning, message} ->
          {:error, %{status: 400, body: "Error during planning: " <> message}}

        :unsupported ->
          {:error,
           %{
             status: 405,
             body: "This feature is not implemented: Unsupported SQL statement: " <> trimmed
           }}
      end
    end
  end

  # Regexes nested in a list cannot be module attributes on OTP 28, so the
  # table is a function.
  @spec statement_kinds() :: [{Regex.t(), atom() | {:planning, binary()}}]
  defp statement_kinds do
    [
      # Statements the engine answers with rows. The ones the double does
      # not model (EXPLAIN, SHOW TABLES, DESCRIBE) reach its parser and are
      # refused by name there, not reported as unimplemented.
      {~r/^(?i)(?:SELECT|WITH|EXPLAIN|SHOW|DESCRIBE)\b|^\(/, :query},
      {~r/^(?i)DELETE\b/, :delete},
      {~r/^(?i)INSERT\b/, {:planning, "DML not supported: Insert Into"}},
      {~r/^(?i)UPDATE\b/, {:planning, "DML not supported: Update"}},
      {~r/^(?i)CREATE\s+(?:OR\s+REPLACE\s+)?VIEW\b/,
       {:planning, "DDL not supported: CreateView"}},
      {~r/^(?i)CREATE\s+(?:DATABASE|SCHEMA)\b/, {:planning, "DDL not supported: CreateCatalog"}},
      {~r/^(?i)CREATE\s+TABLE\b/, {:planning, "DDL not supported: CreateMemoryTable"}},
      {~r/^(?i)DROP\s+VIEW\b/, {:planning, "DDL not supported: DropView"}},
      {~r/^(?i)DROP\s+TABLE\b/, {:planning, "DDL not supported: DropTable"}}
    ]
  end

  @spec statement_kind(binary()) :: :query | :delete | {:planning, binary()} | :unsupported
  defp statement_kind(sql) do
    Enum.find_value(statement_kinds(), :unsupported, fn {pattern, kind} ->
      if Regex.match?(pattern, sql), do: kind
    end)
  end

  @spec execute_delete(Store.t(), binary(), binary(), binary()) ::
          {:ok, map()} | {:error, term()}
  defp execute_delete(table, database, measurement_raw, rest) do
    measurement = LineProtocolParser.unescape_measurement(measurement_raw)

    with {:ok, where} <- SQLParser.parse_where(rest) do
      count =
        Store.delete_points(table, database, measurement, &SQLExecutor.matches_all?(&1, where))

      {:ok, %{"rows_affected" => count}}
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxQL and Flux queries
  # ---------------------------------------------------------------------------

  @doc """
  Executes an InfluxQL query.

  Answers what InfluxDB 3 answers, verified against the engine:

    * `SHOW DATABASES` — `%{"iox::database" => name, "deleted" => false}`
    * `SHOW MEASUREMENTS` — `%{"iox::measurement" => "measurements", "name" => m}`
    * `SHOW TAG KEYS [FROM m]` — `%{"iox::measurement" => m, "tagKey" => k}`
    * `SHOW FIELD KEYS [FROM m]` — `%{"iox::measurement" => m, "fieldKey" => k,
      "fieldType" => "integer" | "unsigned" | "float" | "string" | "boolean"}`
    * `SELECT ...` — InfluxQL, not SQL: see `InfluxElixir.Client.Local.InfluxQL`
      for the row shape (`iox::measurement` and `time` on every row, time
      order, `mean`/`count`/... aggregates, an unknown column or measurement
      is `{:ok, []}`) and for what is refused by name
  """
  @impl true
  @spec query_influxql(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  def query_influxql(%{table: table} = conn, influxql, opts \\ []) do
    with :ok <- require_capability(conn, :query_influxql) do
      Format.answer(query_format(opts), fn ->
        do_query_influxql(table, conn, String.trim(influxql), opts)
      end)
    end
  end

  # `format:` as `Client.HTTP` sends it; see `Client.Local.Format`.
  @spec query_format(keyword()) :: term()
  defp query_format(opts), do: Keyword.get(opts, :format, :json)

  @show_databases ~r/^(?i)SHOW\s+DATABASES\s*;?$/
  @show_measurements ~r/^(?i)SHOW\s+MEASUREMENTS\s*;?$/
  @show_keys ~r/^(?i)SHOW\s+(TAG|FIELD)\s+KEYS(?:\s+FROM\s+("(?:[^"\\]|\\.)+"|\S+?))?\s*;?$/

  @spec do_query_influxql(Store.t(), map(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  defp do_query_influxql(table, conn, influxql, opts) do
    if String.match?(influxql, @show_databases) do
      {:ok, Enum.map(database_names(table), &%{"iox::database" => &1, "deleted" => false})}
    else
      # The engine parses the statement before it looks for the database.
      with {:ok, statement} <- influxql_statement(influxql),
           {:ok, database} <- influxql_database(opts, conn),
           :ok <- database_exists(table, database) do
        case statement do
          :show_measurements -> {:ok, show_measurements(table, database)}
          {:show_keys, match} -> {:ok, show_keys(table, database, match)}
          {:select, query} -> influxql_select(table, conn, database, query, opts)
        end
      end
    end
  end

  @spec influxql_statement(binary()) ::
          {:ok, :show_measurements | {:show_keys, [binary()]} | {:select, map()}}
          | {:error, term()}
  defp influxql_statement(influxql) do
    cond do
      String.match?(influxql, @show_measurements) -> {:ok, :show_measurements}
      match = Regex.run(@show_keys, influxql) -> {:ok, {:show_keys, match}}
      true -> with {:ok, query} <- influxql_parse(influxql), do: {:ok, {:select, query}}
    end
  end

  # HTTP sends an InfluxQL query without `db` when there is none, and the
  # engine answers this 400 (verified).
  @spec influxql_database(keyword(), conn()) :: {:ok, binary()} | {:error, map()}
  defp influxql_database(opts, conn) do
    case resolve_database(opts, conn) do
      {:ok, _database} = ok ->
        ok

      {:error, :no_database_specified} ->
        {:error,
         %{
           status: 400,
           body: "must specify a 'db' parameter, or provide the database in the InfluxQL query"
         }}
    end
  end

  # The engine lists its own `_internal` database with the others (sorted).
  @spec database_names(Store.t()) :: [binary()]
  defp database_names(table) do
    table |> Store.databases() |> MapSet.put(DatabaseRules.internal()) |> Enum.sort()
  end

  @spec show_measurements(Store.t(), binary()) :: [map()]
  defp show_measurements(table, database) do
    table
    |> Store.measurements(database)
    |> Enum.map(&%{"iox::measurement" => "measurements", "name" => &1})
  end

  # Tag and field keys come from the column schema, in (measurement, key)
  # order.
  @spec show_keys(Store.t(), binary(), [binary()]) :: [map()]
  defp show_keys(table, database, [_full, kind | from]) do
    only =
      case from do
        [m] -> m |> String.trim("\"") |> LineProtocolParser.unescape_measurement()
        [] -> nil
      end

    for {m, column, type} <- Store.columns(table, database),
        only in [nil, m],
        row = key_row(String.upcase(kind), m, column, type),
        row != nil do
      row
    end
  end

  @spec key_row(binary(), term(), binary(), binary()) :: map() | nil
  defp key_row("TAG", m, column, "iox::column_type::tag"),
    do: %{"iox::measurement" => m, "tagKey" => column}

  defp key_row("FIELD", m, column, "iox::column_type::field::" <> _type = kind),
    do: %{
      "iox::measurement" => m,
      "fieldKey" => column,
      "fieldType" => LineProtocolParser.v2_field_type(kind)
    }

  defp key_row(_kind, _m, _column, _type), do: nil

  # The statement's WHERE is evaluated by the SQL engine (the grammar the two
  # share: comparisons, AND/OR/NOT, time literals, now()); InfluxQL then
  # shapes the rows. A measurement or column the engine does not know is an
  # empty InfluxQL result, not an error (verified).
  #
  # The inner query gets typed rows: the caller's `format:` applies once, to
  # the InfluxQL result (it used to render the rows as CSV strings before
  # InfluxQL aggregated them).
  @spec influxql_select(Store.t(), map(), binary(), InfluxQL.query(), keyword()) ::
          InfluxElixir.Client.query_result()
  defp influxql_select(table, conn, database, query, opts) do
    where = if query.where, do: " WHERE " <> query.where, else: ""
    # ORDER BY time sorts on the stored nanoseconds; rows carry microsecond
    # DateTimes, so sorting those alone would tie sub-microsecond points.
    sql = ~s|SELECT * FROM "#{query.measurement}"| <> where <> " ORDER BY time"
    inner_opts = opts |> Keyword.drop([:params, :format]) |> Keyword.put(:database, database)

    case query_sql(conn, sql, inner_opts) do
      {:ok, rows} ->
        tags = Store.tag_columns(table, database, query.measurement)
        {:ok, InfluxQL.run(query, rows, tags)}

      {:error, %{body: "Error during planning: table " <> _rest}} ->
        {:ok, []}

      {:error, %{body: "Schema error: No field named" <> _rest}} ->
        {:ok, []}

      error ->
        error
    end
  end

  @spec influxql_parse(binary()) :: {:ok, InfluxQL.query()} | {:error, map()}
  defp influxql_parse(influxql) do
    case InfluxQL.parse(influxql) do
      {:ok, query} -> {:ok, query}
      {:error, message} -> {:error, %{status: 400, body: "Client.Local: #{message}: #{influxql}"}}
    end
  end

  @doc """
  Executes a Flux query as InfluxDB 2 does; see `InfluxElixir.Client.Local.Flux`
  for the stages supported. Every stage is applied or the query is refused
  (`{:error, %{status: 400, body: json}}` naming it) — a stage is never
  skipped. Rows use the engine's long shape, one per field value:

      %{"result" => "_result", "table" => 0, "_start" => %DateTime{},
        "_stop" => %DateTime{}, "_time" => %DateTime{}, "_measurement" => "cpu",
        "_field" => "value", "_value" => 1.0, "host" => "web01"}

  A bucket that does not exist is the engine's 404.
  """
  @impl true
  @spec query_flux(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  def query_flux(%{table: table} = conn, flux, _opts \\ []) do
    with :ok <- require_capability(conn, :query_flux),
         {:ok, query} <- flux_parse(flux),
         :ok <- flux_bucket_exists(table, query.bucket) do
      case Flux.run(query, Store.points_in_db(table, query.bucket)) do
        {:ok, rows} -> {:ok, rows}
        {:error, message} -> {:error, flux_error(400, "invalid", message)}
      end
    end
  end

  @spec flux_parse(binary()) :: {:ok, Flux.query()} | {:error, map()}
  defp flux_parse(flux) do
    # The clock untimed points are stamped with, plus a nanosecond: `stop`
    # is exclusive and the clock can read the same value for a write and
    # the query right after it, which on a real server never happen at
    # the same instant.
    case Flux.parse(flux, Store.now_ns() + 1) do
      {:ok, query} -> {:ok, query}
      {:error, message} -> {:error, flux_error(400, "invalid", message)}
    end
  end

  @spec flux_bucket_exists(Store.t(), binary()) :: :ok | {:error, map()}
  defp flux_bucket_exists(table, bucket) do
    if Store.bucket?(table, bucket) or Store.database?(table, bucket),
      do: :ok,
      else:
        {:error,
         flux_error(
           404,
           "not found",
           "failed to initialize execute state: could not find bucket \"#{bucket}\""
         )}
  end

  @spec flux_error(pos_integer(), binary(), binary()) :: map()
  defp flux_error(status, code, message),
    do: %{status: status, body: Jason.encode!(%{"code" => code, "message" => message})}

  # ---------------------------------------------------------------------------
  # Database admin
  # ---------------------------------------------------------------------------

  @doc """
  Creates a named database in this local instance.

  Creating an existing database is `:ok` (the engine's 409, which
  `Client.HTTP` treats as success). A name the engine refuses is its 400,
  and a sixth database on the `:v3_core` profile its 422 — see
  `InfluxElixir.Client.Local.DatabaseRules`.
  """
  @impl true
  @spec create_database(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_database(%{table: table} = conn, name, _opts \\ []) do
    with :ok <- require_capability(conn, :create_database),
         :ok <- DatabaseRules.check_new(name, Store.databases(table), conn.profile) do
      Store.put_database(table, name)
      :ok
    end
  end

  @doc """
  Returns the databases as maps with a single `"name"` key, sorted, with
  the engine's own `_internal` among them as InfluxDB 3 lists it.
  """
  @impl true
  @spec list_databases(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_databases(%{table: table} = conn) do
    with :ok <- require_capability(conn, :list_databases) do
      {:ok, Enum.map(database_names(table), &%{"name" => &1})}
    end
  end

  @doc """
  Deletes a database from this local instance.

  Returns `{:error, %{status: 404, body: "the requested resource was not
  found: name"}}` — the engine's answer (verified) — if the database does
  not exist.
  """
  @impl true
  @spec delete_database(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_database(%{table: table} = conn, name) do
    with :ok <- require_capability(conn, :delete_database),
         :ok <- deletable(name) do
      # Dropping a database drops its tables: points and schema go with it,
      # so a re-created database starts empty.
      case Store.drop_database(table, name) do
        :ok -> :ok
        :error -> {:error, %{status: 404, body: "the requested resource was not found: #{name}"}}
      end
    end
  end

  # The engine's answer for its own database (verified).
  @spec deletable(binary()) :: :ok | {:error, map()}
  defp deletable("_internal"), do: {:error, %{status: 500, body: "cannot delete internal db"}}
  defp deletable(_name), do: :ok

  # ---------------------------------------------------------------------------
  # Bucket admin (v2 compat)
  # ---------------------------------------------------------------------------

  @doc """
  Creates a named bucket in this local instance.

  `retention:` is the expiry in seconds (default `0`, none). InfluxDB 2
  refuses a period between 1 and 3599 seconds with a 500 `retention policy
  duration must be at least 1h0m0s` (verified), and so does this.
  Creating an already-existing bucket is idempotent.
  """
  @impl true
  @spec create_bucket(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_bucket(%{table: table} = conn, name, opts \\ []) do
    with :ok <- require_capability(conn, :create_bucket) do
      case Keyword.get(opts, :retention, 0) do
        seconds when seconds in 1..3599 ->
          {:error,
           %{
             status: 500,
             body:
               Jason.encode!(%{
                 "code" => "internal error",
                 "message" => "retention policy duration must be at least 1h0m0s"
               })
           }}

        seconds ->
          Store.put_bucket(table, name, %{retention: seconds})
          :ok
      end
    end
  end

  @doc """
  Returns all buckets in this local instance as maps with `"id"`, `"name"`
  and `"retentionRules"` (`[%{"type" => "expire", "everySeconds" => n}]`,
  the shape InfluxDB 2 lists; verified).
  """
  @impl true
  @spec list_buckets(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_buckets(%{table: table} = conn) do
    with :ok <- require_capability(conn, :list_buckets) do
      bkts =
        table
        |> Store.buckets()
        |> Enum.map(fn {name, %{retention: seconds}} ->
          %{
            "id" => bucket_id(name),
            "name" => name,
            "retentionRules" => [%{"type" => "expire", "everySeconds" => seconds}]
          }
        end)

      {:ok, bkts}
    end
  end

  @doc """
  Deletes a bucket from this local instance.

  Returns `{:error, %{status: 404, body: "bucket not found: name"}}` for a
  bucket that does not exist — InfluxDB 2 answers 404 (verified), which
  `InfluxElixir.Client.HTTP` reports with this body.
  """
  @impl true
  @spec delete_bucket(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_bucket(%{table: table} = conn, name) do
    with :ok <- require_capability(conn, :delete_bucket) do
      case Store.delete_bucket(table, name) do
        :ok -> :ok
        :error -> {:error, %{status: 404, body: "bucket not found: #{name}"}}
      end
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

      Store.put_token(table, id, token)
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
      Store.delete_token(table, token_id)
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
  # Private — storage policy
  # ---------------------------------------------------------------------------

  # v3 Core/Enterprise auto-create databases on write; v2 requires pre-existing
  @spec ensure_database(Store.t(), binary(), profile()) :: :ok | {:error, term()}
  defp ensure_database(table, database, profile) when profile in [:v3_core, :v3_enterprise] do
    with :ok <- DatabaseRules.check_new(database, Store.databases(table), profile) do
      Store.put_database(table, database)
      :ok
    end
  end

  # v2 writes target buckets, so anything registered via `create_bucket/3` is a
  # valid target. Names seeded through `databases:` at start are accepted too,
  # so a v2 connection can be prepared either way.
  defp ensure_database(table, bucket, :v2) do
    cond do
      Store.bucket?(table, bucket) ->
        :ok

      Store.database?(table, bucket) ->
        :ok

      true ->
        # The engine's answer for a bucket that does not exist (verified).
        {:error,
         %{
           status: 404,
           body:
             Jason.encode!(%{
               "code" => "not found",
               "message" => "bucket \"#{bucket}\" not found"
             })
         }}
    end
  end

  # The SQL executor's view of the store: a measurement's points, or
  # `:error` for one that was never written (the engine's "table not
  # found").
  @spec point_source(Store.t(), binary(), binary()) :: {:ok, [point_map()]} | :error
  defp point_source(table, database, measurement) do
    if Store.measurement?(table, database, measurement),
      do: {:ok, Store.points(table, database, measurement)},
      else: :error
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
  # Private — utilities
  # ---------------------------------------------------------------------------

  # The engine's exact wording; a placeholder with no binding is a planning
  # error there, never an empty result.
  @spec unbound_placeholder_error(binary()) :: %{status: 400, body: binary()}
  defp unbound_placeholder_error(name) do
    %{
      status: 400,
      body: "Error during planning: No value found for placeholder with name #{name}"
    }
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
