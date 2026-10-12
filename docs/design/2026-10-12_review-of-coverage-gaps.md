# Review of coverage gaps

**Date:** 2026-10-12
**Status:** Implemented

## Context

A sweep with no open GitHub issues. Earlier sweeps reviewed every module and the test
rules, and the public API's docs and specs. This pass read the least-covered modules of
the unit tier, for behaviour no test pins and for dead code.

## Decisions

### Float constants Elixir prints with an exponent

- **The gap.** `InfluxQLLiteral` names a constant in the engine's planning error
  (`expected field argument in mean(), got Literal(Float(...))`).
  - Elixir prints `100000000000000.0` as `1.0e14` and `0.0001` as `1.0e-4`. Rust's `Debug`,
    which the engine uses, writes both out in full.
  - The code that writes the digits out had no test reaching it.
- **Verified on InfluxDB 3 Core 3.10.1.** Each of these is named as written:
  - `mean(100000000000000.0)` is `Float(100000000000000.0)`.
  - `mean(1234567890123456.5)` is `Float(1234567890123456.5)`.
  - `mean(0.0001)` is `Float(0.0001)`.
  - `mean(-0.00012)` is `Float(-0.00012)`.
  - `mean(0.00009)` is `Float(9e-5)`. The double refuses that one by name ("a float
    constant of that size"), as the planner test pins.
- **Pinned.** The four constants are cases of the contract's table of constants, which
  runs against the double and the engine. Together they reach each branch: a point past
  the digits, one inside them, and one before them.

### A remainder by zero

- The engine breaks the connection on a remainder by zero, so the double refuses it by
  name. No test reached the refusal.
- The planner test now pins it for an integer, an unsigned, a float, and a divisor that
  comes to zero only per row.

### Unused defaults and a delegate removed

- **How they were found.** Coverage counts a function head as missed when its shorter,
  defaulted form is never called. Each was checked against every call site in the library
  and the tests, so none rests on coverage alone.
- **Defaults removed.** Every caller passes the full arguments to these internal functions:
  - `Admin.create_database/3`, `Admin.create_bucket/3` and `Admin.create_token/3`;
  - `FluxQuery.query_flux/3` and `InfluxQLQuery.query_influxql/3`;
  - `InfluxQLArithType.operand/3`;
  - `InfluxQL.run/4` and `InfluxQLRun.run/4`;
  - `LineProtocolParser.parse_lines/3`. Its default `:v3` dialect could have read a v2
    write as v3 if a caller ever left the dialect out.

  The facade `Client.Local` keeps its own defaults.
- **`LineProtocolParser.line_error/3` removed.** It delegated to `LineProtocolError`, which
  the scanner calls directly. Nothing called it.
- **What the search ruled out.**
  - The other public functions of the hidden modules each have a caller.
  - Five that appear to have none are callbacks of the `InfluxQLWalk` behaviour.

### An `and` inside an `or`, pushed to storage

- **The gap.** A top-level `and` is split into conjuncts before pushdown, so the
  pushdown evaluation (`pushed?/2`, and `pinned/1`, which finds the measurements a filter
  names) meets an `and` only inside an `or`. Every such case in the contract held a
  conjunct storage cannot take, so it went to Flux instead.
- **Verified on InfluxDB 2.7**, over the contract's three points:
  - `(r.h == "a" and r._value > 1) or r.h == "b"` keeps `a` 3 and `b` 2.
  - `(r.nosuch != "a" and r.h == "a") or r.h == "zzz"` keeps both `a` rows. The missing
    key is the empty string to storage, inside the `and` as well.
- **Pinned.** Both are cases of the contract's pushdown table, which runs against the
  double and 2.7.

### Invalid UTF-8 of every lead width

- **The gap.** `Body` gives Rust's `Utf8Error::error_len` for a body that is not UTF-8,
  in Core's message `invalid utf-8 sequence of N bytes`. The contract covered only the
  leads `0xFF`, `0xE0`, `0xED` and `0xF0`.
- **Verified on Core 3.10.1:**
  - a two-byte lead with a bad second byte (`C3 78`), and an overlong lead (`C0 80`), are
    1 byte;
  - a three-byte lead with a bad third byte (`E1 80 78`, `EF 80 78`) is 2 bytes;
  - a four-byte lead with a bad fourth byte (`F1 80 80 78`) is 3 bytes;
  - `F4` followed by a byte past `0x8F` (`F4 90 80 80`) is 1 byte.
- **Pinned.** All six joined the write contract, which runs against the double and Core.

### `InfluxQL.reserved?/1` removed

Nothing called it. Its callers use `InfluxQLText.reserved?/1`, so the delegate and the
alias it needed are gone.

### Unused accessors removed

- **What was removed.**
  - `InfluxQLText.operator_glue_class/0`, with the attribute only it read.
  - `InfluxQLText.operand_open_class/0`. The attribute stays, because the module's own
    clause regex uses it.
  - `InfluxQLParens.excess_close?/1`. `InfluxQLSelectCheck` has a private function of the
    same name, which is the one called.
- **Kept, and why.** `InfluxQLText.item_end_class/0` also shows as never run, but it is
  called once, at compile time, inside a regex attribute of `InfluxQLParser`. Coverage
  does not count compile-time calls, so a removal must be checked against every use,
  not against coverage.

### Gaps that stay

- **`SQLLimits`, at 40%:** its uncovered lines are macros, which expand where they are
  used.
- **`FlightService.Service`, at 50%:** the gRPC stub is generated.
- **`HTTP.Buckets`, `HTTP.Stream` and `Flight.Client`:** their remaining lines need a
  server. The integration tier covers them.

## Verification

- The Local v3 Core contract passed, 738 tests.
- The v3 Core integration contract passed against `influxdb:3.10.1-core`, 749 tests, and the v2
  integration contract against `influxdb:2.7`, 111 tests.
- The unit tier, coverage and every gate were run one at a time. Total coverage rose
  from 94.09% to 94.17%, to 94.21% with the unused defaults removed, to 94.28% with
  the pushdown and UTF-8 cases, and to 94.29% with the unused accessors removed.
