# `Client.Local` Flux Pipelines

**Date**: 2026-09-24
**Scope**: `Client.Local.Flux` (new), `Client.Local.query_flux/3`
**Issue**: scheduled quality sweep

---

## Problem

`query_flux/3` matched regexes anywhere in the query text: a bucket, a
`_measurement ==`, a `_field ==`, `r.key == "string"` filters, and a
relative `range(start:)`. Everything else was ignored, so the double gave
a plausible and wrong answer instead of an error:

| Query tail (after `range(start: 0)`) | InfluxDB 2.7 | Double before |
|---|---|---|
| `\|> mean()` | one row per table, no `_time` | the raw rows |
| `\|> last()`, `limit(n: 1)`, `count()` | per-table results | the raw rows |
| `\|> aggregateWindow(...)`, `pivot(...)`, `group() \|> sum()` | computed | the raw rows |
| `filter(... r.host == "a" or r.host == "b") \|> count()` | both hosts, counted | host `a` only, uncounted |
| `filter(fn: (r) => r.host != "a")` | host `b` | every row |
| `filter(fn: (r) => r._value > 2.0)` | 3 rows | every row |
| `range(start: 0, stop: 1700000030)` | rows before the stop | every row |
| no `range()` | 400 `cannot submit unbounded read ...` | every row |
| missing bucket | 404 `could not find bucket "nope"` | `[]` |
| any row | carries `_start`, `_stop` | missing |
| table numbers | series order: measurement, tags, field | first-seen order |

## Decision

A pure `Client.Local.Flux` module splits the query at top-level `|>`
(outside strings and brackets) and parses each call. The first must be
`from(bucket:)`; exactly one `range()` is required. Supported stages and
their verified semantics:

| Stage | Semantics |
|---|---|
| `range(start:, stop:)` | Unix seconds, RFC3339, `-Nd/h/m/s/w`, `now()`; `stop` defaults to now; rows get `_start`/`_stop` |
| `filter(fn: (r) => ...)` | `r.key` / `r["key"]`, `== != < <= > >=`, `and`/`or`/`not`/parentheses, three-valued: a missing key is null and never matches |
| `first` `last` `min` `max` | the selected row per table (first of a tie) |
| `mean` `sum` `count` | one row per table without `_time`; `mean` is a float; strings are the engine's `unsupported input type for mean aggregate: string` |
| `limit(n:, offset:)` | per table |
| `yield(name:)` | sets `result` |

Any other function, or arguments the double does not model, is
`{:error, %{status: 400, body: {"code":"invalid","message":"Client.Local: unsupported Flux function: pivot()"}}}`.
Tables are grouped by series, sorted measurement → tag set → field,
renumbered from 0 after the pipeline with empty ones dropped. `now()`
uses the same clock (`System.system_time/1`) that stamps untimed points,
so a point just written is inside `range(start: -1h)`.

## Verification

24 queries covering every row above plus `r["key"]`, selectors, `limit`
with `offset`, a filter after `mean()`, `yield`, RFC3339 and Unix bounds,
no `range()` and a missing bucket: identical on InfluxDB 2.7 and the
double. The v2 contract suite gains `v2_flux_pipeline_tests`
(23 tests, 0 failures on both).

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/flux.ex` | New |
| `lib/influx_elixir/client/local.ex` | `query_flux/3` through `Flux`; regex helpers removed |
| `test/influx_elixir/client/local_test.exs` | pipeline block; two tests corrected to the engine's answers |
| `test/support/client_contract.ex` | `v2_flux_pipeline_tests` |
| `docs/guides/testing-with-local-client.md`, `usage-rules/query.md`, `CHANGELOG.md` | Updated |

```bash
mix format --check-formatted && mix compile --warnings-as-errors
mix test                      # three runs, 0 failures
mix credo --strict && mix dialyzer && mix docs
docker run -d --rm --name influx2_verify -p 8086:8086 \
  -e DOCKER_INFLUXDB_INIT_MODE=setup -e DOCKER_INFLUXDB_INIT_USERNAME=dev \
  -e DOCKER_INFLUXDB_INIT_PASSWORD=devpassword123 -e DOCKER_INFLUXDB_INIT_ORG=dev-influx \
  -e DOCKER_INFLUXDB_INIT_BUCKET=metrics \
  -e DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=dev-influx-token-123456789 influxdb:2.7
mix test test/integration/contract_v2_test.exs --include v2 --include integration
docker stop influx2_verify
```
