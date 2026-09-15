# `Client.Local` Schema Errors for Unknown Columns

**Date**: 2026-09-15
**Scope**: `Client.Local` executor (`check_query_columns/2`)
**Issue**: scheduled quality sweep (generalises the `WHERE` check from #19)

---

## Problem

The #19 fix returned the engine's schema error for an unknown column
inside a `WHERE` expression. Probing the other clauses against InfluxDB 3
Core (`influxdb:3-core`, two rows with `host` and `v`) showed the same
error everywhere and the double answering every one:

| Query | Engine | Double before |
|---|---|---|
| `SELECT nosuch FROM p` | 500 "No field named nosuch" | rows without the column |
| `SELECT host, nosuch AS n FROM p` | 500 | rows without `n` |
| `WHERE nosuch = 1`, `IS NULL`, `IN ('a')` | 500 | `[]` / all rows |
| `ORDER BY nosuch` | 500 | rows in insertion order |
| `GROUP BY nosuch` | 500 | one group |
| `MAX(nosuch)`, `COUNT(DISTINCT nosuch)`, selectors, `first_value` | 500 | column omitted / 0 |
| `DISTINCT nosuch` | 500 | `[]` |
| `WITH w AS (SELECT host FROM p) SELECT nosuch FROM w` | 500 "Valid fields are w.host" | rows |
| `ORDER BY v` with `v` not projected | rows | rows |
| `SELECT host FROM p GROUP BY host` | one row per host | **every row** (GROUP BY ignored) |
| `SELECT host, v FROM p GROUP BY host`; `SELECT host, MAX(v) FROM p` | 400 "must appear in the GROUP BY clause" | **rows** (a group member sampled) |
| `... GROUP BY host ORDER BY t DESC` | ordered | **map order** |

A typo, or a string literal missing its quotes, therefore passed a test
against the double and failed in production.

## Design

One pass collects every source column the query names — projection
sources and expression fields, aggregate arguments, selector fields and
orderings, `first_value` fields and orderings, grouping columns, `WHERE`
keys and expression fields, `GROUP BY` and `DISTINCT` columns, and the
`ORDER BY` column unless it is an output alias — and checks them against
the union of the rows' tags and fields plus `time`. The first missing one
is returned with the engine's wording and status. With no rows the schema
is unknown, so nothing is checked (the engine, which has the schema, would
still error; documented). The check runs after `CROSS JOIN`, so the right
side's columns count.

Two neighbours of the same shape were fixed with it: a `GROUP BY` with no
aggregate now dispatches to the grouped executor (one row per group), a
projected column that is neither grouped nor aggregated is the engine's
planning error instead of a sampled row, and `ORDER BY` is applied to
column-grouped rows as it already was to `DATE_BIN` buckets.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local.ex` | `check_query_columns/2`, `referenced_columns/1`, `output_aliases/1`, moduledoc |
| `test/influx_elixir/client/local_test.exs` | Regression block: every clause, alias ordering, empty-source case |
| `test/support/client_contract.ex` | Four schema-error assertions run against Local and the server |
| `docs/guides/testing-with-local-client.md`, `usage-rules/query.md`, `CHANGELOG.md` | Updated |

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
