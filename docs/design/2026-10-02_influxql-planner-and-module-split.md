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
  them, each a column of the point that the SQL reads (`{column, check}`; the
  caller fills it with `holds?/2`), so `AND`, `OR` and parentheses combine it
  with the rest. A plain unsigned field against a non-negative integer needs
  no check. A comparison with a string, a tag or a regular expression stays
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

---

## Second pass: what the first one refused, and the layout of `Client.Local`

Every claim below was read from InfluxDB 3 Core (`curl localhost:8181/api/v3/query_influxql`)
and the double compared with it statement by statement over the same data
(about 1,000 statements, no difference but the ones refused by name). The
answers are pinned in `test/support/contract/influxql_planner_contract.ex`
(with the cases in `influxql_*_cases.ex`), run against `Client.Local` and,
as an integration test, against Core.

**Unsigned `OR`** (`u > 5 OR i < 0` and the shapes in the contract). Fixed
as described above; it was a false refusal of what Core answers.

**Regular expressions on string fields.** `=~` and `!~` match the values of a
string field as they match a tag (unanchored, case-sensitive, `(?i)` works);
a null value matches neither. The engine reads a backslash before a letter
other than `d D w W s S p P x` as that letter (`\b`, `\A`, `\z`, `\t`, `\Q`
are `b`, `A`, `z`, `t`, `Q`; there is no word boundary), before a digit as a
back reference it refuses, and only `\/` escapes in the literal (`/\\/` is
unterminated). `!~ /.*/` on a string field is the optimizer's `= ''`. A
pattern with `\u`, a back reference or one the double cannot compile is
refused by name.

**Times.** A quoted time with a zone: `Z`, `UTC` (any case), `+HH:MM`,
`+HHMM`, with blanks before the zone, hours up to 23, minutes up to 59;
leading blanks, a `+` year and unpadded parts are read when a zone is given.
A date with a zone, a clock without seconds, `GMT`/`EST`, `+HH`, a trailing
blank are `is not a valid timestamp`. A duration is one or more
`<count><unit>` (`1h30m`); its total past the signed range is `overflow` at
the end of the literal, anything left after it (`5sx`, `1h30`) is left over
from there. `time` is compared with `term (+|-) term ...` of quoted times,
durations, integers (nanoseconds), `now()` and parentheses: an instant plus
or minus a length is an instant, an instant minus an instant a length;
instants are folded without a range and only the result must fit 64-bit
nanoseconds (`timestamp out of range: 2297-10-16 00:00:00.500 +00:00`, the
fraction in groups of three digits). `now()` is read once, when the `WHERE`
is planned, so `now() - 1`, sub-second durations and `now() + 1` are exact.
`5s - 'ts'`, `1 + now()`, `*`, `/`, `%` and a bad quoted time inside an
expression are the engine's errors; they are refused by name.

**`count(distinct(host))`** on a tag is `[]` (any aggregate of a tag alone
is); of a field it counts the distinct values.

**`GROUP BY time(every[, offset])`.** Buckets start at `offset` plus multiples
of `every` from the epoch (`time(7s)`, `time(1m, 30s)`; `time(1m, 90s)` is
`time(1m, 30s)`). The range runs from the bucket of the `WHERE` lower bound
(of the series' first point without one) to the bucket of the upper bound
(`time < x` ends with the bucket of `x - 1ns`; `now()` without one), a series
with no value in it is not answered, every bucket of it is. A bucket is
*present* when an aggregate had a value to work on in it (a `count` of zero is
no value). `fill` is applied to the aggregates before an expression is
computed: `null` (a `count` of an empty bucket is zero), `none` drops empty
buckets, `previous` carries the last value (a `count` too), `linear`
interpolates `y0 + (y1 - y0) * ((i - p) / (q - p))` (truncated toward zero
for integers; nothing before the first or after the last value), a number is
cast to the column (`1.5` is `1` for an integer, `-1` wraps for an unsigned).
A null column of a present bucket is filled like an empty bucket, a `count`
there keeps its value. `ORDER BY time DESC`, `LIMIT` and `OFFSET` apply after
the fill, per series. `fill()` without `GROUP BY time` changes nothing, but
`fill(none)`/`fill(linear)` of plain columns is the engine's planning error.
Refused by name: `fill(linear)` with a `count` or on text (Core breaks the
connection), a second `time()`, `time(0s)`, a number on a string column that
is not a plain integer or fraction, and more than a million rows in a series
(a `LIMIT` stops the stream early, so an unbounded `time(1m)` since 2024 with
`LIMIT 2` is answered).

**Aggregates.** `median` (the middle; the mean of the middle two, an integer
for integers, truncated toward zero), `spread` (`max - min`, but an integer
maximum starts at zero: a lone `-9` has spread 9; several negative values and
negative floats are refused), `stddev` (Welford, sample; null for one value
and the row stays), `min`/`max` of strings (bytes). `mean`, `sum`, `median`,
`spread`, `stddev` of a string field are the engine's planning errors, quoted
exactly. An aggregate of a tag answers nothing alone (beside a field it is
refused). A column beside a non-selector aggregate is `mixing aggregate and
non-aggregate columns is not supported`, beside several selectors `mixing
multiple selector functions ...`.

**Arithmetic.** See `InfluxQLExpr`: names are the names in the expression
joined by `_`; `/` of two signed integers is a float division and a division
by zero is zero; unsigned arithmetic wraps and a negative literal beside it is
`2^64 + n - 1`; a signed integer field beside an unsigned one, and a tag or
string in arithmetic, are the engine's planning errors. A row of a plain
select is kept when a field it names is in it; `LIMIT` counts the rows where
the expression is not null.

### Layout

`Client.Local` (facade and SQL) over `Scope` (profile, database, store reads),
`Writes`, `Admin`, `Buckets` (v2 buckets), `InfluxQLQuery`, `FluxQuery`.
InfluxQL: `InfluxQLText` (reserved words, quoting, masks, clause regex) under
`InfluxQLParser` / `InfluxQLCheck` / `InfluxQLSelectCheck` / `InfluxQLGroup`;
`InfluxQLPlan` (select-list planning errors); `InfluxQLExpr`,
`InfluxQLAggregate`, `InfluxQLBuckets`, `InfluxQLRun`. `Durations` and
`SQLLimits` are the one definition of the duration units and the 64-bit
limits. `LineProtocolColumn` moved into `LineProtocolNumber`, `InfluxQLReserved`
into `InfluxQLText`; `InfluxQLParens` and `InfluxQLShow` stay (each is read by
one caller and merging them would only lengthen `InfluxQLCheck`). Remaining
runtime cycles of the library are outside these modules (`SQLCondition` and
`SQLBatch`, `Connection`).

### Not modelled

Core's answer varies with the data or with how its optimizer folds the
expression, or is an error the double words differently: `distinct(f)` (hash
order), `median(*)`, `max(f), n` per bucket, the errors of `fill()` options
written with a blank, `time()` calls other than durations, `ts + now()`.
