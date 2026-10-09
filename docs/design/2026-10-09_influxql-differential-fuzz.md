# InfluxQL Differential Fuzz Against Core 3.10.1

**Date**: 2026-10-09
**Scope**: `Client.Local`'s InfluxQL parser, planner and evaluator, at 7016034.
**Issue**: scheduled quality sweep (no open issues). The differences the
[`2026-10-09_twenty-first-review`](2026-10-09_twenty-first-review.md) left:
`GROUP BY time<c>1m)`, `v > (w > 1)`, older fuzz mismatches and a quadratic
select list.

---

## Problem

A differential run compared 32,788 InfluxQL statements between InfluxDB 3 Core
3.10.1 and `Client.Local`. The statements were:

- the contract tables' statements;
- fuzz mutants of those statements: one character inserted, replaced or
  removed at a random position, with fixed seeds 1 to 5;
- matrices of nested conditions, glued keywords, arithmetic, time, SHOW, FROM
  and GROUP BY forms.

At 7016034, 2,148 of them got an answer from Local that was neither Core's nor a
named `Client.Local:` refusal. A `SELECT` list of 4,000 items also took 1.5 s,
where 1,000 took 0.15 s.

## Causes and fixes

| Cause | Example | Core | Local before | Local after |
|---|---|---|---|---|
| A text starting with no statement keyword, or `SELECT` against a character that is no blank, operator, parenthesis or `;` | `select#n from m`, `sebect ... /* x` | `Nom(whole, Tag)` at 0, a literal or comment never closed is never met | lexer error, "expected field", or a refusal | the engine's error |
| Nothing but blanks, comments and `;` | `;` | "must provide only one InfluxQl statement per query" | refusal | the engine's error |
| `SHOW` against a character | `SHOWx`, `SHOW(x)` | `Fail` / `Many1` with the rest after `SHOW` | refusal or N | the engine's error |
| Junk after the sources and between clauses (`InfluxQLClauseScan`) | `FROM m grou~ by host`, `FROM m limit 1 s~limit 2` | left over from the junk | left over from a later clause, or a refusal | the engine's error |
| The list of sources (`InfluxQLSources`) | `FROM m-1`, `FROM m, limit 1`, `FROM m.` | `m` then left over; left over from the comma; "invalid FROM clause" | `m-1` was a name | the engine's error; qualified names refused |
| A measurement named twice in `FROM` | `FROM m, m` | every point twice | once | twice (`stddev` refused) |
| `ASC`/`DESC`, types and reserved words need a keyword boundary | `ORDER BY time desc[limit 1`, `host::tag#`, `to"p(x)` | not keywords | keywords | identifiers |
| `LIMIT` with a blank and no number | `LIMIT ` | "expected unsigned integer" at the end | left over | the engine's error |
| `GROUP BY time<c>(1m)` | `time#(1m)`, `time\r(1m)` | `time` is a name, `#` left over | "invalid TIME call" | the engine's error |
| Cut operators `\|` and `^`, characters that start no operand, bind parameters in calls | `select n^ from m`, `top(n, #2)` | `Failure` at the operand | `Error` N | the engine's error |
| A parenthesised condition compared with a column | `v > (w > 1)`, `u = (n > 1)`, `ok < (n > 1)` | the group is a boolean operand: never true, or the unsigned planner error without `type_coercion` | SQL type error, wrong rows | `InfluxQLTyped.nested_boolean/3` |
| `time` over a measurement that does not exist, or beside a column it lacks | `select time + 1 from absent` | nothing | `incompatible operands` | nothing |
| An invalid time before a bare operand | `time >= '2023-10-01T00:)0:00Z' AND 0` | "not a valid timestamp" | 500 stack error | the engine's error |
| A column the measurement lacks with `fill(number)` | `select nosuch + 1, n fill(7)` | the number wherever it is read | omitted | the number |
| Names of arithmetic that need quoting | `"a b" / ok` | `"a b"_ok` | `a b_ok` | `"a b"_ok` |
| Quadratic naming of equal select items | 4000 x `n` | | 1.5 s | 0.28 s |

Refused by name where Core's rule is not verified: qualified source names, `GROUP BY time()`
of an expression, an aggregate of a missing column inside arithmetic in buckets or a window, a
missing column aliased to a `GROUP BY` dimension, an arithmetic expression compared with a
parenthesised condition when an unsigned column is in it, and a `tz()` zone other than UTC with
a clause behind it.

## Known differences left

150 statements still differ. About 39 of them are `SHOW DATABASES`, a harness
artifact: Core held 1,500 databases and Local held 2. The rest are mostly
single statements; the groups are:

- `/re/-FROM`;
- WHERE oddities (`x.y )`, `n ^tz('UTC')`);
- `tz('U@TC')`;
- `time((1m))`;
- an out-of-range time in a WHERE;
- `group' by`;
- `u + (y + s) = 1`.

These are the next review's work.

## Verification

- **Differential.** At 7016034 the counts were 18,496 matches, 2,148 mismatches
  and 12,016 named refusals. Now they are 29,162 matches, 150 mismatches and
  3,476 named refusals. No statement that matched Core at 7016034 differs now.
  Local raises on none.
- **Contract cases.** Every claim above was read from Core 3.10.1 and is pinned
  as a contract case:
  - 215 cases in 11 new tables of `InfluxQLGlueCases`;
  - 18 pinned refusals;
  - the `exact_answers/0` lists of the tables whose refusals are now answered.

  The differential is rebuilt with `tmp/` scripts and is not part of the tree.
- **Timings,** under a 5M-word heap cap: 4,000 `n` items went from 1,530 ms to
  265 ms, and 8,000 items from over 5 s to 584 ms.
- **Unit and integration runs.**
  - Unit: 2,207 tests, run three times one at a time; coverage 92.98%; credo,
    dialyzer, docs and both compile environments clean.
  - Integration, run twice each: Core 697 tests and InfluxDB 2.7 90 tests.
    Auth-enabled Core tokens: 8 tests.
- **Fixed on the way.**
  - Dialyzer flagged the query map's new `:copies` key, missing from
    `InfluxQL.query()`, and a throw-only clause in a function spec'd to
    return. Both are fixed.
  - One pinned refusal (`distinct()` over `FROM m, m`) recorded two values in
    the order Core happened to give, and failed against Core when that order
    changed. It now selects one value, so no order is pinned.
