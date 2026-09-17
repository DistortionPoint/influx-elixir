# `Client.Local`: `IN`-List Items and Select-List Constants

**Date**: 2026-09-17
**Scope**: `Client.Local.SQLParser`, `Client.Local.SQLExecutor`
**Issue**: scheduled quality sweep

---

## Problem

Two more places where the double answered a query the engine refuses, or
refused one the engine runs, found by probing InfluxDB 3 Core:

| Query | Engine | Double before |
|---|---|---|
| `WHERE host IN (a, b)` | 500 "No field named a" | rows matching the strings `"a"`, `"b"` |
| `WHERE v IN (1, other)` | rows where `v` equals 1 or the `other` column | `other` compared as the string `"other"` |
| `SELECT 1 AS one FROM p` | `1` | 500 "No field named 1" |
| `SELECT host, 0.0 AS volume FROM p GROUP BY host` | `0.0` per row | 400 "unsupported column expression" |
| `SELECT 0.0 AS volume, MAX(v) AS m FROM p` (the #17 candle shape) | `0.0`, `2.0` | 400 |
| `SELECT host, 'x' AS label FROM p` | `"x"` per row | schema error |

## Design

`IN`-list items go through the same comparand parser as the right side of
a comparison — quoted string, number, `NULL`, or a column / expression —
and are evaluated per row; the schema check collects column references
from lists as it does from expressions.

A constant with an alias is a `{:constant, value, alias}` select column
in aggregate queries and a `{:lit, value}` expression in projections, so
grouping, `DATE_BIN`, ordering and the schema check treat it as an output
with no source column. An unaliased constant is refused: DataFusion names
it after its own rendering (`Int64(1)`), which the double will not guess.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/sql_parser.ex` | `parse_in_values/2` via `parse_comparand/1`; `@constant_column`; `{:constant, _, _}` |
| `lib/influx_elixir/client/local/sql_executor.ex` | `IN` items evaluated per row; constants in aggregate rows; list references in the schema check |
| `test/influx_elixir/client/local_test.exs`, `test/support/client_contract.ex` | Regression and contract tests |
| `lib/influx_elixir/client/local.ex`, `CHANGELOG.md` | Docs |

## Verification

```bash
mix format --check-formatted && mix compile --warnings-as-errors
mix test                      # three runs, 0 failures
mix credo --strict && mix dialyzer && mix docs
docker run -d --rm --name influx3_verify -p 8181:8181 influxdb:3-core \
  influxdb3 serve --node-id node0 --object-store memory --without-auth
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration
docker stop influx3_verify
```
