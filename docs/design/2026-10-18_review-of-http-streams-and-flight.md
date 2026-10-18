# Review of the HTTP client, its streams and Flight

**Date:** 2026-10-18
**Status:** Implemented

## Context

A sweep with no open GitHub issues. A read-only review covered these modules and their
tests:
- `Client.HTTP` and `client/http/` (requests, streams, v2 buckets);
- `Query.SQLStream` and `StreamError`;
- `Flight.Client`, `Flight.Reader` and `Flight.FlatBuffer`.

It did not re-raise what
[`2026-10-10_review-of-flight-and-http`](2026-10-10_review-of-flight-and-http.md) settled.
Every server claim was probed:
- on InfluxDB 3 Core 3.10.1;
- on InfluxDB 2.7.

## Decisions

### A streaming query's caller errors are `:invalid_request`

- **The bug.** `Client.HTTP.query_sql_stream/3` raised every error found before the request
  as `kind: :transport`. That covered options that are not a keyword list, a parameter or
  text JSON cannot carry, and a keyword connection with no pool name. The message read
  `streaming query transport error: {:invalid_param, ...}`. `Client.Local` did the same for
  the parameter errors it shares. `StreamError`'s docs say `:transport` is a Finch or Mint
  failure.
- **The fix.**
  - A new kind, `:invalid_request`, whose `reason` is the error `query_sql/3` returns for
    the same call.
  - Both clients raise it. `:transport` is left for failures of the transport.
  - The SQL parser contract pins the error on Local and on Core.

### Flight reads a decimal's digits once

- **The bug.** `scale_decimal/2` divided the unscaled integer by `10^scale`. That made the
  integer a float and then rounded the quotient, so a decimal could round twice. A
  Decimal256 of `12345678901234567` at scale 17 came back as `0.12345678901234568`.
- **The engine.** Core prints a decimal's digits over HTTP: `1.23456789012345664` for a
  `DECIMAL(38,17)`, and `12345678901234567.00` for scale 2. The JSON decoder rounds that
  text once, to `0.12345678901234567`.
- **The fix.** The reader writes the digits with the decimal point placed, and reads them
  with `String.to_float/1`. A test of five values at scales 17 and 2 failed on the old code.
- **Not a bug.** The review expected `ArithmeticError` above 1e308. Decimal256 holds at most
  76 digits, so no decimal is that large.

### A v2 `create_bucket` without an org

- **The bug.** With `:org` empty and no `:org_id`, the client looked up the org named `""`.
  2.7 answers `GET /api/v2/orgs?org=` with every org the token can read. The client took the
  first, `aaa-other` in the probe, and created the bucket there.
- **The engine.** `POST /api/v2/buckets` without `orgID` is a 400, `organization id must be
  provided`. A write without an org is also a 400.
- **The fix.** With no org name and no `:org_id`, no `orgID` is sent and the server's 400
  is the answer. `Admin.Buckets.create/3` documents it.

### `delete_bucket` of 16 hex digits

- **The bug.** A bucket name of 16 lowercase hex digits was taken for an ID and never looked
  up, so deleting the bucket `deadbeefdeadbeef` was a 404.
- **The fix.** The name is looked up first. 16 hex digits are an ID only when no bucket of
  the connection's org has that name. The deletion by a real ID still works: the v2 suite
  deletes one bucket by its hex name and one by its ID.

### Docs

- **Float16 in Flight's type table.** The table said Float16 and Float32 print "the
  shortest decimal that reads back as the same bits (`0.1`)". A Float16 `0.1` is held as
  0.0999755859375. The shortest decimal of that Float32 is `0.099975586`, which is what
  Core prints over HTTP (the `float16` fixture records it). The code was right, and the
  table now gives both examples.
- **`Flight.Client`.** A comment pointed to a moduledoc "Errors" section that does not
  exist. It now points to `query/3`'s doc. `build_ticket_payload/2` says it raises on text
  JSON cannot carry.
- **The `StreamError` kinds.** `InfluxElixir.query_sql_stream/3` and `SQLStream.stream/3`
  list the new kind.

### Refactoring

- **`Reader.apply_nulls/3`.** It zipped a range with the values and called `:binary.at/2`
  per cell. It is now one walk of the values and the bitmap together, with the same answer
  for a bitmap shorter than the values. A new test pins that answer.
- **The fixed-width decoder.** It took a width from a map and matched it again in twelve
  clauses. Its signedness and width now come from one `@int_layouts` table. The comment
  about a Utf8 column without data sits on the clause it describes.

### Tests

- **`stream_error_test.exs`.**
  - Every case now compares the whole struct.
  - "defaults to :transport" now checks every default, not only `kind`.
  - "is raisable and rescuable" became a check that `raise` builds the same error.
- **An early stop of an HTTP stream.** It was covered only by the integration tier. A unit
  test now takes one row from a chunked answer, and asserts that the enumerating process's
  mailbox is empty.
- **v2 buckets.** `TestServer.controlled/1` gains `request_line: true`, so a test sees
  each request's method and path. Unit tests pin:
  - the org-less create;
  - `:org_id`;
  - the three outcomes of a hex delete.

### Left

- **A first Flight message that is not a Schema.** It gives zero columns, so the batches
  after it decode as empty rows. Only a server that breaks the Flight protocol sends that,
  and the reader's tests pin these degenerate answers on purpose.
- **A `FixedSizeList` of size 0.** It would decode as `nil` rather than `[]`. Core panics on
  `arrow_cast(make_array(), 'FixedSizeList(0, Int64)')`, so no server answer carries one.
- **`shortest32/1` and `zip_columns/3`.** These are small costs: up to eight formats per
  Float32 cell, and `Map.put` per cell. Neither has been measured.
- **The stream buffer's `<>`.** The BEAM appends in place to a binary that it owns.
- **The timeouts in the Flight client tests (50 ms against a server that never answers).**
  They need a real deadline to pass, and nothing asserts a duration. Their headers document
  this.

## Verification

- **The engines.**
  - Core's HTTP decimal printing.
  - Core's panic on a zero-size `FixedSizeList`.
  - 2.7's orgs listing for `?org=`.
  - 2.7's 400s for a bucket and a write without an org.
- **The gates.**
  - the unit tier: 21 doctests and 2418 tests, 0 failures, three times;
  - the Core suite: 752 tests, 0 failures;
  - the 2.7 suite: 115 tests, 0 failures.
