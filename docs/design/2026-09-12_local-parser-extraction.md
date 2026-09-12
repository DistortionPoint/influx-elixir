# `Client.Local` Parser Extraction

**Date**: 2026-09-12
**Scope**: `InfluxElixir.Client.Local` internals; `InfluxElixir.ClientContract` test support
**Trigger**: scheduled code/test sweep (no open GitHub issues)

---

## Problem

`lib/influx_elixir/client/local.ex` had grown to 2,472 lines and 213
functions: ETS storage, capability checks, the line-protocol parser, a SQL
parser with ~60 private functions, the SQL executor, InfluxQL `SHOW`
handling, Flux emulation and admin all in one module. Every fidelity fix of
the last two days touched it, and finding the parser among the executor
required scrolling by section comment.

## Design

Two pure modules are extracted; the remaining `Client.Local` keeps every
public function and behaviour callback, so no consumer code changes.

| Module | Contents | Public surface |
|---|---|---|
| `InfluxElixir.Client.Local.LineProtocolParser` | line splitting with escape/quote rules, tag and field parsing, field typing, precision scaling, unescaping | `parse/2`, `unescape_measurement/1`, `t:point/0` |
| `InfluxElixir.Client.Local.SQLParser` | SELECT/DISTINCT/aggregate/projection parsing, WHERE parsing, ORDER BY/LIMIT, `$param` substitution, the `Client.Local:` error prefix | `parse_select/1`, `parse_where/1`, `resolve_params/2`, the `parsed_query`/`where_clause`/`select_column` types |
| `InfluxElixir.Client.Local` | lifecycle, capability table, ETS storage, write, query execution, InfluxQL `SHOW`, Flux rows, admin | unchanged |

`unescape_measurement/1` is needed by the SQL parser (measurement names in
`FROM`), by `execute_sql/3` (`DELETE FROM`) and by `SHOW TAG KEYS`, so it is
the one line-protocol helper exposed publicly. `Client.Local.point_map/0`
is now an alias of `LineProtocolParser.point/0`.

The move was mechanical (section ranges cut with `sed`, references
module-qualified); the only code change alongside it is
`do_query_influxql/4`, which matched the `SHOW TAG KEYS` regex twice and now
matches each pattern once via two small helpers.

## Test support

The shared contract module repeated

```elixir
if ctx[:query_delay] && ctx.query_delay > 0,
  do: Process.sleep(ctx.query_delay)
```

thirty times. It is now `InfluxElixir.ClientContract.settle/1`, a documented
public function that sleeps only when the context carries a positive
`query_delay` (real servers), so the wait strategy lives in one place.

## Verification

Line counts after: `local.ex` 1,445; `sql_parser.ex` 758;
`line_protocol_parser.ex` 305.

```bash
mix compile --warnings-as-errors && mix test && mix credo --strict && mix dialyzer
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration
```
