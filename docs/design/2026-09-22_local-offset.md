# `Client.Local` `LIMIT n OFFSET m`

**Date**: 2026-09-22
**Scope**: `Client.Local.SQLParser` clause handling, `Client.Local.SQLExecutor.apply_limit/3`
**Issue**: GitHub #21

---

## Verification of the report

Replayed against InfluxDB 3 Core (`influxdb:3-core`, five rows `a`..`e`
one second apart):

| Query | Engine | Double before |
|---|---|---|
| `ORDER BY time LIMIT 2 OFFSET 1` | b, c | 400 `unsupported SQL construct OFFSET` |
| `LIMIT 2 OFFSET 0` / `OFFSET 4` / `OFFSET 10` | a, b / e / [] | 400 |
| `OFFSET 3` (no LIMIT); `OFFSET 3 LIMIT 1` | d, e / d | 400 |
| `GROUP BY host ... LIMIT 2 OFFSET 1`; `DISTINCT host ... LIMIT 2 OFFSET 2` | b, c / c, d | 400 |
| `OFFSET -1` | 400 "OFFSET must be >=0" | 400 (different reason) |
| `OFFSET abc` | 500 "No field named abc" | 400 |

The report is real. `OFFSET` had been placed on the refused-construct list
in the #18 work because ignoring it would have paged wrongly; the honest
refusal was right then, and implementing it is right now.

## Design

`OFFSET` becomes a clause like `LIMIT`: it ends the statement (either order
with `LIMIT`), the `WHERE`, `GROUP BY` and `ORDER BY` extractors stop at
it, the tail check accepts non-negative integers for both and reports a
negative one with the engine's wording (a bare word is the engine's schema
error). The executor's single `apply_limit/3` drops `offset` rows and then
takes `limit`, on every row kind — raw, projected, grouped, `DATE_BIN` and
`DISTINCT` — so the five call sites stay one function.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/sql_parser.ex` | `offset` in `parsed_query`, `parse_offset/1`, clause regexes, `check_limit/2` for both clauses |
| `lib/influx_elixir/client/local/sql_executor.ex` | `apply_limit/3` |
| `test/influx_elixir/client/local_test.exs` | Regression block, including the reported query; construct test narrowed to `OVER` |
| `test/support/client_contract.ex` | `offset_tests`, run against Local and the server |
| `lib/influx_elixir/client/local.ex`, `docs/guides/testing-with-local-client.md`, `usage-rules/query.md`, `CHANGELOG.md` | Updated |

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
