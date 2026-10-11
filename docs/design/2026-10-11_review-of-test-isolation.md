# Review of test isolation and weak assertions

**Date:** 2026-10-11
**Status:** Implemented

## Context

A sweep with no open GitHub issues, and with every library module reviewed in the passes of
2026-10-10. This pass reads the unit tier against the testing rules, across the whole suite:
- every module is async and isolated;
- there are no timing assertions and no shared state;
- assertions compare exact values;
- each test tests what its name says.

## Decisions

### Isolation: nothing to change

- **One module runs synchronously.** It is `ConnectionSupervisorClientErrorTest`. It swaps
  the application-wide `:client` setting, which the connection supervisor reads by design,
  and its comment says so. Every other module is `async: true`.
- **Fixed atom names appear only in child specs that are never started.** Every started
  process, connection and registry entry has a unique name.
- **Sleeps:** the only ones are `Process.sleep(:infinity)` in processes a test kills, and
  the bounded poll in `TestSupport.Await`. Neither times an assertion.
- **Logs:** captured logs are asserted only against values unique to their test (a
  generated token), so a log line from a test running alongside cannot change an outcome.
- **"Ok or error" assertions:** two tests take either answer on purpose. Both check that the
  code never raises, over corrupt Flight frames and over generated InfluxQL statements.

### Tests fixed

- **The Flight protobuf tests could not fail on a wrong field.**
  - They encoded a message and decoded it again. That round trip holds for any field
    numbering. The test named "data_body field number is 1000" never looked at the
    number.
  - A third of the tests read struct defaults, which belong to the `protobuf` library.
  - Each message is now pinned to the bytes Arrow's `Flight.proto` gives it, both ways.
    This covers `data_body` as field 1000 (the varint tag `<<0xC2, 0x3E>>`) and the varint
    fields.
  - The service's RPCs are compared as one exact list.
  - Twenty-two tests became six, and nothing they pinned is lost.
- **`ConnectionSupervisorTest`:**
  - The registration test compares the whole registered connection. It used to match
    `{:ok, _}`.
  - The log test takes its result from `with_log/1`. It used to send the result to itself
    from inside `capture_log/1`.

## Verification

The unit tier, coverage and every gate were run one at a time.
