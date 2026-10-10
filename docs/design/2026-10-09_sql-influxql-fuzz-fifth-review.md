# SQL and InfluxQL Differential Fuzz, Fifth Review: Precedences from the Engine, Calls Counted, Quotients Typed, Items Bounded

**Date**: 2026-10-09
**Scope**: `Client.Local`'s SQL front end (`lib/influx_elixir/client/local/sql/*`: the parser mirror
`SQLSyntax`, the clause patterns, the DML operand writer) and its InfluxQL planner
(`lib/influx_elixir/client/local/influxql/*`: the typer, the walker, the depth bound, the order of the
errors of a connective), at 8b39c7e.
**Issue**: review of the [fourth review](2026-10-09_influxql-fuzz-fourth-review.md)'s commit.
**Supersedes**: the "left" paragraph of its SQL section, which gave `||`, `~` and `<<` a precedence
"without a probe".

Every claim was read from InfluxDB 3 Core 3.10.1 (`influxdb:3.10.1-core`, no auth, `--memory 2g`, all
CPUs), one request at a time, on the database `fxi29`: the SQL fixture of `SQLScalar.fixture/0`
(`main`, `mext`, `ping`) and the measurement `m` of the review (a tag `t`; `n` integer, `f` float, `b`
boolean, `u` unsigned, `s` string; five rows `(a,1,0) (b,2,3) (a,-3,5) (b,7,2) (c,4,1)`, the `~p3` of
the planner contract).

## Problem and findings

| # | Statement | Core | Before | After |
|---|---|---|---|---|
| F1 | `"SELECT " <> 60 x "- " <> "1 " <> 2100 x "+ 1 " <> " /*"` (8.5 KB), `" $$"`, `" $a$ x"` | `TokenizerError("Unexpected EOF while in a multi-line comment ... Column: 8533")`, the dollar-quote errors | `RecursionLimitExceeded` | as Core (the window path is taken only for a text with no `/*` and no `$`) |
| F2 | `SELECT CEIL(<60 x "- ">1.5)`, `CEIL((1 + (1 + ... 1.5)))` 24 deep, `SUBSTRING('abc', <nest>)` | `RecursionLimitExceeded`, from 47 signs / 24 parentheses | answered | as Core, for `CEIL`, `FLOOR`, `SUBSTRING`, `SUBSTR`, `OVERLAY`, `TRY_CAST`, `EXTRACT`, `POSITION`, `TRIM` |
| F3 | `INSERT INTO main (v) VALUES (<s signs>1)`, `INSERT ... SELECT`, `UPDATE main SET v = <s signs>1`, `UPDATE ... WHERE`, `DELETE ... WHERE` | `DML not supported` to s = 47 (INSERT) / 48 (the others), the recursion error after | `RecursionLimitExceeded` from s = 25 | as Core |
| F4 | `u + n / 1 = b`, `u + (n / 1) = b`, `n / n + u = b`, `u + 1 / 1 = b`, `u + 4 / 2 = b` | `UInt64 = Boolean` | `[]` | as Core |
| F4 | `u + n / 2 > b` | `UInt64 > Boolean` | `[]` | as Core |
| F4 | `u + n / 2 = 5` (rows), `u + n / 2 = 3`, `n / 3 + u = 3`, `u - n / 2 > 1`, `u * (n / 5) > 1` | rows, the quotient cut to an integer | rows of the float | as Core (1,120 comparisons: 502 differed; now 1,030 match and 90 are refused by name, where the stream fails on Core) |
| F4 | `u + u / s = b OR u + u / s > 1`, `u / u / b = b OR u / u / b > 1`, `u + s / u = b OR u + s / u > 1` (either order) | `UInt64 = Boolean` | `UInt64 / Utf8`, `Boolean = UInt64` | as Core |
| F5 | `SELECT 'a' = 'b' || <46 signs>1` | `RecursionLimitExceeded` | answered | as Core |
| F5 | `SELECT 1 BETWEEN 1 & 2 AND 3` (also `\|`, `^`, `<<`, `>>`) | 200 `true` / `false` | `ParserError` | read; refused by name (the double computes none of them) |
| F6 | `SELECT 1` + 32,000 blanks + `+ 1 AS x`; 32,000 blanks in a `WHERE` comparison; in a `WHERE ... IN` | answers | 3.6 s; 15.8 s; 6.7 s | 0.04 s; 0.15 s; 0.15 s |
| F9 | `select abs(abs(...n...)) from m` 650 deep, `(((...n...)))` 1,900 deep, `n + n + ...` 850 terms | the server dies | answered | refused by name |
| new | `SELECT 'ab' LIKE 'a' = 'b'`, `... LIKE 'a' IN ('b')` | `There isn't a common type to coerce Utf8 and Boolean in LIKE expression` | `Boolean = Utf8` | refused by name |
| new | `SELECT CEIL(1.5, - 1)`, `FLOOR(1.5, - 1)`, `CEIL(1.5, n)` | `Failed to coerce arguments to satisfy a call to 'ceil' function` | 405 `CEIL with scale is not supported` | refused by name (a plain number is the scale; any other second argument is a call of the function) |
| new | `u = b OR n + (u / s) > 1`, `u = b OR abs(s) > 1`, `u = b OR s + u > 1` | the error of building the second comparison | `UInt64 = Boolean` | as Core |
| new | `f + u / s > 1 AND u * (s / u) > 'x'`, `u + s / u = f OR b / u = f` | the first of the divisions a sum or a product made | the last | as Core |
| new | `select ... where - + 'x' = b` | `unexpected unary expression` | `[]` | as Core |
| new | `group by time(((1m)))` | answers | `invalid TIME call, expected a duration` (an error Core does not give) | refused by name |
| new | `u / (n / 2) > 0` | the stream fails | rows | refused by name (an unsigned division by zero) |
| new | `UPDATE main SET b = (n, -n)` | | the refusal worded `(n, (- n))` | worded `(n, - n)` |

## Findings and their rules

### F1: Core tokenizes the whole text first

A text over 8 KB is judged from its first 8 KB (then 64 KB) only when every byte of it is one that no
tokenizer error can be about. `/` and `*` and `$` stood in that set; a `/*` or a `$$` after the window
is the tokenizer's error, which comes before any error of the parser. The set now excludes `$`, and a
text with a `/*` anywhere (closed or not) is read whole, as the short texts are (a closed comment after
the window is the recursion error, as on Core: the case is pinned).

### F2: the calls with a syntax of their own

`CEIL(x [TO field | , scale])`, `FLOOR`, `SUBSTRING(e [FROM e] [FOR e])`, `SUBSTRING(e, e [, e])`,
`SUBSTR`, `OVERLAY(e PLACING e FROM e [FOR e])`, `TRY_CAST(e AS type)`, `EXTRACT(field FROM e)`,
`POSITION(e IN e)`, `TRIM([BOTH | LEADING | TRAILING] [e] FROM e | , e)` were skipped to their closing
parenthesis (counting only `(`, to 40). They are read now (`special_call/2`): each expression of them is
a `parse_expr`, counted as one is, `POSITION`'s first operand a `parse_subexpr` of `BETWEEN`'s precedence.
When the syntax of the call fails the parser reads the call as any other (`call_arguments/2`), and
reports the first error if that fails too (`POSITION` swallows the error of its own syntax and reports
the call's). A syntax error followed by a recursion error of the call is the parser's error for the
syntax, which the double does not word: refused by name. A call open inside another is read twice by the
engine's retry, so the second level on is counted with the frames that swallow the limit (20).

| Shape (inside `SELECT <call> AS x FROM ping`) | Core answers | Core refuses | The double |
|---|---|---|---|
| `CEIL(<signs>1.5)`, `FLOOR`, `SUBSTRING('abc', <signs>1)`, `SUBSTRING('abc' FROM <signs>1 [FOR 3])`, `SUBSTR`, `OVERLAY(... FROM <signs>1)`, `TRY_CAST(<signs>1 AS INT)`, `POSITION(<signs>'a' IN 'abc')`, `TRIM(<signs>'a')` | 46 | 47 | as Core |
| `CEIL((1 + (1 + ... 1.5)))`, `EXTRACT(YEAR FROM (((...))))`, `POSITION('b' IN (((...))))`, `TRIM(BOTH 'x' FROM (((...))))` | 23 | 24 | as Core |

Each pair was read at both sides of the threshold on Core (a binary search for the first refused nest of
each of about two dozen forms; the double's threshold is the same for every one). The time of the reading is
unchanged (the cost tests of `sql_cost_test.exs` and `sql_dml_cost_test.exs` give the same ratios).

### F3: the operand of a statement that changes data

The planner checks an operand by writing it as `SELECT <operand>`; a unary minus was written `(- x)`,
which doubled the levels the parser counts for a run of signs. A sign is written `- x`. The credit of
one level (`credited/1`) was the same process-dictionary key as the recursion depth, and the inner
check's cleanup deleted it. The state of a read (a refusal, the planner's error to come, the depth, the
swallowing frames, ...) is now **one map under one key**, made by `with_state/1` for the read and put
back as it was when the read ends; the credit is a key of its own that `with_state/1` reads. The four
cleanup idioms and the hand-kept `@flags` list (14 keys) are gone.

### F4: the quotient of integers is an integer to the planner

Alone, `n / 2` is a float (`n / 2 = 1.5` holds). Beside an unsigned number the planner types it as the
integer's type (`u + n / 2` is `UInt64`), and the value is the float **cut toward zero and cast to
unsigned like any integer** (verified over 1,120 comparisons: `u + n / 2 = 3` holds for `u = 5`,
`n = -3`; `u + n / 2 * 2 = 1` holds for it too, `u + n / 1 > 1` drops the point). The typer's value has
a `quotient` marker (as it has `literal`): set by an operation of two integers or markers whose result
is a float, kept by a sign and `abs()`, read by `typed_beside/2` (an integer beside an unsigned number).
`InfluxQLArithmetic` casts such a quotient the same way where it meets an unsigned operand
(`cast_quotients/4`); a division by an unsigned zero it makes is refused by name as before.

Across a connective the planner builds every comparison before it types any:

1. the errors of building a comparison (the rewriter's `cannot use + between an integer and unsigned`,
   the coercion of an operation, a call) come first, in the order of the comparisons;
2. then the first comparison of two types that do not meet (`UInt64 = Boolean`), even when the side that
   is unsigned also holds a division that waits (`u + u / s = b OR n > 1`; alone the division's error is
   the engine's);
3. then the errors of divisions that waited: the first comparison of an unsigned number with the wrong
   type, else the **first** division a sum, a product or a call made of a quotient, else the last of the
   quotients themselves (`(b / u) < (u / s)`).

(1 and 2 were the old behaviour for the first comparison only: a clash thrown at once hid the errors of
the comparisons after it, `u = b OR n + (u / s) > 1`.)

### F5: one table of precedences

Read from Core, by the value of `1 << 2 + 1` = 8, `1 << 2 * 3` = 64, `1 << 2 = 4`, `1 | 2 << 1` = 5,
`3 ^ 1 << 1` = 4, `2 & 3 << 1` = 4, `5 | 3 ^ 1` = 7, `1 + 3 & 2` = 0, `2 * 3 || 'y'` = `'6y'`,
`1 + 2 || 'y'` (a coercion error), `'a' ~ 'a' = true`, `'a' = 'a' ~ 'a'` (`Boolean ~ Utf8`),
`'a' ~~ 'a' = true`, `'ab' ~ 'a' || 'b'`, `'a' ~ 'a' LIKE 'x'`, `'a' LIKE 'a' ~ 'a'`, and by the first
nest the parser refuses after each operator:

| Operators | Precedence |
|---|---|
| `::`, `[`, `->`, `:`, `(` | 50 |
| `*`, `/`, `%`, `//`, `\|\|` | 40 |
| `+`, `-` | 30 |
| `&` | 23 |
| `^`, `<<`, `>>` | 22 |
| `\|` | 21 |
| `=`, `==`, `<`, `>`, `<=`, `>=`, `<>`, `!=`, `<=>`, `~`, `!~`, `~*`, `!~*`, `~~`, `~~*`, `!~~`, `!~~*` | 20 |
| `LIKE`, `ILIKE`, `SIMILAR` | 19 |

(sqlparser: `MulDivModOp` takes `||`; `Caret` takes `^`, `<<`, `>>`, `#`; the regular expression and
`LIKE` operators are `Eq`. The double had `||`, `<<`, `>>`, `~` at 16 and `~~` at 19.) The table is
`@symbol_precedence`: the right operand of every operator **and the low bound of a `BETWEEN`** (which is
`infix/2` at `BETWEEN`'s precedence, `1 BETWEEN 1 & 2 AND 3` reads) are both read from it; the
`@bound_operators` is gone and `@operators` is derived from it. `SQLExpr` (which evaluates) applies a
comparison and a
`LIKE` from the left, where the pattern of a `LIKE` goes on with a tighter comparison, `IN` or `BETWEEN`
(`'ab' LIKE 'a' = 'b'`): refused by name.

### F6: a run of blanks

`(.+?)\s+FROM`, `(.+?)\s+AS`, `WHERE\s+(.+?)(?:\s+GROUP ...)` and about twenty patterns like them tried every
blank of a run as the start of the next token and read the rest of the run from each. A lookbehind
`(?<=\S)` after the lazy part (the shortest match never ends in a blank) makes each linear; the `$`
alternative of the `WHERE` pattern is `\s*$` for it. Measured (fresh VM, `Local.query_sql`, `main` of
five rows, least of the runs shown):

| Blanks | select item (HEAD / now) | `WHERE v ... > 1` | `WHERE v ... IN (1, 2)` | `ORDER BY v ... DESC` |
|---|---|---|---|---|
| 8,000 | 344 ms / 154 ms | 1,074 / 62 | 450 / 43 | 270 / 6 |
| 16,000 | 717 / 10 | 4,041 / 69 | 1,765 / 66 | 282 / 13 |
| 32,000 | 3,634 / 36 | 15,825 / 147 | 6,688 / 147 | 287 / 28 |

(`SELECT 1` + N blanks + `+ 1 AS x` at the review's N = 8,000 / 16,000 / 32,000: 0.25 / 1.0 / 4.3 s.)

### F9: the select list and the other clauses

`InfluxQLDepth` read the `WHERE` only. Core's stack overflows in the select list too, at depths of its
own (the server dies, status 000 and no health; 14 crashes in all, each followed by a restart; `m`,
every request under 8 KB):

| Select item | Core answers | Core dies |
|---|---|---|
| `abs(abs(...n...))` | 625 (13 s) | 641, 650, 700 |
| `((((n))))` | 1,500, 1,604 | 1,900, 2,250, 3,000 |
| `n + n + ... + n` | 800 terms | 850, 900, 1,000, 1,200 |
| `n + (n + (... n))` | 700, 729 | 1,000 |
| `-(-(...n...))` | 800, 802 | 1,000, 1,200 |
| `abs(n) + abs(n) + ...` | 800 terms | not searched |
| 200 `abs(` around a sum of 500; 300 `-(` around 200 `abs(` around a sum of 200 (18 s); 1,000 `(` around a sum of 280 | answer | not searched |
| `GROUP BY time(((...(1m)...)))` | 1,500 | 2,500 |
| `GROUP BY time(1d+1d+...)` | 2,600 terms (the size of a request) | none found |

Other clauses with an expression: `GROUP BY time(<expression>)` (the double reads none: any expression
there is refused by name, now also a group in two or more parentheses, which was an engine-shaped parse
error `invalid TIME call` that Core does not give). `LIMIT`, `OFFSET`, `ORDER BY`, `FILL`, `TZ` take no
expression (`select n from m limit (1)`, `order by (time)` are parse errors on Core).

A select item is not a `WHERE`: the engine takes 625 calls where the `WHERE`'s cost of 20 allows 401,
and a parenthesis after an operator costs it almost nothing (`n + (...)` 700 deep answers where the sum
of the costs of the `WHERE` would not). `InfluxQLDepth` has the costs of two places now, each item
checked on its own:

| place | budget | `+ - *` | `( )` | `( )` after an operator | call | sign | `=`, `AND`, `OR` |
|---|---|---|---|---|---|---|---|
| WHERE (as before) | 8,020 | 10 | 6 | 6 | 20 | 6 | 7 |
| item (tenths of a unit: a call is 12.8) | 160,100 | 200 | 100 | 20 | 256 | 100 | 140 |

The bounds are depths Core answers: 625 calls, 1,601 parentheses, 800 terms, 727 levels of `n + (...)`,
800 levels of `-(...)`; the mixed shapes above (cost 151,000 to 155,800) answer. The refusal is
`Client.Local: unsupported InfluxQL (a select item nested or chained deeper than 160100 units, ...)`.
The contract pins the items at three quarters of the crash depth at most (400 calls, 1,000
parentheses, 600 terms, 500 levels of `n + (...)`, 600 of `-(`); the refusals are unit-tested only
(`influxql_limits_test.exs`), since the statements past the budget kill Core.

## Refactors

| # | What | Lines |
|---|---|---|
| R1 | `SQLSyntax`: one state map, `with_state/1`, `state/2`, `put_state/2`; the 14 key attributes, `@flags` and the four cleanup idioms (`Enum.each(@flags, &Process.delete/1)` twice, the save-and-restore of `dml_recursion/1`, `credited/1`'s delete) | about 45 removed, 30 added |
| R2 | `SQLSyntax`: one precedence table (`@symbol_precedence`); `@operators` derived from it, `@bound_operators` and `before_and/1` (4 clauses) gone | 30 removed, 45 added |
| R3 | `InfluxQLTimeComparand` implemented on `InfluxQLWalk` with a `Part` value (`number/3`, `leaf/2`, `combine/4`, `negate/2`, `group/2`, `call/3`): the third copy of the grammar (`sum`, `product`, `more`, `factor` x 9 clauses, `arguments`) gone, with `arguments/3`'s `case rest` and `factor/2`'s missing catch-all, the latent raises | 91 removed, 86 added (the file: 255 to 250 lines) |
| R4 | `InfluxQLWalk.Opts` is `ctx`, `calls`, `state`; `whole`, `outermost`, `operand`, `mode`, `lazy` are `InfluxQLArithType.Config`, the walker asks the module for the options of a put-off operation (`lazy/1`); `group/2` and `enter/2` are optional | 5 fields moved, 2 callbacks added |
| R5 | `InfluxQLDepth.budget/0` and `message/0` (dead) removed; the messages are built from the costs of each place | 10 removed |
| R6 | the kind `false` of `InfluxQLArithType.Value` is `:false_constant` | 9 sites |
| R7 | `early_verdict/1` keeps the verdict of the last long text: the check of the query, of its statements and the parser read the windows once | |

## Files modified

`lib/influx_elixir/client/local/sql/`: `sql_syntax.ex`, `sql_parser.ex`, `sql_select.ex`,
`sql_clauses.ex`, `sql_predicate.ex`, `sql_where.ex`, `sql_agg_expr.ex`, `sql_dml_expr.ex`,
`sql_expr.ex`. `lib/influx_elixir/client/local/influxql/`: `influxql_arith_type.ex`,
`influxql_arithmetic.ex`, `influxql_depth.ex`, `influxql_group.ex`, `influxql_nested.ex`,
`influxql_parser.ex`, `influxql_time_comparand.ex`, `influxql_tokens.ex`, `influxql_walk.ex`,
`influxql_where.ex`, `influxql_where_arith.ex`. Tests: `test/support/contract/sql_catalog_cases.ex`,
`sql_scalar_refusals.ex`, `influxql_nested_cases.ex`, `influxql_planner_contract.ex`;
`test/influx_elixir/client/local/influxql_limits_test.exs`, `sql_blank_runs_test.exs` (new).

## Verification

- **Differential against Core**, two sets (seeds 31 and 77), each: 1,347 statements of the SQL tables
  and 1,500 of the InfluxQL tables (every 5th / 3rd), 2,500 seeded mutants of each language (one token
  deleted, duplicated, swapped, a number or operator replaced, a token inserted), and the focus of this
  round (every pair of operators of F5, `BETWEEN` with each, the nests of F2 at 13 depths, the DML nests,
  the F1 tails, blank runs; 1,120 quotient comparisons, 476 type comparisons, 900 pairs of conditions,
  nests up to 300 deep). Core ran each statement once; both trees (8b39c7e and this one, same VM, same
  fixture) were compared with its answers. `match` is the same status and body (rows compared as JSON,
  without the times); `refusal` is `Client.Local: ...`.

  | | statements | HEAD match / refusal / mismatch | now match / refusal / mismatch | matched at HEAD, not now |
  |---|---|---|---|---|
  | set 1, SQL | 4,554 | 3,611 / 871 / 72 | 3,694 / 841 / 19 | 0 |
  | set 1, InfluxQL | 5,782 | 4,840 / 231 / 711 | 5,398 / 287 / 97 | 0 |
  | set 2, SQL | 4,556 | 3,618 / 865 / 73 | 3,699 / 839 / 18 | 0 |
  | set 2, InfluxQL | 5,796 | 4,842 / 245 / 709 | 5,403 / 302 / 91 | 0 |

  (20,688 statements compared; one timed out on Core.) The first run of set 1 found 26 statements that
  matched at HEAD and not after the first version of F4's order of errors; they led to the order above
  (the comparison's clash held until every comparison is built). The mismatches left are parse positions
  of mutants (an unterminated regex, a stray word) and `time` columns of the `min(time)` family, as at
  HEAD.
- **Tables.** The 8,651 SQL cases (`SQLScalarCases`, `SQLCatalogCases`: every answer table, and every
  `*_refusable` table against the pins of `SQLScalarRefusals`: no unpinned, no stale pin) and the 4,886
  InfluxQL cases of the eight planner modules (`Call`, `Fix`, `Shape`, `Projection`, `Order`, `Defect`,
  `Glue`, `Nested`, with the pinned reason of each of their 266 refusals) answer through `Client.Local`
  as their tables say (helpers' logic, no ExUnit). Against the same run at 8b39c7e: one case changed
  (the wording of a pinned refusal, F3), 98 cases are new.
- **New cases**: 57 SQL and 41 InfluxQL (and one SQL case moved from a refusal to an answer). `SQLCatalogCases.syntax/0` (`recursion/0`: 6 pairs, 5 DML pairs, 9 nests of
  `specials`, the F1 tails, a blank run) and `syntax_refusable/0` (19, pinned in `SQLScalarRefusals`; `EXTRACT` nested 60 deep, which is answered now, moved to `recursion/0`);
  `InfluxQLNestedCases`: `integer_quotients/0` (21), `pending_across_connectives/0` (8), `deep_items/0`
  (5), 4 of `negated_constants/0`, 3 refusals.
- Cost tests (`sql_cost_test.exs`, `sql_dml_cost_test.exs`) measured with their own functions: the same
  ratios as at 8b39c7e (0.86 against 1.5, 0.97 against 1.3, 3.0 against 5, 3.6 to 4.0 against 4.5 / 5).
- **Tests corrected after the hand-off.**
  - `sql_blank_runs_test.exs` asserted a wall-clock bound (`:timer.tc`, under four seconds) and
    only that rows were a list. Each statement now answers its exact rows. The work is counted in
    reductions, as `sql_dml_cost_test.exs` counts it: a run four times as long costs 3.89 to 4.01
    times as much (measured), within 2.5 to 6, where a square would be 16.
  - The new limits tests asserted nine rows; they now assert the values, each a multiple of `v`.
  - Two window cases (an open `/*` and a closed one after the same nest) were one statement to the
    duplicate check, which reads a comment as a blank. The closed one has a `+ 1` after it, which
    changes neither answer.
- **Gates,** each run one at a time:
  - Unit: 2,314 tests, run three times; coverage 93.57%. Every changed line of the modules under
    95% is covered; their misses are older code. Format, both compile environments, credo,
    dialyzer and docs are clean.
  - Integration on fresh `influxdb:3.10.1-core` (`--memory 2g`, CPUs unlimited) and 2.7, run twice
    each: Core 737 tests, InfluxDB 2.7 90 tests. Auth-enabled Core tokens: 8 tests.

## Known differences left

- The select-item bounds are fitted to the shapes above; a shape not probed (a call in the argument of an
  aggregate, a `fill` of expressions) shares the costs of the nearest.
- `GROUP BY time(<expression>)` is refused whatever it holds; Core answers it.
- Core's answer to `SUBSTRING('abc' FROM 1 FOR - 3)` closes the connection; the double refuses it.
