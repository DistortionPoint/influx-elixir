# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
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
