# Review of the positions of a text's statements

**Date:** 2026-10-15
**Status:** Implemented

## Context

A sweep with no open GitHub issues. A read-only review of `SQLSyntax` and `SQLPlan` found that
the double read each statement of a text after the whole text before it, blanked again.
Following that path turned up a wrong answer as well.

## Decisions

### A bare statement word after the first statement: its `;` on its own line

- **The bug.** `SQLStatement.bare_error/1` placed the `;` with the length of the blank before
  the word. That blank was written as spaces of the same length, so its newlines were lost.
  The `;` of `SELECT 1;\nANALYZE;` was put at `Line: 1, Column: 18`.
- **The engine.** Core 3.10.1 answers `Expected: identifier, found: ; at Line: 2, Column: 8`.
- **The fix.** The position is now read from the blank itself, newlines and all.
- **Pinned in the SQL contract**, each case run on the double and on Core:
  - `SELECT 1;\nANALYZE;` (line 2, column 8);
  - `SELECT 1;\n  ANALYZE  ;` (line 2, column 12);
  - `SELECT 1;\nCOMMENT;` (`Expected: ON`);
  - `SELECT 1; /* a\nb */ ANALYZE;`, where a comment carries the line;
  - two cases after `'é'`: a column counts characters, not bytes.
- **The duplicate check.** It reads the three `ANALYZE` texts as one case. They are pinned
  as a group whose answers differ only in the place they name.

### Each statement read alone, from where it starts

- **The cost.**
  - Every statement was tokenized after a blanked copy of the text before it, which put it
    at its line and column.
  - The copy was made again for each statement, so the work grew with the square of the
    number of statements.
  - A text of many statements reaches this path, since it must answer the first statement
    that does not read.
- **A first attempt.** A margin of only the lines before the statement still grew
  faster than linearly: 400 statements cost 7.6 times what 100 did.
- **The fix.**
  - The tokenizer (`scan/2`, `tokenize/2`) and `SQLStatement`'s errors (`parser_error/3`,
    `bare_error/2`) take the line and column a statement starts at.
  - Each statement carries that start on from the one before it.
  - `SQLTokenizer.blank/1` is gone. `split/1` returns the statements alone, since no caller
    read their byte offsets.
- **Pinned in `sql_cost_test.exs`.** Four times the statements must cost between 2.5 and 5
  times as much. The test fails on the old code.

### Reported, and left

- **The read of an argument list.** `special_call`'s second read of the arguments of a
  call that does not read doubles at each level of nesting. That nesting is capped at 20,
  and the second read is the engine's own retry.
- **Duplication in `check_arithmetic/6`.** Its `:select` and `:where` clauses differ only in
  one context argument. Folding them would gain little.

## Verification

- **Core 3.10.1.** The six positions were probed on Core 3.10.1, and the Core contract suite
  ran with them: 749 tests, 0 failures.
- **The unit tier.** 21 doctests and 2390 tests, 0 failures, three times and once with
  coverage (94.29%). Every line the change touched is covered.
- **The other gates.** Format, both compiles, credo, dialyzer and docs pass.
