# Review of admin, telemetry and the test helper

**Date:** 2026-10-17
**Status:** Implemented

## Context

A sweep with no open GitHub issues. A read-only review covered these modules and their
tests:
- `Admin.*`;
- the double's admin path (`client/local/admin/`);
- `Telemetry`;
- `TestHelper`.

Every server claim was probed:
- on InfluxDB 3 Core 3.10.1, with and without auth;
- on InfluxDB 2.7.

## Decisions

### Token expiry: the end of the calendar

- **The bug.** The double added `expiry_secs` to the creation time with no bound. It
  printed the result with `DateTime.to_iso8601/1`, and accepted any non-negative integer.
- **The engine.**
  - An expiry up to `+262142-12-31T23:59:59.999Z` (chrono's last instant) is printed. A
    year past 9999 is signed: `expiry_secs` 253402300799 from `2026-10-17T17:45:46.943Z`
    is `+10056-10-16T17:45:45.943Z`.
  - One second later the expiry is `null`. So is any value up to u64's last,
    `18446744073709551615`, and so is `10^15`.
  - 2^64 is read as a float and refused: `invalid type: floating point
    1.8446744073709552e+19`.
- **The fix.**
  - `new_token/3` works in Unix milliseconds. An expiry past the last instant is `nil`.
  - `token_time/1` prints from `:calendar`, signing a year past 9999.
  - `check_expiry/2` accepts only 0..2^64 - 1.

### serde's names for a value of the wrong type

- **The bug.** The double named a value from its Elixir term:
  - a float with Elixir's printing (`1.0e20`);
  - a list or a map with `inspect/1`;
  - an atom (for `expiry_secs`) also with `inspect/1`;
  - every error at the end of the value.
- **The engine.** It reads the JSON it is sent, for `retention_period` and `expiry_secs`
  alike:
  - a list is `invalid type: sequence`, and a map is `invalid type: map`. Each is refused at
    the byte before the value starts (column 29 for `{"db":"r","retention_period":[1]}`).
    A scalar is refused at the byte before the closing brace;
  - a float is printed positionally from 1e-5 up to 1e16, with `.0` when it is whole. Past
    that it gets an exponent, `+`-signed when positive: `1e+16`, `1.5e-7`, `-0.0`;
  - an integer outside both i64 and u64 is a float, for example
    `-9.223372036854776e+18`;
  - 400 digits is `number out of range at line 1 column N`, with no `expected`.
- **The fix.**
  - Both checks read the value as `Jason` encodes and decodes it, so an atom is a string.
  - `unexpected/1` names the value. `serde_error/4` places the column.
  - `Format.render_serde_float/1` is the CSV float format with the `+`.
  - A retention that no JSON holds (a tuple) is `{:unencodable_body, message}`, as
    `Client.HTTP` answers it. An invalid UTF-8 string keeps its refusal by name.

### A v2 bucket's `retention: false`

- **The bug.** `Keyword.get(opts, :retention) || 0` read `false` as no retention, and
  created the bucket.
- **The engine.** 2.7 answers `everySeconds: false`, `true`, `"2h"`, `7200.5` and `[1]` with
  a 400 `invalid`. Only `null` is 0.
- **The fix.** `nil` alone is 0, and `false` is refused like any other value that is not an
  integer.

### Docs

- **`Admin.Databases`.** It documents its answers:
  - a create of a database that exists is `:ok`, Core's 409;
  - a delete of a missing database is a 404;
  - a delete of `_internal` is a 500.
- **`Admin.Buckets`.**
  - `delete/2` documents its 404.
  - `:org_id` says that `Client.Local` ignores it.
- **`TestHelper.setup_influx/1`.** It says that options `Client.Local.start/1` refuses raise.
- **`Admin.Tokens.create/3`.** It documents the u64 range and the two expiry rules.

### Tests

- **The contracts.**
  - The token contract's `expiry_secs` table gains floats, an integer past u64, an atom, a
    list, a map and an out-of-range integer.
  - A new test pins the `null` and signed expiries.
  - Both run in a `describe` of their own, which keeps the contract's quote block short.
  - The retention table gains the same kinds, and a tuple's `:unencodable_body`.
- **Exact assertions.** `databases_test.exs` and `buckets_test.exs` now compare with `===`:
  - the 400, 404 and 500 bodies;
  - the list after a delete, which `refute ... in` used to check.
- **`token_time_test.exs`.** It takes milliseconds, and pins a year before 1000, the signed
  year Core printed, and the calendar's last instant.

### Claims that did not hold

- **Write telemetry `bytes` for iodata.** `Writer.body/3` turns iodata into a binary before
  the span, so `bytes` is its size.
- **`next === id + 1` on a shared server.** The auth suite is `async: false` for exactly that
  reason, as its header says.
- **`:ex_unit` missing from `extra_applications`.** Both compiles pass with
  `--warnings-as-errors`.

### Left

- **The six manual telemetry emitters.** They are public, and their deprecation is
  documented. Removing them would break callers, and the gain is small.
- **The telemetry tests' clock brackets.** These tests guard the clock fix of 2026-09-10.
  - They read the monotonic clock around the emit.
  - They allow the wall clock a minute.
  - They never sleep.
  They are checks of which clock and unit, not timing assertions.
- **`token_time/1` tested directly.** A created token's time is the real clock's, so a
  whole second, or a given millisecond, cannot be reached through `create_token`.
- **`permissions: nil`.** It is `{:invalid_permission, nil}` on both clients, through one
  builder. That answer is documented.
- **`Admin.Health` and `Admin.Tokens` tests.** They cover those modules' own delegation
  (connection names included), not just the contract's client calls.

## Verification

- **The engines.** Every answer above was probed:
  - on Core 3.10.1, without auth for databases, and with auth for tokens;
  - on 2.7 for buckets.
- **The gates.**
  - the unit tier: 21 doctests and 2406 tests, 0 failures, three times;
  - the Core suite: 751 tests, 0 failures;
  - the Core auth token suite: 9 tests, 0 failures, on a fresh server;
  - the 2.7 suite: 113 tests, 0 failures.
