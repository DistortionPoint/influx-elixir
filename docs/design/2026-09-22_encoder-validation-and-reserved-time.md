# Line Protocol Encoder Validation and the Reserved `time` Wording

**Date**: 2026-09-22
**Scope**: `Write.LineProtocol.encode/1`, `Client.Local` write path, `Query.ResponseParser`
**Issue**: scheduled quality sweep

---

## Problem

`LineProtocol.encode/1` validated three things — no fields, an empty
measurement, a bad timestamp — and encoded everything else. Probed against
InfluxDB 3 (`influxdb:3-core`, the documented one-liner), these encoded
lines are all refused by the server:

| Point | Line | Server |
|---|---|---|
| `tags: %{"host" => ""}` | `m,host= v=1i` | 400 `Expected tag value, got …` |
| `tags: %{"" => "x"}` | `m,=x v=1i` | 400 `Expected tag key, got …` |
| `fields: %{"" => 1}` | `m =1i` | 400 `No fields were provided` |
| `tags: %{"time" => "x"}` | `m,time=x v=1i` | 400 `'time' is a reserved column` (InfluxDB 2: `cannot use reserved tag key "time"`) |
| `tags: %{"host" => "a\nb"}` | `m,host=a` ⏎ `b v=1i` | 400 for line 1 **and a point stored under measurement `b`** |
| `measurement: "m\nx"` | `m` ⏎ `x v=1i` | same: bogus measurement `x` |

Line protocol has no escape for a newline outside a quoted string value,
so a newline in a name ends the line and the rest is a second line. That
is silent data corruption from a value as ordinary as an environment
variable with a trailing newline. A non-string tag value or an unsupported
field value (`nil`, an atom, a `Decimal`) crashed the encoder with a
`FunctionClauseError` inside `String.replace/3`.

Separately, `Client.Local` reported a `time` field as `invalid column type
for column 'time', expected iox::column_type::timestamp, got …` on every
write. The engine says that only when the table already exists; on a new
table a `time` tag or field is `'time' is a reserved column` (verified on
both shapes, both cases).

## Decision

The encoder refuses what no InfluxDB version accepts, and only that:

| Problem | Error |
|---|---|
| measurement not a string / contains `\n` | `{:invalid_measurement, value}` |
| tag key empty / not a string / contains `\n` | `{:invalid_tag_key, key}` |
| tag value empty / not a string / contains `\n` | `{:invalid_tag_value, key, value}` |
| tag key `time` | `{:reserved_tag_key, "time"}` |
| field key empty / not a string / contains `\n` | `{:invalid_field_key, key}` |
| field value not integer / float / string / boolean | `{:invalid_field_value, key, value}` |

A field named `time` is *not* refused: InfluxDB 3 rejects it, InfluxDB 2
drops it silently, so the server decides. A newline inside a string field
value is quoted and both versions store it (verified in the contract
suite). Existing errors (`:empty_fields`, `:empty_measurement`,
`{:invalid_timestamp, v}`) keep their shapes.

An escape fast path (one `:binary.match/2` for the four special
characters before the four `String.replace/3` passes) was benchmarked and
rejected: on typical tag values it is about twice as slow as the four
replaces, so the escaping is unchanged.

`Client.Local` moves the v3 `time` rule from the parser into the store,
which knows whether `{:column, db, measurement, _}` objects exist: none →
`'time' is a reserved column`; some → the column-type conflict with the
kind the line carried (`iox::column_type::tag` or the field type). The v2
parser rule (`cannot use reserved tag key "time"`, whole payload refused)
is unchanged. Also verified and already matching: a rejected line
registers the new columns it names (a tag `n` on a line that fails on `v`
makes `n` a tag).

`ResponseParser.coerce_naive/1` runs a regex on every string cell to spot
InfluxDB 3's zone-less timestamp rendering. A binary pattern
(`dddd-dd-ddT…`) now screens out the strings that cannot match: 14 ns
instead of 340 ns per ordinary string cell, unchanged for timestamps.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/write/line_protocol.ex` | `name?/1`, `encode_tag/2`, `encode_field/2`, `field_value?/1`; "Validation" section |
| `lib/influx_elixir/client/local.ex` | `check_schema/4` → `reserved_time/3` + `check_column_types/4`; moduledoc |
| `lib/influx_elixir/client/local/line_protocol_parser.ex` | v3 `check_columns/3` keeps only the tag-and-field rule |
| `lib/influx_elixir/query/response_parser.ex` | shape guard on `coerce_naive/1` |
| `test/influx_elixir/write/line_protocol_test.exs` | "refuses what no server accepts" block |
| `test/influx_elixir/client/local_test.exs` | new-table wording; existing-table test |
| `test/influx_elixir/query/response_parser_test.exs` | date-shaped non-timestamp stays a string |
| `test/influx_elixir/write/batch_writer_test.exs` | multi-retry exhaustion; `max_retries: 0` transport error |
| `usage-rules/write.md`, `CHANGELOG.md` | Updated |

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
