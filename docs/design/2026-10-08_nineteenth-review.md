# Nineteenth Review: Values That Are Not Text, Fields Bounded by Kind, One Blank Rule

**Date**: 2026-10-08
**Scope**: what commit 6849740 added. In the client: `Config`, `Client.HTTP`,
`Client.Local`'s entry points, and `Flight.Reader` and `Flight.Client`. In
`Client.Local`: InfluxQL blanks and keywords, and the SQL regex rewrite check.
**Issue**: scheduled quality sweep (no open issues). This reviews 6849740
([`2026-10-08_eighteenth-review`](2026-10-08_eighteenth-review.md)).

---

## Problem

The reviewer worked in one BEAM, one script at a time, with no test runs. It
found no regressions in 6849740, but it found these defects in what that
commit had touched:

- **Raises:**
  - `Config.validate/1` raised on a list that is not a keyword list.
  - `Client.HTTP` raised on SQL or a database JSON cannot encode (a tuple, a
    pid).
  - `Client.Local` raised on a statement, body or name that is not a string:
    the previous fix only moved the raise further down.
  - `Flight.Client` crashed its caller on a bracketed IPv6 host.
- **Unbounded allocation:** `Flight.Reader` bounded a batch of null-type
  columns by rows, not cells: 200 null columns of 8192 rows went past 40 MB.
  A field with no buffers of its own inside a batch with data (a `List<Null>`
  child) could be refused as corrupt.
- **InfluxQL:**
  - `\s` in about 87 patterns read `\v` and `\f` as blanks, which the engine
    does not.
  - A keyword glued to a non-ASCII character, `AND`/`OR` where an operand is
    wanted, and text after `tz()` gave another error than the engine's.

## Decision

- **A value that is not text has no engine answer.** `Client.Local` refuses
  it by name at its entry points (the statement or body in the facade, the
  database in `Scope.resolve_database/2`, the admin names in `Admin`).
  `Client.HTTP` sends whatever JSON can encode, as it always did, and
  returns `{:error, {:unencodable_body, _}}` for the rest.
- **Each Flight field is bounded by its own kind.** A field with data allows
  8 rows per byte of body. A field with no buffers of its own (the null
  type, a struct) is bounded by the batch's cells, 524,288 in all. A field of
  an unsupported type is reported as that type before any count.
- **Flight refuses IPv6 hosts by name.** The gRPC client cannot connect to an
  IPv6 address (verified: Core answers on `[::1]` over HTTP), so
  `{:error, {:ipv6_unsupported, host}}` replaces a crash or `:no_addresses`.
- **One InfluxQL blank.** `InfluxQLLex` holds it, and the `~q` sigil makes
  `\s` in a pattern mean exactly that.

## Known differences left

- Flight over an IPv6 address: use the HTTP transport.
- InfluxQL keywords glued to a word (`SELECT@`, `FROMm.`).
- `query_influxql` takes no `params:`.

## Verification

- Unit: 2,142 tests, three runs, one at a time; coverage 92.90%;
  `SQLRegexRewrite` and `InfluxQLBlanks` 100%, `InfluxQLLex` all but its
  `defguard` line, and the compile-time `~q` code (`InfluxQLBlankRegex`) out of
  the count; credo, dialyzer, docs and both compile environments clean.
- Integration on fresh `influxdb:3.10.1-core` (`--wal-snapshot-size 100000`)
  and 2.7, run twice: Core 678 tests, InfluxDB 2.7 90 tests; auth-enabled
  Core tokens 8 tests.
- 5,850 corrupted Flight frames (three seeds) decode under a 16 MB heap cap; a
  batch of 3 null columns of 8192 rows decodes, one of 200 is refused.
- Flight over `127.0.0.1` answers and over `[::1]` is refused by name, against
  the same Core.
- Agents edited only, one at a time; every test run was mine, sequential.
