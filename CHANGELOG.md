# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
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
