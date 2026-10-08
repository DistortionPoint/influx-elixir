# Eighteenth Review: The Seventeenth's Own Defects

**Date**: 2026-10-08
**Scope**: what commit 32bfbb6 added. In the client modules: `Config`,
`Client.HTTP`, `Flight.Reader` and `ResponseParser`. In `Client.Local`: the
admin names, the SQL regex rewrites, the variance, and the InfluxQL lexer and
error ordering.
**Issue**: scheduled quality sweep (no open issues). This reviews 32bfbb6
([`2026-10-08_seventeenth-review-client`](2026-10-08_seventeenth-review-client.md),
[`-sql`](2026-10-08_seventeenth-review-sql.md),
[`-influxql`](2026-10-08_seventeenth-review-influxql.md)).

---

## Problem

The reviewer worked in one BEAM, one script at a time, with no test runs.
It found these defects in 32bfbb6:

- **Client:**
  - `Config.validate(host: <<0xFF>>)` raised: a Unicode regex ran before the
    UTF-8 check.
  - The host rule let through hosts the request URL reads as something else
    (`host:8086`, `x/y`, `user@h`, `[fe80::1%en0]`).
  - A non-binary database or admin name raised (`encodable_text/1` and
    `utf8_name/2` matched only binaries).
  - `Flight.Reader`'s 1,048,576-row floor applied to every column whenever the
    body was small, so a corrupt count still built 240 MB of rows.
- **Local SQL:**
  - The compensated two-pass variance matched Core less often than Welford,
    the engine's own accumulator (31 of 60 small groups against 49).
  - `~*` patterns that DataFusion rewrites to an equality, but that the
    textual check missed, answered with case folding.
- **Local InfluxQL:**
  - A connective glued to a character, and a `$param`, gave an engine-shaped
    error Core does not give.
  - Unicode blanks were trimmed (`WHERE n > 1<NBSP>` answered rows).
  - Errors and refusals were ordered by list position instead of text
    position.
  - A call error was lost behind a group failure keyed at the `WHERE`.

## Decision

- **A host is what the URL reads back as its host.** It must be a name (in
  its `xn--` form if non-ASCII), an IPv4 address or a bracketed IPv6 address.
  `URI.new("http://host:1")` must return it with port 1 and nothing else.
- **Text checks are total over terms.** A non-binary keeps the path it had
  before.
- **Flight counts are bounded by the body.** A column with data allows 8 rows
  per byte of the batch's body, with a 64-row floor. Only a batch of
  null-type columns, which has no body, keeps a fixed bound of 65,536 rows.
- **Variance is Welford.** It is the engine's accumulator: the last digits
  are not reproducible either way, and Welford matches the engine more often.
- **InfluxQL blanks are ASCII only, in one place.** `InfluxQLLex`'s trims
  replace every `String.trim*`. Errors and refusals are ordered by text
  position together, and every group failure is keyed where the parser gives
  up on it.
- **Bind parameters are read as operands, and refused by name** in a
  condition. The order of Core's bind-parameter error against other planning
  errors is not verified.

## Known differences left

- InfluxQL keywords glued to a word (`SELECT@`, `FROMm.`, `BYFROM`) are still
  the main remaining wrong class.
- `query_influxql` takes no `params:`.

## Verification

- Unit: 2,136 tests, three runs, one at a time; coverage 92.85%,
  `SQLRegexRewrite` and `InfluxQLBlanks` 100%, `InfluxQLLex` all but its
  `defguard` line; credo, dialyzer, docs and both compile environments clean.
- Integration on fresh `influxdb:3.10.1-core` (`--wal-snapshot-size 100000`)
  and 2.7, run twice: Core 677 tests, InfluxDB 2.7 90 tests; auth-enabled
  Core tokens 8 tests.
- 5,850 corrupted Flight frames (three seeds) decode under a 16 MB heap cap;
  the reviewer's 1,048,576-row count over a small body is refused.
- The `~*` rewrite rule is a small parser of the pattern: 60 shapes probed on
  Core are answered or refused as Core rewrites them; `s ~ '.*'` is answered
  (Core reads it as "not null", which `NOT (s ~ '.*')` now honours).
- Agents edited only, one at a time; every test run was mine, sequential.
