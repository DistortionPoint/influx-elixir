# Thirteenth Review: Read INSERT Values, One Error-Stage Table, Pinned Reasons

**Date**: 2026-10-05
**Scope**: `Client.Local` SQL typing, error order and DML; InfluxQL selector
ties and comparisons; the case-table, cost and lock tests
**Issue**: scheduled quality sweep (no open issues). This reviews commit
f565fdb ([`2026-10-05_twelfth-review`](2026-10-05_twelfth-review.md)), which
agents wrote and nobody had reviewed. Defects only.

---

## Problem

f565fdb was a net improvement, but it brought in defects of its own:
- **Silent wrong answers and invented engine errors:**
  - a Boolean `IN (NULL, …)` errored where the engine answers;
  - aggregates of `coalesce(tag, number)` gave errors the engine never gives;
  - `Decimal128(35, 15)` was printed as `Float64`;
  - `INSERT` counted the commas of its `VALUES` and never read them, so
    statements it used to refuse got a confident wrong answer;
  - `UPDATE` let the optimizer's error through.
- **Error order:** an unbound `$1` and `HAVING` errors were reported before
  errors the engine reports first.
- **Speed:** the typing memo, keyed by whole expressions, hashed each
  subtree at every lookup. Long chains took quadratic wall time (2.9× slower);
  reduction counts did not show it, because hashing is not counted.
- **InfluxQL:** `top(v, tag, n)` broke ties by the group's first point, and
  an unsigned field beside a boolean or a tag gave the wrong error or no rows.
- **Tests:**
  - about 690 SQL refusal pins accepted any refusal, whatever its reason;
  - catalog cases pinned row order with no `ORDER BY`;
  - the cost test's bound was never shown to fail;
  - two lock tests could pass with the lock never contended.

## Decision

- **INSERT, UPDATE and DELETE read what they are given.** `VALUES` cells are
  planned and typed, and DELETE is parsed. One table-name resolver
  (`SQLDmlName.lookup/2`) and one cast-type grammar (`SQLDmlType`) replace
  the copies.
- **One error-stage table (`SQLStage`)** orders the engine's errors by the
  stage that finds them, in place of numeric ranks shared by float
  coincidence.
- **Typing returns its result bottom-up** instead of looking whole nodes up
  in a map.
- **Every SQL refusal is pinned to its exact reason** (821 pins), as
  InfluxQL's already were.
- **Tests that prove their claim:**
  - the cost test compares a `HAVING` reference's cost over 1,500 and 6,000
    rows, and was shown to fail when the columns are re-read per reference;
  - the lock tests act only once the other process is blocked;
  - the duplicate check folds blanks around operators and strips comments;
  - the alias's switch list is checked against Mix's own documentation.

## Known differences left

- **Error order:**
  - a placeholder against a function error in the same expression (5 of 304
    such random queries differ; the obvious rule lowers overall accuracy);
  - a function error in an `ELSE` under an arithmetic error;
  - a placeholder inside a `HAVING` `CASE`.
- **Other SQL:**
  - `IS TRUE` over `time NOT BETWEEN host AND region` answers where Core
    closes the connection;
  - the parser and syntax checks are still super-linear on deep nesting.
- **InfluxQL:**
  - typed errors of bare operands in three or more `AND`/`OR` members;
  - `fill(number)` on a raw select grouped by a tag.

## Verification

- Unit: 2,068 tests, three runs; coverage 92.19%; credo, dialyzer, docs (no
  warnings) and both compile environments clean.
- Integration on fresh `influxdb:3.10.1-core` (`--wal-snapshot-size 100000`)
  and 2.7, run twice: Core 664 tests, InfluxDB 2.7 90 tests; auth-enabled
  Core tokens 8 tests. The only Core panics are the known DataFusion
  "Incorrect number of identifiers" for six- and seven-part names.
- Random SQL corpus never used for tuning (1,299 queries): same as Core
  1,069 (b04c320), 1,099 (f565fdb), 1,126 now. DML corpus (about 2,700
  statements): wrong answers about 770 (b04c320) to 31. InfluxQL corpora
  (5,100 queries): none moved away from a right answer.
- Wall time of a 3,200-term sum: 243 ms (b04c320), 608 ms (f565fdb), 238 ms.
