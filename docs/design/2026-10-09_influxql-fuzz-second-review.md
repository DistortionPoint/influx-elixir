# InfluxQL Differential Fuzz, Second Review: Arithmetic Types, Qualified Names, Memory

**Date**: 2026-10-09
**Scope**: `Client.Local`'s InfluxQL parser, WHERE planner and query path
(`lib/influx_elixir/client/local/influxql/*`), at 9ae049e.
**Issue**: scheduled quality sweep (review of the
[first review](2026-10-09_influxql-fuzz-review.md) of the differential fuzz).
**Supersedes**: nothing. The "known differences left" of the first review are narrowed here.

---

## Problem

A review of dacd5f6 found seven wrong answers, three inputs that killed a process at five
million words or took tens of seconds, and duplicated code. Each claim was read from InfluxDB 3
Core 3.10.1 before the code changed. Core stopped answering during the work, on the last
request (see Verification), so what follows is read from it up to that request.

### Wrong answers

| # | Statement | Core | Before | After |
|---|---|---|---|---|
| F1 | `nosuch + 1h = ok`, `nosuch + true = ok`, `nosuch + time = ok`, `(nosuch) + 'x' = ok`, `-nosuch + 'x' = ok`, `nosuch + ('x' + 'y') = ok`, `nosuch + nosuch2 + 'x' = ok`, `'x' + 'y' + nosuch = ok` | the points `ok` is false for | `[]` | the same rows |
| F2 | `(w > 1) = host + s`, `host + 'a' = nosuch`, `(n > 1) = 'a' + host` | `Cannot coerce arithmetic expression Dictionary(Int32, Utf8) + Utf8 to valid types` (`Utf8 + Dictionary(Int32, Utf8)` for the last) | `[]` | the error |
| F3 | `FROM rv23."x y".m`, `rv23."a\"b".m`, `rv23."select".m`, `rv23."é".m` | database mismatch (and 404) naming `rv23/"x y"`, `rv23/"a\"b"`, `rv23/"select"`, `rv23/"é"` | `rv23/x y` | the same name |
| F4 | `FROM db.select.m`, `db.where.m`, `db.AND.m`, `db."".m`, `db.foo.""`, `rp.""`, `select.m` | the mismatch naming `db/"select"`, `db/""`, `db/foo`; `[]`; the rows of `m` | unread | the same |
| F5 | `time > '2023-10-01\n'` (also `T`, zoned, short clock, space) | `... is not a valid timestamp`, quoted twice, once as Rust's debug output writes it | rows | the error |
| F6 | `(time > 0) = ok`, `ok = (time > 0)`, `ok = (n > 1 AND time > 0)` | `Cannot infer common argument type for comparison operation Timestamp(ns) > Int64` | the same with a `type_coercion\ncaused by\n` prefix | the same, plain |
| F7 | `SELECT a.b.c.d FROM m`, `SELECT db.autogen.m.v FROM m` | `Nom("SELECT a.b.c.d FROM m", Tag)` at 0 (`Failure` from the dot in a call's arguments) | `[]` | the error |
| Constants | `n > 9223372036854775807 + 1`, `9223372036854775807 + 1 < 0` | the 64-bit integer arithmetic wraps: the lowest integer | refused, or the SQL's own overflow | wraps |
| Constants | `18446744073709551615 + 1 > 0` | `[]` (unsigned arithmetic wraps to 0) | every row | refused by name |

What F1 and F2 come to: the engine types the arithmetic on a side by the types of its operands,
whatever the operator, and the double now folds the tokens the same way
(`InfluxQLFold`, new). A column the measurement lacks is `unknown`.

- `unknown` beside a number is a null number (an integer one, or a float one when a division
  or a float made it); beside the time, a string, a tag, a boolean, a duration or the false of
  another such sum, it is the constant `false` (a boolean that is no null).
- A null number and `false` keep to that: a number leaves them null, text, a boolean, a
  duration or the time make them `false` again (`nosuch + 'x' + 1 + 'y'` is `false`).
- Two operands that are no numbers (`'x' + 1`, `true / -s`, `false` beside text) make a null of
  their own that behaves as the null number. `-s` of a string, a tag or a boolean column is a
  column that is missing (`'x' * -s` is `false`), and `-nosuch` a null integer.
- The coercion errors come from the types and are raised on either side of the comparison, in
  the order written: the time beside anything but a duration, an unsigned number beside text, a
  boolean, a tag or a duration (`+ - *`; its division is the unsigned number and the error is
  the comparison's), a tag beside a string under `+`, two times or two durations under `+ * /`
  (`Cannot get result type for temporal operation ...`).
- An unsigned number beside a column the measurement lacks stays that column; beside a null
  integer it is an unsigned null, which is the planner's `UInt64 = Boolean` beside a boolean.

What the rules do not tell is left to the code that answered before, or refused.

F3: the retention policy of a three-part source is printed as the engine prints a name:
bare when it matches `[A-Za-z_][A-Za-z0-9_]*` and is no reserved word (any case), else
double-quoted with `\`, `"` and a line feed escaped. The database part is never quoted. The
column of an expression that joins names is printed the same way, reserved words included
(`"select"_k`, `"Select"_k`, `"AND"_k`: verified over every reserved word tried), so the two
share `InfluxQLText.quoted_if_needed/1`.

F4: only the last part of a source is checked against the reserved words (`m.limit` and
`db.rp.select` are "invalid FROM clause"; `select.m`, `db.where.m` and `limit.m` read), an
empty quoted name is a name (`""`, `rp.""`, `db.foo.""`), and so is an empty regular expression
(`//` matches every measurement).

F5: the escape `\n` is a line feed since the first review, and the time patterns ended in `$`,
which also matches before a final line feed. They end in `\z` now, and a content that ends in a
blank is an invalid timestamp. The other `$` patterns of the directory read the text of the
statement, not a value, but for the name patterns of `InfluxQLSql.ident_sql/1` and the literal
printer of `InfluxQLExpr`, which end in `\z` as well.

F6: no `comparison operation` error of Core carries the `type_coercion` wrapper (all 170 in the
cache of the differential are plain), so the double strips it from those the SQL engine raises.

F7: a name of more than three parts is read up to its third part and the dot is left over. As an
item (or a term of an item's arithmetic) that leaves the whole statement unparsed; in the arguments
of a call the call fails from the dot (`Failure`); in parentheses that are no call the engine's
answer differs by what stands before them, and the double refuses by name.

### Memory and quadratic behaviour

| # | Input | Before | After |
|---|---|---|---|
| F8 | `FROM m, m, ...` 33,333 times, or a measurement of 30 points 3,300 times | killed at 5M words | refused by name before the list is read (more than 2,500 sources, or a statement of more than 262,144 bytes) |
| F8 | the points a repeated measurement makes, 100,000 per measurement | each measurement was bounded alone | 20,000 per measurement, and 20,000 together over the measurements that are repeated (the rows they made) |
| F9 | `ok = (w > 1 AND ok = (n > 1 AND ...))` nested 400 / 800 deep | needs a cap of 6M / 20M words | 0.8M / 1.5M words (1,600 deep: 3M) |
| F10 | `abs(1) + abs(1) + ... > 0` x 100 / 800 / 3,000 | 0.12 s / 5.0 s / 69.7 s | 0.08 s / 0.08 to 0.12 s / 0.29 to 0.40 s |

F8: Core takes 17 s to plan 2,500 copies of one measurement, so 2,500 is the most sources that
was read from it; the product bound keeps a capped process at about fifty words a row.

F9: the cause is not the re-parse of every level. The frame of `nested_sql` kept the whole
classification, the tokens of the group included, while the group below it was planned, so a
statement n deep held n copies. The values a frame needs afterwards are worked out before the
call now, and the tokens of a comparison are dead in the branch that plans its groups. The time is
still quadratic in the depth (0.26 to 0.40 s at 400, 0.77 to 1.3 s at 800), the memory linear.

F10: `read_call` tokenized, scanned for a `)` that closes nothing and scanned for a comma outside
the parentheses the text before every call. The three are found once for the condition, each as the
offset where it starts; a call at or past the least of them is behind an earlier error.

### Duplication and refactors (no change of behaviour)

| # | What | Lines |
|---|---|---|
| F11 | `Nested.plan/4`, its `env` and the `inner` closure of `Where` (11 lines) are `Nested.classify/3`, which returns data (`:never`, `{:same \| :different, a, b}`, `{:column, operand, op, name}`, `{:constant, operand, wanted}`, `:unplaced`) over `{:group, tokens} \| :false`; `InfluxQLWhere.nested_sql/3` renders it with its own `plan/3` | `kinded/2`, `kind/2`, `sql_of/3` and the closure: 40 lines |
| F12 | `Tokens.unwrap_parens/1` is gone (`unwrap_group/1` everywhere); `connective_word_inside?` and `connective_inside?` are one (33 lines to 12); `top_level_operators` (13 lines) and `top_level_groups` (30) are `Tokens.at_top_level/2` (20); the depth of a group is never below zero | 17 + 21 + 23 lines |
| F13 | `chain/3` (15 lines) and `boolean_operand?/2` are the general rule (a comparison chained with another is the first compared with the last, in `operands/1`); `other_operand/3` has no `kind` that shadows another; `Map.fetch` for `has_key?` and `fetch!` | 19 lines |
| F14 | `InfluxQLSql.never/0` for `"(1 = 0)"` (six spellings); `InfluxQLError.refuse/1` for the throwers of Nested (`chained/0`, `refuse/0`, `refuse_timed/0`: 21 lines), Buckets, TimeExpr, Projection, Wild and Time; `Tokens.lacking/2` and `Tokens.absent_columns/3` for the five spellings of "a column the measurement lacks" (`Nested.absent?/absent_in?/false_arithmetic?/text?`: 29 lines) | 21 + 15 + 29 lines |
| F15 | `Typed.plan_comparison/2` is the one function (`plan_unnested` is gone); `Typed.plain/3` is private again (the column of a classification is a name) | 4 lines |
| F17 | `:weird` is `:false`; `part/2` and the parser's `@select` read the one `@name` and `@regex` of `InfluxQLSources`; `pair/4` and `against_boolean/5` are two cases of the one `against/5` and stay | |

Not done: the `first` and `timed` flags of `Where` stay. A pre-pass would give the leaf a shape
every reader of the tree (`Time`, `Typed`, `Where`) has to learn, for two flags that three
functions pass on.

### Found on the way, fixed in the same pass

- The unterminated string that follows the comma of the source list (`FROM m, x."`) is the lexer's
  error, not the leftover: a literal never closed right after a comma and the qualifiers of the
  source after it is read first.
- `time > 1 + time` (a bare `time` on a side) is the engine's split of the time, not a coercion:
  the fold leaves a comparison with the time on a side to the code that reads it.
- A column the measurement lacks beside a time in a condition in parentheses
  (`ok = (w > 1 AND time > 0)`) answered `[]` where Core raises the type error of the time: refused
  by name.
- The unsigned number beside a null integer (`nosuch + 1 + u = ok`, `(n > 1) = -nosuch + u`) is the
  planner's error `UInt64 = Boolean`, in the order written; it was `[]`.
- A condition with a duration in a group (`ok = (n > 1h)`) leaked the SQL (`INTERVAL '3600
  seconds'`) in its refusal; it is refused by the name "a duration beside a condition in
  parentheses".

## Design

`InfluxQLFold` is a recursive descent over the tokens of a side (sum, product, factor), with the
type of each operand and whether it is a constant (no column of the measurement in it); it
returns `{:ok, kind}`, `:unread`, or the planner's error as `{:error, body}`. `InfluxQLNested`
asks it for both sides of a comparison before it decides anything: an error is raised (left
first), a side that is the false is a boolean of its own, a null keeps no row, an unsigned null
is the planner's error beside a boolean. A comparison it does not place goes on as before.

Rejected: reading the arithmetic with `InfluxQLWhereArith`'s evaluator (its kinds fold a missing
column to a null, which the false is not); a depth limit for the conditions (Core answers 400
levels); a limit on the number of rows read before `LIMIT` (the projection drops rows with no
field, so the limit cannot be applied to the rows before it).

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/influxql/influxql_fold.ex` | new: the type of arithmetic |
| `.../influxql_nested.ex` | `classify/3` over data, the chain rule, null and unsigned arithmetic, the duration refusal |
| `.../influxql_where.ex` | renders a classification, no `plan_nested`, the frames of the recursion |
| `.../influxql_tokens.ex`, `influxql_parens.ex` | `at_top_level/2`, `take_call/1`, `lacking/2`, `absent_columns/3`; `unwrap_parens/1` removed |
| `.../influxql_sources.ex`, `influxql_parser.ex` | reserved qualifiers, empty names, empty regex, the cap of 2,500, `quoted_if_needed`, the literal after a comma |
| `.../influxql_select_check.ex`, `influxql_check.ex` | names of more than three parts; the calls of a condition in one pass |
| `.../influxql_text.ex`, `influxql_time.ex`, `influxql_error.ex`, `influxql_sql.ex`, `influxql_expr.ex` | `quoted_if_needed/1`, `\z`, `invalid_timestamp/1`, `refuse/1`, `never/0` |
| `.../influxql_typed.ex`, `influxql_where_arith.ex` | wrapping constants, unsigned constants, one `plan_comparison/2`, tag beside string, `coercion_body/3` |
| `.../influxql_query.ex` | the wrapper of comparison errors, the sum of repeated rows, the size of a statement |
| `.../influxql_buckets.ex`, `influxql_time_expr.ex`, `influxql_projection.ex`, `influxql_wild.ex` | the shared `refuse/1` |
| `test/support/contract/influxql_nested_cases.ex` | 8 new tables (209 cases), 12 constants, 12 refusals; 7 refusals now answered moved out |
| `test/support/contract/influxql_shape_cases.ex` | one refusal now answered |
| `test/support/contract/influxql_planner_contract.ex` | the new tests |
| `test/influx_elixir/client/local/influxql_limits_test.exs` | new: the limits in a capped process |
| `CHANGELOG.md` | the entry |

## Verification

- **Differential** against the answers Core gave (39,671 statements: the contract tables before
  the new ones, the mutants of seeds 1, 2 and 3 of them, a matrix of 10,028 statements of the cases
  above, and one mutant of each of those), at 9ae049e and now, the same statements, one database,
  Local capped at 5M words:

  | | match | mismatch | named refusal | crash |
  |---|---|---|---|---|
  | 9ae049e | 33,375 | 3,024 | 3,270 | 2 |
  | now | 37,105 | 341 | 2,223 | 2 |

  3,730 statements that did not match now do, and none that matched differs. (An earlier run
  of the new code killed a 20,168-row window, `moving_average(mean(v), 4) ... GROUP BY time(30s)
  fill(100)`, that needs 5M words at the margin of the cap: a counter held in the query map cost
  it the margin, and is gone.) The crashes are two windows of months of one-minute buckets.
  Local raised on none.
- **Tables.** Every fix-style, refusal, rows and SHOW case of the planner contract (4,719 cases,
  the 233 new among them) answers as its table says through `Client.Local`. Each new case was read
  from Core 3.10.1, and the double answered the same before it was written down, but for the
  twelve pinned as refusals.
- **Timings**, capped at five million words, 9ae049e then now: F8 `FROM p1` x 3,300 killed then 12 ms;
  F9 above; F10 above.
- **Coverage of the new code.** `InfluxQLFold`, `InfluxQLNested` and `InfluxQLTyped` are all at
  100%: each reachable branch gained a case with Core's answer, and each dead one was removed.
  This turned up more fixes:
  - A null divided by an integer is a null integer (`(nosuch / 1) + u = ok` is Core's
    `UInt64 = Boolean`).
  - The difference of two timestamps is refused by name. It answered `[]` where Core keeps rows.
  - The lowest 64-bit integer behind signs is typed `Int64`, as Core types it. A bare `-
    9223372036854775808 tz('UTC')` raised a `CaseClauseError`.
  - A sign outside parentheses applies to the value, so the literal inside keeps its own type.
    `-(9223372036854775808)` and `-(-(…))` are `UInt64`, as in Core; they gave a
    "non-boolean predicate" body Core does not give.
- **Tests.** The capped-process test `influxql_limits_test.exs` asserted only `is_list(rows)`
  for the 800-deep condition. It now asserts Core's answer, the two points whose `ok` is
  false, which Core gives at every even depth (verified at 2, 4, 6 and 40). Its loose `==`
  became `===`, and its redundant one-minute deadline is gone.
- **Dialyzer** found a clause of `unsigned_null?` that could never match. It and the dead
  argument it guarded are removed.
- **Gates,** each run one at a time:
  - Unit: 2,245 tests, run three times; coverage 93.32%. Format, both compile environments,
    credo, dialyzer and docs are clean.
  - Integration on fresh `influxdb:3.10.1-core` and 2.7, run twice each: Core 713 tests,
    InfluxDB 2.7 90 tests. Auth-enabled Core tokens: 8 tests.
- **Core stopped answering** on a GET of 27 KB with a sum of 3,000 `abs(1)` (it had answered
  800 in a second), which is why the sum of 3,000 and the list of 2,501 sources are not pinned
  against it.

## Known differences left

- A line feed typed inside a quoted string (`'2023-10-01<LF>'`) is an unterminated string for
  Core; the double reads it as a part of the string.
- `time + 1h` (and `1h + 1h`, `1h * 2`) beside `ok` is Core's `Timestamp(ns) = Boolean` or a null;
  the double refuses it by the SQL it would run.
- `nosuch + 1 + u` beside a number (not a boolean) and arithmetic of an unsigned number beside text
  under `/` beside a number differ in the error the double refuses or answers.
- A statement of more than 262,144 bytes, more than 2,500 sources, and more than 20,000 repeated
  points are refused by name where Core answers.
