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
- **The FlatBuffer tests rested on malformed fixtures and loose assertions.**
  - Two fixtures declared a vtable larger than the bytes written, so a slot past the end
    read the table's own soffset as a field offset. No test reached that slot.
  - Most assertions were orderings: a position `> 0`, a vtable before its table, one vtable
    larger than another. A vtable shared by several tables can lie after them, with a
    negative soffset, so "before its table" was also wrong as a rule.
  - One test read the vtable header back through the size it had just read, so it agreed
    with itself whatever that size was.
  - One hand-laid buffer now holds each kind of field, with every byte position in a
    comment. Every reader is asserted against the exact position or value. This includes
    a slot past the vtable, whose bytes are the soffset, so it is `nil` only because the
    size is checked. It also includes two tables that share a vtable after them.
  - Forty-one tests became six.
- **`BatchWriter`: a Point's own stamp.** The test that a Point without a time is
  stamped by the write call asserted only `year > 2000`. It now asserts that the stamp lies
  between clock reads taken before and after that call.

### Refusals and failure messages compared whole

- **Local's refusals.** The InfluxQL limits, time-aggregate and SQL qualifier tests matched
  a fragment of each refusal with `=~`. The whole message is fixed text, so each is now
  compared whole, with `===`.
  - The refusal of a statement with too many sources quotes the statement back after a
    colon, which the fragment never showed. The test now pins it.
  - The refusal of a statement over 256 KiB quotes nothing, so the statement is not read
    back.
- **`TestSupport.Check`.** Its tests matched pieces of the failure messages. Each is now
  the exact message: the counts, the headings, and every case named in sorted order.
  - `each_case/2` and `assert_rows_close/3` had no failure test, though the module says
    their failure paths are pinned. Both have one now, including a map with other keys
    and a list of another length.
  - The line `each_case/2` gives for an exception is that exception's own message.
    Elixir words it, so the expected line is built with `Exception.message/1`.

## Verification

The unit tier, coverage and every gate were run one at a time.
