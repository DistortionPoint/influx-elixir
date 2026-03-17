# Fix: Connection Registry Never Populated

**Date**: 2026-03-17
**Scope**: `InfluxElixir.ConnectionSupervisor`, `InfluxElixir`, `InfluxElixir.Connection`
**Bug**: Connection registry (`persistent_term`) is never populated during startup

---

## Problem

`InfluxElixir.Connection` provides a `:persistent_term`-backed registry with
`put/2`, `get/1`, and `fetch!/1`. The `@moduledoc` states:

> Connections are typically registered by `InfluxElixir.ConnectionSupervisor`
> during startup.

But `ConnectionSupervisor.init/1` never calls `Connection.put/2`. Neither does
`InfluxElixir.add_connection/2`. The registry is always empty.

This means `Connection.fetch!(:trading)` always raises even though the
`:trading` connection was configured and started.

## Root Cause

Two sites create connections without registering them:

1. **`ConnectionSupervisor.init/1`** (line 40-68) — starts Finch pool and
   optional BatchWriter, but does not call `Connection.put(name, config)`.

2. **`InfluxElixir.add_connection/2`** (line 269-280) — starts a new
   `ConnectionSupervisor` child but does not register the config.

Symmetrically, `InfluxElixir.remove_connection/1` does not call
`Connection.delete/1`.

## Fix

### 1. `ConnectionSupervisor.init/1` — register on startup

After validating config and before returning the children spec, call
`Connection.put(name, config)`. This ensures every connection started by the
supervisor tree is immediately queryable by name.

### 2. `InfluxElixir.add_connection/2` — register after successful start

After `Supervisor.start_child/2` returns `{:ok, pid}`, call
`Connection.put(name, opts)`.

### 3. `InfluxElixir.remove_connection/1` — deregister on removal

After successfully terminating and deleting the child, call
`Connection.delete(name)`.

### 4. Facade functions — resolve atom names

Update the facade module (`InfluxElixir`) so that `write/3`, `query_sql/3`,
`health/1`, etc. accept either a keyword config list or an atom name.
When an atom is passed, resolve it via `Connection.fetch!/1`.

This is the consumer-facing improvement: callers can write
`InfluxElixir.health(:trading)` instead of manually resolving config.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/connection_supervisor.ex` | Add `Connection.put/2` in `init/1` |
| `lib/influx_elixir.ex` | Add `Connection.put/2` in `add_connection/2`, `Connection.delete/1` in `remove_connection/1`, resolve atom names in facade functions |
| `test/influx_elixir/connection_supervisor_test.exs` | Test registry population on startup |
| `test/influx_elixir/supervisor_test.exs` | Test add/remove populates/clears registry |

### New Files

| File | Purpose |
|------|---------|
| `test/influx_elixir/connection_supervisor_test.exs` | Registry population + cleanup tests |

## Verification

```bash
mix test test/influx_elixir/connection_supervisor_test.exs
mix test test/influx_elixir/supervisor_test.exs
mix test
mix credo --strict
mix format --check-formatted
```

## Implementation Status

**Completed**: 2026-03-17

All items implemented per design:

1. **`ConnectionSupervisor.init/1`** — calls `Connection.put(name, config)`
   after extracting the connection name, before returning child specs.
2. **`InfluxElixir.remove_connection/1`** — calls `Connection.delete(name)`
   after terminating and deleting the supervisor child.
3. **`InfluxElixir.resolve_connection/1`** — new public function that accepts
   an atom (resolves via `Connection.fetch!/1`) or passthrough for keyword/map.
4. **All 14 facade functions** (`write/3`, `query_sql/3`, `health/1`, etc.)
   call `resolve_connection/1` on their connection parameter.
5. **Tests**: 6 new tests in `connection_supervisor_test.exs`, 5 new tests
   in `influx_elixir_test.exs` for resolve + facade atom name support.
6. **CI**: 607 tests pass, 0 failures, 90.11% coverage, 0 Credo issues,
   format clean.
