# Telemetry Emission, BatchWriter Retry Classification, Supervisor Wiring

**Date**: 2026-09-11
**Scope**: `InfluxElixir` facade, `Write.Writer`, `Write.BatchWriter`, `ConnectionSupervisor`, `Config`, `Telemetry`
**Trigger**: scheduled code/test sweep (no open GitHub issues)

---

## Bugs found and fixed

### 1. Telemetry was documented but never emitted

`InfluxElixir.Telemetry` (and CLAUDE.md) described `[:influx_elixir, :write |
:query, :start | :stop | :exception]` events, and shipped `span_write/2` and
`span_query/2`, but no library code called them. Consumers attaching handlers
saw nothing.

**Fix**: `Write.Writer.write/3` wraps the client call in `span_write/2` with
`%{database, bytes, point_count}`; because `BatchWriter` flushes go through
`Writer`, they are covered too. The facade's `write/3` now goes through
`Writer` (gaining the >1 KB gzip the writer already applied), and
`query_sql/3`, `execute_sql/3`, `query_influxql/3`, `query_flux/3` wrap the
client in `span_query/2` with `%{database, transport: client_module}`. The
`:stop` metadata adds `result: :ok | :error` and `row_count` for list results;
an error tuple is a `:stop`, not an `:exception`, because nothing raised. The
moduledoc's claimed `compressed_bytes` metadata never existed and was removed.

### 2. `BatchWriter` retried 4xx responses

Both the immediate-flush and retry paths matched
`{:error, {:http_error, status}}` to discard 4xx batches — a shape neither
client produces (`Client.HTTP` and `Client.Local` return
`{:error, %{status, body}}`). Every rejected batch was therefore retried with
exponential backoff until `max_retries` ran out. The existing tests encoded
the wrong behaviour ("LocalClient error does not match 4xx discard clause").

**Fix**: match `{:error, %{status: status}} when status in 400..499`. Tests now
assert a 4xx is dropped on the first response. The genuine retry path needs a
retryable error: a new `:client` option on `BatchWriter`/`Writer` lets the
test use `Client.HTTP` against `127.0.0.1:1` (a real closed port, no mocking)
while the suite's configured client stays `Local`.

### 3. `ConnectionSupervisor` gave the writer the raw config

`init/1` called `init_connection/1` and registered the initialised connection,
but started the `BatchWriter` with `connection: config`. Under `Client.Local`
the initialised connection is the ETS-backed map, so the writer's first flush
failed with a `FunctionClauseError`. **Fix**: pass `conn`. A supervisor-level
test writes through the named connection's writer and reads back with the
facade.

### 4. Config typos were silently ignored

`InfluxElixir.Config` was never used by the library. The facade and
application moduledocs (and a test) used `default_database:`, which is not a
key at all, and nothing complained. **Fix**: the supervisor validates the
config with `Config.validate!/1` when the client is `Client.HTTP` (a `Local`
connection legitimately has no host). The schema gained the keys the
supervisor and HTTP client actually read: `:timeout`, `:batch_writer`,
`:finch_name`. Docs corrected to `database:`.

### 5. `transport: :flight` was documented but ignored

The facade, `Query.SQL` and `usage-rules/query.md` all described a
`transport: :flight` option; `Flight.Client` existed; nothing read the option,
so every query went over HTTP. **Fix**: `Client.HTTP.query_sql/3` dispatches
on `:transport`. For `:flight` it builds the Flight connection map from the
HTTP connection (host, token, resolved database) and `flight_port` (per-call
opt → connection → 443), forwards `:timeout`/`:connect_timeout`/`:tls`, and
rejects `params:` (the Flight ticket has no parameter slot) rather than
dropping them. `Config` gains `:flight_port`. Verified against InfluxDB 3 Core,
which serves Flight on its HTTP port without TLS: the Flight rows equal the
HTTP rows for the same query. `Client.Local` ignores the option (in-memory).

### 6. `time` differed between transports

With Flight implemented, selecting `time` showed the gap: `Flight.Reader`
returned Timestamp columns as raw integers, and the HTTP path *also* failed to
convert — InfluxDB 3 renders JSON timestamps without a zone
(`"2023-11-14T22:13:20.123456789"`), which `DateTime.from_iso8601/1` rejects,
so `ResponseParser` had been leaving `time` as a string. **Fix**: the reader
parses the Arrow `TimeUnit` from the Timestamp table and converts with
`DateTime.from_unix!/2`; the parser falls back to `NaiveDateTime` and stamps
UTC. Both truncate to microseconds, so rows are identical — the integration
test asserts `flight_row == http_row` including `time`. The reader's
fixed-width decoders were also rewritten as binary comprehensions.

Fixing HTTP exposed the third divergence: `Client.Local` rendered `time` and
`DATE_BIN` buckets as ISO 8601 strings, so the contract suite had been
asserting `is_binary(row["time"])` against a string on Local and (by accident
of the zone-less parsing bug) a string on HTTP. Local now returns `DateTime`
too, sorts bucket rows with the `DateTime` comparator (term order on structs
is not chronological), and every timestamp the library returns is normalised
to microsecond precision so values from JSON, Flight and Local are `==`.
Contract tests assert the single instant `~U[2023-11-14 22:13:20.000000Z]`
across all three.

### 7. Test isolation for telemetry

Handlers are global, so once the facade emitted spans, an async test in
`telemetry_test.exs` received a `:stop` from another module. Both test files
now attach a module-function handler that forwards only events emitted by the
test process itself (the handler runs in the emitter). The module capture also
removes telemetry's "local function" info log printed on every attach, which
was noise in every test run.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir.ex` | write via `Writer`, query spans, doc example, `add_connection` simplification |
| `lib/influx_elixir/write/writer.ex` | span, `:client` option, metadata |
| `lib/influx_elixir/telemetry.ex` | accurate moduledoc, `:stop` metadata |
| `lib/influx_elixir/write/batch_writer.ex` | 4xx classification, `:client` option |
| `lib/influx_elixir/connection_supervisor.ex` | initialised connection to writer, HTTP config validation, spec |
| `lib/influx_elixir/config.ex` | `:timeout`, `:batch_writer`, `:finch_name` |
| `lib/influx_elixir/application.ex` | doc example |
| tests | retry rewrite with real transport error, supervisor writer test, facade telemetry tests, config tests, isolated handlers |
| `CHANGELOG.md` | Unreleased entries |

## Verification

```bash
mix compile --warnings-as-errors && mix test && mix credo --strict && mix dialyzer
mix format --check-formatted
```
