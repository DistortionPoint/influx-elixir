# LocalClient Aggregate SQL Support

**Date**: 2026-03-17
**Scope**: `InfluxElixir.Client.Local` — add DATE_BIN + aggregate function support to the SQL query engine

---

## Problem

`Client.Local.query_sql/3` only supports `SELECT * FROM measurement`. Any SQL with
aggregate functions (`AVG`, `SUM`, `COUNT`, `MIN`, `MAX`) or `DATE_BIN(INTERVAL ...)`
returns `{:error, %{status: 400, body: "unsupported SQL: ..."}}`.

This blocks consuming applications from testing time-bucketed aggregate queries — a
core InfluxDB v3 SQL feature.

## Target SQL Pattern

```sql
SELECT
  DATE_BIN(INTERVAL '1 hour', time) AS time,
  AVG(value) AS value
FROM "system_metrics"
WHERE time >= $start_time AND time < $end_time
GROUP BY DATE_BIN(INTERVAL '1 hour', time)
ORDER BY time ASC
```

## Design

### Approach: Detect query type, dispatch to correct parser

`parse_select/1` inspects the SQL to determine the query type:

- Contains `SELECT *` → passthrough parser (existing logic, unchanged)
- Contains aggregate functions (`AVG`, `SUM`, `COUNT`, `MIN`, `MAX`) or `DATE_BIN` → aggregate parser

Single dispatch point, no try-and-fallback.

### Aggregate Parser

Extract from the SQL:
- **FROM** — measurement name (quoted or unquoted)
- **SELECT columns** — each is either:
  - `DATE_BIN(INTERVAL '<n> <unit>', time) AS <alias>` → time bucket column
  - `AGG(field) AS <alias>` where AGG is AVG/SUM/COUNT/MIN/MAX → aggregate column
- **WHERE** — reuse existing `parse_where/1`
- **GROUP BY** — detect `DATE_BIN(INTERVAL ...)` presence (interval must match SELECT)
- **ORDER BY** / **LIMIT** — reuse existing parsers

### Extended `parsed_query` type

```elixir
@type parsed_query :: %{
  measurement: binary(),
  where: [{atom(), binary(), term()}],
  order_by: {:time, :asc | :desc} | nil,
  limit: pos_integer() | nil,
  # New fields for aggregate queries:
  group_by_interval: pos_integer() | nil,   # nanoseconds
  select_columns: [select_column()] | nil   # nil = SELECT *
}

@type select_column ::
  {:time_bucket, binary()}                          # {alias}
  | {:aggregate, :avg | :sum | :count | :min | :max, binary(), binary()}  # {agg, field, alias}
```

### Execution Pipeline (aggregate path)

```
fetch_points → apply_where → bucket_by_interval → aggregate_per_bucket →
  apply_order_by → apply_limit → format_rows
```

**bucket_by_interval**: Group points by `div(timestamp, interval_ns) * interval_ns`.

**aggregate_per_bucket**: For each bucket, compute each aggregate:
- `AVG` — sum / count of numeric values (skip nils)
- `SUM` — sum of numeric values
- `COUNT` — count of non-nil values
- `MIN` / `MAX` — min/max of numeric values

**format_rows**: Build maps with aliased keys. Time bucket column gets the bucket
start timestamp.

### Interval Parsing

`INTERVAL '<n> <unit>'` where unit is:
- `second` / `seconds` → n * 1_000_000_000
- `minute` / `minutes` → n * 60_000_000_000
- `hour` / `hours` → n * 3_600_000_000_000
- `day` / `days` → n * 86_400_000_000_000

### Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local.ex` | Add aggregate SQL parser + execution |
| `test/influx_elixir/client/local_test.exs` | Add aggregate query tests |

### No New Files

All changes go into the existing LocalClient module and its test file.

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
- `parse_aggregate_select/1` — dispatches aggregate SQL through dedicated parser
- `parse_select_columns/1` — extracts DATE_BIN and AGG() columns with aliases
- `parse_aggregate_from/1` — extracts measurement (quoted and unquoted)
- `parse_group_by_interval/1` + `parse_interval/1` — INTERVAL to nanoseconds
- `bucket_by_interval/2` — groups points by `div(ts, interval) * interval`
- `aggregate_per_bucket/2` — computes AVG/SUM/COUNT/MIN/MAX per bucket
- `apply_order_by_rows/3` — sorts aggregate rows by time bucket alias
- `parse_where/1` updated to stop at GROUP BY clause
- 14 aggregate query tests added (94 total in local_test.exs)
- CI checks: 0 test failures, 90.05% coverage, 0 Credo issues, format clean
