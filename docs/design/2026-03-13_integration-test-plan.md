# Integration Test & LocalClient Fidelity Plan

**Date**: 2026-03-13
**Scope**: Full integration tests against real InfluxDB instances + LocalClient behaviour fidelity audit

---

## Checklist

### Phase 1: Test Infrastructure
- [x] 1.1 — Integration test helper module (`test/support/integration_helper.ex`)
- [x] 1.2 — ExUnit tag strategy (`:integration`, `:v2`, `:v3_core`, `:v3_enterprise`)
- [x] 1.3 — Test cleanup hooks (unique names, `on_exit` teardown)

### Phase 2: LocalClient Response Shapes (atom → string keys)
- [x] 2.5 — `health/1` return string keys (`%{"status" => "pass"}`)
- [x] 2.6 — `list_databases/1` return string keys (`%{"name" => "db"}`)
- [x] 2.7 — `list_buckets/1` return string keys with `"id"` field
- [x] 2.8 — `create_token/3` return string keys

### Phase 3: LocalClient Behaviour Fixes
- [x] 2.1 — `execute_sql/3` actually deletes points on `DELETE FROM`
- [x] 2.2 — `query_sql/3` scopes queries to `database:` option
- [x] 2.3 — `query_influxql/3` handles `SHOW DATABASES`, `SHOW MEASUREMENTS`, `SHOW TAG KEYS`
- [x] 2.4 — `query_flux/3` applies `range()` and `filter()` predicates
- [x] 2.9 — `write/3` documents `gzip: true` option behaviour

### Phase 4: LocalClient Edge Case Tests
- [x] 4.1 — WHERE clause edge cases (`!=`, booleans, floats, time, case insensitivity)
- [x] 4.2 — Line protocol edge cases (escapes, negatives, scientific notation, comments)
- [x] 4.3 — Multi-database isolation (after 2.2 fix)
- [x] 4.4 — Flux query engine tests (after 2.4 fix)

### Phase 5: HTTP Client Fixes
- [x] 5.1 — HTTP client returns `{:error, :no_database_specified}` when database is nil
- [x] 5.2 — Contract test `build_real_conn/0` returns keyword list, not map

### Phase 6: Integration Tests Against Real InfluxDB
- [x] 3.1 — v3 Core tests (port 8181): health, write, query, database CRUD
- [x] 3.2 — v3 Enterprise tests (port 8182): Core tests + token management
- [x] 3.3 — v2 tests (port 8086): health, write, Flux query, bucket CRUD
- [x] 3.4 — Contract test refactor (shared helper, correct connection format)

---

## Context

We have three InfluxDB instances in Docker:

| Instance | Version | Port | Auth | Notes |
|----------|---------|------|------|-------|
| `dev-influxdb` | v2.7 | 8086 | token: `dev-influx-token-123456789`, org: `dev-influx`, bucket: `metrics` | v2 API only |
| `dev-influxdb3-core` | v3 Core | 8181 | No auth token (v3 Core has no auth) | v3 API, no buckets/tokens endpoints |
| `dev-influxdb3-trading` | v3 Enterprise | 8182 | No auth token (license-based) | v3 API, full admin endpoints |

**Key difference**: v3 Core has NO token-based auth and NO bucket/token management APIs. v3 Enterprise has token management. v2 has bucket APIs but different database/query endpoints.

---

## Part 1: Test Infrastructure

### 1.1 — Integration Test Helper Module

**Status**: DONE

**File**: `test/support/integration_helper.ex`

Create a shared helper that:
- Reads config from environment variables with sensible localhost defaults
- Starts a dedicated Finch pool for integration tests (`start_supervised!`)
- Returns a ready-to-use connection keyword list
- Provides helpers for each target: `v2_conn/0`, `v3_core_conn/0`, `v3_enterprise_conn/0`
- Detects which instances are actually reachable (HTTP health check) and skips tests for unavailable instances
- Generates unique database/measurement names per test run to prevent cross-test pollution

**Environment variables** (with defaults for the Docker Compose setup):
```
INFLUX_V2_HOST=localhost        INFLUX_V2_PORT=8086
INFLUX_V2_TOKEN=dev-influx-token-123456789
INFLUX_V2_ORG=dev-influx        INFLUX_V2_BUCKET=metrics

INFLUX_V3_CORE_HOST=localhost   INFLUX_V3_CORE_PORT=8181
INFLUX_V3_ENT_HOST=localhost    INFLUX_V3_ENT_PORT=8182
```

### 1.2 — ExUnit Tag Strategy

**Status**: DONE

**File**: `test/test_helper.exs`

Tags:
- `:integration` — any test hitting a real instance (already excluded by default)
- `:v2` — requires InfluxDB v2 on port 8086
- `:v3_core` — requires InfluxDB v3 Core on port 8181
- `:v3_enterprise` — requires InfluxDB v3 Enterprise on port 8182

Running:
```bash
mix test --include integration                          # all integration tests
mix test --include v3_core                              # only v3 core tests
mix test --include v3_enterprise                        # only v3 enterprise tests
mix test --include v2                                   # only v2 tests
```

### 1.3 — Test Cleanup Hooks

**Status**: DONE

Databases/buckets created during integration tests must be cleaned up in `on_exit/1` callbacks. Use unique names (e.g. `"test_#{System.unique_integer([:positive])}"`) to avoid collisions when running with `async: true` against real instances.

---

## Part 2: LocalClient Fidelity Gaps

Audit of every `Client` behaviour callback — does `LocalClient` respond with the same shapes and semantics as the real InfluxDB?

### 2.1 — `execute_sql/3` Is a No-Op

**Status**: DONE

**Problem**: Returns `{:ok, %{rows_affected: 0}}` for any input. Real InfluxDB v3 returns different response shapes depending on the statement (CREATE TABLE, DELETE, etc.). At minimum, the LocalClient should actually delete matching points when it receives a `DELETE FROM measurement` statement, so that test suites exercising delete workflows see realistic behaviour.

**Fix**:
- Parse `DELETE FROM <measurement>` and `DELETE FROM <measurement> WHERE ...` in LocalClient
- Actually remove matching points from ETS
- Return `{:ok, %{rows_affected: N}}` with the correct count
- Unknown statements still return `{:ok, %{rows_affected: 0}}`

### 2.2 — `query_sql/3` Needs `database:` Option Support

**Status**: DONE

**Problem**: LocalClient's `query_sql/3` ignores the `database:` option — it searches ALL databases for the measurement. Real InfluxDB only queries the specified database. This means tests pass even when they omit the required `database:` option, hiding bugs.

**Fix**: `query_sql/3` should accept `opts[:database]` and scope the ETS lookup to that database. Default to `"default"` when omitted (matching real InfluxDB default database behaviour).

### 2.3 — `query_influxql/3` Should Parse InfluxQL-Specific Syntax

**Status**: DONE

**Problem**: Delegates directly to `query_sql/3`. InfluxQL has syntax that SQL doesn't (e.g., `SHOW DATABASES`, `SHOW MEASUREMENTS`, `SHOW TAG KEYS`). The LocalClient should handle at least the most common InfluxQL commands.

**Fix**: Add handling for:
- `SHOW DATABASES` → returns list from ETS
- `SHOW MEASUREMENTS` → returns measurement names from ETS
- `SHOW TAG KEYS FROM <measurement>` → returns distinct tag keys
- Everything else → delegate to the existing SQL engine

### 2.4 — `query_flux/3` Doesn't Support `range()` or `filter()` Predicates

**Status**: DONE

**Problem**: The Flux engine only extracts bucket name and measurement name. Real Flux queries with `range(start: -1h)` or `filter(fn: (r) => r.host == "web01")` would filter results — LocalClient returns all points.

**Fix**: Parse and apply:
- `range(start: ...)` — filter by timestamp (support `-1h`, `-1d`, RFC3339)
- `filter(fn: (r) => r.<key> == "<value>")` — already partially handled for `_measurement`, extend to any field/tag equality
- This is best-effort — Flux is a full language, we only need the most common patterns

### 2.5 — `health/1` Response Shape Doesn't Match Real InfluxDB

**Status**: DONE

**Problem**: Returns `%{status: "pass"}` (atom key). Real InfluxDB v3 returns `%{"status" => "pass"}` (string key) from JSON. The HTTP client uses `Jason.decode` which produces string keys. LocalClient should match.

**Fix**: Return `%{"status" => "pass", "version" => "local"}` with string keys to match the JSON-decoded shape consumers will see from the HTTP client.

**Impact**: This is a **breaking change** for existing tests that pattern match on `%{status: "pass"}`. Must update:
- `test/influx_elixir/client/local_test.exs` health test
- `test/influx_elixir_test.exs` health test
- `test/integration/contract_test.exs` health tests

### 2.6 — `list_databases/1` Response Shape Doesn't Match Real InfluxDB

**Status**: DONE

**Problem**: Returns `[%{name: "db"}]` (atom key). Real v3 API returns `[%{"name" => "db_name"}]` (string key). Same JSON-decode mismatch.

**Fix**: Return maps with string keys: `[%{"name" => "db_name"}]`

**Impact**: Breaking change for tests that use `db.name` — must switch to `db["name"]`.

### 2.7 — `list_buckets/1` Response Shape Doesn't Match Real InfluxDB v2

**Status**: DONE

**Problem**: Same atom-vs-string key issue. Also, real v2 `list_buckets` returns much richer maps (`%{"id" => ..., "name" => ..., "orgID" => ..., "retentionRules" => ...}`). LocalClient returns just `%{name: "bucket"}`.

**Fix**: Return string-keyed maps with at minimum: `%{"id" => generated_id, "name" => name}`. Full v2 shape is optional but the key format must be strings.

### 2.8 — `create_token/3` Response Shape Mismatch

**Status**: DONE

**Problem**: Returns `%{id: ..., token: ..., description: ...}` with atom keys. Real v3 API returns string keys.

**Fix**: Return `%{"id" => id, "token" => token_string, "description" => desc}` with string keys.

### 2.9 — `write/3` Gzip: Should Compress, Not Just Decompress

**Status**: DONE

**Problem**: LocalClient *decompresses* gzip payloads (good), but the `gzip: true` option in `HTTP.write/3` expects the caller to pass pre-compressed data. The LocalClient `write/3` doesn't accept the `gzip: true` option at all — it auto-detects via magic bytes. This is fine, but worth documenting that the option is ignored.

**Fix**: No code change needed — just add a test verifying that `gzip: true` option is accepted without error (opts are just passed through, decompression happens via magic byte detection).

---

## Part 3: Integration Tests Against Real InfluxDB

### 3.1 — v3 Core Integration Tests

**Status**: DONE

**File**: `test/integration/v3_core_test.exs`
**Tags**: `@moduletag :v3_core`, `@moduletag :integration`

Tests:
1. **Health**: `GET /health` returns `%{"status" => "pass"}`
2. **Write**: POST line protocol to `/api/v2/write?db=...`, verify 204
3. **Write + Query round-trip**: Write point, query it back with `query_sql/3`
4. **Parameterized SQL query**: Write tagged points, query with `$param` placeholders
5. **Streaming SQL query**: Write multiple points, `query_sql_stream/3` returns all rows
6. **InfluxQL query**: `query_influxql/3` returns rows
7. **Create database**: Create a test database, verify it appears in `list_databases/1`
8. **Delete database**: Create then delete, verify it's gone
9. **Write to non-existent database**: Expect `{:error, %{status: 404}}`
10. **Multiple measurements**: Write to two measurements, query each independently
11. **Timestamp precision**: Write with explicit nanosecond timestamps, verify round-trip
12. **Large batch write**: Write 1000 points in one line protocol payload
13. **Empty query result**: Query measurement that doesn't exist, expect `{:ok, []}`

### 3.2 — v3 Enterprise Integration Tests

**Status**: DONE

**File**: `test/integration/v3_enterprise_test.exs`
**Tags**: `@moduletag :v3_enterprise`, `@moduletag :integration`

All v3 Core tests plus:
1. **Token create**: `create_token/3` returns map with `"id"` and `"token"` keys
2. **Token delete**: Created token can be deleted
3. **Token delete is idempotent**: Deleting a non-existent token returns `:ok`

Note: v3 Enterprise shares the same write/query APIs as v3 Core. Token management is the main differentiator.

### 3.3 — v2 Integration Tests

**Status**: DONE

**File**: `test/integration/v2_test.exs`
**Tags**: `@moduletag :v2`, `@moduletag :integration`

Tests:
1. **Health**: `GET /health` returns passing status
2. **Write**: Write line protocol to v2 write endpoint
3. **Write + Flux query round-trip**: Write point, query with `query_flux/3`
4. **Bucket create**: `create_bucket/3` returns `:ok`
5. **Bucket list**: `list_buckets/1` returns list including created bucket
6. **Bucket delete**: Create and delete bucket
7. **Auth token required**: Requests without valid token return 401

### 3.4 — Cross-Version Contract Tests (Refactor Existing)

**Status**: DONE

**File**: `test/integration/contract_test.exs` (refactor existing)

The existing contract test only tests LocalClient with a couple of `@tag :integration` tests that use wrong connection format (map instead of keyword list). Fix:
- Refactor `build_real_conn/0` to return a keyword list (matching what `HTTP` expects)
- Include `finch_name:` pointing to the test Finch pool
- Use `IntegrationHelper` for connection setup
- Add contract test matrix: each contract test should pass against both LocalClient AND real InfluxDB

---

## Part 4: LocalClient Exhaustive Tests

### 4.1 — WHERE Clause Edge Cases

**Status**: DONE

**File**: `test/influx_elixir/client/local_test.exs` (extend)

Add tests for:
- `WHERE field != value` (not-equal operator)
- `WHERE tag = 'value' AND field > N` (compound conditions — already partially tested)
- `WHERE` with boolean values: `WHERE active = true`
- `WHERE` with float comparisons: `WHERE temp > 98.5`
- `WHERE` on `time` field (timestamp filtering)
- Case insensitivity: `select * from cpu where host = 'web01'`

### 4.2 — Line Protocol Edge Cases

**Status**: DONE

**File**: `test/influx_elixir/client/local_test.exs` (extend)

Add tests for:
- Tag value with escaped equals sign: `m,k=v\=1 f=1i`
- Tag value with escaped comma: `m,k=v\,1 f=1i`
- Empty tag set (just measurement + fields): `m field=1i`
- Measurement name with escaped comma: `my\,measurement field=1i`
- Field with negative integer: `m value=-42i`
- Field with negative float: `m value=-3.14`
- Field with scientific notation: `m value=1.5e10`
- Multiple lines with comments (lines starting with `#`)
- Blank lines between data lines
- Line with trailing whitespace

### 4.3 — Multi-Database Isolation

**Status**: DONE

**File**: `test/influx_elixir/client/local_test.exs` (extend)

After fixing 2.2, add tests verifying:
- Points written to `db_a` are NOT visible when querying `db_b`
- Same measurement name in two databases returns different data
- `query_sql` without explicit `database:` option uses `"default"`

### 4.4 — Flux Query Engine Tests

**Status**: DONE

**File**: `test/influx_elixir/client/local_test.exs` (extend)

After fixing 2.4, add tests for:
- `from(bucket: "db") |> range(start: -1h)` filters by time
- `from(bucket: "db") |> filter(fn: (r) => r.host == "web01")` filters by tag
- `from(bucket: "db") |> filter(fn: (r) => r._measurement == "cpu")` filters by measurement
- Flux query with no matching bucket returns empty list

---

## Part 5: HTTP Client Connection Fix

### 5.1 — HTTP Client Needs `database` Default from Connection

**Status**: DONE

**Problem**: Several HTTP client methods fall back to `conn_val(connection, :database)` when no `database:` option is given. But Config validates `:database` as an optional field. If the consumer doesn't set a default database, these calls crash or send `nil` to InfluxDB.

**Fix**: Add validation in HTTP client methods — if `database` resolves to `nil`, return `{:error, :no_database_specified}` instead of sending a bad request.

### 5.2 — HTTP Client `build_real_conn` in Contract Test Is Wrong

**Status**: DONE

**Problem**: `build_real_conn/0` returns a map (`%{host: ..., token: ...}`) but `HTTP` client expects a keyword list. This means the integration tests would crash on `Keyword.get/3`.

**Fix**: Return a keyword list and include all required keys: `:host`, `:token`, `:scheme`, `:port`, `:name`, `:finch_name`.

---

## Implementation Order

| Phase | Items | Description |
|-------|-------|-------------|
| **Phase 1: Infrastructure** | 1.1, 1.2, 1.3 | Test helpers, tags, cleanup |
| **Phase 2: LocalClient response shapes** | 2.5, 2.6, 2.7, 2.8 | String keys to match JSON decode |
| **Phase 3: LocalClient behaviour fixes** | 2.1, 2.2, 2.3, 2.4, 2.9 | Functional gaps |
| **Phase 4: LocalClient edge case tests** | 4.1, 4.2, 4.3, 4.4 | Exhaustive coverage |
| **Phase 5: HTTP client fixes** | 5.1, 5.2 | Connection handling |
| **Phase 6: Integration tests** | 3.1, 3.2, 3.3, 3.4 | Real InfluxDB verification |

---

## Quality Gate Results (Final)

- [x] `mix test` — 480 tests, 0 failures (up from 427), 30 excluded integration tests
- [x] `mix test --include integration` — ready, requires Docker instances running
- [x] `mix credo --strict` — 0 issues
- [x] `mix dialyzer` — 0 errors
- [x] `mix format` — clean
- [x] All new public functions have `@doc` and `@spec`
