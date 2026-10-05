# Fourteenth Review (InfluxQL): The Planner's Order of Errors and the Operands of AND / OR

**Date**: 2026-10-05
**Scope**: `Client.Local` InfluxQL (`lib/influx_elixir/client/local/influxql/`); the
InfluxQL contract tables; the unit tier's equality, lock, cost, case-table and
`mix test` argument tests
**Issue**: scheduled quality sweep (no open issues). Reviews commit 31ddadb
([`2026-10-05_thirteenth-review`](2026-10-05_thirteenth-review.md)). Defects only.

---

## Problem

Each item was reproduced against InfluxDB 3 Core 3.10.1 (Docker one-liner in
`README.md`), a `fxt8` database with the `~p1` fixture of the projection cases:

- **A raise:** `SELECT v FROM m SLIMIT x` as the first statement of a VM raised
  `ArgumentError` (`String.to_existing_atom("slimit")`); `fill()`'s option read
  with `String.to_atom`.
- **Error order** (a regression of the 31ddadb "clash after the select list"): `max(u) /
  sum(n) ... WHERE ok != 1 OR usage < n AND u >= true` answered the projection's
  `cannot use / between an integer and unsigned`; Core answers the WHERE's comparison.
- **Silent wrong answers:** `n * (-3)`, `n % (3)`, `pow(n, (2))`, `derivative(n, (1s))`
  returned rows (Core: `field must contain at least one variable`, or the `Nested(...)`
  argument errors); `WHERE s AND b <= u` answered `[]` (Core: the comparison's error); a
  bare operand in three or more members of `AND`/`OR` answered `[]` for `b OR s OR b` (Core:
  the rows where `b`); `fill(n)` of a plain select left the columns a row lacks null.
- **Invented errors:** `SELECT count(host) ... WHERE host` and every select list that reads no
  field (Core: `[]`, the condition and the window never planned).
- **Tests:** the lock tests inferred "blocked on the lock" from a process's reductions
  (coupled to the store's 1 ms retry) and pinned the whole mailbox; the `mix test` argument
  test failed on a new Mix switch and raised on a missing docs chunk; the cost test carried
  a dead string and a false comment (there is no shared cache; the cost is module loading);
  the spelling pins of the case tables had no member count and compared nothing of the
  parser's errors but their number; 244 loose `==` in the unit tier.

## Design

What Core does, found by running every pair of operand kinds, chains of three and four and
groups (about 3 200 statements), then the clauses, the aggregates and the casts:

1. **Order of the engine's errors** (`influxql_query.ex`, `influxql_selected/6`): the errors
   of rewriting the statement (every body starts `rewriting statement`) first, whatever the
   condition holds; then a select list that reads no field is empty (`InfluxQLPlan.reads_field?/2`);
   then the condition's comparison and connective errors (`clash`), in the order the planner
   builds the filter, leaves first; then the select list's own planning errors; then the
   `LIMIT` range, then the condition that is no boolean (`deferred`). A refusal of the
   double stands where the engine's error it stands for stands (`@unplanned_call`).
2. **`AND` / `OR` typed leaves up** (`InfluxQLTyped.operand/4`): a pair with a bare operand
   (field, constant, tag, duration) keeps no point (false); it is the planner's `Cannot infer
   common argument type` error when one operand is unsigned, both are numbers, or both are
   durations. A tag is `Utf8` in that error only when the condition is that pair alone. A
   comparison of constants, and a column the measurement lacks, are refused beside a bare operand
   (Core types them in ways the double does not follow).
3. **A constant alone in parentheses** (`InfluxQLExpr.paren_constant?/1`) is the gather error
   `field must contain at least one variable` at its item; a transform of a field in a
   `GROUP BY time()` is `aggregate function required inside the call to <name>`.
4. **Clauses** are read in order (`WHERE`, `GROUP BY`, `fill()`, `ORDER BY`, `LIMIT`,
   `OFFSET`, `SLIMIT`, `SOFFSET`, `tz()`): the first one out of its place is the `Nom` error
   at its start; of two bad operands the leftmost is the error; a bad `SOFFSET` operand is
   worded as `SLIMIT`'s. No atom is made from a statement's text.
5. **Aggregates:** of a tag or a boolean beside a field are the engine's coercion errors
   (`Dictionary(Int32, Utf8)` in a signature, `Utf8` in the message of `avg`/`sum`), none
   when the tag is a `GROUP BY` dimension, and empty alone; several that fail are refused (the
   engine names one in an order of its own). `median`/`mean`/`stddev` of a string or tag type
   as numbers in arithmetic, `first`/`max`/`sum`/... of a tag as a tag.
6. **`fill(n)` of a plain select** fills the number columns a row of the answer lacks, cast to
   the column's type (an integer wraps into an unsigned column, a float is cut and saturates);
   a string or boolean column, and a value an expression computed to null, stay null; a
   selector over a string or boolean column is the `no conversion` 500.

Tests: the lock tests prove ordering by effects (a message order, a check inside the critical
section) and never read a process's reductions; the pins of the case tables carry the member
count, and a `:position` pin compares the parser's errors with the places taken out; the table
scan is compared with the sources of the cases modules.

Rejected: modelling the engine's error order of several failing aggregates, and of a bare
operand beside a comparison of constants or a missing column (neither was derivable from the
probes); both are refused by name.

## Files Modified

| File | Change |
|------|--------|
| `lib/.../influxql/influxql_{check,group,parser,plan,query,expr,typed,where,where_arith,run}.ex` | the changes above |
| `test/support/contract/influxql_defect_cases.ex`, `influxql_planner_contract.ex` | 432 statements with Core's answers |
| `test/support/contract/influxql_{order,shape,projection}_cases.ex` | a twin for the empty `group by host limit 1 offset 1`; refusals that now answer moved out; reasons updated |
| `test/influx_elixir/client/local/{store_locks,sql_cost,influxql_clauses}_test.exs`, `contract_case_tables_test.exs`, `test/mix/test_args_test.exs`, `test/support/test_support/await.ex` | see Problem |
| `test/influx_elixir/client/local/sql_stage_test.exs` | deleted (tested an internal; the SQL contracts pin the behaviour) |
| `CHANGELOG.md`, `docs/guides/testing-with-local-client.md` | |

## Verification

Random InfluxQL corpora (select lists, expressions with parenthesised constants,
aggregates, selectors, transforms, `AND`/`OR` trees with bare operands, `GROUP BY`,
`fill()`, every clause with bad operands and in every order) were run on Core, on f565fdb
(`HEAD~1`) and on the tree: 5 884, 5 869 and 7 805 statements (three seeds). No statement
that f565fdb answered as Core answers (or refused) moves away from Core; 560-790 per corpus
that f565fdb answered otherwise now match; none raises.
Contract: `mix test --only v3_core` (the Local tiers), `mix credo --strict`,
`MIX_ENV=test mix compile --force --warnings-as-errors`, `mix dialyzer`.
