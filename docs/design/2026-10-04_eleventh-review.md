# Eleventh Review: Verified Shapes Only, Linear Typing, a Tested Alias

**Date**: 2026-10-04
**Scope**: `Client.Local` SQL statements and expression typing, InfluxQL
counts and comparisons, the `mix test` alias
**Issue**: scheduled quality sweep (no open issues). This reviews commit
74a8594 ([`2026-10-04_tenth-review`](2026-10-04_tenth-review.md)), which
agents wrote and nobody had reviewed. Defects only.

---

## Problem

- **Statements.** Each round matched more wordings of rarely used
  statements (`UPDATE`, `GRANT`, `CREATE`, `DESC`), and each round's matching
  produced new engine-shaped errors the engine never gives: `UPDATE … SET n
  = CASE …` answered "No field named case".
- **Wrong answers.** `||` bound like `+` (`'a' || 1 + 2` answered `"a3"`);
  `SELECT DISTINCT … HAVING` ignored the `HAVING`; InfluxQL `count()` of a
  missing field added a zero column, and a comparison between mismatched
  kinds kept every row.
- **Cost.** A 4,100-character name raised; a sum of 900 terms took 5 s to
  type, and even after a first fix cost 6.8 times as much as 300 terms: every
  operator re-walked its whole subtree for its fields and type.
- **The `mix test` alias** took an option's value that names a directory
  (`--exclude lib`) for a path. It had been rewritten in four reviews and had
  no test.

## Decision

- **Verified shapes only.** For `UPDATE`, `GRANT`/`REVOKE`/`DENY`, `DESC` and
  similar statements the double answers exactly the shapes pinned in a case
  table with the engine's answer, and refuses every other shape by name. It
  no longer reaches a generic fallback that imitates an engine error.
- **One typing pass.** Each node of an expression is typed, and its fields
  found, once, bottom-up; a test compares the work of 900 and 300 terms in
  reductions, which do not depend on the machine's load.
- **The alias** is `InfluxElixir.MixTestArgs` in `mix/test_args.ex`, loaded
  by the `test` alias only (the package ships `mix.exs` without `mix/`), and
  tested in `test/mix/test_args_test.exs`. Known switches take their values;
  every other argument is a path when it is one.
- **Tests of internals.** A direct test of the InfluxQL arithmetic kernel was
  removed: the contract tables reach the kernel through queries.

## Verification

- Unit: 2,017 tests, three runs; coverage 91.60%; credo, dialyzer, docs (no
  warnings) and both compile environments clean.
- Integration on fresh `influxdb:3.10.1-core` (`--wal-snapshot-size 100000`)
  and 2.7, run twice: Core 646 tests, InfluxDB 2.7 90 tests, no panic;
  auth-enabled Core tokens 8 tests.
- Typing: a 900-term sum costs 3.18 times a 300-term one (6.8 before); a
  3,600-term comparison chain takes 1.2 s (51 s before).

## Known limits left

`SQLCoerce` re-types each coerced result at every level of a `CASE … ELSE
CASE …` or `COALESCE(n, COALESCE(…))` nest: quadratic, about 400 ms at 600
levels, which no real query reaches. Three `HAVING` queries that mix a bare
and a qualified unknown column report the qualified one first.
