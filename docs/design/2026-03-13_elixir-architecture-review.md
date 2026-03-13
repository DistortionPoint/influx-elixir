# Elixir Architecture Review & Remediation Plan

**Date**: 2026-03-13
**Sources**: BEAM/OTP Process Concurrency article, ../docs Elixir reference materials, codebase audit
**Scope**: influx_elixir library — alignment with Elixir/OTP best practices

---

## Summary of Findings

The codebase is well-structured overall. Supervision tree design, behaviour-based client abstraction, and tagged tuple error handling are all solid. The issues below range from **critical OTP violations** to **missed opportunities** that the reference materials explicitly recommend.

---

## CRITICAL — OTP Violations

### 1. BatchWriter `Process.sleep/1` Blocks the GenServer

**Status**: DONE

**File**: `lib/influx_elixir/write/batch_writer.ex:337`
**Problem**: `do_retry/5` calls `Process.sleep(delay)` inside a `handle_call` callback. This blocks the entire GenServer — no other messages can be processed during retry backoff. If a flush takes 3 retries with exponential backoff, the process is frozen for seconds. All pending `write/2`, `write_sync/2`, `flush/1`, and `stats/1` calls queue up.

**Best Practice (from BEAM article)**: *"Each process handles its state sequentially — no concurrent access to same data."* This is fine, but sleeping inside that sequential handler starves all callers.

**Fix**: Replace synchronous retry with async retry using `Process.send_after(self(), {:retry, payload, attempt}, delay)` and a `handle_info({:retry, ...})` callback. This frees the GenServer mailbox between retries.

**Resolution**: Implemented `handle_info({:retry, payload, attempt})` callback. `do_flush/1` now calls `schedule_retry/3` which uses `Process.send_after/3` for non-blocking backoff. State tracks `retry_payload` and `retry_attempt`.

---

### 2. BatchWriter `init/1` Schedules Timer — Should Use `handle_continue/2`

**Status**: DONE

**File**: `lib/influx_elixir/write/batch_writer.ex:173-194`
**Problem**: `init/1` calls `schedule_flush(state)` which calls `Process.send_after/3`. While this isn't heavy work, the reference materials (GenServer best practices from ../docs) explicitly state: *"Use `handle_continue/2` to defer work until after parent receives the PID"* and *"Prevents blocking supervision tree startup."*

**Resolution**: `init/1` now returns `{:ok, state, {:continue, :schedule_initial_flush}}`. New `handle_continue(:schedule_initial_flush, state)` callback schedules the flush timer.

---

### 3. Missing `@impl GenServer` on Multiple `handle_call` Clauses

**Status**: DONE

**File**: `lib/influx_elixir/write/batch_writer.ex:214, 233, 238`
**Problem**: Only the first `handle_call` clause (line 196) has `@impl GenServer`. The `write_sync`, `flush`, and `stats` clauses lack it. This means the compiler won't warn if these callbacks have signature typos.

**Resolution**: Added `@impl GenServer` above every callback clause: `handle_call({:write, ...})`, `handle_call({:write_sync, ...})`, `handle_call(:flush, ...)`, `handle_call(:stats, ...)`, `handle_info(:flush, ...)`, `handle_info({:retry, ...})`, `handle_continue/2`, `terminate/2`.

---

### 4. `cancel_timer/1` Doesn't Flush Stale Messages

**Status**: DONE

**File**: `lib/influx_elixir/write/batch_writer.ex:363-365`
**Problem**: `Process.cancel_timer(ref)` may return `false` if the timer already fired and the `:flush` message is in the mailbox. The current code ignores this, meaning a stale `:flush` message can arrive after cancellation and trigger an unexpected double-flush.

**Resolution**: `cancel_timer/1` now checks the return of `Process.cancel_timer/1`. On `false`, performs a non-blocking `receive do :flush -> :ok after 0 -> :ok end` to drain any stale message.

---

## HIGH — Architecture Gaps

### 5. Empty Stub Modules: Config and Connection

**Status**: DONE

**Files**: `lib/influx_elixir/config.ex`, `lib/influx_elixir/connection.ex`
**Problem**: Both are empty stubs with only `@moduledoc`. They're referenced in CLAUDE.md architecture but do nothing. NimbleOptions is a dependency but unused.

**Resolution**:
- `Config` — Implemented NimbleOptions schema with 8 options (`:host`, `:token`, `:org`, `:database`, `:port`, `:scheme`, `:pool_size`, `:name`). Provides `validate/1`, `validate!/1`, and `base_url/1`. 54 tests.
- `Connection` — Implemented `:persistent_term`-backed named config store with `put/2`, `get/1`, `fetch!/1`, `delete/1`, `finch_name/1`. 19 tests.

---

### 6. Facade `flush/1` and `stats/1` Are Disconnected No-ops

**Status**: DONE

**File**: `lib/influx_elixir.ex`
**Problem**: The top-level `InfluxElixir.flush/1` and `InfluxElixir.stats/1` don't delegate to `BatchWriter`. They exist in the facade but do nothing useful.

**Resolution**: `flush/1` and `stats/1` now look up the named BatchWriter process via `ConnectionSupervisor.batch_writer_name/1` and delegate. Return `{:error, :no_batch_writer}` when no writer is configured. `ConnectionSupervisor.init/1` optionally starts a BatchWriter child when `batch_writer: [...]` is in config.

---

### 7. HTTP Client Entirely Stubbed

**Status**: DONE

**File**: `lib/influx_elixir/client/http.ex`
**Problem**: Every callback returns `{:error, :not_implemented}`. The library can't talk to a real InfluxDB instance.

**Resolution**: All 14 callbacks implemented with Finch HTTP requests:
- `write/3` — POST `/api/v2/write`, gzip support
- `query_sql/3` — POST `/api/v3/query_sql`, parameterized queries, format selection
- `query_sql_stream/3` — Lazy `Stream.resource` over JSONL responses
- `execute_sql/3` — POST `/api/v3/query_sql` for non-SELECT statements
- `query_influxql/3` — POST `/api/v3/query_influxql`
- `query_flux/3` — POST `/api/v2/query` (v2 compat)
- `create_database/3`, `list_databases/1`, `delete_database/2` — v3 database CRUD
- `create_bucket/3`, `list_buckets/1`, `delete_bucket/2` — v2 bucket CRUD
- `create_token/3`, `delete_token/2` — v3 token management
- `health/1` — GET `/health`

6 unit tests + 4 integration tests (tagged `:integration`).

---

## MEDIUM — Best Practice Improvements

### 8. BatchWriter State Should Be a Struct

**Status**: DONE

**File**: `lib/influx_elixir/write/batch_writer.ex:178-191`
**Problem**: State is a plain map. The `@type state` is defined but not enforced. A typo in a key (e.g., `%{state | bufer_size: 0}`) would silently create a new key.

**Resolution**: Converted state to `defstruct` with `@type t`. All callbacks pattern match on `%__MODULE__{}`. Added `retry_payload` and `retry_attempt` fields for async retry state. Test verifies state is a struct via `:sys.get_state/1`.

---

### 9. Flight.Reader Heuristic Schema Parsing Must Be Replaced

**Status**: DONE

**File**: `lib/influx_elixir/flight/reader.ex`
**Problem**: The entire schema and record batch parsing layer relies on heuristic binary scanning that is fundamentally broken:

1. **`scan_for_names/2`** (line 161) — Scans the raw binary for any printable ASCII string preceded by a `<<len::little-16>>`. This matches random binary data.

2. **`peek_type_byte/1`** (line 206) — After finding a "name", peeks at the next 16 bytes for any byte matching a known Arrow type ID. Common byte values match.

3. **`scan_for_row_count/1`** (line 258) — Scans for the first `<<count::little-64>>` where `count > 0 and count < 1_000_000_000`. Any 8-byte sequence that satisfies this guard is treated as the row count.

4. **`scan_buffer_pairs/2`** (line 274) — Same heuristic scanning for offset/length pairs.

5. **Tests are circular** — The test fixtures construct binary data that *matches the heuristic format*, not actual Arrow IPC FlatBuffer format.

**Resolution**:
- New module `InfluxElixir.Flight.FlatBuffer` — spec-compliant FlatBuffer binary reader with `root_table_pos/1`, `read_vtable/2`, `field_pos/5`, scalar readers, `read_string/2`, `read_offset/2`, `read_vector_header/2`, `read_vector_table/3`. 48 tests.
- `Flight.Reader` rewritten — Schema parsing via proper FlatBuffer table traversal: Message → Schema → Field[] → name + Type union. RecordBatch parsing reads exact row count and buffer specs from FlatBuffer tables. Type resolution maps FlatBuffer Type union (Int with bitWidth/is_signed, FloatingPoint with precision, Bool, Utf8, Timestamp) to internal type IDs. 82 Reader tests with proper FlatBuffer binary fixtures.
- Column decoding logic (decode_ints, decode_floats, decode_bools, decode_utf8_column) preserved unchanged — that code was correct.

---

### 10. Credo Max Line Length (120) vs Formatter (98)

**Status**: DONE

**Files**: `.credo.exs`, `.formatter.exs`
**Problem**: Formatter enforces 98 chars. Credo allows 120. This means Credo will never catch line length issues that the formatter already fixes. The gap is harmless but confusing.

**Resolution**: Changed `.credo.exs` `MaxLineLength` from 120 to 98 to match `.formatter.exs`.

---

### 11. LocalClient ETS Table Is `:public`

**Status**: DONE

**File**: `lib/influx_elixir/client/local.ex`
**Problem**: ETS table created with `:public` access. Any process can read/write. While this enables `async: true` tests, it violates the principle of process isolation.

**Resolution**: Added comment documenting the trade-off: `:public` access is intentional for `async: true` test isolation; a GenServer wrapper would be correct for production but adds latency and complexity to a test-only client. No code change — design decision is acceptable and now documented.

---

### 12. No `terminate/2` Callback in BatchWriter

**Status**: DONE

**File**: `lib/influx_elixir/write/batch_writer.ex`
**Problem**: When the BatchWriter is shut down (supervisor restart, connection removal), buffered data is lost. There's no `terminate/2` to attempt a final flush.

**Resolution**: Added `@impl GenServer` `terminate/2` callback that calls `do_flush(state)` before returning `:ok`. Test verifies data is written to LocalClient on `GenServer.stop/1`.

---

## LOW — Polish

### 13. `write/2` Uses `GenServer.call` for an Async-Feeling API

**Status**: DONE

**File**: `lib/influx_elixir/write/batch_writer.ex:109-111`
**Problem**: `write/2` docs say "Returns `:ok` immediately" but it uses `GenServer.call` (synchronous). Under backpressure or GenServer overload, this blocks the caller.

**Resolution**: Updated `@doc` to say "Blocks until the buffer accepts the point, then returns. Does not wait for the data to be flushed to InfluxDB."

---

## Implementation Order

| Phase | Items | Status |
|-------|-------|--------|
| **Phase 1: BatchWriter fixes** | #1, #2, #3, #4, #8, #12, #13 | DONE |
| **Phase 2: Flight.Reader rewrite** | #9 | DONE |
| **Phase 3: Core infrastructure** | #5, #7 | DONE |
| **Phase 4: Wiring** | #6 | DONE |
| **Phase 5: Polish** | #10, #11 | DONE |

---

## Quality Gate Results (Final)

- [x] `mix test` — 427 tests, 0 failures (up from 297)
- [x] `mix credo --strict` — 0 issues
- [x] `mix dialyzer` — 0 errors
- [x] `mix format` — clean
- [x] All public functions have `@doc` and `@spec`
