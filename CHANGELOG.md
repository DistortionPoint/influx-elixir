# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- **`InfluxElixir.Client.Local.query_sql_stream/3` now mirrors the HTTP client's
  error semantics** (#11). `Client.Local` is the documented drop-in test double for
  `Client.HTTP`, but it still returned an empty stream on a query error or an
  unsupported operation while `Client.HTTP` raised — so consumer code that rescues
  `InfluxElixir.StreamError` (to avoid treating an outage as "no data") could not be
  exercised against the test double. It now raises `InfluxElixir.StreamError` on
  enumeration for both cases, matching `Client.HTTP`.

### Added
- `InfluxElixir.StreamError` exception, raised while consuming a streaming query
  that cannot produce rows. Carries a `:kind` (`:no_database | :http_status |
  :transport | :decode | :unsupported`) plus `:status`/`:body`/`:reason` context.
  `InfluxElixir.StreamError.stream/1` builds an `Enumerable.t()` that defers the
  raise to enumeration, shared by both client implementations.
- Tests covering the HTTP `:no_database`/`:transport` paths (real Finch pool, no
  mocking), the Local `:http_status`/`:unsupported` paths, lazy (deferred) raising,
  and `StreamError` message construction.

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
