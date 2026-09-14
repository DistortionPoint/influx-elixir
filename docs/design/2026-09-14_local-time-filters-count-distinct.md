# `Client.Local` Time Comparands, `COUNT(DISTINCT)`, `IS NULL`, `MAX(time)` and `BatchWriter` Backpressure

**Date**: 2026-09-14
**Scope**: `Client.Local`, `Client.Local.SQLParser`, `Write.BatchWriter`, contract and integration suites, testing guide
**Issue**: scheduled quality sweep (no open issues beyond the ones already fixed locally)

---

## Problem

With no new issues, the sweep probed the double with queries a consumer is
likely to write and replayed each against InfluxDB 3 Core
(`influxdb:3-core`, `--object-store memory --without-auth`):

| Query | Engine | Double before |
|---|---|---|
| `WHERE time >= now() - INTERVAL '2 minutes'` | rows in the window | `{:ok, []}` (compared the literal string) |
| `WHERE time > 1000000000` | 400 "Cannot infer common argument type … Timestamp(ns) > Int64" | `{:ok, rows}` |
| `WHERE time > $start`, integer param | 400 (same, `UInt64`) | `{:ok, rows}` |
| `WHERE time >= 'garbage'` | 500 "Error parsing timestamp" | `{:ok, []}` |
| `WHERE time >= $start`, `DateTime` param | rows (Jason sends ISO-8601) | `~U[...]` in the SQL, `{:ok, []}` |
| `SELECT DISTINCT provider … ORDER BY provider DESC` | `c, b, a` | `a, b, c` |
| `SELECT DISTINCT provider … ORDER BY price` | 400 "ORDER BY expressions must appear in select list" | `a, b, c` |
| `MAX(time)`, `MIN(time)`, `COUNT(time)` | timestamps, count | `{:ok, [%{}]}` |
| `AVG(time)`, `SUM(time)`, `STDDEV(time)`, `MAX(time - 1)` | 400 planning errors | — |
| `COUNT(DISTINCT provider)` | `3` | 400 `invalid aggregate` |
| `WHERE bid IS NOT NULL` | rows with the field | 400 `unsupported WHERE clause` |

The first four are the serious ones: the double returned *something* for a
query the engine refuses, or nothing for one it runs. Every one is the class
of divergence the double exists to prevent (#12, #13, #16, #17).

The test review found the `BatchWriter` backpressure tests forging
GenServer state with `:sys.replace_state/2` and the retry tests injecting
`{:retry, …}` messages and reading `:sys.get_state/1`. Following the code
showed why: every flush emptied the buffer, so `{:error, :buffer_full}` —
documented in the moduledoc — could never occur through the public API. A
retry chain also replied to whichever `write_sync/3` caller happened to be
in `pending_sync` when it finished, not necessarily its own.

## Design

**Time comparands** are parsed, not compared as opaque terms. The parser
accepts exactly the engine's forms — a quoted ISO-8601 datetime (zoned,
zone-less or fractional), a quoted date, or `now()` followed by `+`/`-`
`INTERVAL 'N unit'` terms — and rejects everything else with a
`Client.Local:` 400 that quotes the engine's rule. `now()` becomes
`{:now, offset_ns}` and is resolved in the executor at query time, as the
engine does. `time IN (...)` goes through the same parser. Calendar params
render as ISO-8601 strings (what Jason sends). The executor's string
parsing helpers moved into the parser, which is where every other literal
is already typed.

**`DISTINCT`** rows are built first, then ordered with the same
`DateTime`-aware comparator the aggregate rows use, then limited. `ORDER BY`
must name a selected column, with DataFusion's message otherwise.

**Aggregates over `time`**: `eval_expr` resolves `time` to the point's
timestamp as a `DateTime`; `MIN`/`MAX` compare with the `DateTime`-aware
order. The parser refuses every other aggregate over `time`, and any
expression containing it, because DataFusion refuses them.

**`COUNT(DISTINCT col)`** is its own select column, counting distinct
non-null values of a field or tag. **`IS NULL` / `IS NOT NULL`** are two
new `where_op`s tested on field-or-tag presence.

**`BatchWriter`**: automatic flushes (batch size, timer) wait while a retry
chain is in flight — `retry_payload != nil` — so a failing server gets one
chain at a time and the buffer grows to the documented bound, at which
point `write/3` and `write_sync/3` return `{:error, :buffer_full}`.
Explicit `flush/2` and a plain `write_sync/3` still flush immediately.
When the chain ends the deferred buffer is flushed if it has reached
`batch_size`; otherwise the timer takes it. The `write_sync/3` caller's
`from` travels inside the `{:retry, payload, attempt, from}` message, so
only that chain answers it.

**Tests**: the unit suite exercises the chain through a closed port
(transport error, retried) and the backpressure through the public API; the
integration suite (real InfluxDB 3 Core) holds a one-connection Finch pool
with a streaming request so the first flush fails at checkout and the retry,
after the backoff, reaches the server — once succeeding, once answered with
a real 400 that ends the chain. No messages are injected and no state is
read.

Rejected: keeping integer `time` comparands "for convenience" — that is the
double certifying a query production refuses, the inverse of #13.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/sql_parser.ex` | `parse_time_comparand`, `now()` offsets, `IS [NOT] NULL`, `COUNT(DISTINCT)`, `check_time_argument`, `parse_distinct_order_by`, calendar params |
| `lib/influx_elixir/client/local.ex` | `{:now, _}` resolution, `time` in aggregates, `count_distinct`, null checks, `DISTINCT` ordering, `MAX` comparator, moduledoc |
| `lib/influx_elixir/write/batch_writer.ex` | Deferred automatic flushes during a retry chain, bounded buffer, `from` carried by the chain |
| `test/influx_elixir/client/local_test.exs` | Regression block for every row of the table; integer-time tests rewritten to expect rejection |
| `test/support/client_contract.ex` | `time_filter_tests`: the same assertions against Local and the server |
| `test/influx_elixir/write/batch_writer_test.exs` | State forging and message injection removed; real-path backpressure and chain tests |
| `test/integration/contract_v3_core_test.exs` | End-to-end retry success and 4xx-on-retry against the server |
| `docs/guides/testing-with-local-client.md`, `usage-rules/query.md` | Time filters, params, `DISTINCT`, `COUNT(DISTINCT)`, `IS NULL`, `MAX(time)` |
| `CHANGELOG.md` | Fixed entries |

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
