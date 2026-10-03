# Local Applies a v3 Database's Retention

**Date**: 2026-10-03
**Scope**: `Client.Local` (`Store`, `Retention`, `Admin`, `Scope`, `InfluxQLQuery`,
`InfluxQLShow`), `InfluxElixir.Admin.Databases` docs, the testing guide
**Issue**: confirmed wrong answer: `create_database(conn, name, retention: "1h")`
validated the period and discarded it
**Supersedes**: the "stores no retention" half of
[`local-retention-and-health`](2026-09-29_local-retention-and-health.md)

---

## Problem

On InfluxDB 3 Core (`--wal-flush-interval 10ms`, no auth) a database created
with `retention_period: "1h"` hides a point older than an hour, and
`SHOW RETENTION POLICIES` prints `1h0m0s`. `Client.Local` returned both rows
and `0s`.

## What Core does (probed with `curl`, 2026-10-03)

- **A write is never refused for age.** `m v=1i <now-2h>` is 204, alone or
  mixed with a live point, with `accept_partial` unset, `false` or `true`.
  There is no error body.
- **A read hides.** `SELECT v FROM m ORDER BY time` returns only the live
  point; InfluxQL `SELECT`, `SELECT count(*)` (`0` for a table of expired
  points) and `SHOW TAG VALUES` (`[]` for expired values) agree. InfluxQL has
  no `DELETE` (`This feature is not implemented: DELETE`); the table delete
  (`DELETE /api/v3/configure/table`) works on a table of expired points.
- **The unit of expiry is a chunk, not a point.** 30 tables each with an
  expired point `X` and a live point `Y` 400 s later: `X` was shown exactly
  when `X` and `Y` fell in the same 600-second window (a multiple of 600 s
  since the epoch; the prediction matched all 30), and hidden when `Y` was in
  the next window. A table whose newest point in a window is expired hides
  that whole window. The same held for rows persisted to Parquet
  (`system.parquet_files`), where the engine's files are per window.
- **The cut-off is `now - retention` at query time**, moving with the
  clock: a point at `T` was visible at wall second `T+3599` and gone at
  `T+3600`. Whether the cut-off is inclusive cannot be seen at a
  nanosecond; the double hides a chunk whose newest point is before it.
- **The schema stays.** Tables and columns that only expired points created
  remain in `information_schema.tables|columns`, `SHOW MEASUREMENTS`,
  `SHOW TAG KEYS` and `SHOW FIELD KEYS`.
- **Zero is a period.** `"0"`, `"0h"` and anything under a second store
  `retention_period_ns = 0`, which hides every point before now (a future
  point stays). It is not "no retention".
- **The period** is Rust `humantime`: whole seconds are kept (`1500ms` and
  `1999ms` are `1s`, `1m500ms` is `1m0s`), a month is 30.44 days and a year
  365.25 days.
- **`SHOW RETENTION POLICIES`** is `[{"iox::database": db, "name": "autogen",
  "duration": d}]`, `d` in Go's format: `1h`→`1h0m0s`, `90m`/`1.5h`→`1h30m0s`,
  `1d`→`24h0m0s`, `7d`/`1w`→`168h0m0s`, `30s`→`30s`, `10min`→`10m0s`,
  `1M`→`730h33m36s`, `1y`→`8766h0m0s`, `2y`→`17532h0m0s`, `3months`→
  `2191h40m48s`, `0` and a database without one→`0s`. Without `ON` and without
  a `db` it lists every database (`_internal` is `168h0m0s`); `ON x` with a
  different `db` is a 400 (unchanged).
- `GET /api/v3/configure/database?format=json` lists names only. The retention
  is in `system.databases.retention_period_ns` (absent for none; `_internal`
  `604800000000000`), which the double refuses by name as before.
- **Changing it**: `PUT /api/v3/configure/database {"db","retention_period"}`
  is 200 (without `retention_period` it clears it; unknown database 404;
  bad period 400); `DELETE /api/v3/configure/database/retention_period?db=`
  is 204. `POST` of an existing database is 409 and changes nothing.
  `PATCH` is 404, and InfluxQL `CREATE`/`ALTER RETENTION POLICY` are parse
  errors. `Client.HTTP` has no call for the update, so the double has none.
- **Enterprise**: nothing in the repository documents its retention;
  unverified. The double applies Core's rule to both v3 profiles.

## Design

`Store` keeps `{:retention, db} => seconds` for a database created with a
period (`Store.create_database/4`; a database that exists is untouched, as the
engine's 409; a drop removes it). `Retention` (new) holds the grammar, the
seconds, the Go format and `visible/3`, which `Store.points/3` and
`Store.points_in_db/3` apply, so SQL, InfluxQL, `SHOW TAG VALUES` and the
information schema all read through one rule. The schema is not touched.
`Scope.retention/2` gives `_internal` seven days; `SHOW RETENTION POLICIES`
prints each database's.

Not modelled: a window the engine has split across Parquet files by writes on
either side of a snapshot (each file would expire alone). The Enterprise
`DELETE FROM` counts stored rows, expired ones included (unverified).

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/store/retention.ex` | new: grammar, format, chunk rule |
| `lib/influx_elixir/client/local/store/store.ex` | retention kept, dropped, applied on read |
| `lib/influx_elixir/client/local/admin/admin.ex` | the period is stored, not discarded |
| `lib/influx_elixir/client/local/shared/scope.ex`, `influxql/influxql_query.ex`, `influxql/influxql_show.ex` | `SHOW RETENTION POLICIES` prints it |
| `lib/influx_elixir/client/local.ex`, `lib/influx_elixir/admin/databases.ex` | docs |
| `docs/guides/testing-with-local-client.md` | Retention section, SHOW |
| `test/support/contract/retention_contract.ex` | new contract |
| `test/influx_elixir/client/contract_local/{v3_core,v3_enterprise}/retention_test.exs`, `test/integration/contract_v3_core/retention_test.exs` | wiring |
| `test/influx_elixir/client/local/retention_test.exs` | grammar, format, `SHOW` without a database |

## Verification

`mix test`, `mix credo --strict`, `MIX_ENV=test mix compile --force
--warnings-as-errors` and `mix dialyzer`; the contract against Core with
`mix test --include integration --include v3_core
test/integration/contract_v3_core/retention_test.exs`.
