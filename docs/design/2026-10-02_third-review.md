# Third Review: Unaliased Items, Empty Ranges, Strict Test Equality

**Date**: 2026-10-02
**Scope**: `Client.Local` SQL (select-list naming, empty ranges, number
literals, field lists, time zones), InfluxQL parse errors and series order,
the store's locks, and the contract and HTTP tests
**Issue**: scheduled quality sweep (no open issues). This reviews commit
55d376b, which agents wrote and nobody had reviewed
([`2026-10-02_local-write-concurrency-retention-and-mixed-types`](2026-10-02_local-write-concurrency-retention-and-mixed-types.md),
[`2026-10-02_local-sql-split-and-second-review`](2026-10-02_local-sql-split-and-second-review.md)).

---

## Problem

Two independent reviews read 55d376b and its tests. Each finding below was
confirmed against InfluxDB 3 Core or InfluxDB 2.7.

**The tests could not tell 1 from 1.0.** In Elixir `%{"v" => 1} ==
%{"v" => 1.0}` is true, so every row assertion written with `==` accepted
an integer where the engine returns a float, and the reverse.

**SQL answers that differed from Core:**
- `SELECT count(*) FROM t`, and every aggregate or expression without
  `AS`, was refused. Core answers and names the column.
- A `time` range left empty by the top-level `AND` returned `[]`. Core
  answers 500 `External error: unexpected: provided filters on time column
  did not produce a valid set of boundaries`.
- The same for a numeric field (`v > 1 AND v < 1`): Core fails with a
  DataFusion internal error, `Only intervals with the same data type are
  comparable, lhs:Null, rhs:Int64.` plus its bug-report tail.
- Integer literals past UInt64 were refused (Core: Float64); `1e400` did
  not lex (Core: null); `abs` of the Int64 minimum returned a value (Core:
  an empty 200, the connection closed mid-response).
- Quoted names in the select list were refused instead of being the
  "No field named" schema error.
- "Valid fields are" listed bare names; Core qualifies each with the table
  and lists the select list first for `ORDER BY` and `GROUP BY`.
- UTC aliases, `Etc/GMT±N`, `EST`/`MST`/`HST` and `:60` were refused.

**InfluxQL:** `GROUP BY r, h` followed the written order (Core sorts by tag
key); `v > --1`, integer overflow, a lone `.` and `; SELECT 2` gave Local's
own wording instead of the engine's positioned parse errors.

**Tests:**
- The HTTP pool-timeout test still flaked: the holder request inherited
  the connection's `pool_timeout: 100`.
- `:local_divergence` tags carried no reason; one `client == Local` branch
  was untagged.
- `System.unique_integer` restarts with every BEAM, so a second run on a
  persistent server reused names.
- Bucket tests deleted their scratch buckets as their last line, so a
  failed assertion leaked them.
- About 35 `on_exit(fn -> Local.stop(conn) end)` calls never did anything:
  the table dies with the test process first.
- Concurrency tests started their tasks without a barrier.
- Byte columns in error bodies were computed by re-spelling `Client.HTTP`'s
  JSON.
- The 14-variant backslash test had been lost.

**A claim that did not reproduce.** The previous design doc gave the
chunked parse's memory as +287 MB for 200k lines. Re-measured: about
170 MB retained and 380-470 MB at peak (above a collected baseline, sampled
every millisecond).

## Decision

- **Unaliased items** are named as DataFusion prints them: `count(*)`,
  `avg(t.v)`, `sum(t.v * Int64(2))`, `Int64(1)`, `Utf8("x")`, `(- t.v)`. A
  name that depends on which side of a `CROSS JOIN` holds a column, and two
  items with one name, are refused by name.
- **Empty time range.** `SQLExecutor.check_time_range` raises the engine's
  500 after the schema, type and optimizer errors, in the engine's order.
  An `OR`, `LIMIT 0` or a constant false keeps it from firing.
- **Empty numeric range** (`SQLBounds`, new). It fires when every top-level
  conjunct is a bound of a bare numeric column (or one the engine folds
  away) and some column is left empty. The wording comes from the first
  conjunct as written: `>`/`>=` gives `lhs:Null, rhs:T`, `<`/`<=` gives
  `lhs:T, rhs:Null`, `=` gives `intersectable`. `T` is that column's type;
  the store's column kinds tell UInt64 from Int64. InfluxQL goes through
  `SQLExecutor.run_influxql/2`, which skips the check, because the engine's
  InfluxQL planner answers `[]`. Shapes whose wording could not be pinned
  are refused by name. About 4,000 random `WHERE` clauses gave no
  difference from Core outside those refusals.
- **Literals.** Int64, then UInt64, then Float64; past the double range is
  null. An Int64 divided by a UInt64 is a decimal truncated to four places.
- **Field lists** are qualified and ordered as the engine orders them. The
  contract asserts the whole body through `ClientContract.no_field/4`.
- **Time zones.** The UTC aliases and fixed-offset names are read; zone
  database names (`Europe/Paris`) stay refused by name.
- **InfluxQL** sorts `GROUP BY` keys and reproduces the parse errors at the
  engine's positions.
- **Store locks.** `:global.trans` backed off for seconds under contention
  (16 concurrent creates of one database took 4.4 s). A lock is now a
  `{:lock, resource}` key inserted with `insert_new` and deleted in
  `after`; a waiter deletes the key of a holder that has died, and a test
  kills a holder to cover that. The two locks never nest.
- **Tests.**
  - Row and value assertions use `===`. No int/float divergence turned up.
  - `IntegrationHelper.unique_name/1` adds the wall clock.
  - Scratch buckets are deleted in `after` (`with_scratch`,
    `with_scratch_many`).
  - Dead `on_exit` calls are gone; concurrency tests release 16 tasks on a
    barrier.
  - `QueryParams.request_body/4` builds the body `Client.HTTP` sends, and
    tests compute byte columns from it.
  - Every `:local_divergence` tag carries its reason.
  - The HTTP holder passes its own `pool_timeout`, and the black-hole
    listener is supervised by the test.

## Not modelled

`trunc()`, `X'..'` literals, `SELECT` without `FROM`, duplicate output
names, `CAST(x AS INT)` as Int32, and a CTE that renames `time` are refused
by name or left as they were. InfluxQL `LIMIT`/`OFFSET` overflow and a
dangling arithmetic operator still differ in wording. (`trunc`, the Int32
cast and InfluxQL `LIMIT`/`OFFSET` overflow were modelled by the next
review,
[`2026-10-02_fourth-review`](2026-10-02_fourth-review.md).)

## Verification

- Unit: 2,216 tests, four runs; credo, dialyzer, docs and both compile
  environments clean.
- Integration on fresh servers, then again on the same servers: Core 304
  tests, InfluxDB 2.7 64 tests, auth-enabled Core tokens 8 tests.
