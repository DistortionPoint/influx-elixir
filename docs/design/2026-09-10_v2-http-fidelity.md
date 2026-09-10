# InfluxDB v2 HTTP Fidelity, Flux Row Shape, and Encoding Fixes

**Date**: 2026-09-10
**Scope**: `Client.HTTP` v2 endpoints, `Query.ResponseParser` CSV, `Client.Local.query_flux/3`, `Write.LineProtocol` floats, `Telemetry` start events, `Flight.Client` channel lifecycle
**Trigger**: scheduled code/test sweep; every claim below was verified against a live `influxdb:2.7` (org `dev-influx`, bucket `metrics`) or `influxdb:3-core` container

---

## What the real v2 engine showed

Running the existing v2 contract suite against InfluxDB 2.7 for the first time
gave 11 tests, 6 failures:

| Symptom | Cause |
|---|---|
| `write/3` of garbage or to a ghost bucket returned `{:ok, :written}` | `write/3` always posted to `/api/v3/write_lp`; a 2.7 server answers **200** to that path and stores nothing |
| `create_bucket/3` → `400 id must have a length of 16 bytes` | body carried `"orgID": ""`; v2 wants the org's 16-hex ID, not its name |
| `delete_bucket/2` with a name → same 400 | v2 deletes by ID; `Client.Local` deletes by name, so the contract could never pass on both |
| Flux rows carried `\r` in the last cell, a junk row per blank line, and the second table's header as data | hand-rolled `String.split("\n")` CSV parser; real output is CRLF, multi-table, quoted |

## Design

### `api_version` on the connection

`InfluxElixir.Config` gains `api_version: :v3 | :v2` (default `:v3`). The
version cannot be sniffed — the v3 path "succeeds" on v2 — so it is declared.
`Client.HTTP.write/3` builds the URL from it:

* `:v3` → `/api/v3/write_lp?db=<database>&precision=<precision>`
* `:v2` → `/api/v2/write?org=<org>&bucket=<database>&precision=ns|us|ms|s`
  (`v2_precision/1` maps the v3 spellings and atoms)

The v2 integration helper sets `api_version: :v2`.

### Org and bucket ID resolution

* `create_bucket/3`: `opts[:org_id]` if given, else `GET /api/v2/orgs?org=<name>`
  → first org's `id`. A `422 … already exists` is success, matching
  `Client.Local`'s idempotent create and `create_database/3`'s 409 handling.
* `delete_bucket/2`: a 16-hex argument is used as the ID; anything else is
  resolved with `GET /api/v2/buckets?name=`, and a miss is
  `{:error, %{status: 404, body: "bucket not found: <name>"}}`.

### Annotated CSV with NimbleCSV

`nimble_csv` was already a dependency (CLAUDE.md lists it for CSV parsing) but
unused. `ResponseParser.parse/2` `:csv` now:

1. parses with `NimbleCSV.RFC4180` (CRLF, quoting);
2. splits tables on blank rows;
3. per table, takes `#`-prefixed annotation rows, then the header, drops the
   empty annotation column, and types cells from `#datatype`
   (`double`/`long`/`unsignedLong`/`boolean`/`dateTime:RFC3339[Nano]`; empty →
   `nil`). Without annotations cells stay strings, as before.

`query_flux/3` requests `dialect: {annotations: ["datatype"]}` so real
responses are typed. `coerce_types/1` also converts `_time`/`_start`/`_stop`.

### Local Flux rows match real Flux

Real Flux output is long — one row per field. `Client.Local.query_flux/3` now
emits `%{"result" => "_result", "table" => n, "_time" => DateTime, "_value",
"_field", "_measurement", tags...}`, numbering `table` per series
(measurement + tags + field) and ordering by table then time.
`filter(fn: (r) => r._field == "...")` is honoured. The contract test asserts
typed values and the row shape on both clients.

### Encoding and lifecycle bugs found by reading

* `LineProtocol` floats: `{:decimals, 17}` rounded `1.0e-20` to `0.0`. `:short`
  (shortest round-trip) is used; InfluxDB 3 Core accepts `1.0e-20`/`2.5e-7` and
  reads them back exactly (verified).
* `Telemetry.write_start/1`/`query_start/1` emitted monotonic time as
  `system_time`. Now wall-clock, with `monotonic_time` alongside, as
  `:telemetry.span/3` does.
* `Flight.Client.query/3` leaked the gRPC channel when `DoGet` failed.
* `ResponseParser.parse/2` `:json` raised `CaseClauseError` on a scalar body.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/config.ex` | `api_version` option |
| `lib/influx_elixir/client/http.ex` | v2 write URL/precision, org + bucket ID resolution, dialect annotations, moduledoc |
| `lib/influx_elixir/query/response_parser.ex` | NimbleCSV annotated-CSV parser, `_time`/`_start`/`_stop`, scalar JSON |
| `lib/influx_elixir/client/local.ex` | long-format Flux rows, `_field` filter |
| `lib/influx_elixir/write/line_protocol.ex` | `:short` floats |
| `lib/influx_elixir/telemetry.ex` | wall-clock `system_time` + `monotonic_time` |
| `lib/influx_elixir/flight/client.ex` | disconnect on every path |
| `test/support/client_contract.ex` | typed long-format Flux contract, `_field` filter |
| `test/support/integration_helper.ex` | `api_version: :v2` |
| tests for parser, config, line protocol, telemetry, Local Flux | updated / added |
| `docs/guides/testing-with-local-client.md` | Flux section |
| `CHANGELOG.md` | Unreleased entries |

## Verification

```bash
docker run -d --rm --name influx2_verify -p 8086:8086 \
  -e DOCKER_INFLUXDB_INIT_MODE=setup -e DOCKER_INFLUXDB_INIT_USERNAME=dev \
  -e DOCKER_INFLUXDB_INIT_PASSWORD=devpassword123 -e DOCKER_INFLUXDB_INIT_ORG=dev-influx \
  -e DOCKER_INFLUXDB_INIT_BUCKET=metrics \
  -e DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=dev-influx-token-123456789 influxdb:2.7
mix test test/integration/contract_v2_test.exs --include v2 --include integration
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration
mix test && mix credo --strict && mix dialyzer && mix format --check-formatted
```
