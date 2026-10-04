# Twelfth Review: One Typing Table, One Projection Plan, an UPDATE Parser

**Date**: 2026-10-05
**Scope**: `Client.Local` SQL typing and UPDATE, InfluxQL projection, the
case-table and cost tests, the `mix test` alias module
**Issue**: scheduled quality sweep (no open issues). This reviews commit
b04c320 ([`2026-10-04_eleventh-review`](2026-10-04_eleventh-review.md)),
which agents wrote and nobody had reviewed. Defects only. The structures
are described in
[`2026-10-04_sql-one-typing-table`](2026-10-04_sql-one-typing-table.md) and
[`2026-10-04_influxql-projection-plan`](2026-10-04_influxql-projection-plan.md).

---

## Problem

The review found raises (`HAVING abs(y)` on a text alias, a leading `;`
before `UPDATE`, InfluxQL `true / abs(time)`), silent wrong answers (an
unsigned field beside text in an InfluxQL `WHERE` kept no point; untyped
`HAVING` aliases; an unbound `$1` in `HAVING`), and regressions (the strict
`UPDATE` grammar refused about 9% of statements the previous build answered
as Core does).

Several traced to structure rather than to single mistakes:
- SQL types were decided in three tables that disagreed, through a
  256-entry linear cache;
- `UPDATE` was matched token by token;
- InfluxQL column names and their order were encoded in three places
  (naming, windowing, the duplicate-name error).

Tests: the duplicate check missed a `:sel` case and its `:raw` spelling, and
a spelling pin could hide a real duplicate; the lock test waited on a 200 ms
negative; the alias test used a fake file system.

## Decision

- **One typing table** (`SQLExprType.node_type/4`), memoised in an exact map
  per query, with the planner's and the coerced type kept apart as the
  engine keeps them.
- **An UPDATE parser**: operands that read no column are accepted, columns
  are schema-checked as the engine checks them.
- **One InfluxQL projection plan** (`InfluxQLProjection.build/2`), in the
  engine's column order, used for naming, `LIMIT`/`OFFSET` per column and
  the duplicate-name error.
- **Every InfluxQL refusal is pinned to its reason**, as SQL's already were.
- **Tests**: duplicate identity is the full statement; each spelling pin
  names whether its members must differ or share an answer; the lock test
  waits on the dropper's state; the cost test bounds the slope of the work;
  `MixTestArgs` is tested on the repository's real paths.

## Known differences left

On two random corpora generated after the fixes (7,036 and 4,677 queries),
nine queries each are further from Core than at the previous commit: nested
expressions with several errors whose order is not pinned, and Decimal128
messages the double refuses to word. Timestamps and `NULL` in `IN`/`BETWEEN`
lists can still be answered where Core errors. A `CASE`/`COALESCE` nest
hundreds deep is still quadratic.

## Verification

- Unit: 2,049 tests, three runs; coverage 92.08%; credo, dialyzer, docs (no
  warnings) and both compile environments clean.
- Integration on fresh `influxdb:3.10.1-core` (`--wal-snapshot-size 100000`)
  and 2.7, run twice: Core 658 tests, InfluxDB 2.7 90 tests; auth-enabled
  Core tokens 8 tests. Core logs a DataFusion panic ("Incorrect number of
  identifiers") for a name of six or seven parts, which closes that query's
  connection, as the cases expect; the server keeps serving.
- Random SQL corpus of 5,898 queries against Core: same answer 3,468 → 4,409,
  a different error 891 → 29, raises 10 → 0.
