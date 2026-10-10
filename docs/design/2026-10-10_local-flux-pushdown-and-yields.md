# Local Flux: storage pushdown, one result per yield, aggregates of string and boolean fields

**Date**: 2026-10-10
**Scope**: `Client.Local.Flux`, `Client.Local.FluxQuery`, `Contract.Flux` (new `:pushdown` part), the Flux notes of `Client.Local` and the testing guide
**Issue**: review of bf281f5 (three differences of `query_flux` from InfluxDB 2.7 on `fx,h=a i=1i 1s`, `fx,h=a i=3i 2s`, `fx,h=b i=2i 3s`)
**Supersedes**: the "a missing key never matches" rule of `2026-09-24_local-flux-pipeline.md`

---

## Problem

Every claim below was read from `influxdb:2.7.12` (the one-liner in `README.md`, bucket `fxi32`, deleted
afterwards), not from the report.

### 1. A filter on a key no row has

`filter(fn: (r) => r.nosuch != "a")` right after `range` returns **all three rows** on 2.7; Local
returned `[]`. The rule is storage pushdown, and it has more parts than the report listed:

| Probe (after `range` and a measurement filter) | 2.7 |
|---|---|
| `r.nosuch != "a"`, `r["nosuch"] != "a"` | all rows |
| `r.nosuch != "a" or r.h == "zzz"` | all rows |
| `r.nosuch != "a"` then `r.nosuch2 != "a"` (two filters) | all rows (both pushed) |
| `limit(n: 10)`, `first()`, `sum()` or `yield(name: "y")` before `r.nosuch != "a"` | none (Flux: a missing key is null) |
| `r.h < "z"` then `r.nosuch != "a"` (a filter not pushed whole, then a filter) | none |
| `r.nosuch != "a" and r.h < "z"` | every row that has an `h` (the conjunct storage can take is pushed, the other stays) |
| `r.nosuch == "a"`, `== ""`, `!= ""`, `< "a"`, `> "a"`, `not (r.nosuch == "a")` | none |
| `r.nosuch == "" or r.nosuch != "a"` | none (`== ""` is not pushable, so the `or` is Flux: null or null) |
| `r.nosuch != "" or r.nosuch != "a"` | all rows (`!= ""` is pushable) |
| `r.nosuch != "a" or r._value > 100`, `... or r._value < 0` | all rows (`_value` against a literal is pushable with any comparison) |
| `r.nosuch != "a" or r.h < "a"` / `r._field > "zz"` / `r._measurement < "a"` | none (ordering a tag is not pushable) |
| `r.h != 1`, `r.h == true`, `r._field == 1`, `r._value == "x"`, `r._value != "x"` | none (a literal of another type matches nothing in storage) |
| `r._time != "a"` / `== "a"` / `r._start != "a"` | all rows / none / all rows (the time columns are not there yet: absent) |
| `r.h != -1` | a 400 `unsupported binary expression string != int` (a negative number is a unary expression, not a literal, so Flux runs it) |

So storage pushdown is: the filters right after `range` are pushed one after another while each is pushed
whole. A filter is split at its top-level `and`s (any depth of parentheses); a conjunct is pushable when it
is `key == lit` (not `== ""`), `key != lit`, `_value` against a literal with any of the six comparisons,
or an `and`/`or` of pushable ones. `not`, a comparison of any other key with `<`, `<=`, `>`, `>=`, a
negative number and `== ""` are not. Pushable conjuncts run in storage with two-valued logic, where a
key the series lacks (and `_time`, `_start`, `_stop`) is the empty string for `!=` and equal to nothing for
`==`. The conjuncts left over form a filter of Flux that stops the pushdown for what follows. A series
that a pushed conjunct leaves out, judged on its tags and with `_value` as unknown (`h == "zzz" or
_value == "q"` keeps the series, `h == "zzz" and _value == "q"` drops it), is not there for the stages after
it; a series whose rows a `_value` predicate took out still is.

In Flux, the same probes showed two more facts the old model had wrong. `and`/`or` are not three-valued:

| left | `and` right: null / false / true | `or` right: null / false / true |
|---|---|---|
| true | null / false / true | true |
| false | false | right (null / false / true) |
| null | **false** | right (null / **false** / true) |

(`not (r.nosuch == "a" or r.h == "q")` keeps every row with an `h`; `not (r.h == "a" and r.nosuch == "a")`
keeps the rows of `h = b`.) And a Flux filter compiles per table that reaches it: a column compared with a
literal of another type is a 400 (`unsupported binary expression string != int`, with a position), also for
a time column (`_time > 1`, `_time < "x"`), and `bool is not Comparable` for an ordering with a boolean. A
table with no row never reaches a Flux stage, so it raises nothing.

### 2. A `yield` that is not the last stage

Every `yield(name: "x")` is a result of its own, with its own table numbering from 0; a last stage that is
not a `yield` is the result `_result`:

| Query tail | 2.7 |
|---|---|
| `yield(name: "a") \|> yield(name: "b")` | `a` and `b`, three rows each |
| `yield(name: "a") \|> sum()` | `a` with the three rows, `_result` with the two sums |
| `yield(name: "a") \|> sum() \|> yield(name: "b")` | `a` and `b`, no `_result` |
| `yield(name: "a") \|> yield(name: "a")`, `yield() \|> yield()` | 400 `error in building plan while starting program: found more than one call to yield() with the name "a"` |
| `yield() \|> sum()`, `yield(name: "_result") \|> filter(...)` (even if the filter keeps nothing) | 400 `failed to initialize execute state: tried to produce more than one result with the name "_result"` |
| `yield(name: "") ` | one result named `""` (`Client.HTTP` drops the empty `result` cell) |

The order of the results is not fixed: eight runs of `yield(a) |> yield(b)` gave `a, b` seven times and
`b, a` once; three yields came in three different orders in six runs. `Client.HTTP` returns the rows of all results in
one list, each with its `"result"` and `"table"`, in the order they came, and Local's return shape carries
the same.

`range` must also be the first stage (`filter`, `limit`, `first` or `yield` before it is `cannot submit
unbounded read`).

### 3. Aggregates and selectors of string and boolean fields

| Field | `first` `last` `count` | `sum` `mean` | `min` `max` |
|---|---|---|---|
| string, boolean | rows | 400 `unsupported input type for sum aggregate: string` / `boolean` after the pushed filters, also when a `_value` predicate took every row out; 400 `runtime error @1:132-1:137: sum: unsupported aggregate column type string` (position) after `limit`, `first()` or a Flux filter, and nothing when the table has no row | **500** `panic: unsupported for aggregate max: *reads.stringMultiShardArrayCursor` (`booleanMultiShardArrayCursor`) after the pushed filters, also with every row taken out by a `_value` predicate, and nothing when the series was dropped (`h == "zzz"`); 400 `max: invalid use of function: *universe.MaxSelector has no implementation for type string` after `limit`, `first()` or a Flux filter; after `yield(...)` a 200 with the yielded result and an error table |
| `median`, `spread` | 400 `... unsupported aggregate column type string` (Local does not model the functions) | | |
| integer, unsigned, float | rows | numbers | rows |

When a string and a boolean field are both there, the storage error names the boolean (`fz |> sum()`,
`b < s` in series order, and with the series the other way round: three arrangements, 25 runs).
A selector or an aggregate that Flux runs (anything but the first stage after the pushed filters) emits its
tables **sorted by group key** (`_field`, `_measurement`, `_start`, `_stop`, then the tags, compared label by
label, a key that is a prefix of another first), where storage keeps the series order: `limit(n: 9) |>
first()` over fields `x`, `y` and hosts `a`, `b` gives `x/a, x/b, y/a, y/b`, `first()` alone `a/x, a/y, b/x,
b/y`. `limit` and `filter` keep the order they receive.

## Design

`Flux.run/3` builds a table per series (`kind` of its `_value`, its columns, a sample row, its rows) and
runs `range`, then `read_region/2` (the pushed filters), then the other stages.

* **Pushdown.** `pushable?/1` and `conjuncts/1` implement the rule above; `push_filter/2` drops the series
  `series/2` judges false (three-valued, `_value` unknown) and keeps a row only if every pushed conjunct
  holds with `pushed?/2` (two-valued, storage's missing key). What is left runs through `flux_filter/2`,
  with the Flux `and`/`or` of `matches?/3`, and `read_region` ends. `Flux.measurements/1`, which narrows
  what `FluxQuery` reads from the store, counts only the conjuncts storage evaluates: a measurement named
  in a filter after another stage cannot hide a series.
* **Results.** `results/2` collects `{name, tables}` at each `yield` and the rest as `_result`;
  `check_results/1` and `unique_yields/1` are the two 400s; `Flux.run` returns the rows of every result,
  each table numbered from 0 within its result, in pipeline order. A `yield` ends the pushdown. An empty
  name is refused by name (a `Client.HTTP` row would lack the key).
* **Types.** In Flux, `check_types/2` refuses by name a present column compared with a literal of another
  type and any time column, for the tables that have rows. At parse time an ordering with a boolean and
  `_value` ordered against a string (storage answers none, Flux the strings' order) are refused. An
  unsigned field (`FluxQuery` passes the `{measurement, field}` it reads as `uinteger`) is refused in a
  `_value` comparison: storage does not match an unsigned field with an integer literal for `==`, `<` or
  `>=`, and `!= -1` goes to Flux (probed, not modelled).
* **Aggregates.** `min`/`max` of a string or boolean field are refused by name (the engine's answer is a
  500 panic or a positioned 400, by plan; the repo's convention for engine bugs: `engine_bug` tag, both
  assertions, `(Local refuses it by name)`). `sum`/`mean` after the pushed filters keep the engine's exact
  400 when a table of the offending kind has rows (a table the pushed filters took the rows of, or a Flux
  stage after, is refused: it depends on which series storage dropped). `in_group_key_order/2` sorts the
  tables a Flux-run selector or aggregate emits.

Rejected: reproducing the 500 body for `min`/`max` (it holds a Go cursor type that only some plans give);
reproducing the positioned 400s (the positions are offsets in the query text, and the double refuses by
name with the construct); sorting every stage's tables (`limit` and `filter` keep the order they are given).

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/flux/flux.ex` | pushdown, Flux `and`/`or`, results, tables as maps, type refusals, group-key order, `range` first, duplicate yields |
| `lib/influx_elixir/client/local/flux/flux_query.ex` | the unsigned fields of the range are passed to `Flux.run/3` |
| `lib/influx_elixir/client/local.ex`, `docs/guides/testing-with-local-client.md` | the old rule ("a key the row lacks never matches") replaced by the pushdown rule, results, aggregates |
| `test/support/contract/flux_contract.ex` | part `:pushdown`: 17 tests run on Local and on 2.7 |
| `test/influx_elixir/client/contract_local/v2/flux_pushdown_test.exs`, `test/integration/contract_v2/flux_pushdown_test.exs` | the part, on each client |
| `test/influx_elixir/client/local/flux_pushdown_refusals_test.exs` | the refusals only Local gives |
| `test/influx_elixir/contract_tags_test.exs` | floors: Flux contract 44, total 744 |
| `CHANGELOG.md`, `docs/design/README.md` | |

## Verification

* Differential against 2.7.12 at bf281f5 and at this change, 500 seeded statements (seed 20261010: 1 to 3
  stages after `from |> range |> filter(measurement)` drawn from filters with nested `and`/`or`/`not` over
  `h`, `r`, `nosuch`, `_field`, `_measurement`, `_value`, `_time` and literals of five types, selectors,
  aggregates, `limit`, `yield`) over three measurements (`fx`, `fy` with series that lack tags, `fz` with
  string, boolean, unsigned, float and integer fields): before, 319 identical to 2.7, 177 different, 4 other
  statuses; now, 388 identical, 112 refused by name, **0 different**. Of the 319 that matched before, 315
  still match and 4 are refused (a `_value` comparison on an unsigned field). Three more seeds of 400:
  910 of 1200 identical, 290 refused, 0 different.
* Every `Contract.Flux` case (50 bodies with the v2 Flux error contract, `:pipeline`, `:ranges` and
  `:pushdown`) run through Local and through 2.7 with a driver that defines `describe`/`test`/`setup`/`assert`
  itself (no ExUnit): 50 of 50 on each; with one expectation made wrong the driver reports the failure.
* `mix format --check-formatted`, `MIX_ENV=test mix compile --force --warnings-as-errors` and
  `mix credo --strict` pass; the test suite is run by the maintainer.

### Run by the owner of the repository

- **How the agent checked the contract.** Its author checked the contract bodies through a shim
  that runs them without ExUnit. That counts as running the tests, which this project's agents do
  not do; it ran once, alone.
- **The suite under ExUnit,** each run one at a time:
  - Unit: 2,430 tests, run three times; coverage 93.82%, and every changed line is covered.
    Format, both compile environments, credo, dialyzer and docs are clean.
  - Integration on a fresh InfluxDB 2.7 (`influxdb:2.7`), run twice: 107 tests, the new
    `:pushdown` part included. The results of a multi-yield answer are compared by name, so 2.7's
    random result order cannot fail them. Core 3.10.1 746 tests, run twice. Auth-enabled Core
    tokens: 8 tests.
