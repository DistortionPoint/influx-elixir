# Fourteenth Review (SQL): Core's Folding Rules, One Cast Grammar, Linear DML

**Date**: 2026-10-05
**Scope**: `Client.Local` SQL queries and INSERT/UPDATE/DELETE; the SQL case
tables and their refusal pins
**Issue**: scheduled quality sweep (no open issues). This reviews commit
31ddadb ([`2026-10-05_thirteenth-review`](2026-10-05_thirteenth-review.md)),
which agents wrote and nobody had reviewed. Defects only. The InfluxQL and
unit-test half of the same review is
[`2026-10-05_fourteenth-review-influxql`](2026-10-05_fourteenth-review-influxql.md).

---

## Problem

31ddadb was a net improvement (4,310 more random queries matched Core) but
brought in defects of its own:

- **A silent wrong answer.** The pruning of empty relations treated any two
  `=`/`IN` conditions on a column as contradictory. `SELECT -u … WHERE n = 1
  AND n IN (2, 3)` answered `[]` where the engine reports the negation error.
- **Parser errors the engine never gives:**
  - array literals in `VALUES`;
  - `ORDER BY` inside a call's arguments in DML;
  - named arguments (`abs(x => 1)`).
- **A silent wrong answer next to the cast work:** `1::BIGINT UNSIGNED` read
  one type word and took `UNSIGNED` for the column's alias.
- **Speed:**
  - `||` chains in INSERT and DELETE re-planned every left subtree, so a
    400-term chain took 5 s;
  - `HAVING` was up to 65% slower;
  - INSERT was 1.7× slower per row.
- **Structure:** four cast-type grammars and two table resolvers remained.
- **Tests:**
  - some refusal reasons were shared by dozens of cases, too coarse to catch
    a wrong one;
  - new unit tests tested internal modules instead of behaviour.

## Decision

- **Pruning follows the engine's verified rules:**
  - an `IN` with another `IN` folds only when adjacent in the `AND` tree;
  - equalities fold across all top-level conditions;
  - the literal must be of the column's own kind;
  - `OR` and `NOT` are not looked into.

  The rules live in `SQLContradict`/`SQLPrune`, out of `SQLPlan`.
- **One cast grammar.** `::` and `CAST … AS` read `SQLDmlType.parse` through
  `SQLCastType`.
- **One table resolver.** `SQLTable` resolves names and holds the system
  tables' columns.
- **DML operands are typed once per link.**
- **Exact refusal reasons.** Each refusal reason names its cause and each
  parser fallback names its token. All 1,138 refusals are pinned to their
  exact reason.
- **No tests of internals.** Behaviour that tests of internal modules
  pinned now lives in the case tables, with answers read from Core, and runs
  through `Local` on both tiers.

## Known differences left

- Last digits of `var`, `stddev` and `avg` of floats: the engine's
  partitioning cannot be recovered.
- `HAVING 5 < min(time)` prints its operands mirrored.
- A CTE whose negation is dead only because the outer query is provably empty
  still reports the negation error.
- Core's "Did you mean …?" for an unknown function changes from run to run,
  so it is never pinned.

## Verification

- Unit: 2,095 tests, three runs; coverage 92.55%; credo, dialyzer, docs (no
  warnings) and both compile environments clean.
- Integration on fresh `influxdb:3.10.1-core` (`--wal-snapshot-size 100000`)
  and 2.7, run twice: Core 673 tests, InfluxDB 2.7 90 tests; auth-enabled
  Core tokens 8 tests. The only Core panics are the known DataFusion
  "Incorrect number of identifiers" for six- and seven-part names.
- Fresh random SELECT corpus (3,000 queries, never tuned): wrong answers 143
  (f565fdb), 114 (31ddadb), 45 now; no refusal became a wrong answer.
- Fresh random DML corpora (about 50,000 statements): wrong answers about
  460 per 8,000 at 31ddadb, 1 in all now.
- Wall time: a 400-term `||` INSERT 7.5 s (31ddadb) to 2.3 ms; a 100-term
  `||` UPDATE 587 ms to 2.2 ms; a 400-condition HAVING 275 ms to 161 ms.
