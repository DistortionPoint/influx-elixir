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

### Gaps that stay

- **`SQLLimits`, at 40%:** its uncovered lines are macros, which expand where they are
  used.
- **`FlightService.Service`, at 50%:** the gRPC stub is generated.
- **`HTTP.Buckets`, `HTTP.Stream` and `Flight.Client`:** their remaining lines need a
  server. The integration tier covers them.

## Verification

- The Local v3 Core contract passed, 738 tests.
- The v3 Core integration contract passed against `influxdb:3.10.1-core`, 749 tests.
- The unit tier, coverage and every gate were run one at a time. Total coverage rose
  from 94.09% to 94.17%.
