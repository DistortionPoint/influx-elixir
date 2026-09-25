# `Client.Local.Store`: One Module Owns the ETS Layout

**Date**: 2026-09-25
**Scope**: `Client.Local` storage, clock
**Issue**: scheduled quality sweep (maintainability)

---

## Problem

`local.ex` had grown to 1,583 lines: the behaviour facade, profiles, the
write rules, the InfluxQL/Flux wiring, admin, and every storage detail.
The ETS key layout (`{:point, db, m, seq}`, `{:series_time, ...}`,
`{:duplicates, ...}`, `{:column, ...}`, the registries) was used directly
in 40 places, including the InfluxQL `SHOW` commands, the Flux bucket
check and the admin functions. Changing the layout — as the last three
sweeps did — meant finding every pattern by hand.

Moving the storage out exposed a latent flake: the double read three
clocks. Untimed points and Flux `now()` used `System.system_time/1`, SQL
`now()` used `System.os_time/1`; measured, `system_time` lagged
`os_time` by about 27 µs, so a test point stamped with `os_time` could be
after the double's Flux `now()` and fall out of `range(start: -1h)`. The
three predicate tests that write "now" with `os_time` failed whenever the
suite's timing let the query land inside that window.

## Decision

`InfluxElixir.Client.Local.Store` owns the table and the layout:
lifecycle (`new/1`, `drop/1`), registries (databases, buckets, tokens),
points (`store_point/3`, `points/3`, `points_in_db/2`, `measurements/2`,
`measurement?/3`, `delete_points/4` taking a match function so the store
stays free of SQL), the column schema (`register_column/5`, `table?/3`,
`columns/2`, `tag_columns/3`) and the clock. It is policy-free: which
writes are valid, which errors the engine returns and how rows are shaped
stay in `Client.Local` and the parser/executor modules. Code moved
verbatim; `local.ex` has no `:ets` call left.

`Store.now_ns/0` is the later of `os_time` and `system_time`, used for
stamping untimed points and for SQL and Flux `now()`. Flux's `stop` is
exclusive and macOS `os_time` has microsecond resolution, so a write and
the query right after it can read the same value; Flux's `now()` is
`now_ns() + 1`, which is what a real server guarantees by the query
following the write.

## Verification

Unit suite three times and six more full runs: 1272 tests, 0 failures.
`Store` coverage 100%. v3 integration 104/0, v2 23/0. A separate one-off
`Writer` test timeout (Finch pool start under a machine busy with
benchmark loops) did not recur in the later runs.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/store.ex` | New |
| `lib/influx_elixir/client/local.ex` | uses `Store`; storage helpers removed; docs |
| `lib/influx_elixir/client/local/sql_executor.ex` | SQL `now()` from `Store.now_ns/0` |
| `CHANGELOG.md` | Updated |
