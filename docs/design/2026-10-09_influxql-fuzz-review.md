# InfluxQL Differential Fuzz, Review of 1596ed2: Groups Beside Arithmetic, Qualified Sources, Shared Scans

**Date**: 2026-10-09
**Scope**: `Client.Local`'s InfluxQL parser, WHERE planner and select-list naming
(`lib/influx_elixir/client/local/influxql/*`), at 1596ed2.
**Issue**: scheduled quality sweep (review of the
[differential fuzz](2026-10-09_influxql-differential-fuzz.md)).
**Supersedes**: nothing. The "known differences left" of the fuzz document are narrowed here.

---

## Problem

A review of 1596ed2 reproduced sixteen findings against InfluxDB 3 Core 3.10.1: wrong answers,
two inputs that killed a process at 5M words, and duplicated code. Every claim below was read
from Core 3.10.1 before the code changed.

### Wrong answers

| # | Statement | Core | Before | After |
|---|---|---|---|---|
| F1 | `FROM m tz('utc') limit 1` (also `tz('Nowhere')`, `tz('')`) | `unable to find timezone at pos N` (the zone is looked up as soon as the string is read; names are case sensitive) | `Nom("limit 1")` | refused by name (which zones Core knows needs a time zone database) |
| F2 | `WHERE v > (w > 1) + 1` and kin | `Nom("+ 1", Tag)` at the operator | planner error `Boolean + Int64` | the parse error, for every shape below |
| F3 | `WHERE 'x' + v > (w > 1)` | `[]` | planner error `Utf8 + Float64` | `[]` |
| F4 | `SELECT "x\"y" / k` | column `"x\"y"_k` | `"x"y"_k` | `"x\"y"_k` (backslash too: `"a\\b"_k`) |
| F5 | `SELECT v, v, v, v_1` | keys `v, v_2, v_3` | `v, v_1, v_2` | `v, v_2, v_3` |
| F6 | `WHERE (w > 1) = ok`, `true = (w > 1)` | rows | refusal with the false text "( w (a parenthesis is not closed)" | rows |
| F6 | `FROM m, m.` | `Nom(", m.")` | refusal "a qualified source name" | `Nom(", m.")` |
| F6 | `FROM m..x` | `provided a database in both the parameters (db) and query string (m) that do not match` | refusal | the same error |

What F2 comes to (a "group" is a parenthesised condition: a comparison, `AND` or `OR` in it):
the parser reads a group as a complete operand of a comparison, never of arithmetic.

- An operator `+ - * /` behind a group is left over from the operator (`Nom` at it).
- As the operand of `+` or `-` the parse fails from the start of the operand, signs included
  (`v > 1 + (w > 1)`, `v + -(w > 1)`: `Parsing Failure`); after `*` or `/` the operator is left
  over; after a comparison or a connective the operand is missing (`invalid conditional
  expression`); at the start of the condition the whole `WHERE` is left unparsed.
- A text that fails anywhere inside a group in the operand position fails as the operand
  (`v + (NOT w)`, `v + (1 = )`: the failure from the group; `v * (NOT w)`: the operator left over).
- Inside the arguments of a call a group is another matter and keeps its old answers.
- `|`, `^`, `%` and `&` are still refused by name (the tokenizer does not read them).

F3: Core does not coerce the other side to a boolean: arithmetic of strings, tags, booleans or
numbers beside a group keeps no row. An unsigned column in the arithmetic is the planner's error
(`UInt64 = Boolean`), which stays refused by name.

F6, sources: a source with no name after its dot (`m.`, `m.1`, `m.limit`) ends the list at the
comma before it when it is not the first. A source may be qualified up to three parts
(`rp.m`, `db.rp.m`, `db..m`): the retention policy is ignored, three parts name the database
(`db` for `autogen` or none, else `db/rp`), which must be the `db` of the call (checked before the
database is looked up and before the statement is planned); with no `db` the named one is used.
Sources written with different qualifiers are `can only perform queries on a single database`.

### Performance and robustness

| # | Input | Before | After |
|---|---|---|---|
| F7 | `WHERE v > ((…(w)…))`, `((…(w)…)) > v`, `((…(w > 1)…)) = ok`, depth 1600 | heap-killed at 5M words (quadratic memory) | linear: 80 to 110 ms |
| F8 | `FROM m, m, … ` (200 copies of 1000 points), `LIMIT 1` | heap-killed | refused by name above 100,000 points times copies |

### Duplication and refactors (no change of behaviour)

| # | What |
|---|---|
| F9 | `skip` blanks helper written four times (clause scan, sources, args, group): one `InfluxQLLex.skip_blanks/2` (about 30 lines removed) |
| F10 | The FROM grammar was written five times: `Sources.split/2` now reads and returns the parsed sources and the stop; the parser's `@source`, `sources/1` and the second split are gone (about 40 lines); `{:invalid, at, detect}` is `{:missing_name, %{source_at, wanted_at}}` |
| F11 | One list of math functions (`InfluxQLText.math_function?/1`, with `date_part`, which Core's parser accepts in a condition) and one `InfluxQLTokens.split_names/1` for "a name not followed by `(`" (it was four `chunk_every`s) |
| F12 | `boolean_group?` is `strip_group` and then `boolean_inside?`, on the one scan of F7 (`InfluxQLTokens.unwrap_group/1`) |
| F13 | The `LIMIT` regex is compiled once; `fill`/`tz` and `call/3` are one clause; the end of the text is `:end`; the clause ranks are `InfluxQLText.clause_ranks/0` (the parser had its own copy) |
| F14 | `time_call?` is one regex built from `InfluxQLText.operator_glue_chars/0` (it was three) |
| F15 | `alias_leftover` lost a redundant step and its `\s`; `tz_leftover` tests `(?-i:'UTC')` |
| F16 | `absent_aggregate` has no double negative and computes `windowed_rows?` once; "a column the measurement lacks" is `InfluxQLExpr.absent?/3` (four spellings); `project/3` makes one projection per row under `fill(number)` |
| Dead code | `column_rule(:absent, …)` and the two `plain_type` clauses are gone with the module they were in |

### Found on the way, fixed in the same pass

- `v > (w > 1)` and its kin lived in `InfluxQLTyped`; a comparison with a boolean of its own as an
  operand is `InfluxQLNested` now (`InfluxQLTyped` lost 220 lines): groups, `true`/`false`, and
  arithmetic of a column the measurement lacks with text (`nosuch + 'x'`), which Core reads as
  `false` (`nosuch + 'x' = ok` keeps the points `ok` is false for).
- The condition inside such a group is planned as a condition: `ok = (s > 'a')` types the
  string ordering (false for every row) where the SQL engine would have compared the strings.
- A chain `a = b = c` is `(a = b) = c` (verified), answered when `c` is a boolean.
- `( > 1)`, `(= 1)`, `(* 1)`: an operator with nothing before it in a group fails the group
  (`v > ( > 1)` answered `[]`).
- `tz('UTC'!` and `tz('UTC't)` are no clause: the statement is left over from the `tz`.
- A quoted name or string with a backslash: `\\` is a backslash, `\n` a line feed, and any other
  escape (`'a\b'`, `"a\x"`) is `invalid escape sequence, expected \\, \' or \n` (or `\"`) at the
  character after the backslash. Local read `"a\\b"` as two backslashes and never refused the rest.
- An equality of two booleans one of which is a group is refused by name when a comparison of the
  `time` is in the condition and the equality is not its first condition (Core rebuilds it:
  `time > 0 AND ok = (w > 1)` keeps the points both are true for).

## Design

`InfluxQLNested` (new) plans a comparison when one side is a boolean of its own: a group, or the
false of `nosuch + 'x'`. `InfluxQLWhere.plan/3` asks it before it coerces the types of the other
side, so the Core order (the group decides) holds. The group's inner condition is planned by the
caller's own planner (a callback), so its leaves are typed, and groups inside it nest.
`InfluxQLParens.group_error/1` is one pass over the masked text that finds the first group beside
arithmetic, with the kind of error the parser meets (`reserved_kind`'s: operand, failure, operator,
unparsed); `InfluxQLCheck.check_where/4` orders it among the other errors of the text with
`leftmost/2`, except that an error inside the group is met first.

Rejected: refusing every `(cond) op` shape (the parse error is exact and cheap); a row cap that
also counts the rows of an aggregate (the product of points and copies is what is held).

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/influxql/influxql_nested.ex` | new: comparisons with a boolean of their own |
| `.../influxql_parens.ex` | `group_error/1`, `enclosing_error/2` |
| `.../influxql_check.ex` | the group errors in `check_where`, invalid escapes in the lexer, `unknown_zone?/2`, `broken_tz?/2` |
| `.../influxql_tokens.ex` | `unwrap_group/1`, `unwrap_parens/1`, `split_names/1`, operator first in a group |
| `.../influxql_sources.ex`, `influxql_parser.ex`, `influxql_query.ex` | one source grammar, qualified names, the database of a source |
| `.../influxql_clause_scan.ex`, `influxql_text.ex`, `influxql_lex.ex` | tz zones, clause ranks, `math_function?/1`, `unescape/1`, `skip_blanks/2` |
| `.../influxql_names.ex`, `influxql_expr.ex` | reserved names, escaped names, `absent?/3` |
| `.../influxql_typed.ex`, `influxql_where.ex`, `influxql_where_arith.ex`, `influxql_time.ex` | nested rules moved out, linear paren stripping |
| `.../influxql_plan.ex`, `influxql_projection.ex`, `influxql_run.ex`, `influxql_args.ex`, `influxql_group.ex`, `influxql_sql.ex`, `influxql_error.ex`, `influxql.ex` | refactors listed above |
| `test/support/contract/influxql_nested_cases.ex` | new tables: 158 cases, 13 of them refusals |
| `test/support/contract/influxql_planner_contract.ex` | the new describe block |
| `test/support/contract/influxql_glue_cases.ex` | two refusals now answered, moved to `exact_answers/0` |
| `CHANGELOG.md` | the entry |

## Verification

- **Differential** (21,190 statements: the contract tables, 848 matrices of the cases above, and
  seeded mutants, seeds 1 to 3, one character inserted, replaced or removed), a fresh database
  each time:

  | | match | mismatch | named refusal | crash |
  |---|---|---|---|---|
  | 1596ed2 | 18,686 | 638 | 1,865 | 1 |
  | now | 19,669 | 111 | 1,409 | 1 |

  985 statements that did not match now do. Two matched at 1596ed2 and differ now, both on
  purpose: `SELECT ov … WHERE nosuch + 'x' <> host + 'a'` (Core answers `[]` before it plans the
  condition when the select list reads no field; for a real field it is the coercion error, which
  Local now refuses by name) and `time > 0 and ok = (n > 1)` over the new fixture (the plain SQL
  agreed with Core's rebuilt condition on that data only; pinned as a refusal). The crash is a
  nine-month window of one-minute buckets killed by the 5M-word cap of the harness, as before.
- **Tables.** Every fix-style, rows, ids, show and refusal case of the planner contract
  (5,195 cases, the 158 new among them) answers as its table says through `Client.Local`, and
  the 158 new cases answer so through Core 3.10.1 as well (0 mismatches).
- **Timings**, 5M-word cap, depth of the parentheses 400 / 1600 / 6400:

  | Statement | 1596ed2 | now |
  |---|---|---|
  | `v > ((…(w)…))` | 286 ms / killed / killed | 180 / 110 / 588 ms |
  | `((…(w)…)) > v` | 29 ms / killed / killed | 17 / 92 / 551 ms |
  | `((…(w)…))` | 6 / 45 / 1,268 ms | 5 / 22 / 81 ms |
  | `v > ((…(w > 1)…))` | 9 ms / killed / killed | 12 / 21 / 69 ms |
  | `((…(w > 1)…)) = ok` | refused / killed / killed | 16 / 19 / 75 ms |
  | `v > ((…(w > 1)…)) + 1` | 18 / 74 / 501 ms (wrong error) | 6 / 16 / 69 ms (the parse error) |
  | `FROM big, big, …` x200, `LIMIT 1` | killed | refused in 2 ms |

  What is left of the 588 ms is the SQL engine reading the parentheses, which is not this
  document's code. `count(v)` over 200 copies of 1000 points answered at 1596ed2 and is refused
  now (the product is past 100,000 points).
- **Coverage of the new code.**
  - `InfluxQLNested` went from 86.54% to 100%, and `InfluxQLTyped` from 82.77%
    to 97.63%. Each reachable branch gained a case with Core's answer, and each
    branch proved dead was removed.
  - On the way, two literals made `Local` raise: 330 digits, and two 300-digit
    floats multiplied. Core answers both with no rows; Local now refuses them by
    name.
  - Two comparisons answered wrong and are now refused by name: a float field
    against an integer division (`usage > 85 / 2`), and a duration beside a group.
- **Dialyzer.** The literal `MapSet.new()` in `InfluxQLNames` tripped OTP 28's
  opaque-type check, so the reserved names are now a plain map.
- **Gates,** each run one at a time:
  - Unit: 2,221 tests, run three times; total coverage 93.24%. Format, both
    compile environments, credo, dialyzer and docs are clean.
  - Integration on fresh `influxdb:3.10.1-core` and 2.7, run twice each: Core
    704 tests, InfluxDB 2.7 90 tests. Auth-enabled Core tokens: 8 tests.

## Known differences left

- A group in the operand position that holds a literal never closed (`v + (w > 1 AND 'a) > 1`)
  is the lexer's error in Local, Core's failure from the group.
- `1 + (w>1 +` (a sign ends the text inside a group) and `(NOT w)` as an operand of arithmetic
  differ in the text the failure quotes.
- A compound group with a column the measurement lacks compared with a string, or through a
  function, differs: Core makes that leaf a null, Local false.
- `tz(UTC)` without quotes (Core: `invalid TZ clause, expected string`), and a second `tz(` after
  an unknown zone.
- The `/re/` sources with qualifiers answer the same measurements as Core only when the databases
  hold the same measurements (the harness's two databases did not).
