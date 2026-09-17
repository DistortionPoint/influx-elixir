# `Client.Local`: SQL Executor Extraction

**Date**: 2026-09-17
**Scope**: `InfluxElixir.Client.Local`, new `InfluxElixir.Client.Local.SQLExecutor`
**Issue**: scheduled quality sweep (refactoring); one latent bug fixed on the way

---

## Problem

`docs/design/2026-09-12_local-parser-extraction.md` split the parsers out
of `Client.Local` and left it at 1,450 lines. Seven issues later the SQL
*executor* — CTEs, `CROSS JOIN`, the boolean `WHERE` evaluator, aggregates,
selectors, casts, multi-key ordering, schema and grouping checks — had
grown to 900 of the module's 2,000 lines, beside storage, profiles,
InfluxQL and Flux. Two consequences showed up in the same sweep:

- the `DELETE` path, written when `WHERE` was a flat list, still folded
  predicates with `matches_condition?/2` and crashed with a
  `FunctionClauseError` on the `{:or, _}` node that `SELECT` had learned to
  evaluate two sweeps earlier — two evaluators in one module, one stale;
- every executor change re-read ETS through `measurement_exists?/3` and
  `fetch_points/3`, so the SQL engine could not be exercised or reasoned
  about without a table.

## Design

`SQLExecutor.run(parsed_query, fetch)` takes the parser's output and a
function `fetch.(measurement) :: {:ok, points} | :error`; CTEs shadow it
by name and `CROSS JOIN` reads its right side through it. Everything from
`execute_query/3` to `point_to_row/1` moved verbatim, with the table and
database parameters replaced by `fetch`; `nanoseconds_to_datetime/1` is
public (`@doc false`) because the Flux path needs it too. `Client.Local`
supplies `point_source/3` (ETS lookup with the "table not found"
distinction) and calls `run/2`; `DELETE` calls the executor's public
`matches_all?/2`, so there is one evaluator.

The executor is pure over the points it is given: no ETS, no connection
state — the same property the parser has.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/sql_executor.ex` | New: the SQL engine, `run/2`, `matches_all?/2` |
| `lib/influx_elixir/client/local.ex` | Executor removed; `point_source/3`; `DELETE` via `matches_all?/2`; moduledoc |
| `test/influx_elixir/client/local_test.exs` | `DELETE` with `OR` / `NOT` / parentheses |
| `CHANGELOG.md` | Changed and Fixed entries |

## Verification

```bash
mix format --check-formatted && mix compile --warnings-as-errors
mix test                      # three runs, 0 failures
mix credo --strict && mix dialyzer && mix docs
docker run -d --rm --name influx3_verify -p 8181:8181 influxdb:3-core \
  influxdb3 serve --node-id node0 --object-store memory --without-auth
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration
docker stop influx3_verify
```
