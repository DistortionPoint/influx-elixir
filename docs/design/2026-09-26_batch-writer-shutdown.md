# BatchWriter: Shutdown, Invalid Points, Concurrent Retry Chains

**Date**: 2026-09-26
**Scope**: `InfluxElixir.Write.BatchWriter`
**Issue**: scheduled quality sweep (no open GitHub issues)

---

## Problem

A review of `BatchWriter` found three defects. Each was confirmed with a
script before it was fixed.

1. **Shutdown lost the buffer.** `terminate/2` flushed the buffer, but the
   writer did not trap exits. A supervisor stops a child with an exit
   signal (`:shutdown`), and a process that does not trap exits dies from
   that signal without running `terminate/2`. So application shutdown and
   `InfluxElixir.remove_connection/1` both dropped every buffered line.
   The script started a writer under a `Supervisor`, wrote one line and
   stopped the supervisor; the measurement did not exist afterwards. The
   test for `terminate/2` used `GenServer.stop/1`, which runs
   `terminate/2` whether or not exits are trapped, so it passed anyway.
2. **An invalid point crashed the writer.** `write/3` passed a `Point` into
   the GenServer, which encoded it with `LineProtocol.encode!/1`. A point
   with no fields raised inside the writer, and the crash took every other
   caller's buffered lines with it. The caller got an exit.
3. **One marker, several chains.** A failed flush starts a retry chain.
   The writer recorded it in a single `retry_payload` field, which
   deferred timer flushes, batch-size flushes and backpressure. An
   explicit `flush/2` or `write_sync/3` flushes at once, so while one chain
   is in flight it can start another. The second chain overwrote the
   field, and the first chain to end reset it to `nil`. That lifted the
   deferral while the other chain was still retrying. `terminate/2` also
   ignored in-flight chains: their batches, and any `write_sync/3` callers
   waiting on them, were dropped.

## Decision

- `init/1` sets `trap_exit`. The parent's `EXIT` ends the writer through
  `terminate/2`, which OTP handles. A catch-all `handle_info/2` logs and
  ignores any other message. With exits trapped, a stray message or `EXIT`
  would otherwise crash the writer and lose its buffer.
- `terminate/2` makes one attempt for each in-flight chain's batch, in the
  order the chains began, and then one for the buffer. It answers each
  waiting `write_sync/3` caller with the result, and a failure is logged.
  It does not retry, because retries cannot outlive the process.
- `child_spec/1` reads `:shutdown`, which defaults to OTP's worker default
  of `5_000`. That gives consumers a way to allow a slower final write.
  `ConnectionSupervisor` passes the connection's `batch_writer:` options
  through, so `batch_writer: [shutdown: 30_000]` works. Children stop in
  reverse start order, so the writer finishes before its Finch pool stops.
- `write/3` and `write_sync/3` encode in the caller with
  `LineProtocol.encode/1`. An invalid point returns `{:error, reason}`,
  the same tagged error `encode/1` gives, and the writer is untouched. The
  `@spec`s now include `{:error, term()}`.
- In-flight chains are tracked in `chains`, a map from a monotonic chain
  id to `{payload, write_sync_from}`. The retry message carries only the
  id. Deferral and backpressure hold while the map is not empty. Replacing
  `retry_payload` and `retry_attempt` with this map also removes
  `retry_attempt`, which was written but never read.

## Verification

The probe script was re-run after the change:
- the supervisor shutdown now stores the line;
- the invalid point returns `{:error, :empty_fields}`;
- the writer stays alive.

Five new tests fail against the previous `batch_writer.ex` and pass with
the change:
- supervisor shutdown flushes;
- `:shutdown` in the child spec;
- an invalid point is the caller's error and the buffer survives;
- backpressure holds after the first of two chains ends;
- a `write_sync/3` caller waiting on a chain is answered at shutdown.

Two tests that only exercised OTP were removed: "starts the GenServer and
returns a pid" and "can be stopped cleanly". The `GenServer.stop/1`
shutdown test was replaced by the supervisor-shutdown test.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/write/batch_writer.ex` | `trap_exit`, `terminate/2`, `child_spec/1`, caller-side encoding, `chains` |
| `lib/influx_elixir.ex`, `lib/influx_elixir/connection_supervisor.ex` | Docs |
| `test/influx_elixir/write/batch_writer_test.exs` | Tests |
| `usage-rules/write.md`, `CHANGELOG.md` | Updated |
