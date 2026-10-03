# Seventh Review: Wrong Groupings, Refusal Rates, Retention, One Fact Once

**Date**: 2026-10-03
**Scope**: `Client.Local` (InfluxQL `GROUP BY` and functions, SQL expressions
and errors, v3 database retention), the contract and Local test files, test
compile cost and coverage
**Issue**: scheduled quality sweep (no open issues). This reviews commit
69cf692 ([`2026-10-02_sixth-review`](2026-10-02_sixth-review.md)), which
agents wrote and nobody had reviewed. Engine rules settled here are in
[`2026-10-02_influxql-planner-and-module-split`](2026-10-02_influxql-planner-and-module-split.md),
[`2026-10-02_local-sql-simplifier-and-intervals`](2026-10-02_local-sql-simplifier-and-intervals.md)
and
[`2026-10-03_local-database-retention`](2026-10-03_local-database-retention.md).

---

## Problem

**Wrong answers.**
- InfluxQL `GROUP BY time(5m), *`, `GROUP BY /re/`, a field as a dimension,
  and malformed `GROUP BY`/`fill()` text were answered with the grouping
  silently dropped: any unparsed dimension became a tag that does not
  exist.
- An InfluxQL `OR` naming a column the measurement lacks found no rows.
- A v3 database's `retention:` was validated and discarded: the double
  returned expired rows and reported `0s` where Core hides them and reports
  the period.

**A hang.** `GROUP BY time(1s) fill(none)` from 1970 walked every bucket
(20 s and more; Core answers in 0.02 s).

**Refusal rates on realistic dashboard corpora.** InfluxQL refused 37% of
what Core answers (`percentile`, `derivative`, `top`, math functions,
`SHOW … LIMIT`, `FROM /re/`); SQL refused 57% (aggregate arithmetic,
`HAVING`, `CASE`, `COALESCE`, string and math functions,
`information_schema`). Some SQL errors had the engine's shape but not its
text.

**Performance.** InfluxQL queries took 15-25% more reductions than the
commit before, and an answerable SQL guarded division 218% more.

**Tests.** Adding four contracts had left their facts pinned two or three
times, in older contracts and in Local files; the Flux contract wrote
points at `now` and read `-30s`; the tag lint missed aliased spellings; the
BatchWriter trace pattern was global and never removed; case tables stopped
at their first mismatch; `mix test` compiled 65 integration modules it then
excluded (about 23 s of CPU); coverage had fallen below CI's 90% threshold
because new SQL modules were barely exercised.

## Decision

- **InfluxQL `GROUP BY`** is parsed by `InfluxQLGroup.extract/3`: each
  dimension is `*`, `/re/`, a name with an optional `::type`, or `time()`,
  and anything else is the engine's positioned parse error. `fill(none)`
  reads only buckets that hold points; the row cap is configurable
  (`:local_influxql_max_rows`, default 2,000,000) and refuses by name, never
  truncates.
- **Functions and statements** dashboards send are modelled, each verified
  on Core; what stays refused is listed in the testing guide.
- **Retention** is stored and applied as Core applies it: writes of any age
  are accepted, reads hide a 10-minute chunk once its newest point is past
  `now - retention`, and `SHOW RETENTION POLICIES` prints Go durations.
- **SQL** errors come from one `SQLSyntax` that gives the parser's own
  messages; guards probe rows only when an operand can actually fail.
- **One fact, one place.** Duplicates were deleted after any unique
  assertion moved; Local files hold only refusals and Local mechanics.
  `ClientContract` is a dispatcher over seven part files.
- **Test helpers.** `TestSupport.Check` reports every failing case at once
  and compares order-dependent floats with a relative tolerance of 1e-12.
  The BatchWriter tests trace through a per-test `:trace` session.
- **`mix test`** passes only non-integration paths unless `INTEGRATION=1`
  or a `test/integration` path is given.

## Engine bugs observed

InfluxDB 3 Core panicked twice while being probed: `timestamp wraparound`
in a snapshot after retention-enabled writes (the write path then hangs
until restart), and an `Option::unwrap()` on `None` in DataFusion's SQL
planner. Neither is reported upstream from here.

## Verification

- Unit: 2,012 tests, three runs; coverage 92.21% (CI threshold 90%);
  credo, dialyzer, docs (no warnings) and both compile environments clean.
- Integration on fresh servers, run twice: Core 625 tests, InfluxDB 2.7 91
  tests; auth-enabled Core tokens 8 tests. Core did not panic under the
  suite; its panics came from heavier probing.
- Differential corpora against Core: InfluxQL 167 dashboard statements
  (refusals 62 → 4), SQL 162 (93 → 37), about 1,700 scalar and catalog
  cases with no difference.

## Known differences left

`WHERE lower(1) IS TRUE` reports the `IS TRUE` type error first where Core
reports the call's; `SELECT 1; DELETE FROM` gives the 405 where Core gives
`Expected: identifier`. Both are error bodies for rare malformed input.
