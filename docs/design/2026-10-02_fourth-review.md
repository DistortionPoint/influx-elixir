# Fourth Review: Overflow, Unsigned Columns, Narrow Casts, Exact Tests

**Date**: 2026-10-02
**Scope**: `Client.Local` SQL (float overflow, UInt64 columns, Int32/Int16/Int8
casts, constant folding, `trunc`, naming), InfluxQL (reserved words, second
statements, `LIMIT`/`OFFSET` range, typed comparisons), the store lock, and
the test suite
**Issue**: scheduled quality sweep (no open issues). This reviews commit
b98d373
([`2026-10-02_third-review`](2026-10-02_third-review.md)), which agents
wrote and nobody had reviewed.

---

## Problem

Two independent reviews read b98d373; their findings, and the further ones
the fixes turned up by differential fuzzing, were confirmed against
InfluxDB 3 Core.

**Wrong answers and crashes in Local SQL:**
- A float overflow raised `ArithmeticError` out of `query_sql`
  (`f * 1e308 * 1e308`, a `sum` past the double range). The engine answers
  `null` and compares the infinity as a number.
- An unsigned field was evaluated as Int64: `u / 2` gave `2` where the
  engine gives the decimal `2.5000`; `-u` answered where the engine refuses
  the negation; sums wrapped at the wrong width.
- `CAST(x AS INTEGER)` was Int64; on the engine `INTEGER` is Int32,
  `SMALLINT` Int16 and `TINYINT` Int8.
- A failing constant in `WHERE` closed the connection where the engine's
  optimizer folds it into a 500.
- A qualified reference to a column both sides of a `CROSS JOIN` have gave
  an "Ambiguous reference" 500 the engine does not give.
- `(v)` was named `t.v`, an unaliased `1e400` was refused, `trunc` was
  refused, and `ORDER BY` positions on `SELECT *` failed.

**InfluxQL:** reserved words (`tag`, `name`, `key`, `field`, …) were
accepted as bare identifiers; a failing statement after `;` got an invented
parse error; `LIMIT` past Int64 answered; a boolean field compared with a
number and a negative number compared with an unsigned field answered
differently from the engine.

**Store lock:** a holder that took its own lock again spun forever.

**Tests:**
- About 150 assertions matched a partial map, which ignores extra keys, and
  about 75 compared numbers with `==`, which cannot tell 1 from 1.0.
- The batch writer's backpressure test depended on a 1.2 s wall-clock
  margin and took 3 s.
- Five tests carried a `local_divergence` tag although both clients give the
  same answer; four tests duplicated contract facts.
- A test left a writer with buffered data, whose shutdown log escaped
  `capture_log`.

**Docs:** the CHANGELOG still gave the memory figure the previous review
found did not reproduce, and counted four error wordings where there are
three.

## Decision

- **Numbers.** `SQLNumber` carries Int8/16/32/64, UInt64, decimals and
  floats with the engine's non-finite values: a response shows them as
  null, comparisons use the engine's total order. Unsigned columns are
  typed from the store's column kinds once per query.
- **Casts.** The width is carried through evaluation; two narrow integers
  wrap at the wider width, a narrow with an Int64 widens. A cast compared
  with an integer literal in `WHERE` is unwrapped as the engine's optimizer
  does. `SQLFold` raises the optimizer's 500 for a failing constant cast;
  `SQLBounds` raises the overflow 500 for a negated minimum where the
  engine's interval analysis reaches it. `FLOAT`/`REAL`, unsigned and
  `DECIMAL` casts are refused by name.
- **Executor split.** `sql_executor.ex` went from 2,263 lines to the
  pipeline alone; evaluation, aggregates, sorting, typing, planning
  errors, schema errors, joins and range checks are their own modules.
  Limits and the negation walk are shared (`SQLLimits`, `SQLPredicates`).
- **InfluxQL.** The engine's reserved-word list is carried into the parser
  with its positioned errors; a second statement is parsed on its own and
  its error shifted to its offset, or refused by name; typed comparisons
  follow the engine's rules (a mismatched kind is false for every row; a
  negative literal against an unsigned field compares as `2^64 + n - 1`).
- **Lock.** Taking a lock already held by the caller raises.
- **Tests.** Whole results are compared with `===`; a deliberately unknown
  column is dropped with a comment. The backpressure test is driven by a
  listener the test answers, and still fails when the end of one chain
  clears another's in-flight marker (checked by breaking that logic). Tags
  mark only tests with a client branch.

## Refused by name

NaN comparisons (the engine orders a NaN by its sign bit); decimals past
38 digits; `avg` of a decimal; narrow integers mixed with UInt64 or
decimals; a CTE that casts to a narrow integer; casts of timestamps; a
qualified shared column in a `CROSS JOIN`; InfluxQL statements after `;`
that the double cannot read.

## Not modelled

The engine simplifies `A AND (B OR A)` to `A` and `K = K` to true before a
failing constant in them runs; Local evaluates them and closes the
connection. Float aggregates may differ from the engine in the last digit,
since they depend on iteration order.

## Verification

- Unit: 2,441 tests, three runs; credo, dialyzer, docs and both compile
  environments clean.
- Integration on fresh servers, then again on the same servers: Core 367
  tests, InfluxDB 2.7 64 tests; auth-enabled Core tokens 8 tests.
- Differential runs against Core: about 8,000 random SQL expressions and
  1,500 InfluxQL statements; the differences left are the refusals above.
