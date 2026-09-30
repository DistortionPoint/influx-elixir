# BatchWriter Timer, v3 CSV, Write Bodies, Connection Restart, Encoder Speed

**Date**: 2026-09-30
**Scope**: `BatchWriter`, `ConnectionSupervisor`, `ResponseParser`, `Writer`,
`Client.HTTP`, `Client.Local` (write bodies, retention errors), `LineProtocol`
**Issue**: scheduled quality sweep (no open issues)

---

## Problem

A review of the code outside `Client.Local` and of the tests found the
following. Each claim below was reproduced, most of them against
InfluxDB 3 Core 3.10.1 and InfluxDB 2.7.

**BatchWriter timer.** `do_flush/1` cancelled the interval timer, and
only the timer's own handler re-armed it. After a size-triggered flush,
an explicit `flush/2` or a `write_sync/3`, the timer never fired again.
With `batch_size: 2, flush_interval_ms: 50`, a third point stayed
buffered until the next full batch or shutdown.

**Connection restart.** `Process.exit(connection_supervisor, :kill)`
stopped `InfluxElixir.Supervisor` with reason `:shutdown`. The killed
supervisor's Finch pool and writer outlive it briefly, still registered.
The restart failed with `:already_started`, and the repeated failures
exceeded the top supervisor's restart intensity. That broke the crash
isolation the supervisor documents.

**v3 CSV.** Core writes a null or empty cell of a one-column result as
`""`:

```
host
a
""
b
```

NimbleCSV reads `""` as `[""]`, which the parser treated as Flux's table
separator. It dropped that row and read `b` as the header of a new
table, so a four-row result came back as one row. A Flux row always has
the annotation, `result` and `table` columns, so only Flux CSV can use
`[""]` as a separator.

**Write bodies.** Several write-body behaviours were wrong:
- `Client.HTTP` sets `Content-Encoding: gzip` from `gzip: true`, but
  `Writer` compressed only payloads over 1 KB. An explicit `gzip: true`
  on a small payload got
  `400 error decoding gzip stream: unexpected end of file` from InfluxDB 3
  and a 500 `internal error` from InfluxDB 2.
- `Client.Local` decompressed on the gzip magic bytes and ignored
  `gzip:`. Both engines let the header decide:
  - a gzip body without the header is refused (InfluxDB 3:
    `body content is not valid utf8: invalid utf-8 sequence of 1 bytes from index 1`);
  - a plain body with the header is refused.
- InfluxDB 3 refuses any body that is not UTF-8. It names the first bad
  byte the way Rust's `Utf8Error` does:
  - `invalid utf-8 sequence of N bytes from index I`;
  - `incomplete utf-8 byte sequence from index I`.

  InfluxDB 2 stores the bytes as they are.
- The engine checks a request in this order: query parameters
  (precision, flags), then the body, then the database. A body error
  therefore creates no database.
- The gzip failure reasons are:
  - `unexpected end of file`: under 10 bytes, or truncated;
  - `invalid gzip header`;
  - `corrupt deflate stream`;
  - `corrupt gzip stream does not have a matching checksum`.

  Concatenated members decode as one body.

**HTTP client.** Three gaps from `Client.Local`:
- `execute_sql/3` sent no `params`, so a placeholder was
  `400 No value found for placeholder with name $host`. `Client.Local`
  runs `execute_sql` through `query_sql` and bound it.
- `resolve_database/2` read an explicit `database: nil` as the database.
  `Client.Local` and the facade's telemetry use the connection default.
- Admin decodes returned a bare `Jason.DecodeError`, and `list_databases`
  raised on JSON that is not a list.

**Retention error.** Core appends `at line 1 column N` to its duration
error. N is the byte offset of the end of the retention value in the
request body, which is the byte before the closing brace of
`{"db":…,"retention_period":…}`. `Client.Local` left the suffix out.

**Encoder speed.** Encoding 10,000 tagged points took 191 ms. Four
chained `String.replace` passes ran on every tag key, tag value and field
key. When those were first swapped for one `:binary.match/2` with a list
pattern, the pattern was compiled on every call, about 1.2 µs a name.

**Tests.** These tests broke the project's rules or could not fail:
- four HTTP "integration" tests that passed with no server and accepted
  any tagged tuple;
- `assert Enumerable.impl_for(stream)`, which is true for any function;
- a "crash isolation" test in which nothing crashed;
- `flush(:default)` passing only because `:default` was never
  registered;
- configuration tests that matched `ValidationError` without its key;
- an isolation test that depended on test order;
- a fixed global Finch name in an async module;
- a 250 ms timing margin in a backpressure test.

## Decision

- **Timer.** `schedule_flush/1` cancels any running timer first, and
  every flush that writes ends by scheduling. Exactly one timer runs, and
  each flush restarts the interval.
- **Restart.** `ConnectionSupervisor.init/1` monitors any process still
  holding its Finch or writer name and waits for it to exit, up to 15 s,
  before starting children.
- **CSV.** `parse(body, :csv)` reads InfluxDB 3's CSV as one table: a
  header, then one row per line, even a line that reads as empty. The new
  `parse(body, :flux_csv)` keeps the annotated multi-table parser, and
  `query_flux` uses it.
- **gzip.** `Writer` owns compression. `gzip: true` always compresses,
  `gzip: false` never does, and the default compresses over 1 KB. The
  client receives `gzip: true` exactly when the body is compressed.
- **Local bodies.** The new `Client.Local.Body.read/3` applies the
  engines' rules above, with their bodies, in the engine's order.
  `:zlib` reports only `:data_error`, so the reason is classified from
  the header and from whether the stream inflates as gzip, or as raw
  deflate without the checksum. Bytes after a complete stream are not
  modelled exactly.
- **HTTP.**
  - `execute_sql` sends `params`.
  - `resolve_database` uses `opts[:database] || conn[:database]`.
  - One `decode_json/1` returns `{:json_parse_error, reason}`.
  - `list_databases` returns `{:unexpected_response, body}` for JSON
    that is not a list.
- **Encoder.** Escaping scans each name once, byte by byte, with guards
  generated per kind of text (`:name`, `:measurement`, `:string`), and
  returns the name unchanged when nothing needs escaping. Lines are built
  as iodata, with one `IO.iodata_to_binary/1` per point or batch.
- **Tests.** Each weak test was fixed or deleted. The new tests assert
  behaviour rather than internal state.

**Rejected findings, after verification:**
- **An empty `Bearer` token over Flight.** Core accepts it: the
  integration suite runs Flight with `token: ""`.
- **v2 `precision: "u"`.** It is the documented pass-through of the
  engine's own 400.
- **Retrying 408/429.** "4xx is never retried" is documented behaviour.
- **A nil stream status, `coerce_types` on non-map rows, a boolean cast
  fallback.** None of these is reachable from a real server response.

## Open: token management does not match either server

The same probes showed that `create_token/3` and `delete_token/2` call
`POST /api/v3/configure/token` and `DELETE /api/v3/configure/token/{id}`.
Neither exists on InfluxDB 3 Core 3.10.1: both answer 404 with auth
enabled, and 405 without. The Enterprise 3.11.5 binary serves:
- `/api/v3/configure/token/admin`;
- `/api/v3/configure/token/named_admin`;
- `/api/v3/enterprise/configure/token` (resource tokens with
  `db:<names>:<actions>` permissions, a name and an expiry);
- deletion by `?token_name=`.

No token has a "description". `Client.Local` models the library's own
shape, so the contract suite could not catch this. Fixing it changes the
public API and needs a licensed Enterprise server to verify, so it is left
for a decision rather than changed here.

## Verification

- **BatchWriter.** Three regression tests (size flush, explicit flush,
  `write_sync`) fail on the old writer and pass on the fix.
- **Restart.** "A killed connection supervisor restarts alone, the others
  untouched" fails without the fix and passes with it, six runs out of
  six.
- **CSV.** The contract test "format: :csv keeps a one-column row whose
  value is null or empty" fails against Core on the old parser (one row
  returned) and passes on the fix.
- **HTTP.** The new `execute_sql` params and `database: nil` contract
  tests fail against Core on the old HTTP client and pass on the fix.
- **Write bodies.** The gzip and UTF-8 contract tests pass on Local and
  Core, with exact bodies. The v2 body tests pass on Local and 2.7.
- **Retention.** The contract test now asserts exact columns, on Local
  and Core.
- **Encoder.** Output is identical before and after, pinned by a test
  covering every escape character next to multi-byte characters; the
  line round-trips through Core. 10,000 points: 191 → 30 ms.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/write/batch_writer.ex` | Timer re-armed after every flush |
| `lib/influx_elixir/connection_supervisor.ex` | `await_release/1` before starting children |
| `lib/influx_elixir/query/response_parser.ex` | `:csv` single table, `:flux_csv` |
| `lib/influx_elixir/write/writer.ex`, `lib/influx_elixir.ex` | `gzip:` option |
| `lib/influx_elixir/client/http.ex` | `params`, `database: nil`, `decode_json/1`, `:flux_csv` |
| `lib/influx_elixir/client/local/body.ex` (new), `lib/influx_elixir/client/local.ex` | Write bodies, check order, retention position |
| `lib/influx_elixir/write/line_protocol.ex` | Escaping and iodata |
| `lib/influx_elixir/admin/*.ex`, `lib/influx_elixir/config.ex` | Docs |
| Tests | See the Problem section; contract blocks for bodies, CSV, params, `database: nil` |
| `CHANGELOG.md`, `usage-rules/write.md`, `usage-rules/query.md`, `docs/guides/testing-with-local-client.md` | Updated |
