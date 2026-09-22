# `Client.Local` `:v2` Write Rules

**Date**: 2026-09-22
**Scope**: `Client.Local.LineProtocolParser` dialects, `Client.Local.write/3` under `:v2`
**Issue**: scheduled quality sweep

---

## Problem

`2026-09-17_local-write-schema-and-partial-writes.md` gave the double
InfluxDB 3's write rules and applied them under every profile. InfluxDB
2.7, probed the same way (`influxdb:2.7`, the documented Docker one-liner),
differs on nearly every point:

| Payload | InfluxDB 3 | InfluxDB 2.7 | Double before |
|---|---|---|---|
| `v=1i` then `v=2.0` | 400, per-line JSON, other lines stored | **422** `unprocessable entity`, `... is type float, already exists as type integer dropped=1`, other lines stored | v3 shape |
| three lines, the second fails to parse | 400 partial write, lines 1 and 3 stored | **400** `{"code":"invalid","message":"unable to parse '<line>': ..."}`, **nothing stored** | v3 shape, lines stored |
| `m time=5i,v=1i` | 400 | **204**, the `time` field dropped | 400 |
| `m,time=x v=1i` | 400 | 400 `cannot use reserved tag key "time"` | 400 |
| `m,host=a host=1i` | 400 | **204**, both stored | 400 |
| tag `k` then field `k` in a later write | 400 | **204** | 400 |
| empty payload | 400 | **204** | 400 |
| `v=1i` then `v=2u` | 400 | 422 `... is type unsigned ...` | v3 shape |

## Design

The parser takes a dialect. Under `:v2` a `time` field is dropped from the
point, a `time` tag is the v2 error, and a key may be both tag and field;
under `:v3` the existing checks apply. Each line error keeps the full line
(`:line`) because InfluxDB 2 quotes it whole; InfluxDB 3's report drops it
and keeps the 20-character prefix.

`store_lines/4` is per profile. `:v2`: any parse error rejects the payload
with the v2 `invalid` body and stores nothing; otherwise field types only
are checked (tags are not registered, so a tag and a field can share a
name), conflicting lines are dropped, and the response is 422 with the
first conflict and `dropped=N`. `:v3_core` / `:v3_enterprise`: unchanged.
The schema store is the same `{:column, database, measurement, column}`
object; type names are mapped to InfluxDB 2's (`integer`, `unsigned`,
`float`, `string`, `boolean`) for its message. An empty payload is
`{:ok, :written}` under `:v2`.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/line_protocol_parser.ex` | `dialect`, `check_columns/3`, `:line` on errors, `v2_field_type/1` |
| `lib/influx_elixir/client/local.ex` | `store_lines/4` per profile, `check_schema/4`, `conflict/5`, empty payload under `:v2`, moduledoc |
| `test/influx_elixir/client/local_test.exs` | `:v2` regression block |
| `test/support/client_contract.ex` | `v2_write_rule_tests`, run against Local and InfluxDB 2.7 |
| `docs/guides/testing-with-local-client.md`, `usage-rules/write.md`, `CHANGELOG.md` | Updated |

## Verification

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
docker run -d --rm --name influx3_verify -p 8181:8181 influxdb:3-core \
  influxdb3 serve --node-id node0 --object-store memory --without-auth
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration
docker stop influx2_verify influx3_verify
```
