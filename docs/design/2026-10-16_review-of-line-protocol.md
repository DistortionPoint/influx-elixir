# Review of the line-protocol write path

**Date:** 2026-10-16
**Status:** Implemented

## Context

A sweep with no open GitHub issues. A read-only review covered the double's line-protocol
scanner, parsers and write path, and the client's encoder (`LineProtocol.encode/2`). Each
claim was probed on InfluxDB 3 Core 3.10.1 and InfluxDB 2.7 before anything was changed.
The probes found one more difference that the review had not reported.

## Decisions

### The encoder: a measurement the server renames

- **The bug.** Both engines strip a leading tab from a line before they read its
  measurement, and 2.7 strips a leading NUL too. The encoder escapes neither, so
  `%Point{measurement: "\tcpu"}` was answered 204 and stored as `cpu`.
- **The engines.**
  - Core and 2.7 both store `\tcpu v=1i` as `cpu`.
  - 2.7 stores `\0cpu v=1i` as `cpu`, and Core refuses it (`Invalid measurement was
    provided`).
  - Both keep a leading `\r`, `\f` or `\v` in the name.
- **The fix.**
  - A measurement starting with a tab is `{:invalid_measurement, name}` on both API versions.
  - A measurement starting with NUL is refused for `api_version: :v2` only. Core refuses
    that line itself.
  - The `:measurement_starts` entry of the encoder's per-dialect table holds both rules,
    with `#`.

### The encoder: a `DateTime` that `auto` misreads

- **The bug.** With `precision: :auto` a `DateTime` was written in nanoseconds. Core's
  `auto` reads a number under 5e15 as seconds, milliseconds or microseconds.
- **The engine.** `1000000000` with `precision=auto` is stored as 2001-09-09T01:46:40.
  `5000000000000000` is 1970-02-27T20:53:20, as nanoseconds.
- **The fix.**
  - A `DateTime` within 5e15 ns of 1970 (58 days either side) is written in seconds when it
    is whole seconds. `auto` reads that number back as the same time.
  - Any other such `DateTime` is `{:invalid_timestamp, datetime}`.
  - Every later or earlier time is written in nanoseconds, as before.

### The double: a v2 number too large for a float

- **The bug.** `Float.parse/1` raises for digits beyond a float that have no point or
  exponent. On the v2 dialect the double called it unguarded, so `m v=` and 400 nines
  crashed the write.
- **The engine.** 2.7 answers `unable to parse '...': invalid float`.
- **The fix.** `LineProtocolNumber.parse_float/1` answers `:error` for it.

### The double: the time of an untimed line

- **The bug.** A line without a timestamp was stamped with the write's time in nanoseconds.
- **The engines.** Both cut the stamp to the write's precision:
  - `precision=second` gives whole seconds, on Core's `/api/v3/write_lp` and
    `/api/v2/write`, and on 2.7;
  - `ms` and `us` cut to those units;
  - `auto` and `ns` keep nanoseconds.
- **The fix.** `Writes.stamp_untimed/2` truncates the stamp to the precision.

### The double: InfluxDB 3's error excerpts

- **The bug.** The echoed `original_line` and the excerpt in an error message were cut by
  grapheme.
- **The engine.**
  - `original_line` is the first 20 bytes, backed off to the start of a character.
    `m,t=x` then twelve `é` echoes 19 bytes.
  - The excerpt in "Found trailing content" and "Tag set malformed" is ten code points and
    `...`. An `e` with a combining accent is two code points.
- **The fix.** `LineProtocolError.cut/1` cuts bytes on a character boundary, and
  `LineProtocolV3`'s `excerpt/1` counts code points. A v3 body is already valid UTF-8 when
  it is read.

### The double: a NUL in a measurement

- **The bug.** The double's v3 dialect read a NUL as an ordinary byte of a measurement.
- **The engine.**
  - A NUL ends a measurement: `\0x v=1i` is `Invalid measurement was provided`, and
    `x\0y v=1i` is ``Expected at least one space character, got `\0y v=1i` ``.
  - In a tag key, a tag value or a field key a NUL is an ordinary byte.
  - Escaped (`x\\\0y`), the NUL is kept with its backslash.
- **The fix.** The measurement has its own end scan, which stops at a NUL as at a tab.

### Claims that did not hold

- **A rejected line keeps its columns.** The review expected Core to register none of a
  rejected line's columns. Core keeps the ones it typed before the conflict:
  - `m a=1,b=1` after `m b="s"` is refused on `b`;
  - a later `m a="x"` is refused on `a`.

  The double already answered both writes the same way.
- **`1e-999` on InfluxDB 3.** It is accepted and stored as 0.0, as the double already did.
- **A trailing space.** `m v=1 ` is trailing content and `m v=1 5 ` is stored, as the
  double already did. The grammar in `LineProtocolV3`'s header said `[SP+ timestamp] SP*`,
  and now says `[SP+ timestamp SP*]`.
- **Dead code in the v2 dialect.** The `key == "" or value == ""` skip and the `_invalid`
  branch of `v2_integer/4` both run in the unit tier. The `text` argument of
  `v3_number_tail/4` is used by its last clause.

### Left

- **`1e999` on InfluxDB 3.** Core stores infinity, which it reads back as null. The double
  still refuses it by name, as the `local_divergence` pin records.
- **Copies of a body.** `Body.check_utf8/2` builds a copy of the body to validate it, and
  `String.valid?/1` would avoid that copy. Whether it is faster was not measured, so it is
  left.
- **The size of `writes.ex`.** Splitting it by dialect would be tidier, but it is not urgent.

## Verification

- **The engines.** Every answer above was probed on Core 3.10.1 and on 2.7.
- **The contract tables.** The new cases are in `LineProtocolCases`, and the stamp test is in
  the `LineProtocol` contract for both dialects. All of them run against the double and
  against the real servers:
  - the Core write contract: 59 tests, 0 failures;
  - the 2.7 write contract: 10 tests, 0 failures.
- **The encoder.** `line_protocol_test.exs` pins the leading tab and NUL, and the `:auto`
  bounds on both sides of 1970.
