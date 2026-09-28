# BatchWriter Option Validation; Failed Connections Leave Nothing Behind

**Date**: 2026-09-28
**Scope**: `Write.BatchWriter.start_link/1`, `InfluxElixir.add_connection/2`
**Issue**: scheduled quality sweep (no open GitHub issues; v0.1.33 released cleanly)

---

## Problem

`BatchWriter.init/1` read every option with `Keyword.get/3` and a default.
Nothing checked the options. `Config` validates connection keys, but
`batch_writer:` is just a `:keyword_list`. Three misconfigurations were
reproduced against `Client.Local`:

- `batch_size: 0`: the backpressure bound is `10 * batch_size = 0`, so
  every `write/3` answered `{:error, :buffer_full}`, forever.
- `flush_interval: 50`, a typo for `flush_interval_ms`: ignored. The
  writer kept its 1 s default, and a test that waited 300 ms found
  nothing stored.
- `batch_size: "10"`: the writer started, then crashed on its first write
  and took its buffer with it.

The test for a validated start found a second bug. `ConnectionSupervisor.init/1`
calls `client.init_connection/1` and registers the connection under its
name before its children start. When a child such as the writer failed,
`add_connection/2` returned the error, but:

- the name still resolved (`Connection.get/1` returned `{:ok, conn}`) to
  a connection that was not running;
- `Client.Local`'s ETS store stayed allocated.

## Decision

- **A NimbleOptions schema** in `BatchWriter` covers every option:
  `connection` (required), `database`, `batch_size` and
  `flush_interval_ms` (positive), `jitter_ms`, `max_retries` and
  `base_retry_delay_ms` (non-negative), `no_sync`, `write_opts`, `client`,
  `name`, and `shutdown` (a timeout, `:infinity` or `:brutal_kill`).
- **`start_link/1` validates** before starting the process and returns
  `{:error, %NimbleOptions.ValidationError{}}`. It does not validate in
  `init/1`, where a failure would exit the linked caller. A supervisor
  therefore fails the child's start with that reason.
- **Defaults** live only in the schema. The `@default_*` attributes and
  the struct defaults were removed; `init/1` reads the validated options.
  `child_spec/1` shares `@default_shutdown` with the schema.
- **The moduledoc's options list** is `NimbleOptions.docs/1` of the
  schema, so the documented options and the accepted ones cannot drift.
- **`add_connection/2`** releases a connection that failed to start. It
  calls the client's `shutdown_connection/1` and deletes the registration.
  It does not do this for `{:already_started, _}` or `:already_present`,
  where the registration belongs to the running connection.

## Verification

- `start_link/1 option validation` covers `batch_size: 0`,
  `batch_size: "10"`, `flush_interval_ms: 0`, `max_retries: -1`,
  `shutdown: :later`, an unknown key and a missing `:connection`. Each is
  refused and names its key.
- `batch_writer: validation`: `add_connection(name, batch_writer:
  [batch_size: 0])` returns the error, the name no longer resolves, and a
  corrected config under the same name then starts. The test fails
  against the previous facade.
- The full suite passes unchanged: every existing configuration was
  valid.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/write/batch_writer.ex` | Schema, validation in `start_link/1`, generated option docs, single defaults |
| `lib/influx_elixir.ex` | `add_connection/2` releases a failed start |
| `test/influx_elixir/write/batch_writer_test.exs`, `test/influx_elixir/connection_supervisor_test.exs` | Tests |
| `usage-rules/write.md`, `CHANGELOG.md` | Updated |
