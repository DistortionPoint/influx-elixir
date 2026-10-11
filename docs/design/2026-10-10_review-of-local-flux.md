# Review of Local's Flux engine

**Date:** 2026-10-10
**Status:** Implemented

## Context

A sweep with no open GitHub issues. This pass covers `Client.Local`'s Flux engine,
`Local.Flux` and `Local.FluxQuery`, and its tests. No other review today read them in full.

Every finding was checked against InfluxDB 2.7 (2.7.12) before it was fixed.

## Decisions

### Fixed

- **An integer sum did not wrap.**
  - The engine adds integers in 64 bits. Two `9223372036854775807i` and a `5i` sum to `3`,
    and two `-9223372036854775807i` to `2`. An unsigned sum wraps at 2^64: two
    `18446744073709551615u` and a `5u` sum to `3`.
  - `mean()` divides the wrapped sum, giving `1.0` for each of those.
  - This holds whether storage reads the aggregate or Flux does (after a `limit`).
  - Local returned the exact sum, a number no 64-bit column holds. It now wraps an
    integer or unsigned sum as the engine does. A float sum is unchanged.
- **String literals kept their escapes.**
  - `r.t == "a\\b"` is the tag `a\b` on the engine. Local compared it with `a\\b`, so the
    filter matched nothing.
  - A result named `"\"q\""` is `"q"`. Local trimmed the quotes from both ends and named
    it `\"q\`.
  - Literals now read the escapes Flux has: `\"`, `\\`, `\n`, `\r`, `\t` and `\$`. Any other
    escape is a positioned error on the engine, and `${` an interpolation, so both are
    refused by name.
- **Syntax the engine refuses was read.**
  - `1e5` and `1.5e2`: Flux has no exponent, so the engine reads `1` and then an undefined
    identifier `e5`. Local read 100000.0. Such a number is now refused.
  - `range(start: 2026-10-10 00:00:00Z)`: the engine needs the `T`. `DateTime.from_iso8601/1`
    takes the space. Such a time is now refused.
  - An argument a stage does not take (`range(start: -5m, foo: 1)`, `limit(n: 1, junk: 2)`,
    `yield(name: "a", x: 1)`) is a positioned error on the engine. Local ignored it. It is
    now refused by name.
  - An argument given twice was read with the last value winning. The engine answers
    with a 400 that has no position: `duplicate keyword parameter specified: "start"`.
    Local now gives the same 400 with the same text.
  - `yield(name: "a" + "b")` names the result `ab` on the engine. Local named it
    `a" + "b`. A name that is not one string literal is now refused.
- **`-0` was pushed to storage.**
  - The engine reads a negative number as a unary expression, which it does not push, and
    `-0` is one too. Compared with a string column it is Flux's type error.
  - Local judged a literal by its value. `-0` and `-0.0` are not below zero, so Local
    pushed them, and storage matched nothing.
  - The tokenizer now marks a negative literal, and a comparison against one stays in Flux.

### Tests

- **New contract tests in the `:pipeline` part, which runs against Local and 2.7:**
  - integer, unsigned and negative sums and means wrapping, as read by storage and by
    Flux;
  - escapes in a filter (`r.t`, `r["t"]`) and in a result's name;
  - an argument given twice, to `range` and to `limit`.
- **The type-error contract** now includes `r.h != -0`.
- **The refusal unit tests:**
  - New cases cover each refused syntax, a name made by an expression, and `-0` against a
    string field (with `-0.0` read in Flux against an integer one).
  - The unsigned test compares the exact values. It used to match maps holding them
    partially.
  - Two tests repeated cases the contract already runs against Local: two results of one
    name, and a range after another stage. They are gone.

## Verification

The unit tier, coverage and every gate were run one at a time. The v2 integration suite
passed 111 tests against InfluxDB 2.7.
