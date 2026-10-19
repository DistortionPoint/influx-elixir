# Review of Local's Flux at its edges

**Date:** 2026-10-19
**Status:** Implemented

## Context

A sweep with no open GitHub issues. A read-only review covered `Client.Local`'s Flux engine
(`client/local/flux/`) and its tests. It did not re-raise what
[`2026-10-10_review-of-local-flux`](2026-10-10_review-of-local-flux.md) and the Flux
pushdown and pipeline designs settled. Every engine claim was probed with curl on InfluxDB
2.7.

## Decisions

### A float sum past the float range is an infinity

- **The bug.** `sum()` and `mean()` added a float series with `Enum.sum/1`. Two `1.7e308`
  raised `ArithmeticError` out of `query_flux/3`.
- **The engine.**
  - 2.7 answers `+Inf` for two `1.7e308`, and `-Inf` for two `-1.7e308`.
  - It also answers `+Inf` for two `1.7e308` followed by a `-1.7e308`, so it adds in
    order and keeps the infinity.
  - `mean()` gives the same answers.
- **What the client sees.** The HTTP client reads `+Inf` from the CSV as the text
  `"+Inf"`, because `Float.parse/1` refuses it.
- **The fix.** The double adds the values in order, and answers `"+Inf"` or `"-Inf"` from
  the first overflow on. Stored values are finite, so the sum is never NaN. A contract test
  pins all three series on both engines.

### An unsigned field the filter does not reach

- **The bug.** A pushed `_value` comparison was refused when any series of the read was
  unsigned. The check ran before the filter dropped the series it excludes, so
  `r._field == "n" and r._value > 0` beside an unsigned `u` was refused.
- **The engine.** 2.7 answers the query.
- **The fix.** The check runs over the series the filter can reach. `r._field == "u" or
  r._value > 0` is still refused.

### A tag named `table` or `result`

- **The engine.** 2.7 writes such a tag as a column of its own, after `result` and
  `table`. Its CSV header is `,result,table,...,_measurement,table`.
- **The client.** It reads a row by name and keeps the later column, which is the tag.
- **The fix.** The double merged its `table` and `result` over the row. It now keeps the
  tag, which matches what a client of a real server sees.

### Times and literals Flux does not read

- **RFC3339 offsets.**
  - 2.7 refuses the offsets `+0200` and `+02` (as the "missing time offset" compile error)
    and the comma in `00:00:00,5Z`.
  - `DateTime.from_iso8601/1` took both offsets.
  - The double's range time is now `T`, an optional `.` fraction, and `Z` or `+hh:mm`.
    Anything else is refused by name.
  - The comma splits the arguments, and was already refused.
- **A float literal past the float range.**
  - 2.7 reads a literal such as `1<400 digits>.5` as an infinity, and answers
    `r._value > <it>` with no rows.
  - `Float.parse/1` raised on it inside the tokenizer.
  - The BEAM has no infinite float, so the predicate is refused by name.
- **`from(bucket:)`.**
  - The bucket was the text between the quotes, unescaped.
  - 2.7 reads `"a\\b"` as `a\b`, as the double already did in filters and yields.
  - The bucket is now read as a string literal. An escape Flux has no meaning for, or a
    quote left open, is refused.

### Not bugs

- **Table order.** The review expected storage to order series by the bytes of
  `m,tag=v#!~#field`, which would put `m!` before `m`, and `a-b=` before `a=`. 2.7 orders
  them as the double does: `m` before `m!`, `a` before `a-b`, and `x` before `x!`.
- **`limit(n: 0)`.** 2.7 answers it with no rows, as the double does.

### Refactoring

- **The tokenizer** matched each token twice (once for the text, once for the names) and
  trimmed the whole remaining predicate to see if it was blank. One named match now gives
  both, and the blank check stops at the first character that is not a space.
- **Docs and specs.** The `predicate` typedoc describes the whole tree, not one operand.
  `measurements/1`, `pinned/1` and `intersect/2` return `[binary()]`. The `Client.Local`
  moduledoc gives the RFC3339 forms, the infinity of a sum and the tag columns.

### Tests

- **New contract cases**, run against both engines:
  - the infinities of `sum()` and `mean()`;
  - the tags `table` and `result`;
  - a `_value` filter beside an unsigned field.
- **The refusals test.**
  - Every refusal is now pinned as the whole error: status 400, code `invalid` and the
    message.
  - New cases cover the RFC3339 offsets, the huge literal, the unsigned filter both ways,
    and the bucket's escapes.
- **The Flux contract.**
  - The newline-string row is compared whole.
  - Its Local branches now pin exact messages instead of regexes.
  - The nameless result's rows on 2.7 are compared with the default result's rows, not
    counted.
- **`influxql_flux_fidelity_test.exs`.**
  - The integer-seconds wrap test was removed: the LP contract pins it on both engines.
  - The `sort()`/`group()` refusal was removed: `unsupported_queries_test.exs` pins it.
  - The wrapped-duration start is now asserted as one of two exact instants.

### Left

- **Rows are built before the pushdown drops a series.** This is the cost of a test double
  over test-sized data. Building rows only for the series that survive would split
  `timed_rows/2` from `series/2`.
- **The typing rules.** `same_type?/3`, `compare/3` and `literal_type/1` each read the
  number, string and boolean types. Folding them together is a larger change than this
  sweep needed.
- **Regex limits.** A string literal of hundreds of KB in a predicate can exceed PCRE's
  limits. A query of that size is not one a test writes.

## Verification

- **The engine.** 2.7 was probed with curl: the infinities of `sum()` and `mean()`, the
  unsigned filter, the tag columns, the RFC3339 forms, the huge literal, `limit(n: 0)`,
  the table order, and the bucket escapes.
- **The suites.**
  - The 2.7 suite (`test/integration/contract_v2`): 118 tests, 0 failures.
  - The Local Flux contract: 0 failures.
  - The unit tier: 21 doctests and 2400 tests, 0 failures, three times.
- **Coverage.** 94.48% in total. Every line changed in `Flux` is covered.
