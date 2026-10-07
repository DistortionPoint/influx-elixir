# Fifteenth Review (SQL, DML, tests): Refuse What Is Not Verified

**Date**: 2026-10-06
**Scope**: `Client.Local` SQL queries and INSERT/UPDATE/DELETE; the unit
tests' use of internal modules, locks, clocks and equality
**Issue**: scheduled quality sweep (no open issues). This reviews commit
6e5b8fd ([`2026-10-05_fourteenth-review`](2026-10-05_fourteenth-review.md)),
which agents wrote and nobody had reviewed. Defects only. The InfluxQL half
of the same review is
[`2026-10-06_fifteenth-review-influxql`](2026-10-06_fifteenth-review-influxql.md).

---

## Problem

Each review since the eighth has found that the previous round's new modelling
was right where verified and silently wrong just beyond it:
- **Pruning** counted `IN (NULL, 1)` as one element and answered `[]` where
  the engine errors.
- **Regex:** checking patterns in the Rust crate's syntax fell back to PCRE
  for constructs it did not know (`[a&&b]` matched 8 rows; the engine matches
  none).
- **Variance:** a Welford pass in an assumed row order.

The commit also raised on a stray character after a cast (`n::int # a`) and
on a `;` inside a `CASE` in `VALUES`.

The tests had their own gaps:
- **Cost test:** UPDATE/DELETE planning was quadratic, from a tokenizer regex
  that re-validated the rest of the text per word. The cost test measured too
  small a range to see it.
- **Lock tests:** they could pass with the lock removed.
- **Atom check:** a guard against creating atoms read library source text.
- **Internal modules:** several tests called them where the public API
  reaches the behaviour.
- **Loose `==`:** about 40 remained.

## Decision

> **Note, 2026-10-07:** the claim below that rows are read in the engine's scan order was
> withdrawn: Core's float `sum` is not deterministic, so no order reproduces it. See
> [`2026-10-07_sixteenth-review-sql`](2026-10-07_sixteenth-review-sql.md).

- **Refuse by name what is not verified.** Where the double does not know
  the engine's exact rule, it refuses by name instead of extending a model:
  - NULL folds beyond the verified ones;
  - regex constructs outside a verified subset;
  - deeper `AND` nests.
- **Floats are answered, not refused.** A refusal of inexact float `sum`,
  `avg`, `var` and `stddev` was tried and reverted: it refused ordinary
  aggregates that consumers' tests depend on. The guide documents that their
  last digits can differ, and the contracts compare floats at a 1e-12
  relative tolerance. Rows are read in the engine's scan order (tags, then
  time).
- **Tests prove their claim:**
  - the DML cost test compares 400 with 1,600 terms, and fails with the old
    tokenizer;
  - the lock tests wait until the waiter is inside `Store.acquire`, coupling
    only to the module under test, and all four fail with the lock removed;
  - the atom test checks at runtime that a unique query text never becomes an
    atom;
  - tests of internal modules were rewritten through `Local`, except the pure
    clock functions (`retention_visibility_test`, `token_time_test`), whose
    moduledocs say why;
  - every unit and contract assertion uses `===`.

## Known differences left

- `time IS NULL` and NULL-list folds beyond the verified ones are refused,
  not answered.
- `n BETWEEN 3 AND 2` beside a range filter gives a DataFusion internal error
  on the engine, which is not reproduced.
- Float aggregate last digits under a filter, a grouping or an expression
  argument.

## Verification

- Unit: 2,099 tests, three runs (the SQL agent ran 5 more seeds); coverage
  92.62%; credo, dialyzer, docs (no warnings) and both compile environments
  clean. No assertion uses `==`.
- Integration on fresh `influxdb:3.10.1-core` (`--wal-snapshot-size 100000`)
  and 2.7, run twice: Core 674 tests, InfluxDB 2.7 90 tests; auth-enabled
  Core tokens 8 tests. The only Core panics are the known DataFusion
  "Incorrect number of identifiers" for six- and seven-part names.
- Never-tuned random SELECT corpus (3,346 queries): wrong answers 526
  (31ddadb), 295 (6e5b8fd), 5 now, none a new modelling gap. Across about
  12,000 queries, nothing right or refused at 31ddadb answers wrong now.
- Mutation proofs: the old tokenizer fails the DML cost test (400 vs 1,600
  terms 7.3x); a lock that is not taken fails all four lock tests; an atom
  made from a table name fails the atom test.
- Reductions of `SELECT *` over 3,000 rows: 381,753 (31ddadb), 446,056
  (6e5b8fd), 384,532 now.
