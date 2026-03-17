# LocalClient `first()` / `last()` Ordered Aggregate Support

**Date**: 2026-03-17
**Scope**: `InfluxElixir.Client.Local` — add `first(field, ordering)` and `last(field, ordering)` aggregate functions

---

## Problem

`Client.Local` supports `AVG`, `SUM`, `COUNT`, `MIN`, `MAX` but not `first()` or `last()` — the two-argument ordered aggregates available in InfluxDB v3 SQL.

These are required for OHLCV candle aggregation:
```sql
SELECT
  DATE_BIN(INTERVAL '1 hour', time) AS time,
  first(price, time) AS open,
  last(price, time) AS close,
  MIN(price) AS low,
  MAX(price) AS high,
  SUM(volume) AS volume
FROM "trades"
GROUP BY DATE_BIN(INTERVAL '1 hour', time)
ORDER BY time ASC
```

## Design

### Changes to existing aggregate infrastructure

**1. `@aggregate_functions`** — Add `FIRST` and `LAST` to the list.

**2. `select_column` type** — Add a new variant for two-argument ordered aggregates:

```elixir
{:ordered_aggregate, :first | :last, binary(), binary(), binary()}
#                     ^agg     ^field   ^ordering ^alias
```

**3. `parse_agg_column/1`** — Extend the regex to match both forms:
- Single-arg: `FIRST(field) AS alias` / `LAST(field) AS alias`
- Two-arg: `FIRST(field, ordering) AS alias` / `LAST(field, ordering) AS alias`

Single-arg `first(field)` is equivalent to `first(field, time)` — default ordering column is `time`.

**4. `aggregate_per_bucket/2`** — Handle the `:ordered_aggregate` column type by finding the point with min/max ordering column value and returning the field value.

**5. `compute_aggregate/2`** — Add clauses for `:first` and `:last` on single-arg form (order by insertion, which is already time-ordered in ETS).

### Execution semantics

For a bucket of points:
- `first(field, ordering)` → value of `field` from the point where `ordering` is smallest
- `last(field, ordering)` → value of `field` from the point where `ordering` is largest
- `first(field)` → equivalent to `first(field, time)` (InfluxDB default)
- `last(field)` → equivalent to `last(field, time)` (InfluxDB default)

### Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local.ex` | Add FIRST/LAST parsing + execution |
| `test/influx_elixir/client/local_test.exs` | Add first/last aggregate tests |

### No New Files

## Verification

```bash
mix test test/influx_elixir/client/local_test.exs
mix test --cover
mix credo --strict
mix format --check-formatted
```

## Implementation Status

**Completed**: 2026-03-17

All items implemented per design:
- `@aggregate_functions` extended with `FIRST` and `LAST`
- `select_column` type extended with `{:ordered_aggregate, agg, field, ordering, alias}`
- `parse_agg_column/1` handles both single-arg and two-arg forms
- `aggregate_per_bucket/2` dispatches `:ordered_aggregate` to `compute_ordered_aggregate/4`
- `compute_ordered_aggregate/4` sorts points by ordering column, returns field from first/last
- Single-arg `first(field)` / `last(field)` default ordering to `"time"`
- 7 tests added: first, last, full OHLCV candle, single-arg defaults, WHERE filter, empty results
- Documentation updated: `@moduledoc`, testing guide, design doc
- CI: 614 tests pass, 0 failures, 90.04% coverage, 0 Credo issues, format clean
