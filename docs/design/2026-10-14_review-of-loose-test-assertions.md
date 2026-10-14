# Review of the loose test assertions

**Date:** 2026-10-14
**Status:** Implemented

## Context

A sweep with no open GitHub issues. It read the unit tier for assertions that check a
substring or a pattern where the value is known, and `lib` for lists indexed or appended to
inside a loop.

## Decisions

### Three assertions now compare the value

- **A misconfigured writer's start error.** Two tests in `connection_supervisor_test.exs`
  checked that the inspected error contained "invalid value for :batch_size option".
  - They now compare it whole: the supervisor's
    `{:shutdown, {:failed_to_start_child, BatchWriter, error}}`.
  - The `error` is what `BatchWriter.start_link/1` answers for the same options. It
    validates them before it starts anything.
- **The child spec.** A test checked that the inspected spec contained `host: "h"`.
  - It now matches the spec's id, type and start.
  - It also checks that the config, without its token, is the one given.
  - The `refute` that the token never prints stays. A substring is the right check for
    an absence.
- **A retried point's stamp.** `batch_writer_test.exs` matched the body against
  `cpu value=1i \d{16,}`.
  - The stamp is now parsed.
  - It is checked to lie between clock reads taken before the write and after its first
    request, in nanoseconds (the flushes' default precision).
  - This follows the existing test of a stamped point.

### Two `Enum.all?` and `Enum.any?` assertions compare the list

A second sweep the same day made two more assertions exact:
- **A database the engine accepts** (`database_rules_test.exs`).
  - The test checked that the name was among the listed ones.
  - Each name is made in a store of its own, so the list is known: that name and
    `_internal`, sorted.
- **Concurrent writers of one series** (`concurrency_test.exs`).
  - The test checked that every result was `{:ok, :written}`.
  - It now compares the whole list, so a failure shows which writer answered what.

Some loose assertions stay because nothing more exact can be known:
- The Flux wrapped start: `now` carries nanoseconds a row's time does not.
- A supervisor's generated pids.
- The scans that must find something to check.
- Core's five winners out of sixteen concurrent creates: which five win is a race.

### Checked, and right as written

- **Isolation.** Every unit module is async. The contract cases get it from their
  template, `InfluxElixir.ContractLocal`. The one exception swaps the application-wide
  `:client`, and its header says why.
- **The other `=~` uses.** They are InfluxQL and Flux regex operators inside query text,
  or refutations that a token leaked.
- **`Enum.at` and `++` in `lib`.** None runs over data that grows:
  - the Arrow view buffers of one column;
  - the one or two sizes of a SQL type;
  - the frames left open at the end of a parse;
  - single lookups by position.

### The design index is in date order again

- **The problem.** The table in `docs/design/README.md` ran oldest-first down to
  2026-10-11. Below that, the documents from 2026-09-27 to 2026-10-14 were listed
  newest-first.
- **The fix.** It is one chronological list now. Every design document still has its
  line.

## Verification

The unit tier ran 21 doctests and 2389 tests with 0 failures, three times and once with
coverage (94.29%, unchanged). Format, both compiles, credo, dialyzer and docs pass.
