# InfluxQL Differential Fuzz, Fourth Review: One Walker, Errors in Order, Quotients

**Date**: 2026-10-09
**Scope**: `Client.Local`'s InfluxQL arithmetic typer and walker, the planner's order of errors, the
split of the time, an unsigned division by zero (`lib/influx_elixir/client/local/influxql/*`), and the
SQL expression tokenizer (`sql/sql_expr.ex`), at d7ecf77.
**Issue**: review of the [third review](2026-10-09_influxql-fuzz-third-review.md).
**Supersedes**: the "known differences left" of the third review that this one closes.

Every claim was read from InfluxDB 3 Core 3.10.1 (`influxdb:3.10.1-core`, no auth) on the measurement
`m` of the review: a tag `t`; `n` integer, `f` float, `b` boolean, `u` unsigned (the first row 0),
`s` string; the absent `nosuch`; five rows `(a,1,0) (b,2,3) (a,-3,5) (b,7,2) (c,4,1)`.

## Problem and findings

| # | Statement | Core | Before | After |
|---|---|---|---|---|
| F1 | `u + b > abs(s)`, `(u + b) * abs(s) > 1`, `u + b + abs(s) > 1`, `time + 1 > abs(s)`, `(u + 's') / abs(s) < 1.5` | the coercion (`UInt64 + Boolean`, ...) | the call's error | the coercion |
| F1 | `(u + 's') + abs(s) * 2 > 1`, `abs(s) + -(u + b) > 1` | the call / the coercion | reversed | as Core |
| F2 | `time > n AND b` (and `f s t b u nosuch (n) true abs(n)`, `n > time`, `b OR time > n`) | `rewriting statement / split condition / found symbol 'n::integer', ...` (400) | 500 `invalid expr stack` | the error |
| F2 | `time > 0 < 1 AND b` | `Timestamp(ns) > Int64` | 500 | the error |
| F3 | `n + (u / s) > 1`, `(u / s) < n`, `abs(n) / (u / s) < 1.5`, `(1 + 2) + (u / s) > 1`, `n * (u / s) / nosuch > 1` | `cannot use + between an integer and unsigned, an explicit cast is required` | the division's error, `[]` | the error |
| F4 | `u / 1h > nosuch`, `-u / 1h > nosuch`, `u / b > nosuch`, `u / time > nosuch` | `[]` | the comparison's error | `[]` |
| F5 | `n + b + time + 1 > b`, `(s + b) + time + 1 > 1`, `(n + b) * time + 1 > 1` | `[]` | `Int64 + Boolean` | `[]` |
| F6 | `m2 where n / u > 0` (zero read first, written last) | the stream fails | rows | refused by name |
| F6 | `t = 'b' and n / u > 1`, `time > ... and n / u > 1` | rows | refused | rows |
| F7 | `separated/4` had no fall-through clause | | a latent `FunctionClauseError` | `:unread` |
| F8 | `SQLExpr.tokenize/2` | | quadratic | linear |

### What the order of the errors is

The planner builds an expression bottom up and asks for the type of both operands of an operation after
it has built both. An operation or a call therefore *carries* its own planning error until it is an
operand of another operation, which raises what its operands carry, left first. Measured over about
200 pairs: `(u + 's') + abs(s)` is the coercion (the call is a direct operand), `(u + 's') + abs(s) * 2`
is the call (the product raises `abs(s)`'s error while it is built, before the sum asks for the left
operand), `abs(s) + -(u + b)` the coercion (the negation is a product with -1), and the errors of the
arguments of a call come before its own (`abs(1, u + b)` is the coercion). The rewriter's error for an
integer beside an unsigned quotient (F3) is raised at once, when the operation is built; the errors of
a quotient that waits for the comparisons around it are the engine's last.

### What the pending errors of a quotient are

| Class | Made by | Rule |
|---|---|---|
| `:quotient` | an unsigned number over text (or text over one) | `UInt64` while beside a boolean, the division's error elsewhere |
| `:division` | the quotient beside another operand, `abs()` of a quotient, a negated quotient | the division's coercion error |
| `:comparison` | an unsigned number over a boolean, the time or a duration | the comparison of that operand with `UInt64` |

A null beside any of them takes the error away (F4) -- but not the `abs()` of a null, which the engine
types `Float64`. Two of them across a comparison or a connective: the first `:comparison`, else the
last `:division`; two in arithmetic: the first for `+ - *`, and for `/` the last `:comparison`, else
the first. A pending error made with a float is a float's, so the integer-beside-unsigned error does
not apply to it (`(n) + 2.5 / (b / u)` is the division's).

### F6: the zero divisor

Measured over every placement of the zero among two to four points and two tags (96 shapes): the
stream fails with three points or more when the zero is not the last point *in the order the engine
reads them*, series by series (tag values sorted by key, two tags verified) and each series by time. A
tag or time comparison of the `AND` narrows the points before the division (verified with `=`, `!=`
and the bounds of `time`). A comparison of a field does not narrow them in any way the double tells
(`n > 5 and n / u > 0` answers, `n < 4 and n / u > 0` fails, `f > 4.0 and ...` answers for every
zero): such a statement is refused whenever the rule over the tag- and time-kept points fails. One
statement that answered by luck at d7ecf77 is now refused: `m2 where n > 1 and n / u > 0` (Core
`[2]`). Points that do not all have the same tag keys are in an order the double does not tell: a zero
among three or more of them is refused wherever it is.

## Design

### One walker, one typer (R1)

`InfluxQLWalk` is the precedence walker and the behaviour a module implements (`number/3`, `leaf/2`,
`combine/4`, `negate/2`, optional `enter/2` and `call/3`; every callback gets `InfluxQLWalk.Opts`: the
columns, `mode`, `lazy`, `whole`, `outermost`, `operand`, `calls`). `lazy` puts off the last operation
of an expression so that it is read as the whole condition reads it; an operation is settled as soon as
an operator follows, so the errors stay in order. `InfluxQLArithType` (was `InfluxQLFold`) is the only
typer; its value is `%Value{kind, pending, named, literal, deferred}`, each documented in its header.
`InfluxQLTyped.Constants` is the only other module of the walker (the numbers themselves, an integer
past the signed range is unread: the pre-scan `unsigned_literals?` is gone from `constant_kind/1`).
`InfluxQLCalls` is gone: its call rules (the arity, the signature wording, `abs()` of a null as a bare
operand) are the typer's, and `InfluxQLWhereArith.check_operands/4` is the one left-to-right check of a
comparison (calls and arithmetic of both sides, then the pair) -- it replaces `check_calls` and the
single-side half of `check_coercion/4`, which reads the sides again only for a division.

### The split of the time (F2)

`InfluxQLTimeComparand` words the error of a comparison with the bare time when the other side is
a column, a tag, the time, a name the measurement lacks (`found symbol 'n::integer'`), a boolean, a
function, arithmetic of them (`invalid expression "n::integer + 1": ...`, `-n` is `-1 * n::integer`,
a function `invalid function call 'abs'`) or the first comparison of a chain. `check_times/3` raises it
before any other error. What is not verified (the arithmetic of strings, durations and floats) is
refused by name; a SHOW statement words the symbol its own way and is left as it was.

### Tokenizer (F8)

`Regex.run` per token validated the whole rest of the text as UTF-8 each time (a 1 MB subject: 164 ms
a call). The text is now scanned in windows of 16 KB, each by one `Regex.scan` with `\G`, which keeps
the memory of a scan bounded (a scan of the whole text pushed a statement nested 8,000 deep over the
5M-word cap the harness uses). The last four matches of a window that stops before the end of the text
are read again by the next one (a number cut inside its exponent is up to four tokens). Checked against
the previous tokenizer on 60,000 random token soups, long strings at every cut, 20 expressions of
3,000 to 20,000 tokens and 840 cuts of 28 token kinds at the window edge: no difference.

`parse_select` of `select 1 from t where (n + (n + ... n)) > 1` (fresh VM, first run / steady):

| Depth | Before | After |
|---|---|---|
| 1,000 | 206 ms | 117 ms / 44-57 ms |
| 2,000 | 217 ms | 73 ms / 86-101 ms |
| 4,000 | 638 ms | 214 ms / 195-240 ms |
| 8,000 | 1,732 ms | 338 ms / 380-430 ms |
| flat sum of 4,000 terms | 1,542 ms (of 3x depth) | 405 ms |

After the fix `SQLExpr.parse` is the smallest part (68 ms at 8,000); the other passes of
`parse_select` are linear.

## Refactors

| # | What | Lines |
|---|---|---|
| R1 | `InfluxQLCalls` deleted (180); `Fold.waiting/1`, `Calls.handlers/4`, `floated/3`, `settle_all/2`, the closure maps; `Typed.constants/0` handlers; `WhereArith.check_coercion` single-side half | about 330 removed, `InfluxQLWalk` (230) and `InfluxQLTimeComparand` (250) added |
| R2 | `strip_parens/1` (2 copies) is `InfluxQLTokens.strip_parens/1`; `InfluxQLTokens.boolean_word?/1` replaces 9 copies of the list; `unsigned_literals?` pre-scan out of `constant_kind/1`; `check_coercion` walks a side once, and again only for a division | 25 |
| R3 | `coercion_body/3` private; `abs_call/2` is `signature/3` + `abs_call/2` + `abs_body/3`; `raise_coercion/1` is `raise_first_error/1`; `InfluxQLFold` is `InfluxQLArithType` (it types); every value documented | |

## Files modified

`influxql_walk.ex` (new), `influxql_arith_type.ex` (was `influxql_fold.ex`), `influxql_time_comparand.ex`
(new), `influxql_calls.ex` (deleted), `influxql_where_arith.ex`, `influxql_where.ex`,
`influxql_nested.ex`, `influxql_typed.ex`, `influxql_tokens.ex`, `influxql_query.ex`, `influxql.ex`,
`sql/sql_expr.ex`; `test/support/contract/influxql_nested_cases.ex` (the fixture `~p4`, six tables of
130 cases and 4 refusals), `influxql_shape_cases.ex` (11 refusals became answers),
`influxql_planner_contract.ex`; `test/influx_elixir/client/local/sql_expr_tokens_test.exs`.

## Verification

- **Differential** against Core, one database, Local capped at 5M words, the tables of
  `InfluxQLNestedCases`, seeded mutants (seeds 21 and 22, 2,500 each), an operand-pair matrix of 35
  operands x 4 operators x 5 shapes, the 3 x 35 x 35 comparisons, 4,000 chains of three and the
  statements of the review: 39,353 statements.

  | | match | mismatch | refusal | raised |
  |---|---|---|---|---|
  | d7ecf77 | 35,467 | 2,850 | 1,036 | 0 |
  | now | 38,212 | 270 | 871 | 0 |

  One statement that matched at d7ecf77 does not now (it is refused, see F6); 2,746 that did not
  match do. Most of the 270 are parse-error positions of mutants and the big-literal arithmetic.
- **Tables.** The 4,446 cases and 259 refusals of the InfluxQL planner tables that `check_fix` and
  `check_rows` run (Call, Defect, Fix, Glue, Nested, Order, Projection, Shape) answer as their tables
  say through `Client.Local` (helpers' logic, no ExUnit).

## Known differences left

- A comparison of a field beside an unsigned division by zero is refused whenever the tag- and
  time-kept points fail the rule; Core answers some of them.
- `(u / s) = abs(nosuch + 1)` answers `[]` (Core: the division's error), `(u / s) = (nosuch + 'x')` is
  refused.
- Arithmetic of an integer past the signed range beside a column (`(n) * 9223372036854775808 > 1`)
  answers differently, as before.
- `1 < time < 3 AND b`: refused (Core: `Int64 < Timestamp(ns)`).

## SQL: the parser's recursion limit (R2)

**Finding.** Core's SQL front end (sqlparser-rs) counts the nesting of its recursive descent and
stops at 50: `SQL error: RecursionLimitExceeded (current limit: 50)`, status 400. `Local.query_sql`
had no limit: it answered a nest 12,000 deep and its process passed 40 MB at 20,000.

**What counts (read from Core 3.10.1, one request at a time).** The counter is decremented while
`parse_statement` (1), `parse_query` (1) and every `parse_subexpr` run, and the call that finds it
at zero fails. A statement's first expression is therefore the third level, and a nest gets 47 more.

| Shape (inside `WHERE <nest> > 0`, a select item, `ORDER BY`, `GROUP BY`) | Core answers | Core refuses |
|---|---|---|
| `(v + (v + ... v))`, `*`, `AND`, `OR`, `-( ... )` (n levels) | 23 | 24 |
| `true BETWEEN false AND (true BETWEEN ...)`, either bound in parentheses | 23 | 24 |
| `- - - v`, `abs(abs(...))`, `coalesce(0, coalesce(...))` | 47 | 48 |
| `(-v * (-v * ...))` | 23 | 24 |
| `(v + 2 * (v + 2 * ...))` (the tighter `*` climbs one level deeper) | 15 | 16 |
| `NOT NOT ... v > 0` | 46 | 47: `ParserError("Expected: end of statement, found: v at Line: 1, Column: ...")` |
| flat `v + v + ... + v`, `a AND b AND ...` (200 terms) | answers | (no extra depth) |
| `true IN (true IN (...))`, `true IN (true, true IN (...))` | answers to 30 | not probed |
| `CAST(CAST(...))`, `NOT (NOT (...))`, `CASE WHEN .. THEN CASE ...` | answers to 20 | not probed |
| `v IN (SELECT .. WHERE v IN (SELECT ..))`, `EXISTS (SELECT ..)` | answers to 22 | slow at 23 |

A unary sign, a `NOT`, a call argument, a parenthesised expression, a list item, a `CASE` part and
the right operand of an operator are each one level; an operator's right operand is a
`parse_subexpr` at the operator's precedence, so an operator that binds tighter after it nests one
level more (sqlparser's `Precedence`: `OR` 5, `AND` 10, `IS` 17, comparisons and `BETWEEN` 20, `+ -`
30, `* / %` 40, `::` 50). The six shapes of the first rows and the climbing shape were checked at
both sides of the threshold on Core.

**The swallowed limit.** `NOT`, `CASE` and `CAST` are keywords the parser retries as a name when
their own syntax fails, and the retry swallows the limit's error. The `NOT` chain is linear (47 is
the parser error above, which `SQLSyntax.attempt/2` reproduces to the column). `CASE ... THEN CASE
...` nested 22 deep did not answer in 5 seconds, and the probes that followed brought Core down; a
`NOT (...)` nest retries at every level the same way. These are the shapes where Core's time grows
with the depth, so they were not searched: the double refuses (`Client.Local: unsupported SQL
(statement nested deeper than Core was verified to answer)`) when more than 20 of them are open,
and when the limit is reached inside one.

**Design.** `SQLSyntax` is already a recursive descent of the engine's grammar over its tokens.
It now keeps the parser's counter (`counted/1`) at the same places, and its `infix/2` reads
operators by precedence so that the right operand of each is the `parse_subexpr` it is. A text the
mirror stops reading half-way (`:bail`: `EXTRACT(...)`, a window, a join) and a statement it does
not read whole (a shape of `INSERT`, `UPDATE`, `DELETE` below) are bounded by their parentheses and prefix operators:
refused by name past 40, since each costs the engine at least one level. Subqueries are refused by
name from the 23rd nested.

**Early and small.** A text over 8 KB whose bytes the tokenizer surely reads, and that is one
query, is checked from its first 8 KB (then 64 KB), cut at a blank or `(`, with the last 16 tokens
left out: an error of the limit raised inside the window is the error of the whole text. A statement
20,000 deep was 3 M words in the scrub and the tokenizer; it is now refused in about 4 ms.

**Verification.** 31 cases in `SQLCatalogCases.syntax/0` (every shape's last answered depth and
first refused, the flat chains, and the `NOT` chain at 46, 47 and 60) answer through `Client.Local`
as they answered on Core, run on both (`fxi25`). The 103,348 statements formed from every string
of the SQL contract and test files give the same verdict through the old and the new
`check_statements/1` and `check/1`; the 8,551 cases of the SQL contract tables (`SQLScalarCases`,
`SQLCatalogCases`, helpers' logic, no ExUnit) have 0 mismatches. The test in
`sql_expr_tokens_test.exs` asserts depth 24, 25 and 20,000 in a process capped at 5 M words.

**Statements that change data.** `INSERT`, `UPDATE` and `DELETE` are read by the same parser with
the same budget, and only then does the planner refuse them (`DML not supported`). They were first
bounded by their parentheses (refused by name past 40); `SQLSyntax.dml_recursion/1` now counts
them: `parse_statement` is the first level, an `INSERT`'s source is a `parse_query` (the second:
`VALUES` rows, `SELECT`, `(SELECT ...)`), and every cell, `SET` value and `WHERE` is a
`parse_expr`. So an `UPDATE` or a `DELETE` has one level more than an `INSERT` (read on Core
3.10.1, `coalesce(..., 1)` nested n deep, `abs(...)` and `(v + ...)` likewise):

| Statement | Nest | Answers (`DML not supported: ...`) | Refuses (the recursion error, 400) |
|---|---|---|---|
| `INSERT INTO main (v) VALUES (<nest>)`, also after another row | calls | 47 | 48 |
| `INSERT INTO main (v) VALUES ((1 + (1 + ...)))` | parentheses | 23 | 24 |
| `INSERT INTO main (v) SELECT <nest> FROM main` | calls | 47 | 48 |
| `INSERT INTO main (v) (SELECT <nest> FROM main)` | calls | 46 | 47 |
| `UPDATE main SET v = <nest>` (also a second assignment, an alias) | calls | 48 | 49 |
| `UPDATE main SET v = (v + (v + ...))` | parentheses | 24 | 25 |
| `UPDATE main SET v = 1 WHERE <nest> = 1` | calls | 48 | 49 |
| `DELETE FROM main WHERE <nest> = 1` | calls | 48 | 49 |
| `DELETE FROM main WHERE (v + (v + ...)) = 1` | parentheses | 24 | 25 |

The planner plans each operand as `SELECT <operand>`, which is one level deeper than an `UPDATE`
has (`SQLSyntax.credited/1` credits that level, since the statement was counted whole). A shape
the grammar does not read whole (`RETURNING`, `ON CONFLICT`, `FROM`, a tuple target) keeps the
bound on parentheses. The 20 cases are in `SQLCatalogCases.syntax/0` (`recursion/0`), run on both.
The reading also gives the parser's own error for `UPDATE ... WHERE n div 1` (`No infix parser for
token ... DIV`, as Core), which the double used to refuse by name; that case moved to the table of
answers. A parse error that stands later in the text than the overflow is the engine's second
answer; the double gives the overflow only when its grammar read up to it. The cost of a nest 10
and 40 deep is a line in the depth (3.6 times for four times the depth, for each statement).

**Left.** `IN` lists, `CASE`, `CAST`, `NOT (...)` and subqueries have no pinned Core threshold
(refused by name past the depth probed); `||`, `~` and `<<` are given sqlparser's `PgOther`
precedence (16) without a probe.

## InfluxQL: conditions deeper than Core answers (R3)

**Finding.** Core 3.10.1 overflows its stack (the server dies, no answer) on a `WHERE` nested or
chained deep enough, and `Local.query_influxql` answered all of them, 8,000 calls deep included. An
answer Core never gives is not the double's to give. Core's limit is not a count of levels: it
depends on what is nested, and the two statements the planner contract pins (`abs(1)` added 800
times, 400 groups that alternate) answer a few percent under where it dies.

**Measured** (Core in a container of 2 GB and 2 CPUs, every request under 8 KB, one at a time, a
restart after each request that gave no answer; 30 crashes in all, on the database `g29` with the
points of the limits test). "Dies" is status 000 with the server down within a second, except
where noted. `v` is an integer field of `nine` (1 to 9), `b` and `ok` booleans.

| Shape | Core answers at | Core dies at | Time of the last answer |
|---|---|---|---|
| `abs(abs(...v...)) = 5` | 400 and 450 (475 once) | 487 does not answer in 20 s (a timeout, the server stays up) | 11 to 14 s at 400, 18 s at 450 |
| `(v + (v + ... v)) > 0` | 450, 736 | 900 | under 1 s |
| `(1 * (1 * ... v)) > 0` | 400 | not probed | |
| `(ok = (ok = ... (v > 1)))` | 450, 540, 614, 615, 666, 667, 668, 700 | 900 | under 1 s |
| `ok = (v > 0 AND ok = (w > 1 AND ... ok = false))` | 400 (pinned) | 412 (and 425, 450) | 1 s |
| `v + v + ... + v > 0` (n terms) | 800, 809, 812, 818 | 825 (and 850, 900, 1000, 1200, 1600) | 1 s |
| `v * v * ... * v > 0` | 800 | 825, 1600 | |
| `abs(1) + abs(1) + ...` | 800 (pinned) | 860 (3,000 by the first measure) | 1 s |
| `((((v))))` | 1,460 and 1,500 | 1,800, 2,400, 3,900 | under 1 s |
| `-(-(...v...)) = 5` | 400, 800 (15 s) | 825, 850, 899, 1,000 | |
| `v = - - - ... 5` (signs before a number) | 1,500 and 2,600 | not found under 8 KB | under 1 s |
| `- - v` (signs before a field) | never: `unexpected unary expression` at any count | | |
| `b AND b AND ...` | 1,290 | not found under 8 KB | under 1 s |
| `b OR b OR ...` | 1,560 | not found under 8 KB | under 1 s |
| `v>0 AND v>0 ...`, `OR` (flat) | 800, 970 (AND), 1,090 (OR) | not found under 8 KB | under 1 s |
| `(b AND (b AND ... b))`, `OR` | 960 | not found under 8 KB | |
| `(v > 0 AND (v > 0 AND ...))`, `OR` | 400 | not probed past | |
| chain 810 or 790 under `... > 0 OR v > 0` | answers | | |

Connectives are not treated like arithmetic: a flat chain of `AND` or `OR` answers at 1,560 terms
where a sum dies at 825. Mixed forms, each near the budget of the first costs (a parenthesis 5, `AND` 8; the final ones are stricter), all answered:
200 calls around a 390-term sum (9 s), 200 calls around 340 `(v + ...)` (10 s), 100 `-(` around 100
calls around 200 `(v + ` around a 170-term sum (13 s), 100 calls around a 380-term sum (10 s), 350
calls around a 100-term sum (10 s), 280 calls around a 250-term sum (13 s), 200 `-(` around a
390-term sum, 330 `(ok = ` around a 400-term sum, 195 alternating groups around a 390-term sum, a
380-term sum or one in 80 parentheses beside a chain of 880 `OR`s, a 400-term sum in 800
parentheses (and 560 in 500), 200 calls in 800 parentheses, 250 calls in 600, a 400-term sum under
300 `(b AND `. The sum of `v` twice at the same depth (`e < 0 OR e > 0`, `e` 130 calls around 250
`-(` around a 320-term sum) did not answer in 20 s: it is the engine's time, not its stack, and the
rule refuses it long before (cost 10,490).

**Why not one depth.** Counting every node as one level cannot hold both pins (a sum of 800 and 400
groups of three nodes) and refuse 500 calls. So each node costs what its shape's cliff says, a
path costs the sum, and a condition is refused when its costliest path passes the cost of the
deepest pinned statement.

| Node | Cost | Because |
|---|---|---|
| arithmetic operator (`+ - * / % & \| ^`) | 10 | a sum dies at 825 terms |
| parenthesis | 6 | a bare parenthesis answers at 1,500 and dies by 1,800: 6 allows 1,335 |
| comparison | 7 | with a parenthesis and `AND`, one group that alternates is 20 (cliff 406: 20 x 406 = 8,120); the 20 is the 7 and 6 and 7 |
| `AND`, `OR` | 7 | a flat chain answers at 1,290 and 1,560 (7 allows 1,146); the group of 20 above |
| call | 20 | 400 calls answer in 11 to 14 s, 450 in 18 s, 487 not in 20 s |
| sign | 6 | with its parenthesis 12: `-(` 800 deep answers in 15 s, 825 dies |

The budget is **8,020**: the cost of the sum of 800 `abs(1)` under `> 0` (a comparison 7, 799
additions, a call 20: 8,017); 400 groups that alternate are 400 x 20 + 7 = 8,007. A
left-associative chain nests to the left, so `n` operators cost `n` operators. Every statement
under the budget that was probed answered (the mixed forms above included), and the statements
past it that were probed die or do not answer (a call 401 deep is refused and answers on Core, the
price of a bound that holds for the rest).

| Shape | Answered by Local up to | Core's last answer |
|---|---|---|
| calls nested | 400 | 450 (475) |
| `(v + (v + ...))` | 500 | 736 |
| `(ok = (ok = ...))` | 615 | 700 |
| groups that alternate | 400 | 400 |
| sum of `v` or `abs(1)` | 802 terms (800 with `abs(1)`) | 818 |
| `((((v))))` | 1,335 | 1,500 |
| `-(-(v))` | 667 | 800 |
| signs before a number | 1,335 | 2,600 |
| `AND` chain, `OR` chain | 1,146 | 1,290, 1,560 |
| `(b AND (b AND ...))` | 616 | 960 |

Every bound is under the last answer Core was seen to give for its shape.

**Where.** `InfluxQLDepth.check/1` runs in `InfluxQLParser.parse_statement/1` as soon as the text
after the sources is known, before the clauses are read: a precedence climb over the masked text
(literals blank, comments blank) that builds nothing, keeps the cost of the path above the node
it is reading, and throws at the first node past the budget (a `((((` of 100,000 is refused after
1,337 characters; the recursion never passes the budget over the cheapest node, 1,337 frames). It
does not parse: what it cannot read it leaves, and the parser gives the engine's error. A refused
statement is `Client.Local: unsupported InfluxQL (a condition nested or chained deeper than 8020
units, where InfluxDB 3 Core 3.10.1 overflows its stack: a call counts 20, ...): <statement>`,
status 400. `SELECT` items, `GROUP BY` and `SHOW ... WHERE` are not measured (their conditions were
not probed).

**Verification.**
- `influxql_limits_test.exs` states the Core answer at the deepest verified depth and the named
  refusal past it and at the old depths (500 to 8,000), in a process capped at 5 M words: groups
  that alternate 400 (the two false points), 401, 450, 800; a sum of 800 calls (all 9 points), 804,
  3,000; calls 400 (`v = 5`), 401, 500, 1,000, 4,000, 8,000; `(ok = ...)` 614 (the two false
  points), 615 (none), 616, 668, 1,500, 3,000, 6,000.
- The 5,680 cases of the nine InfluxQL case modules and the planner contract fixtures (Aggregate,
  Arithmetic, Bucket, Call, Defect, Fix, Glue, Nested, Order, Projection, Shape, Show; every
  zero-arity table through `fix_outcome`, helpers' logic, no ExUnit) give the same answers with
  the check and with a budget of 100 million: 0 differences, 0 refusals by depth, 0 killed by the cap.

## Coverage pass and the round's verification

A coverage pass over `InfluxQLTimeComparand` (78% to 99%), `SQLSyntax` and `SQLExpr` added a
Core-verified case for every reachable line and removed the dead ones. It also found three more
differences, now fixed:

- A chain that ends at the bare `time` (`time > 5 < time`, `1 < 2 > time`) is Core's 500
  `split condition … InfluxQL internal error: expected Expr`, not the coercion error. An error in
  the first comparison still comes first.
- A sign with no operand after a comparison (`n > - = 2`, `n > -`, `time > - > 2`) is Core's
  `invalid conditional expression` at the end of the operator.
- `ANY`, `ALL` and `SOME` after an operand (`SELECT v ANY (1)`, `… WHERE v ALL (1)`) are an alias
  or a stray word to Core's parser, not an operator: they answer as Core does.

The two deep contract cases (alternating groups, a sum of calls) were pinned 400 and 800 deep,
within three percent of where Core's stack overflows, so a contract run could bring its own
server down. They are pinned 300 and 600 deep, where Core gives the same answers (verified).

Two notes on running Core:

- Core is run with `--memory 2g`, so that a statement that overflows it stops only the container.
- Core's CPUs must not be limited: plans that some refusal cases pin name as many partitions as
  Core sees CPUs. With `--cpus 2` they name 2 against the pinned 10, and 12 cases failed.
  `docs/design/README.md` says so beside its one-liner.

Gates, each run one at a time:

- Unit: 2,297 tests, run three times; coverage 93.53%. Format, both compile environments, credo,
  dialyzer and docs are clean.
- Integration on fresh `influxdb:3.10.1-core` and 2.7, run twice each: Core 734 tests, InfluxDB 2.7
  90 tests. Auth-enabled Core tokens: 8 tests.
- The cases padded past 8 KB, which the probes could not send, pass against Core in the contract
  run.
