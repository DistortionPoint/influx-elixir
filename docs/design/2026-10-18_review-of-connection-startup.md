# Review of connection startup and its tests

**Date:** 2026-10-18
**Status:** Implemented

## Context

A sweep with no open GitHub issues. A read-only review covered these modules and their
tests:
- `ConnectionSupervisor`, its `Registration` and `Secret`;
- `Supervisor`, `Connection` and `Config`;
- `TestHelper`.

It did not re-raise what [`2026-10-10_review-of-connections`](2026-10-10_review-of-connections.md)
and [`2026-10-11_review-of-test-isolation`](2026-10-11_review-of-test-isolation.md) settled.
No claim here is about server behaviour, so no engine was probed.

## Decisions

### A config the client refuses is an error, not a crash

- **The bug.** Under `Client.HTTP`, `ConnectionSupervisor.init/1` called
  `Config.validate!/1`. An unknown option such as `default_database:` raised inside `init/1`.
  `add_connection/2` returned `{:error, {{%NimbleOptions.ValidationError{}, stacktrace},
  child}}`, and a crash report was logged. `Client.Local.init_connection/1` let
  `start/1`'s `ArgumentError` (a bad `:profile`, `:databases` that are not a list of
  strings) out the same way.
- **The fix.**
  - `init/1` validates with `Config.validate/1`. It fails with the error as it already
    did for an `init_connection/1` that returns `{:error, reason}`.
  - `Client.Local.init_connection/1` returns `{:error, %ArgumentError{}}`.
  - `start_link/1` returns `{:error, reason}`, and `add_connection/2` returns
    `{:error, {reason, child}}`. Nothing is started or registered.
  - Validation runs before the wait for a killed predecessor's names, so a refused
    config does not wait for them.
- **Unchanged.** A connection listed in the application's config that fails to start still
  fails the application's start. That is how a supervisor treats a child that does not
  start.

### A token of any type is hidden

- **The bug.** `Secret.redact/1` hid only a string `:token`. NimbleOptions puts the refused
  value in its error's `:value` and message. A charlist token was printed in the child spec
  and in the error.
- **The fix.**
  - `redact/1` hides a token of any type, and leaves one it has already hidden as it is.
  - A refused `:token` is `%ValidationError{key: :token, value: nil, message: "invalid value
    for :token option: expected string"}`.

### The supervisor's name is a suffix

- **The bug.** The derived names were:
  - `influx_elixir_conn_<name>` for the supervisor;
  - `influx_elixir_<name>_finch` for the pool;
  - `influx_elixir_<name>_batch_writer` for the writer;
  - `influx_elixir_<name>_registration` for the registration.

  The supervisor of `:a_finch` had the pool name of `:conn_a`, so the second of the two
  failed to start.
- **The fix.** The supervisor is `influx_elixir_<name>_supervisor`. Every derived name now
  ends with its kind, and no kind ends with another. A test starts `:conn_names_<n>` and
  `:names_<n>_finch` side by side.

### Docs

- **A killed supervisor.** The moduledoc said the writer writes its buffer when the
  supervisor is killed. The children then get the exit together, not in reverse order. The
  registration can erase the name and release the connection first, so the writer's last
  write can fail. The moduledoc now says so. Only `remove_connection/1` and application
  shutdown stop the children in order.
- **`add_connection/2`, `start_link/1` and "Failures to start"** list the refusals of each
  client.

### Tests

- **`connection_supervisor_test.exs`.**
  - Two tests asserted only `health/1` of a started connection. They are now one test that
    pins the registered connection and the supervisor's name.
  - The two Finch-pool tests became one test over `[]` and `[finch_name: nil]`.
  - The `fetch!/1` raise after removal now pins its message, and the regex on the facade's
    raise is now the exact message.
  - A test was added for `Client.Local`'s refusals.
  - A test was added for the name collision.
  - A failed start is pinned by its reason. The child next to it is OTP's internal
    `#child` record, not a child spec, so it is not pinned.
- **`connection_supervisor_client_error_test.exs`.**
  - It gains the HTTP client's unknown-option refusal.
  - It gains the charlist token: the error is pinned exactly, and the token appears in
    neither the error nor the child.
- **`config_test.exs`.**
  - Single-key and prefix assertions became whole values: the full default config, every
    option kept as given, and the exact NimbleOptions messages.
  - The type checks cover every option, `:timeout :infinity` and `token: nil` included.
  - Duplicate scheme and override tests were folded.
  - `validate!/1` is pinned to raise the error `validate/1` returns.
- **`test_helper_test.exs`.**
  - The `:profile` test goes through the facade and pins a Flux answer.
  - A refused option is pinned to raise `ArgumentError` with its message.
- **`connection_test.exs`.**
  - A duplicate `finch_name/1` test is removed.
  - An `on_exit` is registered before its `put/2`.

### Left

- **`supervisor_test.exs` pins `Supervisor.init/1`'s whole answer** (intensity, period and
  `auto_shutdown`). These are the library's supervisor flags on the pinned Elixir version,
  and the whole value is what that test is for.
- **`which_children/1` in order.** A `:rest_for_one` supervisor lists its children in
  reverse start order, which this library sets.
- **`Connection.finch_name/1` and `Request.resolve_finch/1`.** Both derive the pool name, but
  from different inputs (a registered name, and a keyword connection). Both call
  `ConnectionSupervisor.finch_name/1`, so the name is built in one place.
- **`token: nil` from an unset `System.get_env/1`.** It is a validation error, as any
  non-string is. The moduledoc says to omit the option.

## Verification

- the unit tier: 21 doctests and 2397 tests, 0 failures, three times. The 21 tests fewer
  than before are the folded `config_test.exs` cases, counted file by file.
- `mix test --cover`: 94.47% in total. No line changed here is missed. The one miss in
  `ConnectionSupervisor` is `await_release/1`'s 15 s timeout.
- `mix credo --strict`, `mix dialyzer` and `mix docs` are clean.
