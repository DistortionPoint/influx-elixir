# Seventeenth Review (client): Untrusted Input, Retryable Statuses, Valid Options

**Date**: 2026-10-08
**Scope**: the consumer-facing modules outside `Client.Local`:
`Client.HTTP`, `Query.ResponseParser`, `Flight.Reader`, `Write.BatchWriter`,
`Config`, `Client.QueryParams`, `Admin.TokenRequest`, and `Client.Local`'s
admin names
**Issue**: scheduled quality sweep (no open issues). The SQL half of the same
sweep is [`2026-10-08_seventeenth-review-sql`](2026-10-08_seventeenth-review-sql.md).
No sweep since the eighth had looked at these modules.

---

## Problem

Probing each module with malformed and hostile input found:

- **Raises where a tuple is promised:**
  - `ResponseParser.parse/2` raised on a CSV body that is not CSV (a proxy's
    error page, a body cut off inside a quote), and on a JSON array or JSONL
    line holding something other than an object.
  - `Client.HTTP` raised `Jason.EncodeError` on SQL, InfluxQL or Flux text, or
    a database, bucket or token name, that is not UTF-8.
  - `Client.Local.create_token` raised on such a name.
- **Lost data:** `BatchWriter` discarded every 4xx, including 408 and 429,
  which ask the client to try later.
- **Unbounded allocation:** `Flight.Reader` trusted a record batch's row count
  and a list column's offsets. In 1,950 frames with one corruption each, 36
  allocated more than 400 MB.
- **Late failures:** `Config.validate/1` accepted a port above 65535 and an
  empty host, or one with a blank or control character. Each failed only at
  the first request.

## Decision

- **Every public function keeps its tuple contract on bad input.** JSON bodies
  are encoded with `Jason.encode/1`: text that is not UTF-8 is
  `{:error, {:unencodable_body, message}}`, and a non-object row is
  `{:error, {:unexpected_json, value}}`. A body that is not CSV is
  `{:error, {:csv_parse_error, message}}`.
- **Names that are not UTF-8 are refused by name in `Client.Local`.** No
  engine answer exists for a name JSON cannot carry. A v2 line protocol write
  is the exception: InfluxDB 2.7 stores the bytes as they are and returns
  them (verified 2026-10-08), and so does the double.
- **408 and 429 are retried like a 5xx**, with the same backoff and
  `:max_retries`. Any other 4xx is still the batch's own fault and is
  discarded.
> **Note, 2026-10-08 (eighteenth review):** the 1,048,576-row floor below still let a corrupt
> count build 240 MB of rows, and the host rule let `host:8086`, `x/y` and `[fe80::1%en0]`
> through. Both were tightened; see
> [`2026-10-08_eighteenth-review`](2026-10-08_eighteenth-review.md).

- **A count from a frame is bounded by what the frame holds.** A row count
  above `max(8 × body bytes, 1,048,576)` is a decode error, and list offsets
  are clamped to the child array. No valid frame decodes differently.
- **Options a request cannot use are validation errors:** ports outside
  1..65535, and an empty host or one with a blank or control character.

## Verification

- Each fix has a test, and each was shown to fail without its fix:
  - the 408/429 retry tests fail with the old 4xx rule;
  - the row-count test and the corrupt-frame property test fail on the old
    reader.
- The Flight tests decode in a process with a capped heap, so a regression
  fails the test rather than taking the machine's memory.
- The seeded corrupt-frame property test runs 360 corrupted fixtures. A
  separate fuzz of 3,900 corrupted frames on two seeds found no raise, hang
  or heap past 40 MB.
- 300 random points with escaped names round-trip through
  `LineProtocol.encode/2` and `Client.Local` unchanged.
- Fuzzing of the Flux and line protocol entry points found no raise or hang:
  31 Flux texts, and 37 bodies × 2 profiles × 2 precisions.
- The whole sweep (this document and the SQL and InfluxQL ones): 2,132 unit
  tests, three runs, one at a time; coverage 92.80%, every module new this
  sweep at 100% except the guard line of `InfluxQLLex` (a `defguard` is never
  counted); credo, dialyzer, docs and both compile environments clean. On
  fresh `influxdb:3.10.1-core` and 2.7: Core 677 tests and InfluxDB 2.7 90
  tests, twice; auth-enabled Core tokens 8 tests.
- Agents edited only; every test run was mine, sequential. One case found by
  the Core run pinned a subquery's hash order and now carries `ORDER BY`.
