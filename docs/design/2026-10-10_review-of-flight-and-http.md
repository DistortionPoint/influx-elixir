# Review of the Flight transport and the HTTP client

**Date:** 2026-10-10
**Status:** Implemented

## Context

A sweep with no open GitHub issues. This pass covers the two transports, which the earlier
passes of the day left out:
- `Flight.Client`, `Flight.Reader`, `Flight.FlatBuffer` and `Flight.Proto`;
- `Client.HTTP` and its `Request`, `Stream` and `Buckets` modules;
- the unit tests of all of these.

Every finding was checked against the code before it was fixed or set aside. The claim about
server behaviour was checked against InfluxDB 3 Core 3.10.1.

## Decisions

### Fixed

- **A decimal with a negative scale failed over Flight.**
  - `CAST(1234 AS DECIMAL(5,-2))` is `Decimal128(5, -2)` holding 12. HTTP answers it as the
    integer `1200`. The reader divided by `10` to the power of the scale, which raised for a
    negative scale, so the whole query was `{:error, {:decode_error, _}}`.
  - A scale of 0 or below is now the integer the unscaled value times `10` to the minus
    scale. A positive scale is still a float.
- **A decimal of a width Arrow does not define read the body forever.**
  - The width comes from the schema. A width of 0 made the binary comprehension match zero
    bits again and again, growing the heap without end; a capped process is killed.
  - Arrow's decimals are 32, 64, 128 or 256 bits wide. Any other width is now refused as
    `{:unsupported_arrow_type, "Decimal<width>", column}`, as the reader refuses every type
    it does not decode.
- **A channel opened just as the connect bound ran out was left open.**
  - The connect runs in a monitored process that is killed at the bound. A result sent just
    before the kill was dropped. With grpc 1.0 that result is an open channel. Its
    connection process lives under `GRPC.Client.Supervisor`, and its socket process is
    linked to the connecting process, which had already exited normally. Nothing then
    closed the channel.
  - The drain also looked for that result once, without waiting. A result still on its way
    landed in the caller's mailbox later, a stray message in a GenServer that queries.
  - After the kill the bound now waits for the process's `:DOWN`, which comes after every
    message the process sent. A result that came too late is released: a channel is closed,
    rows are dropped.
- **A write flag that is not text raised.** `accept_partial: %{}` or `no_sync: {1}` reached
  `to_string/1` and raised `Protocol.UndefinedError`. The other values a URL carries were
  already checked. The flags are now checked with them, giving
  `{:error, {:invalid_value, key, value}}`. A v2 write sends neither flag, so it reads
  neither.
- **An answer of the wrong shape raised.**
  - `execute_sql/3` raised for a JSON array holding something that is not an object. It now
    gives `{:error, {:unexpected_json, value}}`, as `query_sql/3` does, and does the same
    for a body that is neither rows nor a summary map (`true`). It used to return that as
    `{:ok, true}`.
  - `list_databases/1` raised for rows that are not objects. They are now
    `{:error, {:unexpected_response, rows}}`, as a body that is not a list already was.
  - `list_buckets/1` raised for a `buckets` key that is not a list. It is now
    `{:error, {:unexpected_response, body}}`.
- **Smaller changes.**
  - The Flight ticket's JSON is built in one place. The checked call and
    `build_ticket_payload/2` each spelt it out.
  - A clause of the reader for a Utf8 column without its data buffer always decoded no
    values. The general clause gives the same nulls, so it is gone.

### Set aside

- **`FlatBuffer`'s readers raise on a short buffer.** They are the reader's internals.
  Every caller rescues them: a corrupt schema is `:schema_parse_failed`, a corrupt batch a
  `:decode_error`. The fixture test corrupts real frames to pin it.
- **A connect killed between grpc's start of the channel and its reply.** grpc 1.0 starts
  the channel's process under its own supervisor and then answers. A kill in that moment
  leaves the process with no one holding the channel, so no one can close it. The moment is
  local work, with no network wait. Closing it would need the channel's name before
  `connect` returns, which grpc 0.11 does not take. Not covered by a test, as it needs the
  bound to run out inside that moment.
- **The HTTP stream's grace period.** A producer that does not stop within a second of a
  cancel is killed. That second is a bound on cleanup, not a timing anything relies on.

### Tests

- **New tests.**
  - Decimals at a negative scale, at scale 0 and at a positive one, and at undefined widths.
  - The negative scale over both transports against InfluxDB 3 Core, which must give the
    same rows.
  - The write flags with values that are not text, on v3 and v2.
  - Answers of the wrong shape from `execute_sql/3`, `list_databases/1` and
    `list_buckets/1`, through the test server.
- **The reader tests.**
  - Every decode and schema test compares the whole answer with `===`. They used to check
    a key or a length of it, `row["v"] === nil` among them, which holds for a cell left out
    and one present as `nil` alike.
  - Describes named after private functions, some long gone (`decode_int_chunk`,
    `decode_float_chunk`, `safe_slice`, `apply_nulls`), now name the behaviour they pin.
  - Comments citing line numbers or arithmetic the code no longer does are gone. One test
    of a validity buffer past the body read its validity from byte 0 since validity is read
    at its own offset, so it pinned nothing its name said. It now places the buffer at the
    body's end.
  - Duplicates are merged: the buffer past the body (twice), the short-value tests, the
    absent buffer slot (twice). The merged tests add a buffer at the body's exact end and
    one with a negative offset or length.
- **`init_connection/1`** is asserted on its whole answer, not one key of it.
- **The Flight client tests.**
  - The ticket tests compare the whole JSON, and four overlapping ones are merged into one.
  - The bound tests compare exact answers, and the timeout test checks the caller's mailbox
    is empty afterwards. The late-result release is not covered, as it needs the result to
    arrive in the moment of the kill.
  - The authorization tests killed the query process once its bytes were read. Its channel
    then stayed open under `GRPC.Client.Supervisor`, which every test shares. They now stop
    the test server and let the call end, which closes its channel.

## Verification

The unit tier, coverage and every gate were run one at a time, plus the Core integration
suite and the v2 suite on fresh servers; see the commit.
