# InfluxQL: Aggregates of `time`, Time Arithmetic, `WHERE` Strings and Calls

**Date**: 2026-10-04
**Scope**: `Client.Local` InfluxQL (`influxql_aggregate`, `influxql_buckets`,
`influxql_expr`, `influxql_plan`, `influxql_where_arith`,
`influxql_arithmetic`, `influxql_regex`, `influxql_wild`, `influxql_run`,
`influxql_query`), the case table `InfluxQLShapeCases`
**Issue**: scheduled quality sweep (defects found in the review of
[`2026-10-04_ninth-review`](2026-10-04_ninth-review.md)). Defects only.

---

## Problem

Every claim below was read from InfluxDB 3 Core 3.10.1 (no auth,
`--wal-snapshot-size 100000`), on a table of seven points over three hosts
with a float, an integer, a string and a boolean field, the last point an hour
after the others.

- **An aggregate of `time` beside a field read every point.** `max(time),
  count(s)` is the latest point that has an `s`; a series or bucket with no
  such point is not answered; `fill(0)` fills a time column with the epoch;
  `count()` of a field no point holds is `0` once another column has a value
  (`count(*)` lists every field of the measurement, not those of the points
  read). The same holds for a lone `max(time)` beside plain columns or
  expressions (`max(time), v`).
- **Arithmetic with a time, a boolean or a string** is the planning error
  `incompatible operands for operator +: timestamp and integer`
  (`max(time) - min(time)`, `mean(v) + max(time)`, `v + true`); `abs(min(time))`
  alone answers nothing and beside a field aggregate is `abs` of
  `Timestamp(ns)`. The double answered `[]` or a 500.
- **`WHERE` over strings.** `+` of two strings is concatenation (`'a' + 'a' =
  'aa'`, `s + s = 'xx'`); every other operator over a string, a boolean or a
  tag is null (`s + 1`, `-b`, `host - 'a'`); a tag beside a string under `+` is
  the engine's coercion error. A sign before a string, a boolean or a second
  sign before a name is a parse error at the end of the operand. Division by
  zero is `0` for floats, integers and unsigned integers alike; `/` of two
  signed integers is a float division. `abs()` takes one number; its other
  arguments are the planner's errors. The double answered `[]` for every
  function call and closed the connection on `n / 0`.
- **Regular expressions with an unknown flag outside the `WHERE`** are a 400
  planning error that names the expression (`FROM`) or sits inside `expand
  projection` (select list, `GROUP BY`, function arguments).
- **Smaller:** `SELECT *, *` and `*` beside other columns number the names
  (`b`, `b_1`); `top(v, host, 1) ... GROUP BY host` has `host` and `host_1`;
  `AS 1` is not an alias; `mean((v))` and `mean(v + 1)` are `expected field
  argument in mean(), got Nested(VarRef(...))`; `top(v, *::tag, 2)` names the
  wildcard; `SELECT * ... GROUP BY /host/` has no tag that is not grouped;
  `SHOW TAG KEYS WHERE time != x` over a measurement with no tag is the time
  error, not the aggregate-of-nothing one.
- **Precision.** An aggregate row is stamped with the lower bound of the
  range, to the nanosecond (`time > 1700000000000000000` is
  `22:13:20.000000001`, `time > 9223372036854775807` is
  `1677-09-21T00:12:43.145224192`). The double's rows hold microseconds.

## Design

- `InfluxQLAggregate.columns/6` computes the aggregates of `time` over the
  points where one of the fields of the other aggregates has a value; a time
  column is typed `:time`, which `InfluxQLBuckets` fills with the epoch for a
  number (to the microsecond a client reads; a linear fill is refused, since
  Core closes the connection). `zero_counts/1` zeroes a `count()` that found nothing once another
  result exists. `COUNT(*)` names the fields of the measurement.
- `InfluxQLExpr` types a time (`time`, `min`/`max`/`first`/`last`/`mode` of
  it), a boolean and a string as operands that take no part in arithmetic.
  A function of a time is the engine's error only when a field is aggregated
  beside it (it runs a plan): `check/4` takes that as `physical?`.
- `InfluxQLWhereArith` types the sides of a comparison (`:string`,
  `:boolean`, `:tag`, numbers, `:null`); a concatenation is written `||` for
  the SQL; `call_error/3` words `abs()` and refuses every other call by name.
  `InfluxQLArithmetic` also evaluates a comparison with a division or an
  `abs()` (the SQL engine does not follow the rules above).
- `InfluxQLWild` writes `*` out when it stands beside another column; a
  regular expression among the dimensions limits the wildcards to the tags it
  groups by. `InfluxQLRegex.compile/2` takes where the expression stands.
- An aggregate row whose lower bound is not a whole microsecond carries that
  bound to the microsecond (its floor). The engine prints the nanosecond, and
  `Client.HTTP` reads every format's times (JSON, JSON lines and CSV, through
  `ResponseParser`) to the microsecond, so the double's answer is the
  client's. A refusal was tried first and dropped: it refused what a client
  of the engine is answered.

**Known refusals by name** (the engine answers; the double does not compute
it): a math function other than `abs()` in a `WHERE`, `%` in a `WHERE`,
`count((*))`, `mean(abs(v))`, `time = time`, a selector with no value beside
columns that have points, arithmetic on a selector beside columns. They are
listed, with the engine's answer, in `InfluxQLShapeCases.refusals/0`.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/influxql/*.ex` | the changes above |
| `test/support/contract/influxql_shape_cases.ex` | new: 638 statements with Core's answers, and 112 refusals |
| `test/support/contract/influxql_fix_cases.ex` | `max/sum/median/spread/stddev/mode(time)`; the nanosecond stamps (a divergence) |
| `test/support/contract/influxql_planner_contract.ex`, `influxql_flux_lp_contract.ex` | wire the tables; two `local_divergence` tests |
| `CHANGELOG.md` | |

## Verification

- Each statement of `InfluxQLShapeCases` was run on Core and on the double;
  the table holds only those they answer alike. 435 statements of 707 differed
  from Core at 1b8ff04 and are now equal; none that was equal differs, except
  the five that stamp a bound that is not a whole microsecond (above).
- `mix test --only v3_core` (Core, no auth), `mix test`, `mix test --cover`,
  `mix credo --strict`, `mix dialyzer`, `MIX_ENV=test mix compile --force
  --warnings-as-errors`.
- Reductions per query (5 000 points, 12 runs) against 1b8ff04: `SELECT *`
  -0.1 %, a `WHERE` +0.1 %, `GROUP BY time` +0.9 %.
