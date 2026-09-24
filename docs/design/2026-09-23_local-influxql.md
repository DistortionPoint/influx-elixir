# `Client.Local` InfluxQL and Sub-Microsecond Time

**Date**: 2026-09-23
**Scope**: `Client.Local.InfluxQL` (new), `Client.Local.query_influxql/3`, `SQLExecutor` ordering, `SQLParser` time literals
**Issue**: scheduled quality sweep

---

## Problem

`Client.Local.query_influxql/3` answered three `SHOW` commands and handed
every other statement to its SQL engine. InfluxQL on InfluxDB 3 is not SQL
with other keywords. The same data and 50 statements, run on
`influxdb:3-core` and the double, differed on 28:

| Statement | InfluxDB 3 | Double before |
|---|---|---|
| `SELECT v FROM o` | `iox::measurement`, `time`, `v`, in time order | `v` only |
| `SELECT MEAN(v) FROM o` | `%{"mean" => 2.0, "time" => epoch}` | 400 |
| `SELECT SUM(v), MEAN(v), COUNT(v)` | `sum`, `mean`, `count`, time at the epoch | 400 |
| `SELECT MAX(v) FROM o` | `max` at the point's time | 400 |
| `SELECT MAX(v), h FROM o` | the point's `h` too | 400 |
| `SELECT MIN(v), MIN(w)` | `min`, `min_1` | 400 |
| `SELECT COUNT(*) FROM o` | `count_<field>` per field | 400 |
| `SELECT w FROM o` | only rows where `w` is set | every row |
| `SELECT h FROM o` (tag only) | `[]` | rows |
| `SELECT nothere FROM o`, `... FROM nope`, `WHERE nosuch = 'x'` | `[]` | 400 / 500 |
| `SELECT v FROM o GROUP BY h LIMIT 1` | one row per series, series by tag | — |
| `SHOW FIELD KEYS [FROM m]` | `fieldKey`, `fieldType` (`integer`, `unsigned`, ...) | 400 |
| `SHOW TAG KEYS` (no `FROM`) | every measurement's | 400 |
| `SHOW DATABASES` | `"deleted" => false` | missing |
| `... GROUP BY time(1m)` from epoch 0 | one row per empty minute since 1970 | 400 |

Running the probe exposed a second divergence, in SQL. Points written
100 ns apart:

| Query | InfluxDB 3 | Double before |
|---|---|---|
| `SELECT v FROM o ORDER BY time` | 1, 2, 3 | 3, 1, 2 (insertion order) |
| `... WHERE time >= '…:20.0000002Z'` | 2, 3 | 1, 2, 3 |

`ORDER BY time` compared the projected `DateTime`, which stops at the
microsecond, so sub-microsecond points tied. `DateTime.from_iso8601/1`
truncates fraction digits past six, so the literal lost its nanoseconds.

## Decision

A pure `Client.Local.InfluxQL` module parses the `SELECT` subset and
shapes rows. `Client.Local` fetches them with
`SELECT * FROM "m" [WHERE ...] ORDER BY time` through its SQL engine (the
two dialects share the comparison grammar used here) and maps a missing
table or unknown column to `{:ok, []}`. Tags come from the column schema.
`SHOW TAG KEYS` / `SHOW FIELD KEYS` read `{:column, ...}` objects, which
the ordered set yields in (measurement, key) order.

Refused by name, not approximated: `GROUP BY time(...)` (the engine fills
every empty bucket back to the query's start), regular expressions,
`fill()`, `INTO`, `SLIMIT`/`SOFFSET`, subqueries, `GROUP BY *`, `tz()`,
functions other than the seven above, `F(*)` other than `COUNT(*)`, and
plain columns beside anything but one selector.

In SQL, an `ORDER BY` key that is the point's own time (`time`, or an
alias of `time`) sorts on the stored nanoseconds in both the projection
and `SELECT *` paths. Time literals split fraction digits seven to nine
off before parsing and add them back as nanoseconds.

## Verification

After the change all 50 InfluxQL statements and 9 sub-microsecond SQL
statements return identical results from the engine and the double. The
v3 contract suite gains `influxql_select_tests` (shape, aggregates,
selector, per-series `LIMIT`, empty results, field keys, and the
nanosecond ordering and literal), run against Local and `influxdb:3-core`
(99 tests, 0 failures).

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/influxql.ex` | New: parse and shape InfluxQL `SELECT` |
| `lib/influx_elixir/client/local.ex` | `query_influxql/3` rewritten: `SHOW` from the schema, `SELECT` through `InfluxQL` |
| `lib/influx_elixir/client/local/sql_executor.ex` | `ORDER BY time` on nanoseconds |
| `lib/influx_elixir/client/local/sql_parser.ex` | sub-microsecond time literals |
| `test/influx_elixir/client/local_test.exs` | InfluxQL and nanosecond regression blocks |
| `test/support/client_contract.ex` | `influxql_select_tests` |
| `docs/guides/testing-with-local-client.md`, `usage-rules/query.md`, `CHANGELOG.md` | Updated |

```bash
mix format --check-formatted && mix compile --warnings-as-errors
mix test                      # three runs, 0 failures
mix credo --strict && mix dialyzer && mix docs
docker run -d --rm --name influx3_verify -p 8181:8181 influxdb:3-core \
  influxdb3 serve --node-id node0 --object-store memory --without-auth
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration
docker stop influx3_verify
```
