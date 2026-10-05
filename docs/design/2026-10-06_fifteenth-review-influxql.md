# Fifteenth Review (InfluxQL): `fill()` Behind and Inside a Condition, Bare Operands Beside Constants

**Date**: 2026-10-06
**Scope**: `Client.Local` InfluxQL (`lib/influx_elixir/client/local/influxql/`); the
InfluxQL contract tables (`test/support/contract/influxql_*`)
**Issue**: scheduled quality sweep (no open issues). Reviews commit 6e5b8fd
([`2026-10-05_fourteenth-review-influxql`](2026-10-05_fourteenth-review-influxql.md)). Defects
only; the rule of the round is to answer only shapes verified on Core and to refuse the rest
by name.

---

## Problem

Each item was reproduced against InfluxDB 3 Core 3.10.1 (Docker one-liner in `README.md`):

- **A regression to a wrong body (6e5b8fd):** `SELECT f FROM m WHERE fill(1)` answered every
  row. The check stripped the first `fill(...)` found anywhere in the condition. Core:
  `invalid expression, the only valid function calls are 'now' with no arguments,
  date_part(<literal>, time), or scalar math functions at pos 22` (the position is that of the
  call, whatever stands before it that reads and whatever follows it: `WHERE (n > fill(1)`,
  `WHERE n > 1 AND fill(1) LIMIT x`). Behind a whole condition `fill(...)` is a clause, and
  what follows it must be `ORDER BY` or later: `fill(1) fill(2)`, `fill(1) GROUP BY host`,
  `fill(1) = 2` and `fill(1) extra` are `Nom(...)` at the word behind it. The statements
  `WHERE n > 1 fill(1) group by host limit 2` and the like were answered.
- **Over-refusal (6e5b8fd):** the planner's leaves were planned as the connectives were
  typed, and a comparison of constants or of a missing column refused the whole condition
  (`WHERE region OR 'us' =~ /a/`, Core `[]`: 616 of the 645 statements of a corpus of pairs
  and chains of three that 31ddadb had answered rightly).
- **Silent wrong answers:** `WHERE c GROUP BY * LIMIT x` (and `GROUP BY /re/`, any later
  malformed clause) answered `Nom("GROUP BY ...")` at the `GROUP`: the clause had been blanked
  in the masked text only, and the condition was cut from the raw one. A string constant under
  `=~` / `!~` was SQL (`'us' !~ /a/` kept every point; Core keeps none). `WHERE nosuch AND time
  > 0` and `WHERE time > x AND (true)` answered rows or `[]` (Core: the 500 `invalid expr
  stack`). `fill(n)` filled the rows an expression had left null in every column (`f + n`
  where `n` is missing), which Core does not answer at all. `fill(- 1)` was an invalid option
  (Core: minus one); an unclosed `fill(` was `Nom` at the word instead of `invalid FILL option`
  at the end of the parenthesis; `fill(x) ORDER BY y` answered the `ORDER BY` (the leftmost
  error is the `fill`); a second statement that does not parse stood behind the 405 of
  `SLIMIT`.
- **Maintainability:** `error_position/1` read a position back out of the body of the error it
  had just rendered (`" at pos (\d+)"`).

## Design

What Core does, found with about 3 000 statements (pairs and chains of operand kinds, the
clauses after a condition, the signs of a `fill()` number):

1. **`fill(` where an operand is wanted** (first, or after an operator, a connective or a
   parenthesis; `InfluxQLCheck.check_where_call/4`): the call is the error, at its first
   letter, when the text before it reads (its own error, if any, is first, and an early `)`
   ends the condition before the call is reached). The arguments must be a flat list closed by
   `)`; others fail in ways not verified (`fill(` alone is `Parsing Failure ... at pos 0`) and
   are refused by name.
2. **`fill(` behind a whole condition** is the clause (`cut_where/2`, `split_fill/3`; the
   clause pattern takes `fill(...)` for the clause wherever it can, `take_call/3` gives it back
   to the condition when what stands before it wants an operand). Its option is read with the
   same reader as the one after `GROUP BY` (`InfluxQLGroup.read_fill/2`): a sign may stand
   apart from its digits (`fill(- 1)`, `fill(+ 1)`, `fill(- .5)`; `fill(- - 1)` and `fill(- x)`
   are not options). What follows it is `ORDER BY` or later, or left over from where it
   starts. `GROUP BY` behind a `fill()` is left over, so `plain_before?/1` of the group reader
   refuses it.
3. **The leftmost error is the error.** Errors carry their position as data
   (`InfluxQLCheck.positioned/0`, `{position, {:error, reason}}`); the swallowed clause, the
   number past the unsigned range and the `fill()` option are compared on it, and a refusal
   stands at position 0.
4. **Bare operands beside comparisons that raise no error of their own:** a comparison of
   constants (numbers, strings, regular expressions, booleans, mixed; arithmetic over one kind
   of constant), and of a column the measurement lacks compared with a string, a regular
   expression, a boolean or a tag, are not planned: the pair they are in keeps no point. A
   column the measurement lacks compared with a number is the same beside numbers, but beside
   a string, a tag or another non-number it is Core's `Cannot infer common argument type`
   error: refused by name. Arithmetic over strings and numbers of constants (`1 = 1 + 'a'`) is
   typed as a null in the same way and refused. A bare column the measurement lacks, and a
   boolean constant in parentheses, break the stack beside a `time` comparison like any bare
   operand.
5. **`GROUP BY` beside a condition** reads the clause's raw text blanked with its mask
   (`InfluxQLGroup.extract/3` returns both).

Verified shapes outnumber refusals; refusals added: `fill(` unclosed in a condition, nested
parentheses in the call, a comparison of constants with booleans or `now()` or with
arithmetic over several kinds, and a bare string beside a comparison of a missing column.

## Verification

- A corpus of 1 800 random statements (select lists, conditions with bare operands, `fill()`
  forms, `GROUP BY`, clause tails), generated with a fixed seed, run on Core, on 31ddadb, on
  6e5b8fd and on the tree: 31ddadb 847 right / 270 refused / 683 wrong, 6e5b8fd 951 / 396 /
  453, now 1 640 / 157 / 3. None of the 847 31ddadb answers and none of its 270 refusals
  became a wrong body; the 3 left differ only by the clock (a `GROUP BY time()` with no upper
  bound is bucketed up to `now()`, read at a different second by each run).
- `InfluxQLDefectCases.clause_tail/0` (90 statements) and nine more refusals pinned to their
  reason in `refusal_reasons/0`; `host =~ /(?<n>h)1/` moved from the answers to the refusals
  (the regular expression check refuses a named group by name).
- Cost: with 2 000 points, `SELECT * FROM m` was 374 k reductions on 31ddadb and 413 k on
  6e5b8fd (+9 %, `WHERE s = 'v3'` of 40 rows +52 %: about 18 reductions per scanned row). None
  of it was the InfluxQL side: swapping the SQL modules of 31ddadb into 6e5b8fd gave the old
  cost back, and so did the executor alone. `SQLExecutor.ordinal_error/2` asked
  `SQLSchema.output_columns/2` for the columns of the select on every query, and of a
  `SELECT *` (what the InfluxQL path sends) that is the union of the columns of every point;
  it asks only when an `ORDER BY` term is a position. Nine statements, 2 000 points: none above
  31ddadb (reductions of the second run of each).

## Files Modified

| File | Change |
|------|--------|
| `lib/.../influxql/influxql_{check,group,parser,error,sql,typed,where,run}.ex` | the changes above |
| `test/support/contract/influxql_{defect,fix,planner}_*.ex` | `clause_tail/0`, refusals, the moved named-group case |
