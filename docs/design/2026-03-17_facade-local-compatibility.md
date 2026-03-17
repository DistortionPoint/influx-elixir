# Fix: Facade Connection Resolution Incompatible with Client.Local

**Date**: 2026-03-17
**Scope**: `InfluxElixir.Client`, `InfluxElixir.Client.Local`, `InfluxElixir.ConnectionSupervisor`
**Bug**: Facade passes keyword config to Client.Local which expects `%{table: _, databases: _, profile: _}`

---

## Problem

`ConnectionSupervisor.init/1` stores the raw keyword config via `Connection.put(name, config)`. When the facade resolves an atom name, it returns this keyword list. But `Client.Local` pattern-matches on `%{table: table}` — a map with an ETS table reference. The types are incompatible.

Result: every facade call with a named connection raises `FunctionClauseError` when `Client.Local` is configured.

## Root Cause

The `Client` behaviour defines `@type connection :: term()` but has no callback for *initializing* a connection from config. Each implementation has a different connection type:
- `Client.HTTP` — keyword list (host, token, etc.)
- `Client.Local` — map with ETS table reference

`ConnectionSupervisor` stores raw config, which only works for HTTP.

## Design

### Add `init_connection/1` callback to the Client behaviour

```elixir
@callback init_connection(keyword()) :: {:ok, connection()} | {:error, term()}
```

Each implementation converts raw config into its own connection type:
- **`Client.HTTP`** — returns the keyword list as-is (it already is the connection)
- **`Client.Local`** — calls `start/1` to create an ETS table, returns the conn map

### `ConnectionSupervisor.init/1` — call `init_connection/1`

Instead of storing raw config directly:
```elixir
# Before (broken for Local):
Connection.put(name, config)

# After:
{:ok, conn} = InfluxElixir.Client.impl().init_connection(config)
Connection.put(name, conn)
```

### `Client.Local.stop/1` — cleanup on connection removal

`InfluxElixir.remove_connection/1` already calls `Connection.delete(name)`.
For `Client.Local`, the ETS table also needs cleanup. Add a `shutdown_connection/1`
callback:

```elixir
@callback shutdown_connection(connection()) :: :ok
```

- **`Client.HTTP`** — no-op (Finch pool is managed by its own supervisor)
- **`Client.Local`** — calls `stop/1` to delete ETS table

`remove_connection/1` calls `client().shutdown_connection(conn)` before deleting
from the registry.

### Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client.ex` | Add `init_connection/1` and `shutdown_connection/1` callbacks |
| `lib/influx_elixir/client/local.ex` | Implement `init_connection/1` (delegates to `start/1`) and `shutdown_connection/1` (delegates to `stop/1`) |
| `lib/influx_elixir/client/http.ex` | Implement `init_connection/1` (passthrough) and `shutdown_connection/1` (no-op) |
| `lib/influx_elixir/connection_supervisor.ex` | Call `init_connection/1` instead of storing raw config |
| `lib/influx_elixir.ex` | `remove_connection/1` calls `shutdown_connection/1` |
| `test/influx_elixir/connection_supervisor_test.exs` | Test that Local connections are usable via facade |
| `test/influx_elixir_test.exs` | Test facade + named connection + Local round-trip |

### No New Files

### Documentation Updates

| Location | Change |
|----------|--------|
| `lib/influx_elixir/client.ex` `@moduledoc` | Document `init_connection/1` and `shutdown_connection/1` lifecycle |
| `lib/influx_elixir/connection.ex` `@moduledoc` | Update usage example — stored values are initialized connections, not raw config |
| `lib/influx_elixir/connection_supervisor.ex` `@moduledoc` | Note that it calls `init_connection/1` before registering |
| `docs/guides/testing-with-local-client.md` | Add section showing named connections work with Client.Local via the facade |

## Verification

```bash
mix test
mix test --cover
mix credo --strict
mix format --check-formatted
```

## Status: COMPLETE

All changes implemented and verified:
- 614 tests, 0 failures
- Credo strict: no issues
- Format: clean
- Coverage: 90.02%
