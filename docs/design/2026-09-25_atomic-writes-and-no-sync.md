# Atomic Writes (`accept_partial`) and `no_sync`

**Date**: 2026-09-25
**Scope**: `Client.HTTP.write/3`, `Client.Local` write path, `LineProtocolParser`, `Store`
**Issue**: scheduled quality sweep

---

## Problem

InfluxDB 3's `/api/v3/write_lp` takes `accept_partial` (default `true`)
and `no_sync` (default `false`). `HTTP.write/3` built the URL from `db`
and `precision` only, so a consumer could not ask for an all-or-nothing
write — the only way to keep a half-written batch out of the database.
Probed on `influxdb:3-core`:

| Write | Engine |
|---|---|
| `accept_partial=false`, lines 2 and 3 bad | 400 `{"error":"line protocol parsing error","data":{"error_message":…,"line_number":2,…}}`, nothing stored |
| `accept_partial=false`, line 2 conflicts with line 1's type | 400, line 2 reported, nothing stored, table not created |
| `accept_partial=false`, clean payload | 204 |
| `accept_partial=bogus` / `FALSE` | 400 `serde error: provided string was not `true` or `false`` |
| `no_sync=true` | 204; a query 300 ms later did not see the point yet |

Checking the double against these exposed two more divergences:

| | Engine | Double before |
|---|---|---|
| `m    v=1i   1` (runs of spaces) | accepted | 400 "No fields were provided" |
| schema error for `r v=2.0 2` | `original_line` `r v=2 2` | `r v=2.0 2` |

For a schema error the engine reports the line as it parsed it: single
spaces, floats printed shortest and never in exponent form (`2.50` →
`2.5`, `1e3` → `1000`, `1.5e-7` → `0.00000015`, `-0.0` → `-0`),
integers and unsigned integers with their suffix, strings unquoted, tags
and fields in the order written. Parse errors show the raw line.

## Decision

- `HTTP.write/3` appends `&accept_partial=…` / `&no_sync=…` when the opt
  is given, on v3 connections only (InfluxDB 2's endpoint has neither).
- `Client.Local`: both flags must be booleans (else the engine's 400).
  With `accept_partial: false` every line is dry-run against the stored
  schema plus the payload's pending columns (`Store.column_kind/4`, no
  registration), including the reserved-`time` wording that depends on
  whether the table exists; the first error in line order is returned in
  the engine's shape, otherwise the payload is stored as usual. `no_sync`
  is a no-op: the double has no write-ahead log, and a point that is
  visible at once is what a `no_sync` write converges to.
- `LineProtocolParser.schema_error/3` builds a schema error with the
  engine's rendering (`render_line/1`, `render_float/1`); runs of spaces
  between sections are one separator.
- The `:v2` profile ignores both flags.

## Verification

9 of 9 atomic/`no_sync` comparisons and 10 of 10 renderings match the
engine. Contract `atomic_write_tests` run against Local and the engine
(v3 106/0, v2 23/0).

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/http.ex` | `write_flags/2` |
| `lib/influx_elixir/client/local.ex` | `write_flag/4`, `store_lines_atomically/3`, `dry_check/4`, `point_columns/2`; `reserved_time/2` takes whether the table exists |
| `lib/influx_elixir/client/local/store.ex` | `column_kind/4` |
| `lib/influx_elixir/client/local/line_protocol_parser.ex` | `schema_error/3`, `render_line/1`, `render_float/1`; empty sections dropped |
| `lib/influx_elixir.ex` | `write/3` options documented |
| `test/influx_elixir/client/local_test.exs`, `test/support/client_contract.ex` | tests |
| `usage-rules/write.md`, `CHANGELOG.md` | Updated |
