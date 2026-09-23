# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- `Connection.get/1` reads `:persistent_term` with a default instead of
  rescuing `ArgumentError`.
- `Writer` tests assert what a write does — every point of a gzipped
  payload is stored, `precision:` changes the stored time, `:client`
  selects the client — instead of `{:ok, :written}` alone.
- `ResponseParser` tests every string cell for InfluxDB 3's zone-less
  timestamp shape before deciding whether to decode it; a one-clause binary
  pattern now screens out strings that cannot match before the regex runs
  (about 14 ns instead of 340 ns per ordinary string cell). Results are
  unchanged.
- `BatchWriter` tests cover a chain that exhausts more than one retry
  (errors are counted per chain, not per attempt) and `max_retries: 0`
  against a transport error.
- **SQL execution split out of `Client.Local`.** The 900-line executor —
  CTEs, joins, the `WHERE` evaluator, aggregates, casts, ordering, schema
  checks — is `InfluxElixir.Client.Local.SQLExecutor`, pure over the points
  it is handed through a fetch function; `Client.Local` keeps storage,
  profiles and the InfluxQL and Flux paths. Public behaviour is unchanged.
- `Client.Local` checks a query's column references against the first
  row before scanning every row's columns; the scan now runs only when a
  name is missing there, which is also when the error message needs the
  full list. Per-query fixed cost at 10k points drops from about 20 ms to
  under 5 ms; results are unchanged.
- **`Client.Local.SQLParser` cuts a SELECT into its parts in one place.**
  Eight regexes each found "the table after FROM" for their own dispatcher
  (star, column list, aggregate, DISTINCT, the clause check, the alias
  stripper, two helpers); `split_select/1` now does it once and the
  dispatchers work from its parts. No behaviour change; 71 lines fewer.
- `BatchWriter` tests no longer inspect GenServer state to check that
  configuration was stored; scheduling and jitter are asserted through the
  observable flush instead.
- **`Client.Local` split into three modules.** The 2,470-line module now owns
  storage, capability checks and query execution (1,450 lines); the SQL parser
  is `InfluxElixir.Client.Local.SQLParser` and the line-protocol parser is
  `InfluxElixir.Client.Local.LineProtocolParser`, both pure. Public behaviour
  is unchanged; the contract suites prove it.
- `Client.Local.query_influxql/3` matches each `SHOW` pattern once.
- Removed the unused internal `InfluxElixir.InfluxCase` case template from
  `test/support/` (never shipped; no test used it).
- `Client.Local`'s line-protocol splitters accumulate tokens in binaries
  (runtime-optimised append) instead of one list cell per byte plus a
  reverse and join, cutting allocations on every write to the double.

### Fixed
- **`Client.Local` kept duplicate points as separate rows.** InfluxDB 3
  and 2.7 both treat a measurement's points with the same tag set and
  timestamp as one point — fields merge, the later write wins per field,
  the last of two such lines in a payload wins (verified) — and the double
  returned one row per write, so a fixture that rewrote a point saw two
  rows and doubled its aggregates. Points are still stored as written, one
  ETS insert each, and are merged on every read; `DELETE` removes the
  merged point and counts it once.
- **`Client.Local` crashed on precision spellings the engine accepts.**
  `HTTP.write/3` passes `precision:` to InfluxDB 3 verbatim, which takes
  `ns | n | nanosecond | us | u | microsecond | ms | millisecond | s |
  second | auto` (verified), and maps the long names onto InfluxDB 2's
  `ns | us | ms | s`. The double accepted only the four long atoms and
  raised `FunctionClauseError` on `:ms`, `"ms"`, `"nanosecond"` or
  `:auto`, so a write that works in production crashed in tests. It now
  accepts what each profile's server accepts, implements `auto` at the
  engine's thresholds (|ts| below 5e9 seconds, 5e12 milliseconds, 5e15
  microseconds, else nanoseconds; verified), and answers an unknown
  precision with the server's 400 body (`serde error: unknown variant …`
  on v3, `invalid precision; valid precision units are ns, us, ms, and s`
  on v2).
- **`ConnectionSupervisor` started a Finch pool the connection never used.**
  With `:finch_name` pointing at an existing pool, a second idle pool was
  still started per connection, and the batch writer restarted with it
  under `rest_for_one`. No per-connection pool is started when
  `:finch_name` is set.
- `Connection.fetch!/1` raised `:persistent_term`'s bare `ArgumentError`
  for an unknown name; it now names the missing connection and says how
  to register one.
- The manual telemetry emitters `write_stop/2`, `write_exception/2`,
  `query_stop/2` and `query_exception/2` emitted `%{duration}` only, while
  the spans (and the documented events) carry `monotonic_time` too. They
  now emit the same measurements. `write_stop/2`'s docs mentioned a
  `compressed_bytes` metadata key that nothing emits (removed from the
  event docs on 2026-09-11); the leftover is gone.
- **`LineProtocol.encode/1` emitted lines no server accepts.** An empty tag
  value (`host=`), an empty tag key or field key, the reserved tag key
  `time`, and a newline in a measurement, tag key, tag value or field key
  all encoded without complaint and failed at the server — and a newline
  splits the line, so `tags: %{"host" => "a\nb"}` stored a bogus
  measurement `b` on InfluxDB 3 (verified). A non-string tag value or an
  unsupported field value (`nil`, an atom) crashed the encoder with a
  `FunctionClauseError`. Each is now a tagged error from `encode/1`
  (`{:invalid_tag_value, key, value}`, `{:reserved_tag_key, "time"}`,
  `{:invalid_field_value, key, value}`, …); see "Validation" in the
  moduledoc.
- **`Client.Local` worded a `time` field on a new table as a column-type
  conflict.** InfluxDB 3 says `'time' is a reserved column` for a tag or a
  field on a table that does not exist yet, and reports the column-type
  conflict with `iox::column_type::timestamp` only on an existing table.
  The double now does the same (the check moved from the parser into the
  store, which knows whether the table exists).
- **`Client.Local`'s `:v2` profile applied InfluxDB 3's write rules.**
  Verified against InfluxDB 2.7, which differs on nearly every point: a
  field type conflict is HTTP 422 (`"unprocessable entity"`, message ending
  in `dropped=N`) with the other lines stored; a line that fails to parse
  rejects the whole payload with HTTP 400 (`"code":"invalid"`, `unable to
  parse '<line>': ...`) and nothing is stored; `time` as a field is dropped
  silently and as a tag is a 400; a tag and a field may share a name; an
  empty payload is accepted. The double now applies those rules under
  `:v2` and InfluxDB 3's under `:v3_core` / `:v3_enterprise`.
- **`Client.Local` refused `LIMIT n OFFSET m`, which InfluxDB 3 runs (#21).**
  Verified against the engine: `OFFSET` skips rows before `LIMIT` takes
  them, in either order, on plain, projected, grouped and `DISTINCT` rows;
  `OFFSET 0` is a no-op, an offset past the end is an empty result, a
  negative offset is "OFFSET must be >=0" and a bare word is a schema
  error. All of that is now mirrored, so a paginated read can be tested
  against the double instead of re-implementing the offset in Elixir.
- **`Client.Local` accepted writes InfluxDB 3 rejects, and rejected one it
  accepts.** Verified against the engine: a field written as an integer and
  later as a float (or tag then field, string then float, boolean then
  integer) is refused line by line with "invalid column type for column
  'v', expected iox::column_type::field::integer, got
  iox::column_type::field::float"; `time` as a tag or field, a key used as
  both tag and field on one line, an integer outside int64 and an empty
  payload are refused; a rejected line drops only itself — the other lines
  are stored and the response is the partial-write JSON with one entry per
  bad line. The double accepted all of those (and stored every line), and
  refused a newline inside a quoted string value, which the engine keeps.
  It now keeps a per-measurement column schema (`{:column, database,
  measurement, column}`, fixed atomically by the first writer), applies a
  payload line by line, returns the engine's body, and drops the schema
  with the data when the database is deleted. Unsigned integers (`7u`) are
  accepted.
- **`Client.Local.delete_database/2` kept the deleted database's points**,
  so a re-created database was not empty. The points and schema go with it.
- **`Client.Local` read a bare word inside `IN (...)` as a string.**
  `host IN (a, b)` compared against `"a"` and `"b"`; on the engine the
  items are column references (`v IN (1, other)` works, `host IN (a, b)`
  is a schema error). Items are now parsed like every other comparand.
- **`Client.Local` refused a constant in a select list.** `0.0 AS volume`
  (the #17 candle query's placeholder volume) was "unsupported column
  expression" in an aggregate and a schema error in a projection; the
  engine returns the constant on every row. Supported with an alias in
  every query shape; an unaliased constant is refused with the reason.
- **`DELETE ... WHERE a OR b` crashed `Client.Local`** (`:v3_enterprise`)
  with a `FunctionClauseError`: the delete path still folded predicates
  with the helper from before `WHERE` became a boolean expression. It now
  evaluates the same expression tree `SELECT` does.
- **`CAST(col AS INTEGER)` in `WHERE` was rejected by 0.1.24 (#20) — and
  silently matched nothing in 0.1.23.** The report is right that 0.1.24
  refuses the orderbook depth query with `Client.Local: unsupported WHERE
  clause: CAST(level AS INTEGER)`. It was never a working query on the
  double: 0.1.23 read `CAST(level AS INTEGER)` as a column named that and
  returned no rows for it, so tests passing against 0.1.23 were passing on
  an empty result. `CAST` (and DataFusion's `col::TYPE` shorthand) now works
  wherever an expression is allowed — `WHERE`, `BETWEEN`, `LIKE`, projections,
  aggregates, arithmetic and `ORDER BY` — with the engine's semantics,
  verified against InfluxDB 3 Core: `INTEGER` / `INT` / `BIGINT`, `DOUBLE` /
  `FLOAT`, `VARCHAR` / `STRING` / `TEXT`; text converts only when the whole
  string is a number, a float truncates to an integer, a number renders to
  text. A cast that cannot be performed (`'abc'` to `INTEGER`, `time` to
  `INTEGER`) makes InfluxDB 3 Core drop the connection mid-response, which
  `Client.HTTP` reports as `{:error, {:connection_error, %Mint.TransportError{
  reason: :closed}}}`; the double reports `{:error, {:connection_error,
  :closed}}`.
- **`ORDER BY` ignored every term after the first in `Client.Local`.**
  `ORDER BY symbol DESC, level` sorted by `symbol` only. All terms apply,
  each with its own direction, and a term may be an expression
  (`ORDER BY CAST(level AS INTEGER) DESC`) on raw and projected rows.
- **`Client.Local` ignored `GROUP BY` on a plain projection and `ORDER BY`
  on column-grouped aggregates, and sampled a row for an ungrouped
  column.** `SELECT host FROM p GROUP BY host` returned every row; `SELECT
  host, SUM(v) AS t FROM p GROUP BY host ORDER BY t DESC` came back in map
  order; `SELECT host, MAX(v) FROM p` (no `GROUP BY`) picked the first
  row's host. The engine returns one row per group, honours the ordering,
  and fails planning for the ungrouped column ("must appear in the GROUP BY
  clause or must be part of an aggregate function"); the double now does
  all three.
- **`Client.Local` answered queries that name a column no row has.**
  `SELECT nosuch`, `MAX(nosuch)`, `WHERE nosuch = 1`, `GROUP BY nosuch`,
  `ORDER BY nosuch` and `DISTINCT nosuch` are all the same 500 schema error
  on InfluxDB 3 ("No field named nosuch"); the double returned rows without
  the column, no rows, or unsorted rows depending on the clause. Every
  column reference in a query is now checked against the rows' columns
  (the check added for `WHERE` expressions in 0.1.24 generalised), and an
  output alias remains a valid `ORDER BY` target.
- **An unbound `$placeholder` matched nothing in `Client.Local`**; the
  engine fails planning ("No value found for placeholder with name $host").
  The double now returns that error, so a missing binding cannot pass a
  test as an empty result.
- **`Client.Local` refused `median()` and `CROSS JOIN`, which InfluxDB 3
  runs (#19).** Verified against InfluxDB 3 Core: `median` returns the
  middle value, or for an even count the mean of the two middle values in
  the column's type (two integers average with integer division: the median
  of 1 and 4 is 2), null over no rows, and is rejected over `time`;
  `FROM w CROSS JOIN ref` pairs every row with every row of `ref`. Both are
  supported, so the median-screened candle query in the issue now runs on
  the double with the same rows as the server. A column present on both
  sides of the join is refused as ambiguous, as the engine refuses the
  unqualified reference.
- **`Client.Local` compared a bare word in `WHERE` as a string.**
  `price <= med * 3` compared `price` with the text `"med * 3"` and
  `host = prod` with `"prod"` — both silently wrong. Either side of a
  comparison may now be an arithmetic expression over columns, a bare word
  is a column reference, and a column no row has is the engine's schema
  error ("No field named prod"), which is what production returns for a
  forgotten pair of quotes.
- A `nil` param rendered as the word `nil` in `Client.Local`; it now renders
  as `NULL`, which never matches, as the JSON `null` Jason sends over HTTP
  never matches.
- **`Client.Local` returned wrong rows for `OR`, `NOT`, parentheses and
  `<>` in `WHERE`, and for `LIMIT 0`.** The clause splitter only knew `AND`:
  `v > 3 OR v < 2` was read as one predicate against the string
  `"3 OR v < 2"`, `NOT host = 'a'` and `v <> 1.0` matched nothing, and
  `LIMIT 0` returned every row where the engine returns none. `WHERE` is now
  parsed as a boolean expression — `AND` binding tighter than `OR`, `NOT`,
  parentheses, string literals opaque — and `<>`, `[NOT] BETWEEN ... AND
  ...` (including `time`) and `[NOT] LIKE` / `ILIKE` are supported with the
  engine's semantics (`LIKE` case-sensitive, `_` one character, `LIKE` over a
  numeric column reproduces the engine's planning error). `LIMIT 0` returns
  no rows; a negative or non-numeric `LIMIT` is rejected as the engine
  rejects it. A malformed expression is rejected, never truncated.
- **`Client.Local` compared a string tag against a bare number by Erlang
  term order**, so `rack > 3` matched every tag. The engine keeps the column
  as text and renders the literal (`rack = 2` matches `"2"`; `rack > 3`
  does not match `"10"`); the double now does the same.
- **`Flight.Reader` walked empty FlatBuffer vectors at bogus indices.**
  `for i <- 0..(count - 1)` with `count == 0` is the descending range
  `[0, -1]` in Elixir, so a schema with no fields or a record batch with an
  empty buffers vector was read twice at invalid positions instead of not
  at all. The ranges now carry an explicit `//1` step, as the other
  comprehensions in the module already did.
- **`Client.Local` refused projected arithmetic and CTEs InfluxDB 3 runs
  (#18).** Verified against InfluxDB 3 Core: `SELECT (bid + ask) / 2 AS mid,
  time FROM q` and `WITH w AS (SELECT bid, time FROM q) SELECT
  DATE_BIN(INTERVAL '1 minute', w.time) AS time, MAX(w.bid) AS hi FROM w
  GROUP BY DATE_BIN(INTERVAL '1 minute', w.time)` both return rows on the
  server and were `Client.Local:` 400s. The double now supports an arithmetic
  expression as a projected column (with an alias; `ORDER BY` may name it),
  non-recursive `WITH` CTEs executed in order (a later CTE or the final
  `SELECT` reads an earlier one), table aliases (`FROM q AS w`, `FROM q w`)
  and `alias.column` qualifiers in every clause.
- **`Client.Local` silently ignored everything after the table name.**
  `SELECT * FROM w CROSS JOIN q` answered from `w` alone, `... UNION SELECT
  ...` took `UNION` as a table alias, and `WHERE x IN (SELECT ...)` compared
  against the string `"SELECT ..."`. Joins, set operations, subqueries,
  `HAVING`, `OFFSET` and window functions are now rejected by name
  (`Client.Local: unsupported SQL construct JOIN`). Keywords are matched
  by the shape only a clause can have (`OFFSET 1`, `OVER (`) and string
  literals are ignored, so a column named `offset` or `over` and a value
  such as `'select from join'` — both fine on the engine — still work.
- `Client.Local` returned `"time" => nil` for a row without a timestamp (a
  CTE that did not project `time`); the column is omitted, as everywhere
  else.
- **`Client.Local` accepted `time` comparands InfluxDB rejects, and silently
  matched nothing for ones it accepts.** Verified against InfluxDB 3 Core:
  a bare integer (`time > 1700000000`) or integer param fails planning on
  the server ("Cannot infer common argument type for comparison operation
  Timestamp(ns) > Int64") and an unparseable string fails execution, while
  the double returned `{:ok, []}` for both; `now() - INTERVAL '2 minutes'`
  runs on the server but was compared as the literal string, so it too
  returned `{:ok, []}`. The parser now accepts exactly the engine's forms —
  quoted ISO-8601 datetimes (zoned, zone-less, fractional), quoted dates,
  `now()` offset by `INTERVAL` terms, evaluated at query time — and rejects
  the rest with a `Client.Local:` 400 that names the engine's rule.
- **`DateTime` params rendered as `~U[...]` in `Client.Local`.** Jason sends
  them as ISO-8601 strings over HTTP; the double now renders `DateTime`,
  `NaiveDateTime` and `Date` params the same way.
- **`SELECT DISTINCT ... ORDER BY` was ignored by `Client.Local`**: rows came
  back ascending whatever the direction. `ORDER BY` on a selected column is
  honoured; on any other column it is rejected with DataFusion's own
  message.
- **`MAX(time)` / `MIN(time)` returned an empty row from `Client.Local`**
  (the timestamp is not a field, so the aggregate saw only nulls). They now
  return the `DateTime`, as the engine does; `AVG(time)`, `SUM(time)`, the
  statistics over `time` and arithmetic on `time` are rejected as DataFusion
  rejects them.
- **`Client.Local` refused `COUNT(DISTINCT col)` and `WHERE col IS [NOT]
  NULL`**, both ordinary SQL the engine runs. Both are supported.
- **HTTP JSON left aliased timestamp columns as strings** — see the entry
  above for #16/#17; this sweep's contract tests cover `MAX(time)` too.
- **`BatchWriter` documented a backpressure it could never apply.** The
  buffer emptied on every flush, so `{:error, :buffer_full}` was
  unreachable and the tests that "proved" it forged the GenServer state.
  Automatic flushes now wait for an in-flight retry chain instead of
  opening a new chain per batch against a failing server, the buffer is
  bounded at `10 * batch_size` while a chain is in flight, and the deferred
  buffer is flushed when the chain ends. A `write_sync/3` caller is answered
  by its own chain's result (the caller's reference travels with the chain;
  before, a later chain could answer it).
- `BatchWriter` tests no longer inject `:retry` messages or read GenServer
  state: retries are exercised through a closed port (unit) and through a
  Finch pool checkout timeout that resolves before the backoff fires
  (integration, against the real server).
- **`Client.Local` rejected valid InfluxDB 3 SQL (#16, #17).** Verified
  against InfluxDB 3 Core: `STDDEV` / `STDDEV_SAMP` / `STDDEV_POP` /
  `VAR` / `VAR_SAMP` / `VAR_POP`, arithmetic inside an aggregate
  (`SUM(value * value)`, `AVG(bid + ask)`, integer operands dividing as
  integers), `selector_first|last|min|max(field, time)['value' | 'time']`,
  `SELECT DISTINCT a, b`, and `ORDER BY` a projected alias (`ORDER BY bucket
  DESC`) all work on the server and were all `Client.Local:` 400s in the
  double. All are now supported with the values the engine returns; `VARIANCE`
  stays rejected because DataFusion has no such function.
- **`Client.Local` returned `nil` columns the real engine omits.** InfluxDB 3
  leaves a null column out of the JSON row entirely (an empty group carries
  only `COUNT: 0`; a sample statistic over one row has no key). The double now
  omits them too, so `refute Map.has_key?(row, "avg")` means the same thing
  on both.
- **HTTP JSON responses left timestamp columns other than `time` as strings.**
  A `DATE_BIN(...) AS bucket` alias or `selector_*(...)['time']` came back as
  `"2023-11-14T22:12:00"` over HTTP but as a `DateTime` over Flight and from
  `Client.Local`. `Query.ResponseParser` now decodes InfluxDB 3's zone-less
  timestamp rendering under any column name (zoned RFC3339 strings are still
  decoded only under `time` / `_time` / `_start` / `_stop`).
- `mix docs` warned that the README's `LICENSE` link had no target; the
  licence is now an ExDoc extra.

### Added
- `InfluxElixir.Client.Local.check_sql/1` — parse a query without running it
  and get the same `Client.Local:` error `query_sql/3` would, so a test can
  `flunk/1` with the reason instead of being silently excluded.
- Testing guide: "Checking a Query Before Running It" and "Running Against a
  Real InfluxDB" (the integration tier, `INFLUX_V3_CORE_HOST` / `_PORT`,
  Docker one-liners), and the new aggregate, selector and null-omission
  semantics with the values recorded from the engine.
- `CLAUDE.md` described a `/docs` layout (`architecture/`, `api/`,
  `development/`, per-directory READMEs, a design template) that did not exist.
  The READMEs and template now exist, `docs/design/README.md` indexes every
  design document and carries the real-engine Docker one-liners, and
  `CLAUDE.md` describes the actual layout.
- **The shipped usage rules made false claims.** They told consumers to
  start a Finch pool themselves (the supervisor starts one per connection),
  that booleans encode as `t`/`f` (they are `true`/`false`), to pass params as
  a keyword list (a map), and that write errors carry `:retryable` /
  `:non_retryable` atoms (no such atoms exist; errors are `%{status, body}` or
  `{:connection_error, reason}`). All three rule files rewritten against the
  current code.
- **`Client.HTTP` raised on keyword-list `params:`.** Jason cannot encode the
  tuples, so `params: [tag: "v"]` crashed the HTTP client while `Client.Local`
  accepted it — exactly the shape the old usage rules recommended. Both clients
  now accept a map or a keyword list; the contract suite proves it against the
  real engine.
- **`Client.Local` lost concurrent writes to the same database** (#15). Points
  were stored as one list per measurement and every write read the list,
  prepended and wrote it back, so parallel writers overwrote each other's
  inserts while all reported `{:ok, :written}` (159 of 480 survived in the
  report). The ETS layout is now one object per point, database, bucket and
  token, so every mutation is a single atomic insert or delete. The same
  change removes the quadratic copy on bulk writes: 20,000 lines took 63 s
  and now take well under a second. Points scan in insertion order.
- The testing guide's "Key Differences" still listed `first`/`last` as
  supported aggregates and omitted `DISTINCT`, `GROUP BY <columns>`,
  `COUNT(*)` and `$param` substitution; corrected to the current parser.
- **README usage example could not work.** It placed `{InfluxElixir, ...}` in
  a supervision tree (the facade has no `child_spec/1`; the library is an OTP
  application configured via `config :influx_elixir, :connections`), put a
  scheme in `host:` and used the nonexistent `default_database:` key, which
  HTTP config validation now rejects at startup. Rewritten with a working
  configuration, a write/query example, the v2 options and the shipped test
  helper.
- **`InfluxElixir.TestHelper` now ships in the package.** It was documented
  (CLAUDE.md, usage rules, the original design) as a helper for consuming
  applications' test suites, but lived under `test/support/`, which is only
  compiled in this repository's test environment — no consumer ever received
  it. It is now under `lib/`. The usage rules also named a nonexistent
  `setup_local/1`; the function is `setup_influx/1`, which passes its options
  straight to `Client.Local.start/1`. Covered by its own test module.
- `InfluxElixir.Admin.Health` documented an atom-keyed `%{status: "pass"}`
  result; both clients return string keys (`%{"status" => "pass"}`), as the
  2026-03-13 integration plan already required.

## [0.1.21] - 2026-09-11

### Added
- **Telemetry is actually emitted.** `InfluxElixir.Telemetry` documented
  `[:influx_elixir, :write | :query, ...]` events, but nothing in the library
  called it. `Write.Writer.write/3` (hence `InfluxElixir.write/3` and every
  `BatchWriter` flush) now emits the write span with `database`, `bytes` and
  `point_count`; `InfluxElixir.query_sql/3`, `execute_sql/3`, `query_influxql/3`
  and `query_flux/3` emit the query span with `database`, `transport` (the client
  module) and, for list results, `row_count`. `:stop` metadata carries
  `result: :ok | :error`.
- `BatchWriter` and `Write.Writer` accept a `:client` option to write with a
  specific client module instead of the configured one.
- `InfluxElixir.Config` knows `:timeout`, `:batch_writer` and `:finch_name`.

### Fixed
- **`Client.HTTP` never set Finch's `pool_timeout`** (#14), so every request
  waited at most Finch's default 5 s to check a connection out of the pool no
  matter how generous `:timeout` was, and against a slow multi-node endpoint
  failed with a transport `:timeout` at five seconds. A `:pool_timeout` option
  now resolves like `:timeout` (per-call opt → connection → 5_000) and is passed
  on every request, including the streaming query. Verified against InfluxDB 3
  Core with a size-1 pool held by a sleeping stream — which also showed that
  Finch **raises** on a checkout timeout rather than returning an error, so the
  exception used to escape `query_sql/3`. It is now
  `{:error, {:connection_error, :pool_timeout}}`, and the streaming query
  raises `InfluxElixir.StreamError` with `reason: :pool_timeout`.
- **Flight and HTTP now return the same `time` values.** `Flight.Reader`
  decoded Timestamp columns to raw integers while the HTTP path yields
  `DateTime`; the reader now reads the Arrow `TimeUnit` and converts.
  `Query.ResponseParser` also treated InfluxDB 3's zone-less JSON timestamps
  (`"2023-11-14T22:13:20.123456789"`) as opaque strings because
  `DateTime.from_iso8601/1` rejects them; they are now parsed as UTC. Verified
  against InfluxDB 3 Core: identical rows on both transports.
- **`transport: :flight` was documented but ignored** by the facade,
  `Query.SQL` and the usage rules; every query went over HTTP.
  `Client.HTTP.query_sql/3` now dispatches to `Flight.Client` when
  `transport: :flight` is given, using the connection's host/token, the resolved
  database, and `flight_port` (opt, connection, or 443). `params:` are rejected
  over Flight instead of being dropped. Verified against InfluxDB 3 Core's
  Flight endpoint.
- **`BatchWriter` retried 4xx responses.** The discard clause matched
  `{:error, {:http_error, status}}`, a shape no client produces, so a rejected
  batch (bad line protocol, unknown database) was retried with backoff until
  `max_retries` ran out. It now matches the clients' `%{status: 4xx}` and drops
  the batch on the first response. The retry path is covered by a real
  transport error against a closed port.
- **`ConnectionSupervisor` handed the batch writer the raw config instead of
  the initialised connection**, so a `batch_writer:` under `Client.Local`
  crashed on its first flush. Covered by a supervisor-level test.
- **`ConnectionSupervisor` validates HTTP connection config.** A typo such as
  `default_database:` (which the facade and application docs themselves used)
  was silently ignored; with `Client.HTTP` it now fails at startup with a
  `NimbleOptions.ValidationError`. `Client.Local` configs are not validated.

### Changed
- **`time` is a `DateTime` on every client and transport.** `Client.Local`
  returned `time` and `DATE_BIN` buckets as ISO 8601 strings, while the HTTP
  path (once its zone-less parsing was fixed, see below) and Flight return
  `DateTime`. All three now return `DateTime` with microsecond precision, so
  the contract suite asserts one instant across Local, HTTP and Flight. Code
  that compared Local's `time` to a string must use a `DateTime` (six-digit
  sigil or `DateTime.compare/2`).
- `InfluxElixir.write/3` goes through `Write.Writer`, so payloads over 1 KB
  are gzipped like `BatchWriter` flushes already were.
- `Flight.Reader` decodes fixed-width columns with binary comprehensions
  (one pass, no per-element slicing) instead of indexed `binary_part/3`.
- **`Client.Local.query_flux/3` returns the long row shape real Flux returns**:
  one row per field with `_field`/`_value`, `_measurement`, `_time` (a
  `DateTime`), the tags, `result` and a per-series `table` index, ordered by
  table then time. `filter(fn: (r) => r._field == "...")` is honoured. The old
  wide rows (`%{"_measurement", "<field>" => v, "time"}`) could not exercise
  consumer Flux handling; verified against InfluxDB 2.7.
- **`Client.HTTP.query_flux/3` requests `#datatype` annotations** so CSV cells
  come back typed (`double`, `long`, `unsignedLong`, `boolean`, RFC3339 →
  `DateTime`) instead of as strings.
- `Query.ResponseParser.coerce_types/1` also converts `_time`, `_start` and
  `_stop`. `parse/2` returns `{:error, {:unexpected_json, term}}` for a JSON
  scalar body instead of raising `CaseClauseError`.

### Added
- `api_version: :v2 | :v3` connection option (`InfluxElixir.Config`). Required
  for InfluxDB 2.x: a v2 server answers `200` to the v3 write path **without
  storing anything**, so writes silently vanished and malformed line protocol
  or an unknown bucket reported success. With `:v2` the client uses
  `POST /api/v2/write?org=&bucket=&precision=ns|us|ms|s`.

### Fixed
- **`Client.HTTP.create_bucket/3` works against real InfluxDB v2.** It sent
  `"orgID": ""`, which v2 rejects (`id must have a length of 16 bytes`). The org
  ID is now resolved from the connection's `:org` name (`org_id:` overrides).
  Creating a bucket that already exists is treated as success, matching
  `Client.Local`.
- **`Client.HTTP.delete_bucket/2` accepts a bucket name.** v2 deletes by ID;
  the name is resolved via `GET /api/v2/buckets?name=`, so the same call works
  against `Client.Local`. A 16-hex argument is used as an ID directly.
- **Flux CSV parsing uses NimbleCSV.** The hand-rolled splitter left `\r` on
  every last cell and header, turned the blank line between tables into a row
  and the next table's header into data, and broke quoted cells containing
  commas. All were observed against InfluxDB 2.7.
- **`LineProtocol` floats no longer lose precision.** `{:decimals, 17}`
  formatting wrote `1.0e-20` as `0.0`; the shortest round-trip form is used
  (`1.0e-20`, `2.5e-7`), which InfluxDB 3 Core accepts and reads back exactly.
- **`Telemetry.write_start/1` and `query_start/1` emit wall-clock
  `system_time`.** They emitted `System.monotonic_time/0` under that key, an
  arbitrary offset that is useless as a timestamp. A `monotonic_time`
  measurement is emitted alongside, matching `:telemetry.span/3`.
- **`Flight.Client.query/3` closes the gRPC channel when `DoGet` fails**; it
  was only disconnected on success.
- **`Client.Local.stop/1` no longer races the owner process's ETS cleanup.**
  Called from an `on_exit` after the test process had exited, the
  `:ets.info/1` guard could pass and `:ets.delete/1` then raise
  `ArgumentError`, failing the test intermittently.
- **`Flight.Reader` row assembly is linear in the batch's row count.** Cells
  were read with `Enum.at/2` on the column lists for every row, which made
  decoding a record batch quadratic; columns are now tuples read with `elem/2`.

### Changed
- `Client.HTTP` routes every request through one `request/7` helper that maps
  the status to `{:ok, response}` / `{:error, %{status, body}}` /
  `{:error, {:connection_error, reason}}`, replacing fourteen copies of the same
  three-clause `case`. No behavioural change.

## [0.1.20] - 2026-09-10

### Changed
- **`Client.Local` ordered aggregates now use the InfluxDB v3 SQL spelling**
  (#13). `first_value(field ORDER BY col [ASC|DESC])` and
  `last_value(field ORDER BY col [ASC|DESC])` are parsed and executed, including
  `GROUP BY <columns>` for "latest value per group" queries. The InfluxQL-style
  `FIRST(field, time)` / `LAST(field, time)` the double previously accepted are
  **rejected**: InfluxDB v3 fails planning on them (`Invalid function 'last'`),
  so accepting them let a query pass tests and 400 in production. The rejection
  names the v3 spelling. `first_value`/`last_value` without an inner `ORDER BY`
  are also rejected — DataFusion returns an arbitrary group member in that case,
  which the double cannot reproduce. Verified against a live InfluxDB 3 Core;
  the shared contract suite now passes against the real engine (it previously
  failed on the two `FIRST`/`LAST` tests).
- **`Client.Local` parser rejections are prefixed `Client.Local:`** so an
  `unsupported column expression` error reads as a limitation of the test double
  rather than of InfluxDB. Plain aggregates (`AVG`, `SUM`, `COUNT`, `MIN`,
  `MAX`) now reject a second argument, as the real engine does.
- **`Client.Local` reports a missing table the way the real engine does.**
  `query_sql/3` on an unknown measurement returned
  `{:error, {:table_not_found, name}}` while `Client.HTTP` returns
  `{:error, %{status: 400, body: "Error during planning: table ... not found"}}`,
  and the streaming path mapped it to a 404. Both now produce the 400 planning
  error, so consumer code that matches `%{status: 400}` can be exercised against
  the double. Code matching the old tuple must be updated.

### Fixed
- **`BatchWriter` now honours its `:database` option.** The value was stored in
  state and never forwarded to the write, so every flush landed in the
  connection's default database. It is now the write target unless
  `:write_opts` names a `:database` explicitly.
- **`Client.Local` (`:v2` profile) accepts writes to buckets created with
  `create_bucket/3`.** Writes only checked the `databases:` seeded at start, so a
  bucket created through the API returned `404 database not found`.
- **`Client.Local` no longer re-types quoted string literals** (#12). A bound
  string param or quoted literal such as `'08338636'` was parsed back through
  `Integer.parse`, dropping the leading zero and changing the type, so
  `WHERE repcode = $rc` / `IN ($rc)` over zero-padded identifiers never matched
  while real InfluxDB v3 matched correctly. Quoted literals are now strings;
  only bare literals are typed. Comparing a string literal against a numeric
  field compares the field's text rendering, which is what DataFusion does
  (`amount >= '1000.00'` is lexical and matches `500.0` on the real engine
  too), so that footgun now fails in tests the same way it fails in production.
- **Linear-time accumulation in `Client.Local` WHERE parsing and
  `Flight.Reader` batch decoding.** Both appended with `++` inside a reduce,
  which is quadratic in the number of clauses / record batches.
- **`Client.Local` param substitution is whole-placeholder and single-pass.**
  `$h` was previously replaced inside `$hmin`, and a substituted string value
  containing another placeholder's name could be re-substituted.

## [0.1.19] - 2026-07-08

### Fixed
- **`InfluxElixir.Client.Local.query_sql_stream/3` now mirrors the HTTP client's
  error semantics** (#11). `Client.Local` is the documented drop-in test double for
  `Client.HTTP`, but it still returned an empty stream on a query error or an
  unsupported operation while `Client.HTTP` raised — so consumer code that rescues
  `InfluxElixir.StreamError` (to avoid treating an outage as "no data") could not be
  exercised against the test double. It now raises `InfluxElixir.StreamError` on
  enumeration for both cases, matching `Client.HTTP`.

### Added
- Tests covering the Local `:http_status`/`:unsupported` stream-error paths and
  lazy (deferred) raising.

## [0.1.18] - 2026-07-08

### Fixed
- **`query_sql_stream/3` (HTTP transport) now truly streams and no longer swallows
  errors** (#10). Previously it used `Finch.request/3`, which buffered the entire
  response body and eagerly decoded every JSONL line before yielding — giving zero
  memory benefit over `query_sql/3` — and it halted to an empty list on non-2xx
  statuses, transport errors, and unresolved databases, so every failure class
  looked like "zero rows". It now consumes the response with `Finch.stream/5`,
  decoding JSONL line-by-line with back-pressure (constant memory), and raises an
  `InfluxElixir.StreamError` on a missing database, a non-success HTTP status, or a
  transport error when the stream is enumerated.

### Added
- `InfluxElixir.StreamError` exception, raised while consuming a streaming query
  that cannot produce rows. Carries a `:kind` (`:no_database | :http_status |
  :transport | :decode | :unsupported`) plus `:status`/`:body`/`:reason` context.
  `InfluxElixir.StreamError.stream/1` builds an `Enumerable.t()` that defers the
  raise to enumeration, shared by both client implementations.
- Tests covering the HTTP `:no_database`/`:transport` paths (real Finch pool, no
  mocking) and `StreamError` message construction.

## [0.1.17] - 2026-06-30

### Changed
- **Loosened `decimal` constraint to `~> 2.0 or ~> 3.0`** (#9). Unblocks downstream
  apps from upgrading past `decimal 2.4.1` (EEF-CVE-2026-32686) and from picking up
  `ecto ~> 3.14 → ash ~> 3.29` chains. Surface used (`Decimal.to_string/2`,
  `%Decimal{}` pattern) is stable across 2 → 3.
- **Loosened `grpc` constraint to `~> 0.11 or ~> 1.0`** (#9). Unblocks downstream
  apps from upgrading past `grpc 0.11.5` (5 CVEs including EEF-CVE-2026-48853).
- **Defaulted the Flight client to the Mint gRPC adapter** so the library doesn't
  pull in `:gun`, which became `optional` in `grpc 1.0`. Mint is already available
  via `finch`.
- `InfluxElixir.Supervisor` now skips adding `GRPC.Client.Supervisor` as a child
  when `grpc 1.0+` is present (1.0 auto-starts it via its own `Application`).

### Fixed
- `LocalClient` now supports `COUNT(*)` as a scalar and DATE_BIN-bucketed aggregate.
- `LocalClient` WHERE-clause parser now returns a 400 error for unrecognised
  clauses (e.g. `LIKE`) instead of silently matching all rows.

### Added
- Regression tests for `COUNT(*)`, explicit column-list `SELECT`, `IN` operator
  narrowing, write-timestamp preservation, and silent WHERE drop.

## Earlier releases

- Initial project setup with module stubs
- CI pipeline with quality checks and auto-publish to Hex.pm
