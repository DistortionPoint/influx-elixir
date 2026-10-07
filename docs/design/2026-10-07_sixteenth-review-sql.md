# Sixteenth Review (SQL): What the Fifteenth Left Wrong

**Date**: 2026-10-07
**Scope**: `Client.Local` SQL queries, DML and the SQL contract tables
**Issue**: scheduled quality sweep. Reviews 24b300f
([`2026-10-06_fifteenth-review`](2026-10-06_fifteenth-review.md)). The InfluxQL half is another
document.

---

## Problem

- **NULL pairs under `NOT`/`OR`.** `NOT (n IN (NULL) AND n IN (2))` is 300 rows on Core and
  256 at 24b300f; `NOT (n IN (0) AND n IN (1, 2))` 300 and 259; `n NOT IN (1, 0) OR n NOT IN (2)`
  300 and 257. The engine folds an adjacent pair of `IN`-family lists of one operand to a
  constant before it reads a row (`IN` beside `IN` in an `AND` to false when they share nothing,
  `NOT IN` beside `NOT IN`/`IN` in an `OR` to true), also in a select list; for a `NULL`
  operand three-valued logic says `NULL`.
- **Regex.** `\v`, possessive-looking quantifiers (`a*+a`), `(?m)^\z` over a newline, escapes of
  characters beyond ASCII, white space in counts, the span of an unclosed class and repetitions
  Core closes the connection on were answered with PCRE's answer or an invented error.
- **Over-refusal.** `s LIKE 'w1' ESCAPE '\'` and `s LIKE 'w' || '%'` were refused.
- **Cost.** The engine's "scan order" for float aggregates was reproduced at +100-170%
  reductions, and the premise was false (below). The regex guard recomputed static properties
  of the pattern per row; the tokenizer ran a regex per non-ASCII character.
- **Pre-existing:** `WITH c AS (...) ... WHERE NULL = NULL` read a column `time`; `OFFSET` on a
  one-row aggregate; `ORDER BY NULL`; `i::"int"`; a non-ASCII digit in a name; `WITH c AS <bad>`;
  an `INSERT` whose later cell is a parse error.

## Decision

- **Fold gap refused by name** (`SQLContradict.fold_gap?/1`): the double does not model the
  engine's fold with the operand's type and its rule for a `NULL` in a list, so a pair that the
  fold changes the answer of is refused, where a `NOT`, an expression or an `OR` of
  `NOT IN` reads it. As the whole `WHERE` an `AND` pair answers (`NULL` and false both drop the
  row).
- **Regex:** read the crate's counted repetition as it does (white space around numbers, the
  error spans), refuse what PCRE reads differently, drop the hard-coded `\p{Foo}` probes (a
  property that is not a category is refused), cost a pattern and refuse one above a bound fitted
  to what Core did, and compute the data guard once per pattern (`SQLRustRegex.guard/1`). The
  guard depends on the data: one non-ASCII or newline row refuses a query over the table.
- **Scan order withdrawn.** The fifteenth review's Decision says rows are read in the engine's
  scan order (tags, then time). That is withdrawn: twelve runs of one `SELECT sum(f)` on Core gave
  four different last digits, so no order reproduces it. Rows are read in store order, the
  variance stays one pass, and the guide says the last digits are not reproducible.
- **Tagged reasons** replace text tests in DML (`{:cut_off, _}`, `{:unknown_function, _}`); the
  analyzer/optimizer test of an error sits with the constructors (`SQLError.analyzer?/1`); the
  old `:uncertain` refusal is six causes, each worded for its own.

## Verification

Fresh random corpora of 6,000 queries (seeds 20261006 to 20261010) on Core 3.10.1, 24b300f, 6e5b8fd
and this tree: no query that 24b300f answered right or refused is a wrong body now. Probes of
each finding are cases of the SQL contract tables (Core's answer, or a pinned refusal).

Not done: `INTERVAL '1 day 1'` (valid on Core, still refused), and SQLContradict/SQLSimplify
still mix folding with probes of what the engine folds.
