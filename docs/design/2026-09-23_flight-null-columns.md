# Flight Rows Omit Null Columns

**Date**: 2026-09-23
**Scope**: `Flight.Reader` row assembly
**Issue**: scheduled quality sweep

---

## Problem

`usage-rules/query.md` says a null column is absent from the row, not
present as `nil`, and InfluxDB 3's JSON does leave it out. The Flight
reader built every row from every schema column, so a null cell became
a `nil` key. The same query returned different maps over `transport:
:http` and `transport: :flight`.

Probed against `influxdb:3-core`: 25,000 points across 7 series, with a
tag present on only some series, integer, unsigned, float, string and
boolean fields, some string fields missing, spread over several Arrow
record batches. Four queries (`SELECT *` with and without `LIMIT`, a
projection of the sparse columns, a `GROUP BY`) compared row by row:

| Comparison | Mismatching rows (of 25,000) |
|---|---|
| strict equality, before | 11,667 |
| after dropping `nil` keys from Flight rows | 0 |
| strict equality, after the fix | 0 |

So nulls were the only difference; every type, tags included, decodes
identically.

## Decision

`zip_columns/3` skips a `nil` cell instead of storing it. It must not
drop `false`, which a comprehension filter such as
`value = cell(col, i), value != nil` would do (a match in a `for` is a
filter on the value's truthiness). The reader's null tests now assert
`refute Map.has_key?/2`, since `row["v"] == nil` could not tell the two
shapes apart. The v3 integration suite compares a sparse row over both
transports.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/flight/reader.ex` | `zip_columns/3` omits nulls; moduledoc |
| `test/influx_elixir/flight/reader_test.exs` | null tests assert absence |
| `test/integration/contract_v3_core_test.exs` | Flight vs HTTP sparse-row test |
| `usage-rules/query.md`, `CHANGELOG.md` | Updated |

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
