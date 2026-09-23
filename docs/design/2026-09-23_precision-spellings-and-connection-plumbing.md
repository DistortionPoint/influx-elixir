# Precision Spellings, Duplicate Points and Connection Plumbing

**Date**: 2026-09-23
**Scope**: `Client.Local` write precision and duplicate points, `ConnectionSupervisor`, `Connection`, `Telemetry`, Writer tests
**Issue**: scheduled quality sweep

---

## Problem

A Writer test passed `precision: :ms` and passed only because its line
carried no timestamp: `Client.Local` accepted exactly
`:nanosecond | :microsecond | :millisecond | :second` and raised a
`FunctionClauseError` for anything else. `HTTP.write/3` passes the option
to InfluxDB 3 verbatim, so what the double refused was what production
ran. Probed on both engines (the documented Docker one-liners):

| `precision=` | InfluxDB 3 | InfluxDB 2.7 |
|---|---|---|
| `ns` `us` `ms` `s` | 204 | 204 |
| `n` `u` | 204 | 400 |
| `nanosecond` `microsecond` `millisecond` `second` | 204 | 400 (`HTTP.write/3` maps these to the short forms first, so they work through the client) |
| `auto` | 204, unit guessed | 400 |
| `NS` `nanoseconds` `bogus` | 400 `serde error: unknown variant `bogus`, expected one of `auto`, `s`, `second`, `millisecond`, `ms`, `microsecond`, `u`, `us`, `n`, `nanosecond`, `ns`` | 400 `{"code":"invalid","message":"invalid precision; valid precision units are ns, us, ms, and s"}` |
| absent | nanoseconds | nanoseconds |

`auto` on InfluxDB 3, by magnitude sweep (boundaries confirmed with
4 999 999 999 vs 5 000 000 000 at each step):

| \|timestamp\| | unit |
|---|---|
| < 5 000 000 000 | seconds |
| < 5 000 000 000 000 | milliseconds |
| < 5 000 000 000 000 000 | microseconds |
| otherwise | nanoseconds |

Separately: `ConnectionSupervisor` always started a Finch pool, even when
`:finch_name` named the consumer's own — an idle pool per connection, and
under `rest_for_one` the batch writer restarted with a pool it never used.
`Connection.fetch!/1` surfaced `:persistent_term`'s bare `ArgumentError`;
`Connection.get/1` rescued that error for control flow. The manual
telemetry emitters (`write_stop/2` and friends) emitted `%{duration}`
only, while the documented events and the spans carry `monotonic_time`,
and `write_stop/2`'s docs still named a `compressed_bytes` key that the
2026-09-11 sweep had removed from the event docs.

The Writer tests asserted `{:ok, :written}` and nothing else: "applies
gzip" did not check that anything was stored, "passes through custom
opts" did not check that the option did anything.

## Decision

`Client.Local.write/3` normalises `:precision` per profile to what
`HTTP.write/3` plus that engine accept: the v3 table above as atom or
string, case-sensitive; the v2 short forms plus the long names the HTTP
client maps. `LineProtocolParser` gains `:auto` at the engine's
thresholds. An unknown spelling returns the engine's 400 body for the
profile. The default stays nanoseconds.

`ConnectionSupervisor` starts no Finch child when `:finch_name` is in the
config. `Connection.get/1` uses `:persistent_term.get/2` with a
per-call reference as the miss sentinel; `fetch!/1` raises an
`ArgumentError` that names the connection and how to register one. The
manual telemetry emitters send `%{duration, monotonic_time}`. The
`compressed_bytes` mention is removed rather than implemented, keeping the
2026-09-11 decision.

Writer tests now observe behaviour through the real path: a 100-point
payload over 1 KB is stored in full (the client receives it gzipped and
`Client.Local` decompresses on the magic bytes), `precision: :ms` changes
the stored time, and `client: InfluxElixir.Client.HTTP` against a closed
port yields the transport error only that client can produce.


## Duplicate Points

Extending the precision contract test wrote the same measurement at the
same instant three times and expected one row. `Client.Local` returned
three. Probed on both engines:

| Writes (same measurement, `h=x`, same timestamp) | InfluxDB 3 | InfluxDB 2.7 |
|---|---|---|
| `v=1i` then `v=2i` | one row, `v=2` | one row per field: `v=2` |
| `v=1i` then `w=2i` | one row, `v=1, w=2` | `v=1`, `w=2` |
| `v=1i,w=1i` then `v=2i` | one row, `v=2, w=1` | `v=2`, `w=1` |
| `h=x v=1i` and `h=y v=2i` | two rows | two series |
| both lines in one payload | last line wins | last line wins |
| `COUNT(v)`, `SUM(v)` after `v=1i` then `v=2i` | 1, 2 | — |

The store keeps one ETS object per write (the #15 decision: a plain insert
is atomic, so concurrent writers never clobber each other) and merges on
read: `merge_duplicates/1` folds a measurement's objects by
`{measurement, tags, timestamp}`, `Map.merge`-ing fields so the later
write wins, and keeps the first write's position. Every reader — the SQL
executor's source, the Flux and InfluxQL paths — goes through it, per
database. `DELETE` evaluates its `WHERE` over the merged points and deletes
every stored object behind a match, counting merged points. The v3 and v2
contract suites carry the case against the real engines.

## Admin Options and Not-Found Answers

`Admin.Databases.create/3` documented `:retention_period` and
`Admin.Buckets.create/3` documented `:retention_seconds`; `Client.HTTP`
reads `:retention` for both, so the documented option was ignored. Probed:

| Call | InfluxDB 3 | InfluxDB 2.7 |
|---|---|---|
| create database, `retention_period: "30d"` / `"1h"` | 200 | — |
| create database, `retention_period: 3600` | 400 `serde json error: invalid type: integer … expected a duration` | — |
| create bucket, `everySeconds: 3600` | — | 201, `retentionRules: [{type: "expire", everySeconds: 3600, shardGroupDurationSeconds: 3600}]` |
| create bucket, `everySeconds: 60` | — | 500 `retention policy duration must be at least 1h0m0s` |
| create bucket, `everySeconds: 0` | — | 201, no expiry |
| delete missing database / bucket | 404 `the requested resource was not found: <name>` | 404 |
| write to a missing bucket | — (v3 auto-creates) | 404 `{"code":"not found","message":"bucket \"<name>\" not found"}` |

`Client.Local.delete_bucket/2` returned `:ok` for a missing bucket, with a
doc comment claiming that matched v2. It now returns the 404 body
`Client.HTTP` produces for a missing name (`bucket not found: <name>`,
from its ID lookup). `create_bucket/3` stores `retention:` under
`{:bucket, name}` and refuses 1–3599 seconds with the engine's 500 body;
`list_buckets/1` lists `"retentionRules"` in the engine's shape (without
`shardGroupDurationSeconds`, which the engine derives and the double does
not model). `delete_database/2`'s body is the engine's wording. The docs
name `:retention` with each version's format; the contract suites verify
the rule, the refusal and both 404s against the real engines.
## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local.ex` | `normalize_precision/2`, `@v3_precisions`, `@v2_precisions`; `merge_duplicates/1` on every read, `delete_points/4`; bucket retention, 404s; docs |
| `lib/influx_elixir/admin/databases.ex`, `lib/influx_elixir/admin/buckets.ex`, `lib/influx_elixir.ex` | `:retention` documented with the verified formats |
| `lib/influx_elixir/flight/client.ex` | `do_get/4` uses `build_ticket/2` |
| `test/influx_elixir/admin/*_test.exs`, `test/influx_elixir_test.exs`, `test/influx_elixir/flight/client_test.exs` | observable assertions; honest test names |
| `lib/influx_elixir/client/local/line_protocol_parser.ex` | `t:precision/0`, `:auto` in `to_nanoseconds/2` |
| `lib/influx_elixir/connection_supervisor.ex` | no Finch child with `:finch_name`; docs |
| `lib/influx_elixir/connection.ex` | `get/1` sentinel read, `fetch!/1` message |
| `lib/influx_elixir/telemetry.ex` | `monotonic_time` on manual stop/exception emitters; doc fix |
| `test/influx_elixir/client/local_test.exs` | spellings, `auto` thresholds, unknown → 400, v2 profile |
| `test/support/client_contract.ex` | v3 precision block extended; `v2_precision_tests`, `duplicate_tests`, `v2_duplicate_tests` — all run against the real engines |
| `test/influx_elixir/write/writer_test.exs` | rewritten to assert observable behaviour |
| `test/influx_elixir/connection_supervisor_test.exs`, `connection_test.exs`, `telemetry_test.exs` | new assertions |
| `usage-rules/write.md`, `CHANGELOG.md` | Updated |

## Verification

```bash
mix format --check-formatted && mix compile --warnings-as-errors
mix test                      # three runs, 0 failures
mix credo --strict && mix dialyzer && mix docs
docker run -d --rm --name influx3_verify -p 8181:8181 influxdb:3-core \
  influxdb3 serve --node-id node0 --object-store memory --without-auth
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration
docker run -d --rm --name influx2_verify -p 8086:8086 \
  -e DOCKER_INFLUXDB_INIT_MODE=setup -e DOCKER_INFLUXDB_INIT_USERNAME=dev \
  -e DOCKER_INFLUXDB_INIT_PASSWORD=devpassword123 -e DOCKER_INFLUXDB_INIT_ORG=dev-influx \
  -e DOCKER_INFLUXDB_INIT_BUCKET=metrics \
  -e DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=dev-influx-token-123456789 influxdb:2.7
mix test test/integration/contract_v2_test.exs --include v2 --include integration
docker stop influx2_verify influx3_verify
```
