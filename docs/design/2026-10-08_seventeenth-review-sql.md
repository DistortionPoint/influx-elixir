# Seventeenth Review (SQL): What the Sixteenth Left Wrong

**Date**: 2026-10-08
**Scope**: `Client.Local` SQL queries and the SQL contract tables
**Issue**: scheduled quality sweep. Reviews 5b02165
([`2026-10-07_sixteenth-review-sql`](2026-10-07_sixteenth-review-sql.md)).

---

## Problem

- **A raise.** `s ~ '\x{4a}'` (also `\x{1F}`, `(?i)\x{4b}`, `\x{e9}{2}`) raised `ArgumentError`:
  the cost reader of `SQLRustRegex` re-parsed what the syntax reader had validated, and the two
  disagreed on where `\x{..}` ends.
- **IN pairs still wrong.** `i IN (0) AND i IN (1, 2)` (where `i` has NULLs) folds to `false` on
  Core. Local answered three-valued logic inside an aggregate's argument, in `GROUP BY` and
  `GROUP BY 1`, under `IS NULL`, `IS NOT FALSE`, `coalesce`, `= false`, beside a cast
  (`CAST(i AS BIGINT) IN (0) AND i IN (1,2)`), beside an `OR` of equalities, and in a `HAVING`
  whose aggregates were `__agN__`.
- **Rewrites of the engine's simplifier.** `s ~* '^abc$'` is an equality (case kept) on Core;
  `s !~ '.*'` is a test of the value's being empty or null (and `s ~ '.*'` is false, not unknown, for a null: `NOT (s ~ '.*')` keeps the rows with no `s`); a pattern of
  literals with a backslash (`'\\'`, `'\x5c'`, `'[\\]'`) is a `LIKE` whose escape is the
  backslash.
- Smaller: `format: <<255>>` raised `Jason.EncodeError`; `WITH c AS (SELECT length(s) ...)
  SELECT * FROM c` answered `{:int, 32, 3}`; a subquery refusal dropped the first select item
  from its echo; the caret of `a{2,1}??` missed the `?`; a refusal text had an unbalanced `(`.
- Float aggregates: store-order Welford was 34 times further from the true variance than the
  engine's own scatter on `1e9 + k * 0.001`.

## Decision

- **One reader.** `SQLRustRegex.scan` accumulates the cost as it reads (`SQLRegexCost` holds the
  arithmetic only); the data guard is `SQLRegexGuard`. `\x41` and `\x{41}` cost one character.
- **IN pairs.** `SQLContradict.fold_gap?/1` reads the select list, aggregate arguments, `GROUP
  BY`, `ORDER BY`, `WHERE` and `HAVING`; every node but `AND`/`OR`/a list of conjuncts is a
  value; operands are compared without casts; an `OR` of equalities and `IN` lists of one operand
  is one `IN` list; `x = true` is `x`; a `HAVING` is read with `__agN__` replaced by its
  aggregate. `time` is exempt (never `NULL`; verified on Core). The pair is refused without a
  check that the lists share no value: lists that share one fold to the `IN` of what they share,
  which three-valued logic reads alike, but the double has not verified every spelling.
- **Rewrites** are refused by name (`SQLRegexRewrite`): an anchored literal (also in a group, a
  single-character class, an alternation of literals) beside `~*`/`!~*`; any literal backslash;
  the pattern `.*` beside `!~`/`!~*`. The engine decides on the parsed pattern: `(?s)^abc$`, `(?:^abc)$`, `^a[b-b]c$`, `^ab{1}?c$` are the equality too. A pattern the simplifier leaves alone (`^abc`, `abc$`, `^a.c$`, `^a[bB]$`,
  `(?i)^abc$`, `^ab1?$`) is run as written (all verified on Core).
- **`time IS [NOT] NULL`** folds to a constant at the predicate (verified: `-u` beside `time IS
  NULL AND ...` is no error, beside `time IS NOT NULL AND ...` it is as if the test were not
  there); 24 refusals of the contract became answers.
- **Variance** of ordinary floats (finite, below `1e140`) is the corrected two-pass variance with
  compensated sums; equal values give `0.0` (Core sometimes `7.2e-30`); other values keep the
  one-pass accumulator and its overflow results.
- **Reasons** name the cause: the `uncertainty` atoms are one table (`SQLContradict.beside/1`),
  the `NULL`-in-`IN` refusal says which clause it is beside, an unworded statement says its
  kind (`MERGE INTO`, `GRANT SELECT ... on ALL VIEWS`).

## Verification

Each finding is a case of the SQL contract tables (Core's answer, or a pinned refusal). A fresh
random probe of 70 statements on Core: this tree 58 equal, 12 refused, none wrong; 5b02165 62
equal, 5 refused, 3 wrong. Reductions against 5b02165: a regex check 1844 to 1401, a variance
over 1000 floats 256214 to 124979, a grouped variance 121176 to 72863.

Not done: a tag or field that holds no `NULL` is still refused beside an `IN` pair (the answer
is data-dependent); the refusals of DML keep their reasons.
