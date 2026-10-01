# Client.Local Fidelity Sweep; Optional `decimal`; Decimal Params

**Date**: 2026-10-01
**Scope**: `Client.Local` (SQL parser and executor, InfluxQL, Flux, line
protocol, store), `Client.HTTP` params, `local_test.exs` and the contract suite
**Issue**: scheduled quality sweep (no open issues)

---

## Problem

Two reviews read `Client.Local` and its two largest test files in full.
Every claim was then checked against InfluxDB 3 Core 3.10.1 and InfluxDB
2.7 before anything changed.

**Compiling without `decimal`.** `decimal` is an optional dependency,
but `SQLParser.to_sql_literal/1` matched `%Decimal{}`. A scratch consumer
project without `decimal` failed to compile the library:
`Decimal.__struct__/1 is undefined, cannot expand struct Decimal`.
Released 0.1.38 has the same line.

**Decimal parameters.** Jason encodes a Decimal as a JSON string. With
`amount >= $p` and `Decimal.new("1000.00")`, the engine compared text and
kept 500.0, because `"500.0" >= "1000.00"`. `Client.Local` bound the
Decimal as a number and did not keep it. Tests passed and production was
wrong.

**Wrong answers in Local SQL.** Each of these differs from Core:

- **Quoting and parameters.**
  - `''` was not unescaped in literals or `LIKE` patterns.
  - String parameters were injected into the query text.
  - Clause splitting ignored quotes, so commas, operators and `LIMIT` or
    `ORDER` inside literals cut the query.
- **Three-valued logic.**
  - `NOT IN (…, NULL)` and `BETWEEN … NULL` returned rows.
  - A `false` value was read as missing (`first_value`).
  - A null ordering value sorted as 0.
- **Grouping.**
  - `GROUP BY time` collapsed to one row.
  - `DATE_BIN` truncated negative timestamps toward zero.
  - A select-list `DATE_BIN` was never compared with the `GROUP BY` one.
- **Comparisons.**
  - A float compared with a string rendered as `5.0e3` where the engine
    writes `5000.0`.
  - `WHERE 1 = 1` gave "No field named 1".
- **Type checks.**
  - Aggregates over non-numeric columns raised `ArithmeticError` or
    answered.
  - Arithmetic over strings gave nulls.
  - The engine fails planning in both cases, even when no row matches.
- **Wording.** About fifteen error bodies differed from the engine's.
  Pinning the engine's exact text in the contract suite exposed them.
- **Crashes.**
  - A zero `DATE_BIN` interval.
  - `round` with a huge scale.
  - A CTE column named `time` holding strings.
- **Float division by zero.** The engine gives infinity or NaN. A
  response shows it as an explicit JSON `null` (the key is present), but
  it compares as a number, so `WHERE v / 0.0 > 1` keeps every row. Local
  returned null.

**Line protocol, InfluxQL and Flux.**
- Text after the timestamp was dropped silently.
- InfluxDB 2's parse-error texts were not modelled.
- InfluxQL refused queries whose literals contained `into` or `fill(`, and
  refused `time > 0s` and bare-integer times.
- An InfluxQL aggregate's `time` was the epoch where the engine gives the
  `WHERE` lower bound.
- A Flux `range` far in the future raised.
- Bucket maps lacked `type`, `orgID` and shard-group durations.

**Store.**
- A token deleted between claim and put came back.
- The 5-database limit was check-then-insert.
- `Store.measurements` scanned every point.
- InfluxQL `SELECT` made about four full passes and two sorts.

**Tests.**
- `local_test.exs` (6,052 lines) repeated about 2,500 lines of the
  contract suite, which also runs against Local.
- Many tests could not fail:
  - `ORDER BY` on data written already in order;
  - `DISTINCT` on untimed lines, which merge into one point;
  - assertions that accept any 400.

## Rejected after checking

- **A line rejected for a type conflict leaves its other new columns
  registered.** The engine does the same, so Local is right.
- **Flux typing is too loose.** `r._value > 2` on floats returns rows and
  `> "x"` returns none, on the engine as on Local.
- **`min(boolean)` is invalid.** It is valid and returns `false`.

## Decision

- **Optional `decimal`.** Match `%{__struct__: Decimal}`, with
  `@compile {:no_warn_undefined, Decimal}` in `SQLParser` and
  `Client.HTTP`. `test/influx_elixir/optional_dependency_test.exs` fails
  if any `lib/` file expands an optional dependency's struct. The fix was
  verified by compiling a consumer project without `decimal`.
- **Decimal parameters.** `Client.HTTP` sends them as JSON numbers
  (`Jason.Fragment` with `Decimal.to_string(:normal)`). Both clients
  compare numbers, verified on Core.
- **SQL (`SQLParser`).**
  - **Masking.** One mask blanks literal bodies, byte for byte, and every
    clause locator runs over it.
  - **Parameters.** They are bound as quoted, escaped literals.
  - **Constant predicates.** They fold to a constant.
  - **Engine errors.**
    - `time` against a number gives the engine's type-coercion error.
      Integer params are `UInt64`; a contained marker in
      `resolve_params` carries that type.
    - `time` aggregates, DISTINCT ORDER BY, LIMIT/OFFSET and FIRST/LAST
      return the engine's bodies.
    - A mismatched select-list `DATE_BIN` is refused by name, because
      the engine's message embeds an internal interval rendering.
- **SQL (`SQLExecutor`, `Format`).**
  - **Plan-time check.** `check_plan` types scalar calls, arithmetic,
    negation, aggregate arguments, and LIKE and regex operands, in the
    planner's order and wording.
  - **Column reads.** One `column_value/2` reads every column.
  - **Null ordering.** Ordered aggregates reuse the ORDER BY null
    ordering.
  - **Arithmetic.** `DATE_BIN` floors. Integer division by zero closes
    the connection; float division by zero is refused by name.
  - **Float rendering.** Floats render as the engine writes them.
  - **Unknown formats.** `Format.answer/3` takes the request's database,
    so the unknown-format column matches the body `Client.HTTP` sends.
    The `db` key is left out when no database is named.
- **InfluxQL, Flux and line protocol.**
  - The v3 line protocol is a grammar with the engine's
    trailing-content rules.
  - The v2 path ports Go's scanners and their messages; the
    2026-09-30 line-endings doc is updated.
  - InfluxQL masks literals, reads durations and integers as epoch
    nanoseconds, and stamps aggregates with the greatest lower bound.
  - Flux wraps range times in int64 nanoseconds.
  - Bucket maps carry the engine's fields.
- **Store.**
  - Token creation and the database limit run under `:global.trans`
    keyed on the store.
  - `measurements` reads the column index.
  - The InfluxQL path lost its redundant passes.
- **Tests.**
  - `local_test.exs` lost its duplicates and its tests that could not
    fail, and the remaining ones assert exact results.
  - The contract pins engine text.
  - Three new contract modules run against Local and the engines:
    `Contract.SQLParser`, `Contract.SQLExecutor` and
    `Contract.InfluxQLFluxLP`.

**Known gaps, refused by name:**
- a float divided by zero;
- `round` beyond a double's range;
- select-list `DATE_BIN` with no matching `GROUP BY`;
- a `time` comparison inside an InfluxQL `OR`;
- some ungrouped-column wordings (joins, `first_value`, whole-day
  intervals);
- `v=1e999`.

Core also returned `-0.0` for `round(-0.4)` where Local gives `0.0`. They
are `==` but not `===`.

## Verification

- **Integration.** Core runs 189 tests, InfluxDB 2.7 runs 38, and both
  pass with the three new modules wired in. The Local contract and the
  unit suite are green.
- **Engine probes.**
  - Each SQL fix was probed on Core.
  - About 330 malformed lines per line-protocol dialect were diffed
    against both engines.
  - About 100 InfluxQL statements were compared.
- **Timings at 100k points.** InfluxQL `SELECT *`, from 416–600 ms down
  to 193–337 ms, and `mean(v)`, from 327–547 ms down to 130–157 ms. Both
  were measured under load.
- **Optional `decimal`.** A consumer without `decimal` compiles
  `influx_elixir` with no warnings.

During the work, a long-running Core instance stopped accepting writes
(no log line, `/health` fine) after a random line-protocol differential.
A fresh container behaved normally. This is noted here; the library was
not at fault.
