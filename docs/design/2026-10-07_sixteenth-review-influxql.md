# Sixteenth Review (InfluxQL, tests): Parse Errors by Position, No Clock in Tests

**Date**: 2026-10-07
**Scope**: `Client.Local` InfluxQL parsing and its invalid-UTF-8 handling (and
Flux's); the unit tests' load sensitivity, atom coverage, cost bounds and clocks
**Issue**: scheduled quality sweep (no open issues). This reviews commit
24b300f ([`2026-10-06_fifteenth-review-influxql`](2026-10-06_fifteenth-review-influxql.md)).
Defects only. The SQL half is
[`2026-10-07_sixteenth-review-sql`](2026-10-07_sixteenth-review-sql.md).

---

## Problem

- **Silent wrong answers:** `WHERE f OR =~ /a/` and `(x AND )` answered `[]`
  where the engine reports `invalid conditional expression`.
- **Wrong error text:** a call in a `WHERE` got the call error even when its
  arguments do not parse (`fill(+)`). A later clause's error could hide an
  earlier parse error. `fill(-\f1)` was accepted.
- **A raise:** InfluxQL and Flux text that is not valid UTF-8, and such a
  database name, raised `ArgumentError`.
- **Tests:**
  - three tests failed under heavy CPU load on fixed 5- and 30-second bounds
    (the unexplained seed-77 failure);
  - the atom test skipped Flux, line protocol tags, admin names and query
    parameters;
  - cost tests had no lower bound;
  - batch-writer refutations could pass with a retry still pending;
  - telemetry bracketed the wall clock.

## Decision

- **Arguments are read as the engine reads them.** `InfluxQLArgs` returns
  the position where the engine fails, or `:unknown`, which is refused by
  name. Parse errors from every clause are ordered by position, and the
  leftmost wins.
- **Invalid UTF-8 is refused by name** at the InfluxQL and Flux entry points
  and in database names.
- **Tests:**
  - the load-sensitive tests start Finch pools eagerly and give the holder a
    checkout bound far beyond any load;
  - every cost test pins the refusal it measures and has both bounds;
  - batch-writer refutations stop the writer first;
  - telemetry checks the wall clock against monotonic time within a tolerance.

## Known differences left

- About 3 to 4% of mutated InfluxQL statements still get a wrong body, on
  24b300f and now alike: clause keywords glued to an operator (`GROUP BY*`,
  `LIMIT.2`, `ORDER  BYhost`), and time-comparison planning errors.
- `SELECT -/a/` reports its error at the wrong position. `date_part('hour',
  time) = 22` is refused, where the engine answers `[]`.
- A batch-writer retry test failed once, on seed 55, while agents were
  editing library code. It did not recur in six full runs at seed 55 under
  about seven times the normal load.

## Verification

- Unit: 2,111 tests, three runs; coverage 92.66% (`InfluxQLArgs` 100%,
  `InfluxQLTokens` 95.4%); credo, dialyzer, docs (no warnings) and both compile
  environments clean. Six simultaneous full runs at seed 55 under about seven
  times the normal load: 0 failures.
- Integration on fresh `influxdb:3.10.1-core` (`--wal-snapshot-size 100000`)
  and 2.7, run twice: Core 675 tests, InfluxDB 2.7 90 tests; auth-enabled
  Core tokens 8 tests. The only Core panics are the known DataFusion
  "Incorrect number of identifiers" for six- and seven-part names.
- Four fresh InfluxQL corpora (about 73,000 statements): wrong bodies 8,520 to
  2,001, 1,611 to 999, 4,269 to 971 and 1,226 to 775 (24b300f to now); none
  that 24b300f answered right or refused is a wrong body now; no raise.
