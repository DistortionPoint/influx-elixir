# Client.Local: Write Speed, Line Endings and Blank Lines

**Date**: 2026-09-30
**Scope**: `Client.Local.LineProtocolParser`, `Client.Local` write path
**Issue**: scheduled quality sweep (no open issues)

---

## Problem

**Speed.** A 100k-line write to `Client.Local` took about 2.25 s. Of
that, about 1.3 s was parsing and about 1 s was schema checks and
storage. Parsing a bare `m v=1i` still cost about 5.7 µs a line. Three
costs ran on every line or point without need:

- `String.replace(line, ~r/^[ \t]+/, "")`, a regex per line, added for
  InfluxDB 3's leading-tab rule;
- `String.trim(line) == ""`, a Unicode trim of the whole line, just to
  find blank lines;
- in `check_schema/4`, `Store.table?/3` (an ETS match) per point, which
  only a `time` column needs, and two ETS calls per column per point
  (`insert_new` then `lookup`) to confirm column kinds already confirmed.

**Correctness.** Replacing the trim raised the question of which lines
are blank. Probes against both engines answered it, and found more:

| Line | InfluxDB 3 | InfluxDB 2 | Local before |
|------|------------|------------|--------------|
| only NBSP, `\v`, `\f` or `\r` | 400 `Expected at least one space character, got end of input` | 400 `missing fields` | skipped as blank |
| only spaces or tabs | skipped | skipped | skipped |
| `m v=1i 1\r` (CRLF) | 400 ``Could not parse entire line. Found trailing content: `\r` ``; the line echoed without the `\r` | 400 `bad timestamp` | 400 `Unable to parse timestamp value` |
| `m s="x"\r` | 400, trailing `\r` | **stored**, value `x"` | refused |
| `m v=1i\r 1` | 400, trailing `\r 1`; the `\r` echoed | 400 | refused, other wording |
| `m v=abc\r`, `m v=abc\t1` | 400 `No fields were provided` | 400 | v3: "trailing content" (the tab scanner assumed a valid value) |
| `\r` in a tag value or name | stored | stored | stored |

InfluxDB 2 stores a string field followed by `\r` from after its opening
quote up to the `\r`: `"x"\r` is `x"`, `"x y"\r` is `x y"`,
`"x\"y"\r` is `x"y"`, and `""\r` is `"`. A number followed by `\r` is
refused.

## Decision

**Speed:**

- Leading blanks and blank lines are matched by byte. `trim_leading_blanks/1`
  and `blank?/1` stop at the first other byte.
- `check_schema/5` threads a `known` map of `{measurement, column} =>
  kind` through each write. A kind never changes once set, so a column
  the write has already met skips ETS. A new column still registers
  atomically, in the same order, up to a conflict.
- `reserved_time/2` takes a function and asks for the table only for a
  point that names `time`, in `dry_check/4` too.

**Correctness** (only spaces and tabs are blank):

- The tab scanner becomes the terminator scanner, `terminator_error/2`.
  A `\r` ends a field value or a timestamp; elsewhere it is an ordinary
  character.
- The text before a tab or `\r` in a value is parsed. An invalid value
  fails the field, with the same rules as an empty one.
- `original_line` drops one trailing `\r`, the CRLF ending.
- In the v2 dialect, a trailing `"\r` becomes an escaped quote plus a
  closing quote, so the string parser yields the value InfluxDB 2
  stores.
- v2 error *texts* were not modelled at the time: the double kept its own
  wording inside InfluxDB 2's `unable to parse '<line>': …` frame. **They
  are now** (2026-10-01): `parse_line_parts/4` runs a port of the Go
  scanners for the `:v2` dialect and a separate grammar for InfluxDB 3,
  and the `v2_quote_cr/2` rewrite is gone, because the port reads a string
  field up to a `\r` by itself. Probes of about 330 malformed lines against
  both engines give the same message on the double.

## Verification

- **Timing.** Medians of 5 runs at 100k lines:
  - `parse_lines/3`: 1,287 → 831 ms;
  - full write: 2,253 → 1,325 ms;
  - `m v=1i`: 568 → 303 ms.
- **v3 comparison.** 25 whitespace, CR and tab cases through
  `Client.HTTP` against Core and through `Client.Local` give identical
  bodies.
- **v2 comparison.** The seven `"\r` shapes store identical values; the
  number case is refused on both.
- **Contract.**
  - "a CRLF ending, a stray carriage return, a line of other whitespace"
    passes on Local and Core.
  - "a string field before a CRLF ending is stored, closing quote and
    all" passes on Local and 2.7.
- **Dialyzer.** It caught a stale `@spec` on `check_column_types`
  (`:ok` for the new `{:ok, known}`), now fixed.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/line_protocol_parser.ex` | Byte trims, `blank?/1`, terminator scanner with `\r`, value validity, `original_line`, `v2_quote_cr/2` |
| `lib/influx_elixir/client/local.ex` | `known` column cache, lazy `time` table check |
| `test/support/client_contract.ex` | Tests |
| `usage-rules/write.md`, `docs/guides/testing-with-local-client.md`, `CHANGELOG.md` | Updated |
