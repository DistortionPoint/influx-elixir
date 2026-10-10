# Review of connections, the facade's batch calls and the write helpers

**Date:** 2026-10-10
**Status:** Implemented

## Context

A sweep with no open GitHub issues. This pass covers the code that the earlier passes of the
day left out:
- the facade (`InfluxElixir`);
- `Application`, `Supervisor`, `ConnectionSupervisor` and its `Registration`, `Connection`
  and `Config`;
- `Write.LineProtocol`, `Write.Point` and `Write.Writer`;
- `Telemetry`, `TestHelper`, `Client.Options` and `Client.QueryParams`;
- the unit tests of all of these.

Every finding was checked against the code before it was fixed or set aside.

## Decisions

### Fixed

- **`finch_name: nil` started no pool.** The supervisor skipped its Finch child when the
  config had the key at all, but the HTTP client reads `nil` as unset and uses the pool named
  after the connection. Every request then failed with no pool. A `nil`, as an unset
  `Application.get_env/2` gives, now starts the connection's own pool.
- **The registration is the connection supervisor's alone.**
  - `add_connection/2` erased the name after any failed start, and `remove_connection/1`
    after a removal. Both did so after the supervisor had already released it, so the erase
    could only remove a connection that another call had started under the same name in the
    meantime. It also raised a `FunctionClauseError` for a name that is not an atom. Both
    erases are gone.
  - `Registration`, the supervisor's first child, now registers the connection when it
    starts and keeps the client and the connection it registered. Its release shuts down that
    connection with that client. It used to read both back from the registry and the
    application environment, so a name erased in the meantime released nothing, and a
    changed `:client` was handed a connection it did not make.
  - A child that fails to start stops the registration, which releases what it registered.
    The client's own refusal registers nothing.
  - The connection travels to `Registration` in a closure, so a child spec or a process
    state printed in a log never shows an HTTP connection's token.
- **`flush/2`, `stats/2` and `write_batched/3` exited the caller.** This happened when the
  writer stopped while the call was still in its mailbox, for example under
  `remove_connection/1`. The writer answers the calls it has taken before it stops, but not
  those it never took. An exit for a writer that is gone or stopped as a supervisor stops it
  is now `{:error, :no_batch_writer}`, as for a writer stopped before the call. A timeout
  still exits, as documented, and so does a writer that crashed.
- **Two query parameters with one name.** `normalize/1` kept one of them, chosen by the
  order of the entries: the last of a keyword list, and the string key of a map, since atoms
  sort first. It is now `{:invalid_param, name, :duplicate_key}`. The contract tests pin it
  for both clients.
- **Smaller fixes.**
  - Each write and each batch counted its lines by building a list of every newline. The
    count is now one scan, shared by `Writer` and `BatchWriter`.
  - `QueryParams` reads a number's digits by matching on the binary, not through a list of
    its bytes.
  - The `LineProtocol` docs said a v2 measurement escapes `=` and `"`. It escapes spaces and
    commas only, which the code does and the dialect tests pin.

### Set aside

- **An unregistered name through the facade raises.** The facade resolves names with
  `Connection.fetch!/1`, which its moduledoc names. `nil`, `true` and `false` are
  unregistered names like any other. `Writer.write/3`, called directly, returns
  `{:invalid_connection, name}` instead, as its own docs say.
- **The top supervisor's restart intensity.** It is OTP's default and applies to each
  connection supervisor that gives up. Reaching it needs a connection's children to crash
  more than three times in five seconds, four times over. `BatchWriter` sends its requests
  from monitored processes, so a failing server does not crash it.
- **`Connection.finch_name/1` is not called by the library.** It is public API for
  consumers that want the pool's name, and it reads `:finch_name` the way the HTTP client
  does.
- **The telemetry tests' clocks.** They bracket readings of the monotonic clock without
  sleeping. A span's duration can never be less than the time measured inside it, so they
  cannot fail on a slow machine.

### Tests

- **New tests.**
  - `finch_name: nil`.
  - A name that is not an atom.
  - A release after the name was erased, and after the configured client changed. These two
    are in the one module that swaps the application-wide client, which runs alone.
  - A writer that stops with a `flush` or `stats` call in its mailbox.
  - The line count of an empty body.
  - Duplicate parameter names, in the unit tests and in the SQL contract.
- **No more private helpers.** The supervisor tests reach the pool and writer through their
  registered names, not the `@doc false` helpers that build those names.
- **Exact values where weak assertions stood**, in the facade, encoder, dialect, writer,
  supervisor, `TestHelper` and telemetry tests.
- **Misplaced tests.** `Point.new/3` and `Connection.api_version/1` tests moved out of the
  dialect tests, and duplicate tests were merged.

Not covered by a test: two `add_connection/2` calls for one name interleaving with a failed
start. It needs one call to finish in the moment between the other's failure and its reply.
The erase that made it possible is gone.

## Verification

The unit tier, coverage and every gate were run one at a time, plus the Core integration
suite and the v2 suite on fresh servers; see the commit.
