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
  owns storage, profiles and the InfluxQL and Flux paths; SQL execution is
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
    * `{:column, database, measurement, column}` => the column's kind
      (`iox::column_type::tag` or `iox::column_type::field::<type>`), fixed
      by the first write that names the column

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
      inside a quoted string value is part of the value; an empty payload is
      "incoming write was empty".
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
      param) is never true.
    * `WHERE col IN (v1, v2, ...)` and `WHERE col NOT IN (v1, v2, ...)` — each
      item a literal, a column or an expression, as in SQL (a bare word is
      a column reference, never a string)
    * A constant with an alias in any select list (`0.0 AS volume`,
      `'x' AS label`); an unaliased constant is refused because DataFusion
      names it after its own rendering
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
    * `ORDER BY a [ASC|DESC][, b [ASC|DESC] ...]` — each term `time`, a
      column, an output alias, or (on raw and projected rows) an expression
      such as `CAST(level AS INTEGER) DESC`; every term applies, each with
      its own direction
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

  alias InfluxElixir.Client.Local.{LineProtocolParser, SQLExecutor, SQLParser}

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
         :ok <- ensure_database(table, database, profile) do
      case LineProtocolParser.parse_lines(text, precision, dialect(profile)) do
        {:ok, lines} -> store_lines(table, database, lines, profile)
        # InfluxDB 2 answers 204 to an empty payload; InfluxDB 3 refuses it.
        {:error, _empty} when profile == :v2 -> {:ok, :written}
        {:error, _reason} = error -> error
      end
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
  @spec store_lines(:ets.table(), binary(), [LineProtocolParser.line_result()], profile()) ::
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
                store_point(table, database, strip_uint_markers(point))
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
              store_point(table, database, strip_uint_markers(point))
              errors

            {:error, message} ->
              [LineProtocolParser.line_error(message, number, line) | errors]
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

  # InfluxDB 3 reserves `time` for the timestamp column. The wording
  # depends on whether the table exists (verified): a new table refuses
  # the line outright, an existing one reports a column-type conflict.
  @spec check_schema(:ets.table(), binary(), point_map(), LineProtocolParser.dialect()) ::
          :ok | {:error, binary() | {binary(), binary(), binary(), binary()}}
  defp check_schema(table, database, point, :v3) do
    case reserved_time(table, database, point) do
      :ok -> check_column_types(table, database, point, :v3)
      {:error, _message} = error -> error
    end
  end

  defp check_schema(table, database, point, :v2),
    do: check_column_types(table, database, point, :v2)

  @spec reserved_time(:ets.table(), binary(), point_map()) :: :ok | {:error, binary()}
  defp reserved_time(table, database, %{tags: tags, fields: fields} = point) do
    cond do
      Map.has_key?(tags, "time") ->
        reserved_time_error(table, database, point.measurement, "iox::column_type::tag")

      Map.has_key?(fields, "time") ->
        got = LineProtocolParser.column_type(:field, Map.fetch!(fields, "time"))
        reserved_time_error(table, database, point.measurement, got)

      true ->
        :ok
    end
  end

  @spec reserved_time_error(:ets.table(), binary(), binary(), binary()) :: {:error, binary()}
  defp reserved_time_error(table, database, measurement, got) do
    case :ets.match(table, {{:column, database, measurement, :_}, :_}, 1) do
      :"$end_of_table" ->
        {:error, "'time' is a reserved column"}

      _existing_columns ->
        {:error,
         "invalid column type for column 'time', expected iox::column_type::timestamp, got " <>
           got}
    end
  end

  # The measurement's schema, one ETS object per column so the first writer
  # of a column fixes its kind atomically (`insert_new`) and a concurrent
  # writer never loses a column. InfluxDB 3 types tags and fields in one
  # namespace and reports a conflict with its column-type wording; InfluxDB
  # 2 types fields only and reports `{field, measurement, existing, got}`.
  @spec check_column_types(:ets.table(), binary(), point_map(), LineProtocolParser.dialect()) ::
          :ok | {:error, binary() | {binary(), binary(), binary(), binary()}}
  defp check_column_types(table, database, point, dialect) do
    tags = if dialect == :v3, do: Enum.map(point.tags, fn {k, _v} -> {k, :tag, nil} end), else: []
    columns = tags ++ Enum.map(point.fields, fn {k, v} -> {k, :field, v} end)

    Enum.find_value(columns, :ok, fn {column, kind, value} ->
      type = LineProtocolParser.column_type(kind, value)
      key = {:column, database, point.measurement, column}

      if :ets.insert_new(table, {key, type}) do
        nil
      else
        [{^key, existing}] = :ets.lookup(table, key)

        if existing == type,
          do: nil,
          else: {:error, conflict(dialect, column, point, existing, type)}
      end
    end)
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
    with :ok <- require_capability(conn, :query_sql) do
      params = Keyword.get(opts, :params, %{})
      database = resolve_database(opts, conn)
      resolved_sql = SQLParser.resolve_params(sql, params)

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
            "_time" => SQLExecutor.nanoseconds_to_datetime(point.timestamp),
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
        # Dropping a database drops its tables: the points and the column
        # schema go with it, so a re-created database starts empty.
        :ets.match_delete(table, {{:point, name, :_, :_}, :_})
        :ets.match_delete(table, {{:column, name, :_, :_}, :_})
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

  # The SQL executor's view of the store: a measurement's points, or
  # `:error` for one that was never written (the engine's "table not
  # found").
  @spec point_source(:ets.table(), binary(), binary()) :: {:ok, [point_map()]} | :error
  defp point_source(table, database, measurement) do
    if measurement_exists?(table, database, measurement),
      do: {:ok, fetch_points(table, database, measurement)},
      else: :error
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

  # The engine's exact wording; a placeholder with no binding is a planning
  # error there, never an empty result.
  @spec unbound_placeholder_error(binary()) :: %{status: 400, body: binary()}
  defp unbound_placeholder_error(name) do
    %{
      status: 400,
      body: "Error during planning: No value found for placeholder with name #{name}"
    }
  end

  @spec delete_points(:ets.table(), binary(), binary(), [SQLParser.where_node()]) ::
          non_neg_integer()
  # Each matching point is deleted by its own key, so a concurrent write to
  # the same measurement is never lost to a rewrite of the whole list.
  defp delete_points(table, database, measurement, where) do
    table
    |> :ets.select([{{{:point, database, measurement, :_}, :_}, [], [:"$_"]}])
    |> Enum.filter(fn {_key, point} ->
      SQLExecutor.matches_all?(point, where)
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
