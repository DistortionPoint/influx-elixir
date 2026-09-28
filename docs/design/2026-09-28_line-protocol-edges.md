# Line Protocol Edges: Encoder Refusals and InfluxDB 3's Tab Rules

**Date**: 2026-09-28
**Scope**: `Write.LineProtocol.encode/1`; `Client.Local.LineProtocolParser` (v3 dialect)
**Issue**: scheduled quality sweep (no new GitHub issues)

---

## Problem

`encode/1` promises to refuse a point that no InfluxDB accepts. I wrote
awkward points through it to `influxdb:3-core` and `influxdb:2.7`, then
checked what each server stored.

| Input | InfluxDB 3 | InfluxDB 2 | Encoder before |
|-------|------------|------------|----------------|
| field `9223372036854775808` (or below int64 min) | 400 `Unable to parse integer value` | 400 `value out of range` | encoded |
| name ending in `\` (measurement, tag key or value, field key) | 400 `... may not end with a backslash` | 400 `invalid tag format` etc. | encoded, escaped as `\\` |
| measurement `#cpu` | comment line: dropped (`incoming write was empty` alone; inside a batch it silently vanishes while `a` and `b` are stored) | the same | encoded |
| measurement `\#cpu` | stored as `\#cpu`, backslash included | the same | — |
| tab in a measurement, tag or field key | 400, message by position | stored, tab included | encoded |
| `\<tab>` in a tag value | stored with the backslash | stored with the backslash | — |
| tab inside a quoted string, `\r` in a name, `=`, `"`, a leading `_`, Unicode | stored | stored | encoded (correct) |

`Client.Local` accepted every tab case that InfluxDB 3 refuses, and it
kept a leading tab as part of the measurement name, where the engine
treats it as whitespace.

InfluxDB 3's tab rules, taken from 30 probes, are those of its
line-protocol parser. An unescaped tab ends a token as a space does, but
only a space separates sections. So the error depends on where the tab
stands:

| Tab | Message |
|-----|---------|
| ends the measurement or a tag value | `Expected at least one space character, got \`<from the tab>\`` |
| starts a tag key or value | `Expected tag key, got …` / `Expected tag value, got …` |
| in a tag key | `Tag set malformed: could not find equals sign in \`<tag set, first 10 chars>...\`` (the whole tag set when it is at most 10 chars) |
| in the first field's key, or at the start of its value | `No fields were provided` |
| in a later field's key, or at the start of its value | `Could not parse entire line. Found trailing content: …` from just after its comma for the second field, and from its comma for the third field on |
| after a complete value or in the timestamp | `… Found trailing content: \`<from the tab>\`` |

## Decision

- **Encoder.** It refuses only what neither server accepts, and anything
  both drop silently:
  - an integer outside int64 (`{:invalid_field_value, key, value}`);
  - a name ending in a backslash (the existing error for that name);
  - a measurement starting with `#` (`{:invalid_measurement, name}`).

  A tab is not refused, because InfluxDB 2 stores it and InfluxDB 3's
  refusal is a visible per-line error. The moduledoc documents it.
- **Local, v3 dialect.** A tab scanner runs before the split-based parser.
  It only sees a line that contains a tab. It walks the regions
  (measurement, tag key, tag value, field key, field value, timestamp),
  skipping escapes and quoted strings, and answers the engine's message
  for the region where the tab falls. A line that is malformed before its
  first tab is left to the parser. Leading spaces and tabs are trimmed
  before parsing. The v2 dialect is unchanged.
- **Not changed.** Local's v2 error bodies keep the v3 wording inside
  InfluxDB 2's `unable to parse '<line>': …` frame; InfluxDB 2's own texts
  (`invalid tag format`, `strconv.ParseInt …`) differ. The `…` in the
  documented shape already says the text is not modelled.

## Verification

- A comparison script sent 35 tab and whitespace cases through
  `Client.HTTP` to Core and through `Client.Local`. Every error body is
  identical, and so are the stored rows for the cases that were accepted.
- A new contract block, `write/3 — tabs in line protocol contract`, passes
  on Local and on Core. It covers eight refusal positions, a leading tab,
  an escaped tab and a tab in a string.
- New `LineProtocol` unit tests cover each new refusal, and that the int64
  bounds themselves, `#` elsewhere, and a backslash inside a name or at
  the end of a string value still encode.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/write/line_protocol.ex` | Refusals; moduledoc |
| `lib/influx_elixir/client/local/line_protocol_parser.ex` | `tab_error/2` scanner; leading whitespace |
| `test/influx_elixir/write/line_protocol_test.exs`, `test/support/client_contract.ex` | Tests |
| `usage-rules/write.md`, `docs/guides/testing-with-local-client.md`, `CHANGELOG.md` | Updated |

## Follow-up (same day): timestamps, precision and range

**Encoder precision.** `encode/1` wrote a `DateTime` timestamp in
nanoseconds whatever the write's precision. A `BatchWriter` with
`write_opts: [precision: :second]` sent `1790596800123456000` as seconds,
and InfluxDB 3 refused every point with `timestamp, …, out of range for
precision: Second`; the same happened at `:millisecond` and
`:microsecond`.

`encode/2` now takes `precision:` in the spellings `write/3` accepts. It
divides the `DateTime`'s nanoseconds by the unit with `floor_div`, so a
time before 1970 does not move forward. `:auto`, an unknown spelling, or
no option means nanoseconds. An integer timestamp is written as given,
because it is already in the caller's unit.

`BatchWriter` encodes a `Point` in the writer process again, where its
`write_opts` precision is known. It uses the non-raising `encode/2`, so
an invalid point is still the caller's `{:error, reason}`, never a crash.

**Range.** Probing the boundary of each precision on both engines:

- InfluxDB 3 accepts any timestamp whose value in nanoseconds fits in
  int64, at every precision; the next one is `timestamp, N, out of range
  for precision: Second|Millisecond|Microsecond`. A literal past int64 is
  `Unable to parse timestamp value`.
- InfluxDB 2 accepts `-9223372036854775806 .. 9223372036854775806`
  nanoseconds, so the two int64 ends are refused. Its message is
  `time outside range -9223372036854775806 - 9223372036854775806`, and a
  literal past int64 is `strconv.ParseInt: parsing "…": value out of
  range`.

`Client.Local` stored the scaled value, and a later query raised
converting it to a `DateTime`. It now applies each version's range and
wording. Twenty-eight boundary writes gave identical answers from
`Client.HTTP` against Core and 2.7 and from `Client.Local`. A
`BatchWriter` writing a `DateTime` point at each precision stored the
same, truncated, time on both clients.

**Tests.** `write/3 — timestamp range contract` runs on every profile,
with each version's message. There are encoder tests for each precision
and spelling, for truncation before 1970, and for integer timestamps,
plus a `BatchWriter` precision test. The new unit tests fail against the
previous code. `writer_test.exs` built timestamps past int64 by string
concatenation (`"17000000000000000#{i}"`) and now adds instead.
