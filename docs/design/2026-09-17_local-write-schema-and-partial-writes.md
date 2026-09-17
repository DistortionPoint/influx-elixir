# `Client.Local` Write Rules: Column Schema and Partial Writes

**Date**: 2026-09-17
**Scope**: `Client.Local.LineProtocolParser`, `Client.Local.write/3`, `delete_database/2`
**Issue**: scheduled quality sweep

---

## Problem

The line-protocol encoder round-trips every escaping and number-format edge
case identically through InfluxDB 3 Core and the double (ten cases, from
`eu,west` tag values to `1.0e-7`). The *rules* about what a write may
contain did not match:

| Payload | Engine | Double before |
|---|---|---|
| `v=1i` then `v=2.0` (same measurement) | 400 "invalid column type for column 'v', expected …integer, got …float" | stored both |
| tag `host` then field `host`; string then float; boolean then integer | 400, same shape | stored |
| `m,time=x v=1i`; `m time=5i,v=1i` | 400 "'time' is a reserved column" / "invalid column type for column 'time'" | stored |
| `m,host=a host=1i` | 400 "invalid column type for column 'host', expected tag, got field::integer" | stored |
| `v=9223372036854775808i` | 400 "Unable to parse integer value" | stored (as a bignum) |
| three lines, the second bad | 400 **and lines 1 and 3 stored**; body lists every bad line | nothing stored |
| `s="a\nb"` | stored, value contains the newline | 400 |
| empty payload | 400 "incoming write was empty" | `{:ok, :written}` |
| `7u` | stored (uinteger) | 400 |
| delete database, re-create, query | table not found; old schema gone | old points returned |

A test suite that writes a field as an integer in one fixture and a float in
another passes on the double and fails in production — the failure
consumers meet most often.

## Design

**Parser: per-line results.** `parse_lines/2` splits at newlines outside
quoted strings and returns one result per line — `{:ok, point, number,
line}` or `{:error, %{error_message, line_number, original_line}}` (the
line truncated to 20 characters, as the engine reports it). Per-line rules
live there: int64 range (`u` marks unsigned; the marker is stripped after
the schema check), reserved `time`, a key that is both tag and field. An
empty payload is the only whole-payload error.

**Store: schema per column.** `{:column, database, measurement, column}`
holds the column's kind string exactly as the engine names it. The first
writer fixes it with `:ets.insert_new/2` — atomic, so concurrent writers
never lose a column; a later line whose kind differs is rejected with the
engine's message and the others are stored. The response is the engine's
JSON, so consumer code that reads the partial-write body can be exercised.
`delete_database/2` deletes the points and the columns with the database.

Rejected: keeping "first error aborts the write". It was simpler, and
wrong in both directions — the good lines *are* stored on the engine, and
the error body lists every bad line, not the first.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/line_protocol_parser.ex` | `parse_lines/2`, quote-aware line split, int64 / uint64, reserved `time`, tag-and-field check, engine messages |
| `lib/influx_elixir/client/local.ex` | `store_lines/3`, `check_schema/3`, partial-write body, `delete_database/2` drops points and schema, moduledoc "Write Rules" |
| `test/influx_elixir/client/local_test.exs`, `test/influx_elixir_test.exs` | Regression block; one facade fixture kept type-consistent |
| `test/support/client_contract.ex` | `write_rule_tests`, run against Local and the server |
| `docs/guides/testing-with-local-client.md`, `usage-rules/write.md`, `CHANGELOG.md` | Updated |

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
