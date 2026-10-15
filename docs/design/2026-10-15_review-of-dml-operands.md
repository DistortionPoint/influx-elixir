# Review of the operands of a DML statement

**Date:** 2026-10-15
**Status:** Implemented

## Context

A sweep with no open GitHub issues. A read-only review of `SQLDmlOperand` and `SQLDmlExpr`
covered the parser and the type checks the double runs over the operands of `INSERT`,
`UPDATE` and `DELETE`. Every claim about the engine below was probed on Core 3.10.1 before it
was acted on. Two of the review's claims were wrong and are recorded as such.

## Decisions

### A number in a `WHERE`: printed as the engine prints it

- **The bug.** A `WHERE` that is a bare number is answered with the error
  `Cannot create filter with non-boolean predicate '<the number>'`. `SQLDmlOperand` printed
  a float with `Float.to_string/1`, so `1.5e-7` came out as `Float64(1.5e-7)`.
- **The engine.** Rust's `Display` never uses an exponent. Core answers:
  - `1.5e-7` with `Float64(0.00000015)`;
  - `1e20` with `Float64(100000000000000000000)`;
  - `123456789012345678.0` with `Float64(123456789012345680)`;
  - `-0.0` with `Float64(-0)`;
  - `-9223372036854775808` with `Int64(-9223372036854775808)`;
  - `18446744073709551616` with `Float64(18446744073709552000)`.
- **The fix.** `SQLDmlItem.number/1` already printed a literal this way for the names of a
  select list. It is now public, and the predicate uses it in place of its own printer.
- **Refusals that became answers.** The old printer refused a float of 1e15 or more, and an
  integer of more than 18 digits. The double now answers them. The refusal pin of
  `update main set v = 1 where 12345678901234567890` is removed, since the catalog already held
  Core's answer.
- **Pinned in the SQL contract:** the six numbers above.

### A `LIKE` escape: counted in bytes

- **The bug.** `escape_length/1` counted the escape with `String.length/1`, so `ESCAPE 'é'` was
  read as a single character.
- **The engine.** Core counts bytes and answers `Invalid escape character in LIKE expression.
  Expected a single character wrapped with single quotes, got 'é'`.
- **The fix.** The check is `byte_size/1`.
- **Pinned in the SQL contract:** `escape 'é'` (refused), and `escape ''''` (a quote, accepted).

### An `UPDATE`'s arithmetic: typed once

- **The cost.** Two checks typed the operands again at every operator:
  - `trivially_typed?/2` called `type_of/2` on both sides of each operator, and `type_of/2`
    walks the whole subtree;
  - `unsigned_against_time?/2` typed both sides before it looked at the operator.

  For `UPDATE main SET n = n + n + ...`, four times the terms cost 10.1 times the reductions.
- **The fix.**
  - `trivially_typed?/2` is now `trivial_type/2`, which returns the type of a trivially typed
    operand, found on the way up, or `false`.
  - `unsigned_against_time?/2` types the sides of a comparison only.

  The same text now costs 3.9 times as much (8.1 with the second change alone).
- **The IN list.** `asked/2` gathered the calls of an `IN` list with `++` on each item. It now
  builds the list once. No difference was measurable at 400 items.
- **Pinned in `sql_cost_test.exs`.** Four times the terms must cost less than five times as much.
  The test fails on the old code.

### Dead code removed

- **Unreachable refused words.** `CASE` and `CURRENT_TIMESTAMP` were in `@refused_words`, but
  earlier `prefix/1` clauses match both words first.
- **A clause no input reaches.** The `"substring"` clause of `converted_alone?/2` never ran,
  because the parser refuses `SUBSTRING` before it builds a call.
- **A duplicate.** `delete_alias/1` had the same body as `alias_name/1`, which now serves both.
- **A stray comment.** One comment described no code near it and is removed.

### Claims checked and found wrong

- **`power` of two integers.** The review said it types as a float. Core types it `Int64`, and
  so does the double.
- **A negated literal past `Int64`.** The review said `-9223372036854775808` types as `UInt64`.
  The double answers `Int64 + Utf8`, as Core does.

### Reported, and left

- **Repeated lowering.** `plan_typed`, `deep` and `unless_mixed` may lower an operand up to three
  times. `beside/3` plans the sibling of each placeholder. Neither showed a cost growing faster
  than the text.
- **Nested `coalesce`.** Ten and forty levels cost 4.1 times apart, which is linear.
- **Six `reduce_while` helpers of one shape.** They differ in what they stop on. Folding them
  into one higher-order function would hide that.
- **Grapheme slices of quoted text.** `String.slice(text, 1..-2//1)` would drop a combining
  mark written right after an opening quote. The double already refuses non-ASCII text where
  it prints it, so no answer changes.

### A test compared whole

- `influxql_flux_fidelity_test.exs` checked `SELECT * FROM o` by its row count and the
  absence of an empty `k`. It now compares the six rows exactly. Core gives the same rows,
  values and missing keys.

## Verification

- **Core 3.10.1.** Every answer above was probed on Core 3.10.1. The Core contract suite
  ran with the new cases: 749 tests, 0 failures.
- **The unit tier.** 21 doctests and 2391 tests, 0 failures, three times and once with coverage
  (94.29%). No changed line is missed.
- **The other gates.** Format, both compiles, credo, dialyzer and docs (0 warnings) pass.
