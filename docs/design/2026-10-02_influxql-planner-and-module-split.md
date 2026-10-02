# InfluxQL as the Planner Reads It, and the Split of the InfluxQL and Line Protocol Modules

**Date**: 2026-10-02
**Scope**: `Client.Local` InfluxQL (`influxql*.ex`), the line protocol parser
(`line_protocol*.ex`), `store_lines` in `local.ex`, and
`test/support/contract/influxql_flux_lp_contract.ex`
**Issue**: scheduled quality sweep (review of e71cf7b)
**Supersedes**: none; extends
[`2026-09-23_local-influxql`](2026-09-23_local-influxql.md) and
[`fourth-review`](2026-10-02_fourth-review.md)

---

## Problem

A review of e71cf7b found InfluxQL answers in `Client.Local` that differ from
InfluxDB 3 Core, two of them introduced by that commit. Every claim below was
reproduced against Core 3 (`curl localhost:8181/api/v3/query_influxql`) before
it was modelled, and every statement the double now answers or refuses was
compared with Core's answer by a differential run (443 statements in the last
one, no difference).

**Introduced by e71cf7b**
- `SELECT i + as FROM t`, `i + from FROM t`, `i + FROM t`: Core fails from the
  operand on, at position 0 (`Parsing Failure: Nom("as FROM t", Char)`); the
  double gave an alias or `FROM` error at another position. After `*`, `/`,
  `%` or `&` the whole statement is unparsed.
- `SELECT i FROM t; SELECT i FROM t WHERE (`: Core's parse error for the
  second statement (position of its `WHERE`); the double said "only one
  statement". The parentheses of a `WHERE` were never checked: a `(` left open
  or empty leaves the `WHERE` unparsed (or, after an operator or connective,
  is a missing operand, after a binary `+` a failure from the parenthesis);
  a `)` that closes nothing is left over from itself.

**Unsigned arithmetic.** The rule, found by probing, is that an unsigned field
makes the expression around it unsigned (UInt64): both sides of an operator
are cast, an integer next to an unsigned becomes unsigned with a negative one
as `2^64 + n - 1` (the lowest integer is null), and `+ - *` wrap. `-x` is
`x * -1`, so `-u < 0` is never true and `u * -1 = 2` holds for `2^64 - 1`.
`/` truncates and a division by zero is null. An integer field compared with
an unsigned one is cast to unsigned (`j > u`). A `SUM` wraps at the range of
its field's type (Int64 and UInt64), and a float one past the double range is
null (`mean` too); `Enum.sum` neither wrapped nor survived the overflow
(`ArithmeticError`).

**Older differences**
- `not` is a name: `WHERE not`, `k = not`, `not = 7` answer as for any field
  (`NOT x` leaves `x` over, `not (` is a call).
- `SELECT i AS time` has the extra `time_1`; names are numbered in the order
  of the list, skipping those taken; a selected `time` is the leading column
  (named by its alias) and no field of its own, so `SELECT time FROM t` is
  empty; `TIME` in any case is the time.
- `WHERE time = 'a'` is a 400 `'a' is not a valid timestamp`, a time in a form
  it reads that does not fit 64-bit nanoseconds is `timestamp out of range`
  (it was a 500 Arrow error); `GROUP BY time` is `invalid TIME call, expected
  1 or 2 arguments` at the end of the word; `WHERE time` is a 500 "expected an
  element on stack" (`invalid expr stack` beside `AND`/`OR`, a type error in
  parentheses); a constant select item is "field must contain at least one
  variable" and a function of one "expected field argument in f(), got
  Literal(...)" (it answered an empty list).
- `GROUP BY (` was accepted; a string, quoted identifier or regular
  expression that is never closed answered (the lexer's error is at the end
  of the text); `=~` followed by anything but a regular expression was passed
  to the SQL engine; two tags compared (`k = x`, `k != x`, `k = k`) answered
  rows where the engine's answer is empty; the `WHERE` of `SHOW TAG VALUES`
  was not checked at all (`WHERE (` answered).

**Structure.** `influxql.ex` was 2,223 lines and `line_protocol_parser.ex`
1,736, each with functions of 65 to 76 lines.

## Design

Behaviour first, each as the engine does it or refused by name.

- **Unsigned arithmetic is evaluated by `InfluxQLArithmetic`**, not rewritten
  into SQL: the SQL engine of `Client.Local` (which models the SQL path of
  Core, where the same comparison is decimal arithmetic) cannot express
  UInt64 casts and wrapping. `where_plan/3` returns, beside the SQL and the
  lower bounds, `checks`: comparisons of numbers with an unsigned field in
  them, which the caller applies with `keep?/2` over the rows the SQL kept.
  One inside an `OR` is refused by name (a check cannot be one branch of an
  SQL `OR`); a comparison with a string, a tag or a regular expression stays
  on the old path. Rejected: an SQL rewrite with explicit moduli (no `UInt64`
  literal or cast exists in the SQL subset, and the exact decimal arithmetic
  does not wrap).
- **Planner errors carry their status.** `{:error, {:engine, status, body}}`
  joins `{:engine, body}` (400); the 500s of the planner are the engine's.
- **Quoted times** are classified by `InfluxQLTime` before the SQL engine
  sees them: strict forms (`YYYY-MM-DD`, RFC 3339 with `Z` or an offset, the
  space form without a zone) are answered, structures the planner refuses
  (no date, a clock without a zone after `T`, impossible calendar or clock
  fields, trailing blanks, a five-digit year) are its 400, and forms the
  double cannot tell from the engine's (leading blank, `1970-1-1`, `+0100`,
  `UTC`, negative years) are refused by name rather than guessed. The first
  second of 64-bit nanoseconds (before 1677-09-21T00:12:44) is refused by
  name: the SQL engine cannot read it.
- **Select-list planning** (`InfluxQLLiteral`, `InfluxQLNames`) runs after
  the `WHERE` is planned and before `LIMIT` is checked, as the engine does.
  Names are resolved when the statement is parsed, so the rows are shaped
  with their final names. `*` beside other items, and items that end up with
  the same name, are refused by name (the engine's own error quotes its
  internal expressions).
- **`NOT` is an identifier.** A word, number or quoted text right after it
  (other than `AND`/`OR`) is the engine's leftover error; `not (` goes the
  way of any call, refused by name.
- **Not modelled**, because Core's answer varies with how its optimizer folds
  the expression: a bare non-boolean field inside `AND`/`OR` (an empty answer,
  a type error or a different empty answer depending on the neighbours), and
  the function calls of a `WHERE`. They stay refused by name.

Structure: `InfluxQL` is the entry point and the types; the work is in
`InfluxQLParser` (+ `InfluxQLCheck`, `InfluxQLSelectCheck`, `InfluxQLParens`,
`InfluxQLReserved`, `InfluxQLError`), `InfluxQLWhere` (+ `InfluxQLTokens`,
`InfluxQLTyped`, `InfluxQLArithmetic`, `InfluxQLTime`, `InfluxQLSql`),
`InfluxQLRun`, `InfluxQLShow`, `InfluxQLNames` and `InfluxQLLiteral`. The line
protocol parser keeps `LineProtocolParser` as the entry point (types,
`parse_lines/3`) over `LineProtocolScanner` (lines, blanks, numbering),
`LineProtocolV3` and `LineProtocolV2` (the grammars), `LineProtocolNumber`,
`LineProtocolTime`, `LineProtocolEscape`, `LineProtocolColumn` and
`LineProtocolError`. `syntax_error_body` is a table of messages; `store_lines`
delegates its error bodies. `SHOW TAG VALUES` reads its `WHERE` as a `SELECT`
does (its planner errors come without the frame a `SELECT` gets).

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/influxql.ex` | entry point, types, delegates |
| `lib/influx_elixir/client/local/influxql_*.ex` | the split, and the new modules above |
| `lib/influx_elixir/client/local/line_protocol_*.ex` | the split |
| `lib/influx_elixir/client/local.ex` | `check_items`, checks over rows, status of engine errors, `store_lines` shortened |
| `test/support/contract/influxql_flux_lp_contract.ex` | `===` contract tests for each behaviour above, and for `SHOW TAG VALUES` |
| `test/influx_elixir/client/local/influxql_planner_test.exs` | what the double refuses by name, and the pure helpers |
| `CHANGELOG.md` | entry |

## Verification

- Differential run of 443 statements (the contract's, with the contract's
  data) against Core 3 and `Client.Local`: no difference. Statements the
  double refuses by name are listed in the `InfluxQL` moduledoc.
- `mix test`, `mix credo --strict`, `mix dialyzer`,
  `MIX_ENV=test mix compile --force --warnings-as-errors`.
- A 100k-line write (median of 7 runs, three rounds alternating the old and
  the new build on a shared machine): `parse_lines/3` 934, 686, 670 ms
  before and 679, 580, 619 ms after; `Local.write/3` 1516, 1703, 1222 ms
  before and 1434, 1350, 2072 ms after. The spread between rounds is larger
  than any difference between builds: no regression.
