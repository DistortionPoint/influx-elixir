# InfluxQL Differential Fuzz, Third Review: One Typer, Linear Calls and Groups

**Date**: 2026-10-09
**Scope**: `Client.Local`'s InfluxQL arithmetic typer, WHERE planner and condition reader
(`lib/influx_elixir/client/local/influxql/*`), at af0670d.
**Issue**: scheduled quality sweep (review of the
[second review](2026-10-09_influxql-fuzz-second-review.md) of the differential fuzz).
**Supersedes**: nothing. The "known differences left" of the second review are narrowed here.

---

## Problem

A review of af0670d found three copies of the arithmetic grammar and typer
(`InfluxQLFold`, `InfluxQLWhereArith`, `InfluxQLTyped`'s constant folding) with two vocabularies
(`:unknown/:nn/:nnf/:nz/false/{:udiv}` against `:null/:absent`) and two tables that disagreed
(`@text` of the fold has the duration and the false, `@uncoercible` of `WhereArith` has neither).
They are the root of the wrong answers below. Each claim was read from InfluxDB 3 Core 3.10.1
(`influxdb:3.10.1-core`, no auth) on a measurement of a tag `t` and an integer `n`, a float `f`, a
boolean `b`, an unsigned `u` (one of them 0) and a string `s` field, before the code changed.

### Wrong answers

| # | Statement | Core | Before | After |
|---|---|---|---|---|
| F1 | `9223372036854775808 = (n > 1)`, `(9223372036854775808) = ...`, `-(9223372036854775808) = ...`, `9223372036854775808 + 1 = ...`, `abs(9223372036854775808) = ...`, `1 * 18446744073709551615 = ...` | `Cannot infer common argument type for comparison operation UInt64 = Boolean` | `[]` | the error |
| F1 | `t * 18446744073709551615 = (n > 1)`, `s *`, `b *`, `'x' +`, `18446744073709551615 - s` | `Cannot coerce arithmetic expression Dictionary(Int32, Utf8) * UInt64 ...` (and the like) | `[]` | the error |
| F2 | `nosuch * 'x' * u`, `... * u AND b`, `-nosuch * u + t`, `nosuch * 'x' + time`, `time / nosuch2 + time` | `Cannot coerce arithmetic expression Boolean * UInt64 ...`, `UInt64 + Dictionary(Int32, Utf8)`, `Boolean + Timestamp(ns)` | `[]` | the error |
| F2 | `-nosuch + u`, `nosuch + nosuch2 + u` | `type_coercion` ... `logical boolean operation Boolean AND UInt64` | `[]` | the error |
| F3 | `u / time = 1`, `u / b = 1`, `u / true = 1`, `u / b`, `u / time`, `18446744073709551615 / b` | `comparison operation Timestamp(ns) = UInt64` / `Boolean = UInt64`, at once, whatever stands around it | `Cannot coerce arithmetic expression UInt64 / Boolean` | the error |
| F3 | `time / u = b`, `time / abs(u) = b`, `u / s AND b`, `t / u = 1 OR t / u = b` | `UInt64 = Boolean`, `UInt64 AND Boolean`; the second comparison's error beats the first's division | the coercion error | the error |
| F4 | `-nosuch + u / s = b`, `(nosuch * 1) + u / s = b`, `(nosuch / 1) + u / s = b`, `u / s + 1.5 = b`, `-u / s - f = 'x'` | `[]` | `UInt64 = Boolean` or the division's error | `[]` |
| F4 | `nosuch + 'x' + (u / s) = b`, `abs(u / s) = b` | `Boolean + UInt64`, `UInt64 / Utf8` | `UInt64 / Utf8`, `UInt64 = Boolean` | the error |
| F5 | `abs(nosuch + 'x') = b`, `... = (n > 1)`, `abs(nosuch + 'x')` | `Function 'abs' expects NativeType::Numeric but received NativeType::Boolean` (with the signature unless it is the whole condition) | `[]` | the error |
| F6 | `time + time`, `time * time`, `time / time`, `(time + time)`, `time + time AND n > 1` | `Cannot get result type for temporal operation Timestamp(ns) + Timestamp(ns): ...`, no `type_coercion` wrapper | wrapped | plain |
| F7 | `-(time) = b` | `Cannot coerce arithmetic expression Int64 * Timestamp(ns)` | `Timestamp(ns) = Boolean` | the error |
| F8 | `time * 2 > 1 AND b`, `n * time = 1 AND b`, `time + 1h = 1 AND b` | `Cannot coerce arithmetic expression Timestamp(ns) * Int64`, `Int64 * Timestamp(ns)`, `Timestamp(ns) = Int64` | `invalid expr stack` (500) | the first two; the third is refused by name |
| F8 | `nosuch * time = 1 AND b`, `nosuch * time * nosuch2 = 1 OR b` | `[]`, the points `b` is true for | `invalid expr stack` | the same |
| F14 | `1 / u = 1`, `u / u = 1`, `n / u > 1` with `u = 0` in a point | the stream fails half way (HTTP 200, the body cut off) | rows | refused: `unsupported InfluxQL (an unsigned division by zero)` |

What was found on the way (and fixed in the same pass):

- The quotient of an unsigned number and text has more rules than the second review knew. It is
  `UInt64` alone, null beside a null, null beside a float when the comparison is with no number
  (`u / s + 1.5 = b`, `= 'x'`), the division's coercion error beside a float when it is with a number
  (`u / s + 1.5 = 1`), the *outer* operation's error beside text, a boolean, a tag, a duration or the
  time (`u / s + 'x' = 1` is `UInt64 + Utf8`, `(u / s) / t` the division's), and the division's
  error alone (`t + (u / s)` is `UInt64 / Utf8`; `time + 1h * (u / s)` is `Interval * UInt64`). Dividing
  by a boolean, the time or a duration is the comparison with `UInt64` at once, but a null beside it
  takes it away (`nosuch2 - u / b = b` is `[]`). The error of a quotient waits for the comparisons
  around it (`t / u = 1 OR t / u = b` is the second's).
- An unsigned division by a zero the points make fails the stream only over three points or more and
  at a point that is not the last (measured over 2 to 4 points and a zero at each position: `[3, 0]`
  and `[0, 2]` answer, `[2, 0, 5]`, `[0, 3, 5, 2, 1]` and `[3, 0, 0]` fail, `[2, 5, 0]` answers).
  `u / 0 = 0` is folded and answers every point; a division inside a sum (`n + n / u > 1`) answers.
- `abs(-s)` and `abs(host + 1)` are null (a negated text is a null of its own, `abs()` keeps it null).
- `-(nosuch + 'x')` is a null, `-(time)` is `-1 * time`.
- `time + 1h < now()` and `-(time) = now()` are Core's "not implemented: now" (the `now()` is outside a
  comparison with the bare `time`).
- A comparison with `time` in its arithmetic beside a bare operand was never planned (the pair was put
  to false, hiding the error the SQL would raise): `(time) > 0 AND n` answered `[]`; it is refused by
  name, `time * 2 > 1 AND n` is the coercion error.

### Time and memory

Measured in a process capped at five million words, `abs(abs(...(v)...)) > 0` over nine points, and
`(ok = (ok = ... (v > 1)))` over three, before (af0670d) and after:

| Statement | Depth | Before | After |
|---|---|---|---|
| nested calls | 500 | 3.6 s | 0.17 s |
| | 1,000 | killed by the cap (3.3 s) | 0.05 s |
| | 4,000 | killed (54.7 s) | 0.23 s |
| | 8,000 | not finished in 120 s | 0.43 s |
| alternating groups | 500 | 0.83 s | 0.08 s |
| | 1,500 | 1.2 s | 0.24 s |
| | 3,000 | 4.2 s | 0.59 s |
| | 6,000 | 44.9 s | 1.8 s |
| | 12,000 | killed by the cap | 6.0 s |

The calls were quadratic in three places: the arguments of every call were found again by
`take_call` and `split_arguments`, typed again by the evaluator of `WhereArith`, and read again by
`InfluxQLCheck` for each call the text holds (the part that dominated). The groups were flattened
to tokens and classified again at each of their n levels (`time?`, `unwrap_group`,
`absent_columns`, the re-nest of `operand_sql`). What is left at 12,000 deep is the SQL parser of the
double (`SQLExpr.tokenize`, outside this directory) reading the 90 KB of SQL the condition is rendered to.

## Design

### One typer, one walker

`InfluxQLFold` is the only typer of arithmetic. `Fold.walk/2` is the one precedence walker (`sum`,
`product`, `factor`, signs, parentheses, calls with their arguments), over handlers
(`number`, `leaf`, `combine`, `negate`, `enter`, `call`):

| Reader | Handlers |
|---|---|
| `Fold.kind/3` | the kinds below |
| `InfluxQLCalls.problem/3` | the same, with the first problem of a call as the answer (the name at once, the arguments once read); a coercion error inside an argument poisons it: it is the call's answer when the call has a problem of its own (it comes first), and passes on otherwise |
| `InfluxQLTyped.constant_kind/1` | the value of a constant (`+ - *`, a quotient is unread) |
| `Fold.kind/3` with `mode: :alone` | the same, an operation put off until it is an operand: the last is the whole condition's |

The vocabulary is `Fold`'s, documented in a table in its header: `:unknown` (a column the
measurement lacks), `:nn`, `:nnf` (a null integer, a null float), `:nz` (a null of its own), `false`,
`{:udiv, l, r}`, `{:pending, body}` (an error a null beside it takes away) and the types of the
engine. `WhereArith.null?/incompatible?/standalone/argument_type` are `Fold` plus a mapping
(`shaped/1`); `Nested.raise_coercion` and `WhereArith.coercion_error` are
`Fold.raise_coercion/1`. `Fold.number_kind/2` is the one reader of a number (`-9223372036854775808`
is `Int64`, `-(9223372036854775808)` `UInt64`), used by `Fold`, `WhereArith` and `Typed`.

The quotient has four readings (`mode`): `:loose` (beside a boolean, and as an operand of a
connective), `:text` (beside a string or a tag), `:strict` (beside a number), `:alone` (the whole
condition). `WhereArith.check_coercion/4` chooses by the kind of the other side. The error of a
quotient is `{:late, body}`: `Where.join_plans/4` holds it while the other operands of the
connective are planned and raises it if they have no error of their own.

### Calls in one pass

`InfluxQLCalls` (new) reads a condition's calls with `Fold.walk/2`: each call from its name to its
closing parenthesis, once, the arguments typed as they are read. `abs()` of a boolean, a string, a
tag or the time is `Fold.abs_call/2`. `InfluxQLCheck` does not read a call again that a call read in
full holds, and finds the offset where the condition stops reading only when the first call needs it
(`reading_limit/2` is lazy, its `nil` an explicit clause, the unreachable `{:error, _unplaced}` clause
is gone).

### Groups read once

`Where.nest/2` gives each group `facts` (a time, a duration, a call, a column the measurement lacks:
four bits, in the pass that finds the groups). A condition in parentheses that is an operand of a
comparison and holds none of them is read to its tree where the comparison is read, and the
comparison keeps it as one token (`{:cond_group, tree, item}`): `Nested.classify/3` sees a group in
one token, `operand_sql/3` plans the tree. A group with a fact stays tokens, as before, and the
tokens of a comparison are written out again (`expand/1`) where the SQL or the time reads them.

### What `time` is in a condition

Only a comparison with the bare `time` on one side is split out of the condition by the planner
(`InfluxQLTokens.time_comparison?/1`: `time > 0`, `1 < time`, `time > now() - 1h`, `time != 0`;
verified over 40 forms). It alone breaks the planner's stack beside a bare operand
(`InfluxQLTime.mentions_time_comparison?/1`, `check_stack`), and the comparisons with `time` in
their arithmetic (`time * 2 > 1`, `n * time = 1`, `time + 1h > 0`, `-time > 0`, `(time) > 0`) are
typed like any other. The `OR` still refuses an operand that has the time and no comparison.

### Rejected

- A second typer for the planner's errors of calls: the walker with a tolerant `combine` does it.
- Raising the quotient's error at once: `t / u = 1 OR t / u = b` and `nosuch2 - u / b = b` need it
  to wait.
- Refusing every unsigned division by zero: `g2` of the shape cases (two points, `u / w = 0`) is
  answered by Core.

### Refactors (no change of behaviour)

| # | What | Lines |
|---|---|---|
| F10 | `WhereArith.expression/product/more/factor/negate/combine`, `typed_names`, `abs_call/abs_type/number_type`, `calls/split_arguments/call_problem/abs_problem/argument_type`, the tables `@arrow`, `@native`, `@uncoercible`, `@numbers`, `arrow/1`, `coercion_body/3` (now `Fold`'s) | 354 deleted, 70 added in `WhereArith` |
| F10 | `Typed.fold_sum/fold_product/fold_more/apply_op/fold_factor` and the private `number_kind/2` | 76 deleted, 59 added in `Typed` |
| F10 | `Nested.raise_coercion/1` | 8 |
| F11 | the `constant` flag of the fold's operands (`{kind, constant}`, `constant?/1`, `@typep operand`, the argument threaded through `combine/nulls/with_null/known/text/durations/number`) | the whole of the old fold: 307 lines became the typer, the walker and their tables |
| F12 | `Fold.nulls/4` (7 clauses with an unused `op`) is the `@null_pairs` table; `Fold.null?/1` replaces the list in `Nested.nullish?` and `Nested.expression`; `Fold.factor` asks `InfluxQLExpr.absent?/3` | 7 clauses, 2 lists |
| F13 | `@text` is `@non_numeric`; `:nn`, `:nnf` and `:nz` are in a table; `Nested.flipped/0` is `@flipped`; the moduledoc of `Nested` says it classifies; `@max_sources` stands with the other attributes; `negate(false)` is a null (`-(nosuch + 'x') = ok` keeps none, verified) | |

## Coverage pass

The new and changed code had to reach 95% of its lines (`InfluxQLFold` 90.4%, `InfluxQLCalls`
93.2%, `InfluxQLTyped` 91.9%, `InfluxQLWhereArith` 88.2%). Each uncovered line was either reached
through `Local.query_influxql` with a statement whose answer was read from Core 3.10.1 (a case in
`InfluxQLNestedCases`), or proved dead from its callers and removed. The statements were run
through a differential harness (about 20,000 statements of columns, literals, operators, calls and
conditions with the time, before and after, and the 3,600 cases of the other planner tables), and
a random soup of tokens (110,000 conditions, no crash).

### Dead, removed

| What | Why it cannot be reached |
|---|---|
| `WhereArith.unsigned_clash/3`'s boolean outcomes, `boolean_clash`, `literal_clash`, `unsigned_literal?`, `boolean_field?`, `written/1`, and `Typed.unsigned_clash({:boolean, ...})`, `Typed.boolean_clash/2` | `Nested.classify/3` types both sides first and raises the `UInt64`/`Boolean` error for every unsigned side (columns, arithmetic, `abs()`, quotients, constants past the signed range) beside a boolean column or constant; 15,000 statements of 32 unsigned forms against 17 booleans, in both orders and beside a bare operand, never got past it. Only the unsigned side against concatenated text is left (`:text`) |
| `Typed.mismatch/3`, `decide(:boolean, {:integer, n})`, the `:mismatch` outcome | a boolean field against an integer past the signed range has an unsigned side, which `Nested` raised first |
| `Typed.decide/2`'s catch-all and ordering clause, the `:never` outcome of `typed_sql` | a pair that keeps no point (a number against text, a boolean or a tag; an ordering of booleans, strings or tags) is `WhereArith.incompatible?/3`'s, before; 2,800 field/literal/operator forms in both orders never reached them (the `decide/3` operator argument went with them) |
| `WhereArith.clash?` clause for `:regex`/`:null` | a regular expression with an operator other than `=~`/`!~` is the parser's error; `incompatible?/3` runs only after `null?/3` is false |
| `WhereArith.sides/1`'s empty-side clause | a comparison with a side missing is the parser's error |
| `:huge` (`Fold.number_kind/2`, the number handler, `Typed.number_type/2`, two `filter_predicate` clauses) | the lexer refuses an integer past the unsigned range |
| `:empty` arguments (`Fold.arguments`, `settle_all`, `abs_call(:empty, _)`, the refusal of `Calls`), the `separated/4` fall-through and the call clause of `Fold.factor` for handlers with no call | the parser fails `abs(,1)`, `abs(1,)`, `abs(1 now())`, `abs(1 = 2)` as Core does (`Parsing Failure`), and the constant folder has no identifier |
| the defaults of `Fold.typer/2` and `WhereArith.standalone/4` | no caller leaves them out |

### Reached, with cases

`abs(u + 's')` (the coercion error of an argument, alone), `-(u / b) = 1`, `(u / s) + (u / s) = 1`,
`(u / s) / 'x' = 1`, `'x' / (u / s) = 1`, `u / b + 1 = 1`, `abs(u / b) = 1`, `n = -(3)`,
`s + s AND n > 1`, `s + s = t`, `n > 1 = true AND n`, `time > 0 AND abs(now())`, and the refusals
`abs(1, 2) = 1 AND n` and `s > 9223372036854775808` (in `refusals/0`).

### Answers found on the way, and fixed

| Statement | Core | Before |
|---|---|---|
| `abs(u, 1) = 1`, `abs(nosuch, 1) = 1`, `abs(1h, 1) = 1`, `abs(u / s, 1) = 1` | `abs(UInt64, Int64)`, `abs(Null, Int64)`, `abs(Interval(MonthDayNano), Int64)`, `abs(UInt64, Int64)` (a null from text and numbers is `Null`, an unsigned quotient `UInt64`, beside a float `Float64`) | `abs(Float64, Int64)` for all |
| `abs(u + 's', 1) = 1`, `abs(t + 's', 1) = 1`, `abs(time * 2, 1) = 1` | the coercion error of the argument | the arity error |
| `abs(u / s, 1)`, `abs(1, u / b)` (the whole condition) | the quotient's error | the arity error |
| `abs(1h)`, `abs(1h) = 1`, `-abs(1h) = b` | `Function 'abs' expects NativeType::Numeric but received NativeType::Interval(MonthDayNano)` | `Float64` bare, the SQL's error, `[]` |
| `time > 0 AND abs(now())`, `... AND nosuch + 1`, `... AND u + 's'`, `... AND abs()`, `... AND 1h + 1h`, `nomeasure ... AND x` (about 40 forms) | `invalid expr stack`: the planner splits the time out before it types or plans the rest, so any operand that is no comparison and no bare `true`/`false` breaks it | "not implemented: now", the call's error, a coercion error, `[]` |
| `abs(1 (2)) = 1`, `abs(1h (1)) = 1`, `abs(true (1)) = 1` | `Parsing Failure` at the parenthesis | a `Tag` error at another position, or the SQL's refusal |

`abs()` of a null (`abs(nosuch + 1)`, `abs(-s)`, `abs(nosuch2 - u / b)`) is typed `Float64` by Core
when it is a bare operand (`Boolean AND Float64`), where the double reads a null: refused by name
when it stands beside no comparison (it answered `[]`).

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/influxql/influxql_fold.ex` | the one typer and walker, the table of kinds, `abs_call/2`, modes, `{:late, _}` |
| `.../influxql_calls.ex` | new: the calls of a condition in one pass; the coercion error of an argument first, the arguments named as Core names them, `abs()` of a null as a bare operand refused |
| `.../influxql_where_arith.ex` | asks `Fold`; `check_coercion/4`, `standalone/4`; the evaluator and the calls removed |
| `.../influxql_nested.ex` | `Fold.raise_coercion/1`, `Fold.null?/1`, unsigned constants and quotients, `{:node, _}` operands, `@flipped` |
| `.../influxql_where.ex` | `nest/2` with facts, group tokens, `expand/1`, `join_plans/4` holds `{:late, _}`, the time of arithmetic beside a bare operand |
| `.../influxql_typed.ex` | the constant folded by the walker, `Fold.number_kind/2`, `standalone_field/4`, `now_outside_time?/1`; the dead clashes and outcomes removed, `bare_operand?/2` for the planner's stack |
| `.../influxql_time.ex`, `influxql_tokens.ex` | `time_comparison?/1` |
| `.../influxql_check.ex` | the read of calls: lazy limit, nested calls not read twice, `nil` for no limit |
| `.../influxql_arithmetic.ex`, `influxql.ex`, `influxql_query.ex` | `zero_division?/2`, the refusal of an unsigned division by zero, `@planner_errors` has the temporal error |
| `.../influxql_sources.ex` | `@max_sources` moved |
| `.../influxql_args.ex` | a `(` behind an operand in a condition's call is where the parser fails (`true (1)` included) |
| `test/support/contract/influxql_nested_cases.ex` | the fixture `~p3`; 8 tables (121 cases); 9 refusals; the coverage pass adds 6 tables (96 cases), 6 cases of `unsigned_quotients/0` and 5 refusals |
| `test/support/contract/influxql_planner_contract.ex` | the 8 new tests, and 6 for the coverage pass |
| `test/influx_elixir/client/local/influxql_limits_test.exs` | calls nested 8,000 deep, groups that alternate 6,000 deep |
| `CHANGELOG.md` | the entry |

## Verification

- **Differential** against the answers Core gave (one database, Local capped at 5M words, the
  same statements at af0670d and now), three sets, 36,200 statements:

  | Set | Statements | af0670d: match / mismatch / refusal | now: match / mismatch / refusal |
  |---|---|---|---|
  | 1: the tables of `InfluxQLNestedCases` as of af0670d, seeded mutants of seeds 1 to 6, an operand-pair matrix of 26 operands x 4 operators x 6 shapes (`= b`, `> 1`, `= 1`, `= (n > 1)`, bare, `AND b`), 3,000 chains of three | 19,090 | 15,383 / 1,975 / 1,732 | 18,138 / 330 / 622 |
  | 2: the new tables, their mutants of seeds 7 to 15, 14 more operands against 13, 2,000 chains of three | 9,724 | 7,072 / 1,823 / 829 | 9,344 / 145 / 235 |
  | 3: 7,386 random conditions of groups, comparisons and connectives | 7,386 | 7,215 / 27 / 144 | 7,224 / 22 / 140 |

  Every statement that matched at af0670d matches now (0 of 29,670), no refusal became a wrong
  answer, and Local raised on none (a further 12,000 random conditions of 1 to 9 tokens: 0).
- **Tables.** Every fix, refusal and rows case of the planner contract (113 tests) answers as its
  table says through `Client.Local`; each new case was read from Core 3.10.1, and the refusals are
  pinned with their reasons.
- **Coverage pass.** The tables of `InfluxQLNestedCases` (628 cases, 55 refusals) cover every line of
  `InfluxQLFold` and `InfluxQLCalls`; the other planner tables (3,600 cases) answer as before; the
  new cases were read from Core 3.10.1 and the remaining answers of the harness compared with it
  (1,700 statements of calls and bare operands: 60 differ, all in the list below, refusals, or the
  position of a parse error that counts the name of the measurement).
- **Dialyzer** found a wrong spec on `InfluxQLCheck.call_result/4`: it left out the
  `{:next, stop}` that marks nested calls read. The spec is corrected; behaviour is unchanged.
- **Gates,** each run one at a time:
  - Unit: 2,275 tests, run three times; coverage 93.41%. `InfluxQLFold`, `InfluxQLCalls`,
    `InfluxQLNested`, `InfluxQLTyped` and `InfluxQLWhereArith` are at 100%, `InfluxQLArgs` at
    98.04%. Format, both compile environments, credo, dialyzer and docs are clean.
  - Integration on fresh `influxdb:3.10.1-core` and 2.7, run twice each: Core 727 tests,
    InfluxDB 2.7 90 tests. Auth-enabled Core tokens: 8 tests.

## Known differences left

- An integer *column* beside an unsigned number (`n + u`, `(u / s) * n`) is Core's `cannot use + between
  an integer and unsigned, an explicit cast is required`; the double gives the coercion error.
- `time + 1h = 1` and `time + 1h > 0` (a time with a duration in arithmetic) are Core's
  `Timestamp(ns) = Int64`; the double refuses them by name.
- `abs(s) + -time = b` is Core's error for `abs`; the double raises the one of `-time` first.
- An unsigned division by zero where the points are fewer than three, or at the last one, answers
  as Core does; the rest of the positions are refused whether or not Core would fail them (the rule
  was measured over 14 shapes, not derived).
- A condition nested 12,000 deep takes 6 s: the SQL parser of the double reads the rendered
  condition in quadratic time.
- The errors of a comparison come in the order the planner builds them, left to right, calls and
  coercions alike (`u + 's' = abs(b)` is the coercion, `abs(b) = u + 's'` the call). The double
  raises the errors of the calls of a comparison first, then those of its arithmetic: the first
  is wrong when a coercion error stands to the left of a failing call outside its arguments
  (`u + 's' = abs(b)`, `abs(u / s) = u + 's'`).
- Core types the `abs()` of a null as `Float64` in the signature of a call it is an argument of
  (`abs(abs(nosuch + 1), 1)`, done) and in a bare operand (refused by name), and as a null in sums
  (`abs(nosuch + 1) + u = (n > 1)` is `UInt64 = Boolean`); a sum of it with text, a duration or the
  time (`abs(abs(nosuch + 1) + 'x') = 1` is `[]`, `abs(nosuch + 1) + time = b` the coercion error)
  is typed by the double as a null throughout, and answers the error for a boolean argument, or
  `[]` for the time.
- `abs(abs(u / s), 1) = 1` is the arity error for `abs(UInt64, Int64)`; the double gives the
  division's coercion error.
- A source that is a regular expression matching no measurement answers `[]` beside a bare operand
  and a comparison of the time (Core: `invalid expr stack`, as for a measurement that does not
  exist).
