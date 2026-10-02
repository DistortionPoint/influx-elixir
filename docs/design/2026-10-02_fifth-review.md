# Fifth Review: Performance, Simplifier, Test Layout

**Date**: 2026-10-02
**Scope**: `Client.Local` (SQL performance and optimizer rules, InfluxQL
planner, module splits), the test suite's layout, helpers and assertions
**Issue**: scheduled quality sweep (no open issues). This reviews commit
e71cf7b ([`2026-10-02_fourth-review`](2026-10-02_fourth-review.md)), which
agents wrote and nobody had reviewed. The engine behaviour it settled is
recorded in
[`2026-10-02_local-sql-simplifier-and-intervals`](2026-10-02_local-sql-simplifier-and-intervals.md)
and
[`2026-10-02_influxql-planner-and-module-split`](2026-10-02_influxql-planner-and-module-split.md);
this document records the review itself and the test-side decisions.

---

## Problem

**Performance.** e71cf7b made common queries 30-100% slower at 100k
points: `SELECT *` and InfluxQL scanned every point for column names an
`ORDER BY` position might need, every result cell was converted after the
fact, the value-range check made a second pass for column types, and
InfluxQL lost the `SELECT *` fast path and lower-cased every column of
every row.

**A scratch script was committed under `lib/`** and would have shipped in
the Hex package.

**Engine behaviour still differing** (confirmed on Core; the details are in
the two linked documents): the optimizer's simplifier and interval analysis
over casts and decimals, batch evaluation of `AND`/`OR`, UInt64 against
literals past its range, InfluxQL unsigned arithmetic, the `time` column,
parentheses, and two parse errors e71cf7b had broken.

**Tests.**
- One ExUnit module per profile `use`d five contracts. Compiling it took
  14 s with every test excluded, and it set the suite's wall time.
- Helpers were copied across files: two hand-written TCP servers, three
  telemetry forwarders, three token-field droppers, two pollers.
- About 33 assertions dropped a `time` column the test could have known, by
  writing untimed points.
- The batch writer's retry tests timed real backoffs against stats calls;
  one polled with no deadline; three duplicated others.
- Tests inspected private ETS keys; four Local-only tests restated contract
  facts.

## Decision

- **Performance.** Columns for `ORDER BY` positions are read only when a
  position is used; cells are converted only when a row holds a value that
  needs it; column types come from the store's column kinds; InfluxQL's
  `SELECT *` fast path is back and the time test is compiled once per
  statement. Measured in reductions, which other load cannot skew: every
  SQL query within 10% of b98d373 (most within 5%), InfluxQL within 4%.
- **Modules.** `influxql.ex` and `line_protocol_parser.ex` are entry points
  over modules by seam; the SQL expression walkers share
  `SQLExpr.children/1`.
- **Test layout.** Each contract takes a `part:` option, and each profile
  runs every part as its own async module
  (`test/influx_elixir/client/contract_local/<profile>/`,
  `test/integration/contract_<profile>/`), set up by
  `InfluxElixir.ContractLocal` and `InfluxElixir.ContractServer`. The
  largest module now compiles in about 1 s, and `mix test` takes 8-10 s
  instead of 27-41 s. Integration modules each have their own Finch pool
  but stay `async: false`: Core allows five databases.
- **Helpers** live in `test/support`: `InfluxElixir.TestServer` (black-hole
  and test-answered listeners on 127.0.0.1, under the test's supervisor),
  `TestSupport.Await.until/2`, `TestSupport.Telemetry`,
  `TestSupport.Tokens.public/1`.
- **Assertions.** Tests write timestamps and compare whole rows; relative
  Flux ranges bracket `_stop` with the double's clock and pin the width.
  Batch-writer retries are answered by the test, which counts the requests
  and pins the final body. Private-key checks became public reads.
- **Engine-bug pins** carry `@tag engine_bug: "…"`, so a Core upgrade that
  fixes one is found at once.

## Integration speed

The Core suite took 8½ minutes. The `query_delay` sleep was not the cause:
Core and 2.7 are read-your-writes (200 write-then-read pairs on each, none
missing), so it is now 0. The cause was the server: InfluxDB 3 Core answers
a write once its write-ahead log flushes, every second by default, and the
contracts write about 500 times. Started with `--wal-flush-interval 10ms`, a
write takes about 20 ms and the suite 18 s, with the same 460 answers. The
one-liners in [`README`](README.md) and the testing guide say so.

Row order without `ORDER BY` is not deterministic on Core, so Local keeps
time order and the guide says to order.

## Verification

- Unit: 2,751 tests, three runs; credo, dialyzer, docs (no warnings) and
  both compile environments clean.
- Integration on fresh servers: Core 460 tests (with the 1 s flush, then
  three runs with the delay removed, then on the 10 ms flush), InfluxDB 2.7
  64 tests (four runs), auth-enabled Core tokens 8 tests.
- Performance in reductions at 100k points against b98d373: every SQL query
  within 10%, InfluxQL `SELECT *` +2.9%, `WHERE` +4.0%, `GROUP BY` +0.9%.
