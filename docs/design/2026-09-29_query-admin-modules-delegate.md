# Query and Admin Modules Delegate to the Facade

**Date**: 2026-09-29
**Scope**: `Query.SQL`, `Query.SQLStream`, `Query.InfluxQL`, `Query.Flux`, `Admin.*`
**Issue**: scheduled quality sweep (no open issues)

---

## Problem

The library has two public entry points for every query and admin
operation:

- the `InfluxElixir` facade (`query_sql/3`, `list_databases/1`, ...);
- the `Query.*` and `Admin.*` modules (`Query.SQL.query/3`,
  `Admin.Databases.list/1`, ...).

The facade resolves a connection name through `InfluxElixir.Connection`
and wraps each query in a `[:influx_elixir, :query, ...]` telemetry span.
The modules called `InfluxElixir.Client.impl()` directly and did neither.
With `Client.Local` and a connection added under `:qm`:

| Call | Result |
|------|--------|
| `InfluxElixir.query_sql(:qm, sql)` | rows, span emitted |
| `Query.SQL.query(:qm, sql)` | `FunctionClauseError` |
| `Query.SQL.query(conn, sql)` | rows, no span |
| `Admin.Databases.list(:qm)` | `FunctionClauseError` |

The same operation behaved differently depending on the module a caller
picked, and the difference showed up only as a crash or as missing
metrics.

## Decision

Every `Query.*` and `Admin.*` function calls the facade function of the
same operation instead of the client, and the facade never calls these
modules, so there is no cycle. The modules keep their names and docs for
callers who prefer them, and their moduledocs now say they are the facade
under another name. The `Telemetry` moduledoc lists them as span
emitters. As before, `Query.SQLStream.stream/3` emits no span.

## Verification

`the same entry point as the facade` in `Query.SQLTest` uses a named
connection, the query span, `query_stream/3`, `execute/3`,
`Admin.Databases.list/1` and `Admin.Health.check/1`. It fails against the
previous modules and passes now. The rest of the suite is unchanged, and
the integration suites pass.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/query/{sql,sql_stream,influxql,flux}.ex`, `lib/influx_elixir/admin/*.ex` | Call the facade; moduledocs |
| `lib/influx_elixir/telemetry.ex` | Moduledoc |
| `test/influx_elixir/query/sql_test.exs` | Test |
| `CHANGELOG.md`, `docs/design/README.md` | Updated |
