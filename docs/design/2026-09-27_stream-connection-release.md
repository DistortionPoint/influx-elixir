# Streaming Queries Release Their Pool Connection

**Date**: 2026-09-27
**Scope**: `Client.HTTP.query_sql_stream/3` (producer and cleanup), `Flight.Client.query/3`
**Issue**: scheduled quality sweep (no new GitHub issues)

---

## Problem

`query_sql_stream/3` connects the pull-based `Stream.resource` to Finch's
push-based `Finch.stream/5` through a producer process. For each chunk,
the producer sends the chunk to the consumer and blocks until the
consumer acknowledges it. The producer holds a pool connection for the
whole request. There were two ways to lose that connection, and both
were reproduced against `influxdb:3-core` with a `size: 1` pool and a
20,000-row result, which arrives in many chunks:

1. **The consumer dies.** If the consumer is killed (`:kill`, a brutal
   `Task.shutdown/2`, a linked crash), `Stream.resource` runs no cleanup.
   The producer was unlinked and waited only for an acknowledgement, so it
   blocked forever and kept the connection checked out. Every later
   request on the pool was `{:error, {:connection_error, :pool_timeout}}`.
2. **The consumer stops early.** On an ordinary early stop (`Enum.take/2`),
   `stream_cleanup/1` killed the producer. When the owner of a checked-out
   connection dies, Finch's pool drops that connection, but it does not
   serve a request that is already waiting for the pool. Requests made
   after the drop are served. So a request queued at that moment timed
   out, which is common under load.

A first fix, where the producer watched the consumer and called
`exit/1`, cured case 1 only for requests made after the exit. A request
already queued still timed out, because the producer still died holding
the connection. Case 2 had the same cause.

## Decision

- **Halt, never die.** The producer runs `Finch.stream_while/5`. Its
  callback returns `{:halt, :cancelled}` when the producer should stop.
  Finch then ends the request and checks the connection back in, so a
  waiting request is served.
- **Consumer monitor.** The producer monitors the consumer. In
  `emit_and_wait` it waits for either `{:ack, ref}`, `{:cancel, ref}` or
  the consumer's `:DOWN`, and each of the last two halts the request.
  A consumer that dies is noticed at the producer's next chunk. Between
  chunks the producer is inside Finch's socket receive and handles no
  messages.
- **Cooperative cleanup.** `stream_cleanup/1` sends `{:cancel, ref}` to a
  producer that is still alive and waits for its `:DOWN`. Only if the
  producer has not stopped within 1 s (a server gone silent between
  chunks) is it killed, as before. Waiting for `:DOWN` before flushing
  means every message the producer sent is already in the mailbox, so
  none is left behind. After halting, the producer sends nothing more:
  no `:done` and no transport error.
- **`Flight.Client.query/3`** closed its channel on every return path but
  not on a raise. It now uses `try/after`.
- **`wait_until/2`** is the helper in the integration file. A duplicate
  helper was not added, and the existing one's
  `Process.sleep(20) && ...` idiom was straightened.

## Verification

- **Probe scripts** against Core, run on the old and new client:
  - a request queued before the consumer is killed times out on the old
    client and is served on the new one;
  - a request queued during an `Enum.take/2` times out on the old client
    and is served on the new one;
  - a full stream returns all 20,000 rows on both;
  - no messages are left in the consumer's mailbox.
- **Integration tests.** `query_sql_stream/3 releases its pool connection`
  has an early-stop test and a killed-consumer test. Each queues a
  request behind the stream and polls until that request is blocked on
  checkout. Both fail against the previous `http.ex` with `:pool_timeout`
  and pass with the change. The early-stop test also checks that the
  caller's mailbox holds no stream messages.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/http.ex` | `run_producer/7` (`stream_while`, consumer monitor), `emit_and_wait/5`, `stream_cleanup/1`, `await_down/2` |
| `lib/influx_elixir/flight/client.ex` | `try/after` around the query |
| `lib/influx_elixir/query/sql_stream.ex`, `usage-rules/query.md`, `CHANGELOG.md` | Docs |
| `test/integration/contract_v3_core_test.exs` | Tests; helper tidy |
