# SQL References and Streamed Row Types

**Date**: 2026-09-24
**Scope**: `Client.HTTP` streaming decode; `Client.Local` `GROUP BY` / `ORDER BY` references and `DATE_BIN` grouping
**Issue**: scheduled quality sweep

---

## Problem

**Streaming.** `Client.HTTP.query_sql_stream/3` decoded each JSONL line
with `Jason.decode/1` only. `query_sql/3` runs `ResponseParser.coerce_types/1`
over the same rows, so the two disagreed on every timestamp column:

| Row | `query_sql/3` | stream before |
|---|---|---|
| `time` | `~U[2023-11-14 22:13:20.000000Z]` | `"2023-11-14T22:13:20"` |

`Client.Local`'s stream already returned `DateTime`s, so tests passed while
production code switched to streaming broke.

**References.** Against the same data on `influxdb:3-core`:

| Query | InfluxDB 3 | Double before |
|---|---|---|
| `... AS bucket ... GROUP BY bucket` | grouped | 500 `No field named bucket` |
| `GROUP BY 1`, `GROUP BY 1, 2` | grouped by the items | 500 `No field named 1` |
| `h AS host ... GROUP BY host` | grouped | 500 `No field named host` |
| `ORDER BY 2 DESC`, `ORDER BY 1, 2` | sorted by the items | 500 `No field named 2` |
| `GROUP BY DATE_BIN(...), h` | a row per bucket per `h` | 400 `must appear in the GROUP BY clause` |
| `GROUP BY 3` with two items | 400 `Cannot find column with position 3 in SELECT clause. Valid columns: 1 to 2` | 500 schema error |

The testing guide already said grouping columns work "alongside
`DATE_BIN`"; they did not.

## Decision

- Streamed rows go through `ResponseParser.coerce_types/1`, as
  `query_sql/3` rows do.
- `SQLParser.resolve_references/2` runs right after a `SELECT` is split,
  before any clause is read. In `GROUP BY` a position becomes the select
  item's expression and an alias becomes the expression it names; in
  `ORDER BY` a position becomes the item's output name (aliases were
  already accepted there). A position outside the select list returns the
  engine's planning error verbatim. `SELECT *` is left alone.
- The `GROUP BY` list is read item by item: a `DATE_BIN(INTERVAL ...,
  time)` item sets the interval, the rest are grouping columns, and the
  executor groups by `{bucket_start, column values}` in one path (it had a
  path for each and chose one).

## Verification

14 comparison queries (the table above plus the unaliased and combined
forms) and the stream comparison return identical results on InfluxDB 3
and the double. The contract suite gains `reference_tests` (the grouping
forms, the position error, and streamed rows equal to queried rows), run
against Local and `influxdb:3-core` (101 tests, 0 failures).

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/http.ex` | `decode_line/1` coerces types |
| `lib/influx_elixir/client/local/sql_parser.ex` | `resolve_references/2`; `group_by_items/1`; `DATE_BIN` anywhere in `GROUP BY` |
| `lib/influx_elixir/client/local/sql_executor.ex` | one grouped aggregation path, `bucket_start/2` |
| `lib/influx_elixir/client/local.ex` | moduledoc |
| `test/influx_elixir/client/local_test.exs` | references block |
| `test/support/client_contract.ex` | `reference_tests` |
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
