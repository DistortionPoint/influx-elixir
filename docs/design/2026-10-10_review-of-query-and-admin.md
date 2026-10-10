# Review of the query, admin and config modules

**Date:** 2026-10-10
**Status:** Implemented

## Context

A sweep with no open GitHub issues. Recent passes reviewed Flight, line protocol, the
BatchWriter, the connection supervisor and Local's engines; this one read the rest:
`Query.*`, `Admin.*`, `Config`, `Connection`, `StreamError`, `QueryParams`, the telemetry
docs, and their tests. Every finding was checked against the code before it was fixed.

## Decisions

### Fixed

- **`format: :parquet` broke the spec.** `query_sql` and `query_influxql` return the
  response body, a binary, for `:parquet`, but `Client.query_result` allowed only a list of
  rows. The type is now `{:ok, [map()] | binary()} | {:error, term()}`.
- **A health body that decodes to something other than a JSON object was returned as it
  decoded.** For example, a 200 whose body is `true` gave `{:ok, true}`, where the spec
  promises a map. Such a body is now a passing check, as plain text already was.
- **Streaming a long JSONL line was quadratic.** Every chunk was appended to the buffered
  partial line and the whole buffer was split again. Now only the new chunk is split, and its
  first piece is joined to the buffer, so a line costs its length once.
- **A blank `\r` line in a stream raised.** A whitespace-only line between rows (a CRLF
  blank line) raised a `:decode` `StreamError`. Such lines are now dropped, as a blank
  remainder at the end of the stream already was.
- **Docs.**
  - Telemetry examples passed `transport: :http`, but the metadata is the client module.
  - "LocalClient" was used where the module is `Client.Local`.
  - "Non-2xx" was used where streams accept only 200.

### Considered and kept

- **An unknown `:format` is still sent to the server.** The engine answers it with its own
  400, which names the byte where its JSON parser stopped, and `Client.Local` reproduces that
  byte for byte (`Client.Local.Format`). Rejecting it before the request would hide the
  engine's answer and break the double's parity.
- **`connection_supervisor_client_error_test.exs` stays synchronous.** The client is
  application-wide by design (`config :influx_elixir, :client`). A client that refuses every
  connection can only be installed there, and the module's comment says so.

### Tests

- **New tests.**
  - `TestServer.respond/3` can send a body, whole or as separate chunks.
  - New tests cover a non-object health body, and a streamed row split over 7-byte chunks
    with CRLF terminators and a blank line.
  - Token `permissions:` that are not a list are now covered.
- **Exact values where a weak assertion stood.**
  - Database and `SHOW` listings.
  - The stream's rows and its `StreamError` fields.
  - The `StreamError` messages.
  - Parsed timestamps.
  - Flux CSV rows.
  - The bucket id's form.
- **Shared registry keys.** The `finch_name/1` tests read fixed registry keys (`:my_conn`,
  `:conn_a`), which every test shares. They now use unique names, one of them registered.
- **A misleading test name.** A Flux CSV test said "yields no rows" while it asserted a row.
  It was renamed.

## Verification

The unit tier, coverage and every gate were run one at a time; see the commit.
