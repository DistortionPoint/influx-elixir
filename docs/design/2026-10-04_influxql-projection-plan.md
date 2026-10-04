# InfluxQL: One Projection Plan for Names, Windows and Duplicate-Name Errors

**Date**: 2026-10-04
**Scope**: `Client.Local` InfluxQL (`influxql_projection` new, `influxql_run`,
`influxql_names`, `influxql_where_arith`, `influxql_where`, `influxql_expr`,
`influxql_plan`, `influxql_query`), the case tables `InfluxQLProjectionCases`
(new), `InfluxQLShapeCases`, `InfluxQLCallCases` and the planner contract
**Issue**: scheduled quality sweep (review of
[`2026-10-04_influxql-time-aggregates-and-where-calls`](2026-10-04_influxql-time-aggregates-and-where-calls.md))

---

## Problem

Every claim below was read from InfluxDB 3 Core 3.10.1 (no auth,
`--wal-snapshot-size 100000`) on thirty points a minute apart with two tags
(`host`, `region`) and an integer `n`, an unsigned `u`, a float `usage`, a
string `s` and a boolean `ok`, none in every point
(`InfluxQLProjectionCases.fixture/1`).

**Silently wrong or raising**

| Statement | Core | Local before |
|---|---|---|
| `select n from cpu where u + s = 1` (also `u + 'x'`, `u + ok`, `u + host`, `u * true`, `s - u`, `abs(u) + s`, `(u + s) > 1`, `2.5 != u / s`, `ok != u + s`, `u + time`) | 400 `Cannot coerce arithmetic expression UInt64 + Utf8 to valid types` (the Arrow type of each operand as written: `Boolean`, `Dictionary(Int32, Utf8)`, `Timestamp(ns)`) | `{:ok, []}` (`HEAD~1`: the error with `Int64`) |
| `select true / abs(time) from cpu`, `select abs(n), true / abs(time) from cpu` | 400 `incompatible operands for operator /: boolean and timestamp` | `FunctionClauseError` in `InfluxQLExpr.value/3` |
| `select 1 / abs(time) from cpu`, `abs(-abs(time))`, `abs(time) + 1`, `abs(time) * n`, `u / abs(time)` | the same error with the operand types | `{:ok, []}` or rows |
| `select abs(time), n from cpu` (also `abs(time), s`, `abs(time), n * 2`) | 400 `Function 'abs' expects NativeType::Numeric but received NativeType::Timestamp(...)` (a field beside it runs the plan) | rows |
| `select time as n, * from cpu limit 1` (`n` is a field too) | row 2 keeps `n` as the time and drops the field | row 2 had the field `n_1` and no time |
| `select s, u, bottom(ok, 40) as x from cpu where <range> group by time(30m) limit 1 offset 1` | the point with `x = true` (`LIMIT` counts per column) | a row with only `s` |
| `select usage as host, top(n, host, 2) from cpu` | `host` is `usage`, `host_1` the tag | swapped |
| `select ok, bottom(n, host, region, 40) as host, u as region_1 ... group by region` | planning error at positions 5 and 6 | positions 4 and 6 |
| `select usage as host from cpu group by host` (also `mean(n) as host`, `n as region ... group by region`) | the dimension keeps `host`, the column is `host_1` | the column overwrote the dimension |
| `select ((usage)), ((time)) from cpu` (also `(time)`, `(time) as t`) | a `time_1` column holding the time | dropped |
| `select -u, +nosuch / host from cpu` (also `nosuch + s`, `nosuch / 'x'`) | answers `nosuch_host: false` | refused as `incompatible operands ... unknown and tag` |
| `select bottom(ok, 5) from cpu order by time desc` | the last five `false` (a tie goes to the point the scan meets first) | the first five |
| `usage as time, n as time_1` | planning error `cpu.usage AS time_1` at 1 and `cpu.n AS time_1` at 2 | refused by name |
| `select derivative(mean(n)), time from cpu ... group by time(10m)` | the buckets that have a derivative | the empty first bucket too |

**Refused by name at `b04c320` (the eleventh review), answered by `HEAD~1`
and by Core**: `top()` / `bottom()` beside arithmetic or a function of the
point's columns (`select top(n, 3), usage * 2 from cpu`). It is answered
again; a function written *before* the selector is the engine's 500
`External error: InfluxQL internal error: unexpected selector function: abs`
(the first function of the list; after the selector, or with `group by
time(...)` and a selector that is not `top()` / `bottom()`, it is not).

## Design

**One plan** (`InfluxQLProjection.build/2`, called once at the top of
`InfluxQLRun.run/4`) lists every column of the answer in the order the engine
does: the time (the first `time` that is selected takes the place, under its
alias), the dimensions of the `GROUP BY` that are not selected under their own
name, then the select list in order, a `*` written out as the columns it
stands for and `top()` / `bottom()` as the value followed by the tags it
chooses by. Each entry is `%{role, kind, source, item, written, name}`:

- `role` is what the column is to the rows: `:time`, `:dimension`, `:tag`,
  `:field`. A row of a plain select is kept when it holds a `:field` (a
  constant does not count: `plan.kept`); a `LIMIT` / `OFFSET` counts per
  `:field` (`plan.fields`).
- `kind` is where it comes from (`:time`, `:time_expr` for `(time)`,
  `:dimension`, `:column`, `:star`, `:expr`, `:constant`, `:aggregate`,
  `:value`, `:chosen`).
- `written` is the name the select list gives it, `name` the final one.

A name is given twice, as the engine does: the select list alone numbers a
name taken (`name_1`, skipping the names taken: `i AS i_1, i, i` is `i_1, i,
i_2`; `InfluxQLNames.resolve/1`, and the plan for a `*`); then the projection,
with the time and the dimensions in front, numbers a name by how many columns
before it were written with it, and two columns that end up with one name are
the planning error, worded with the expression of each (`cpu.n AS host_1`,
`cpu.host AS host_1`, `NULL AS x` for a column the measurement lacks). The
engine plans the projection, and so words that error, only when the list reads
a field (`reads_field?/3`): `(time), (time)` answers nothing.

The plan gives `InfluxQLRun`:

- the **names** (`plan.items` is the select list under them; the dimensions
  are renamed in the series key, `plan.dimensions`; the `*` and the tags
  `top()` chooses by are `plan.star` and `plan.multi`), in place of
  `multi_names/6`, `unique_names!/4` and the star renaming of `project/3`;
- the **windows**: `window_per_field/2` counts the field names of the plan, so
  the field a `*` writes as `n_1` beside `time AS n` is the one counted; a
  `top()` / `bottom()` beside another field is windowed per column too (it was
  a row window);
- the **duplicate-name error**, one place, positions from the plan.

`InfluxQLNames` loses `lead_time/1` and the duplicate check (the plan numbers
`time` and raises the error); a `(time)` may stand beside a `*`.

**`WHERE` coercion** (`InfluxQLWhereArith.coercion_error/3`): an unsigned
number under `+ - * /` beside a string, a boolean, a tag or the time (either
order, any depth, left to right) is the planner's error; the other numbers
make a null (`n + s`), and a column the measurement lacks is null beside an
unsigned number.

**Expressions** (`InfluxQLExpr`): a math function of a time is a timestamp to
the operation around it (the engine rejects the operation while it rewrites the
projection, before it plans the function; and all rewrite errors of the list
come before the plan's, `InfluxQLPlan.expressions/3`); a column the
measurement lacks beside a tag, a string or a boolean is a constant false
(`fold/3`), beside a number a null, and the type of `unknown op T` is `T`;
`value/3` refuses a string or a boolean by name instead of raising.
`top()` / `bottom()` evaluate the arithmetic of the chosen point's columns
(`multi_row/4`); `InfluxQLPlan.call_before_selector/2` is the 500 above.

**Descending `top()` / `bottom()`** feed the points to the choice latest
first, so a tie goes to the later point. **A `time` aliased beside the
buckets of aggregates** keeps its refusal (`check_renamed_time/3`, now also for
arithmetic and transforms of aggregates, at run time so that the planner's
own errors come first).

**Refused by name, because the engine does something the double does not
reproduce**: a tag or a time aliased to the name of a `GROUP BY` dimension when
a field is read (the engine groups by the alias: `host AS region ... GROUP BY
region` is a series per host); a `GROUP BY` tag selected under another name
beside a second dimension with a `LIMIT` or `OFFSET` (Core's physical plan
fails its own `SanityCheckPlan`, a 400 of several lines of plan); the
duplicate-name error of aggregates (worded `avg(cpu.n) AS host_1`,
`get_field(selector_max(...))`); `%` in a `WHERE`; a math function of a time
beside `*` or an aggregate (Core's 500s); `abs()` / `sqrt()` of a constant
false.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/influxql/influxql_projection.ex` | new: the plan |
| `lib/influx_elixir/client/local/influxql/influxql_run.ex` | reads the plan; `multi_names`, `unique_names!`, `star_time_names`, `field?`, `ungrouped_tags` and the `:fields` option gone; `top()` beside arithmetic; descending ties |
| `lib/influx_elixir/client/local/influxql/influxql_names.ex`, `influxql_query.ex`, `influxql.ex` | `item_name/1` public; no `lead_time` or duplicate check; `window_fields` gone; `(time)` beside `*` |
| `lib/influx_elixir/client/local/influxql/influxql_where_arith.ex`, `influxql_where.ex` | `coercion_error/3` |
| `lib/influx_elixir/client/local/influxql/influxql_expr.ex`, `influxql_plan.ex` | operands of a function of a time, `fold/3`, `first_call/1`, `result/3`, plain fields make the plan physical, `call_before_selector/2` |
| `test/support/contract/influxql_projection_cases.ex` | new: 398 statements with Core's answers (43 coercions, 46 time functions, 31 windows, 80 names, 15 parenthesised times, 55 absent columns, 22 descending, 106 selectors) and 47 refusals, each pinned to its reason by `refusal_reasons/0` |
| `test/support/contract/influxql_shape_cases.ex`, `influxql_call_cases.ex` | `refusal_reasons/0`, `closed_reasons/0`; `mean( (v) )` and `top(v,host,1) ... group by host` (written twice) taken out, `top(v,2), n * 2` and `top(v,2), abs(n)` moved from the refusals to the answers: 791 statements (303 aggregates + 158 select + 285 conditions + 45 shows) and 113 refusals |
| `test/support/contract/influxql_planner_contract.ex` | the projection tests; `check_refusals/3` fails a refusal for any reason but the pinned one, a refusal with no pin, and a pin with no refusal; the `closed` statements are pinned the same way |
| `test/influx_elixir/client/local/influxql_planner_test.exs` | two columns with one name are the engine's error; aggregates stay refused |
| `test/influx_elixir/contract_case_tables_test.exs` | the pin of `mean((v))` / `mean( (v) )` goes with the duplicate |
| `CHANGELOG.md` | |

## Verification

- Every statement of the new tables was read from Core and from the double
  (`mix test --only v3_core` runs the planner contract against Core with unique
  measurement names; `mix test` runs the same against the double).
- Regression: 2 579 select lists (244 of the findings and their neighbours,
  516 select lists by clause, 234 `top()` / `bottom()` lists by window, 176
  more, 1 409 random ones) were run on Core, on `HEAD~1`, on `b04c320` and on
  this tree. None that equals Core at `HEAD~1` or at `b04c320` differs from it
  now (every `SAME` stays `SAME`); the rest that still differs is refused by
  name or is an error of Core's that precedes another in an order the double
  does not know. 20 256 select lists raise on none (`HEAD~1` raised on
  `true / abs(time)`).
- Reductions per query against `HEAD~1` (5 000 points, median of 12): `SELECT
  *` +2.1 %, `SELECT v, n` -3.9 %, a `WHERE` +0.9 %, `mean()` +0.4 %, `GROUP BY
  time` +0.1 %, `top()` -0.8 %; twenty points (median of 30): +1.2 % to +3.7 %.
- `mix test`, `mix test --cover` (91.68 %), `mix credo --strict`, `mix
  dialyzer`, `MIX_ENV=test mix compile --force --warnings-as-errors`, `mix test
  --only v3_core`.
