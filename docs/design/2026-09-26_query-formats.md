# Query Formats: CSV, Parquet and Unknown Formats

**Date**: 2026-09-26
**Scope**: `Client.Local.Format`, `Query.ResponseParser` CSV cells
**Issue**: scheduled quality sweep (no open GitHub issues)

---

## Problem

`query_sql/3` and `query_influxql/3` take `format:`. The probe ran the same
queries through `Client.HTTP` against `influxdb:3-core` and through
`Client.Local`. `:json` and `:jsonl` were identical on both clients. The
other formats were not:

| `format:` | InfluxDB 3 over `Client.HTTP` | `Client.Local` |
|-----------|-------------------------------|----------------|
| `:csv` | every value a string (`"1.5"`, `"true"`); an empty cell a `nil` key | typed values; option ignored |
| `:csv`, nested value (`array_agg`, bare `selector_*`) | `200`, then the server aborts the body (`Nested type List(Float64) is not supported in CSV` in its log): `{:connection_error, %Mint.TransportError{reason: :closed}}` | rows |
| `:parquet` | a Parquet binary (`PAR1...`) | rows |
| `:xml` (any unknown) | 400 `serde json error: unknown variant `xml`, expected one of `parquet`, `csv`, `pretty`, `json`, `json_lines`, `jsonl` at line 1 column N` | rows |
| `:pretty`, `:json_lines` | the engine answers; `ResponseParser` returns `{:error, {:unsupported_format, f}}` | rows |

The results differed, so code that handles CSV could pass against the
double and fail in production.

There was a second problem in `ResponseParser`: it turned an empty CSV cell
into a `nil` key. In JSON, a null column is simply absent from the row, and
the usage rules promise that for every format. In CSV, a null and an empty
string are both an empty cell, and neither InfluxDB version distinguishes
them. v3 was verified with `s=""` and a missing `s`; v2 with a Flux `pivot`,
which leaves a field the row lacks empty.

## Decision

- **Empty cells.** `ResponseParser` leaves an empty cell out of the row.
  This covers InfluxDB 3's plain CSV and Flux annotated CSV.
- **`Client.Local.Format.answer/2`.** Both `Local.query_sql/3` (for
  queries) and `Local.query_influxql/3` wrap the query in it:
  - It checks `format` first, because the engine rejects the format while
    reading the request, before it plans the query:
    - An unknown format gets the engine's 400 body, without the
      `at line 1 column N` suffix. That position depends on how the client
      serialised the request.
    - `:parquet` is refused by name with a `Client.Local:` 400, because the
      double has no Parquet writer.
  - It then runs the query. A query error comes first.
  - It then renders the rows:
    - `:json` and `:jsonl` pass the rows through.
    - `:csv` renders each value the way the engine's CSV does:
      - integers as digits and booleans as `true`/`false`;
      - an empty string is dropped;
      - `DateTime`s are kept, as the parser returns them;
      - a nested value gives the connection error above.
    - `:pretty`, `:json_lines` and string formats give
      `{:unsupported_format, f}`. HTTP sends them and then cannot parse the
      body. `"csv"` is the exception: the engine still fails on a nested
      value first.
- **Float rendering.** The engine's CSV prints floats with a threshold that
  Erlang's `:short` does not follow. Erlang gives `1.0e15` and `1.0e-5`.
  Every pair below was read back from Core:
  - For `1e-5 <= |x| < 1e16`, the engine uses positional notation with
    `.0` when there is no fraction: `1e15` → `1000000000000000.0`,
    `1.5e-5` → `0.000015`, `100.0` → `100.0`.
  - Otherwise it uses the shortest digits with an exponent and no `.0`:
    `1e16` → `1e16`, `1e-6` → `1e-6`,
    `123456789012345678.0` → `1.2345678901234568e17`, `5e-324`.
  - `-0.0` → `-0.0`.

  `render_float/1` takes the shortest digits from `:short` and places the
  decimal point by this rule.
- **`query_sql_stream/3`** always asks the engine for JSONL, so the double
  drops `format:` before it answers, as `Client.HTTP` does.

## Verification

- The probe was re-run after the change. `Client.HTTP` against Core and
  `Client.Local` returned identical results for 30 floats and for tags,
  integers, `u64`, booleans, strings with commas and quotes, and empty
  strings. They matched for `SELECT *`, `GROUP BY`, `selector_last`, a
  missing table, InfluxQL `SELECT` and `SHOW MEASUREMENTS`, and streams, in
  `:csv`, `:json`, `:xml`, `:pretty` and `"csv"`.
- Two differences remain:
  - `:parquet` is refused by the double, by design.
  - `array_agg` is an existing limitation of the double: it refuses it by
    name, whatever the format.
- A new contract block, `query formats contract`, passes on Local and on
  InfluxDB 3 Core.
- The v2 contract suite passes. A v2 `pivot` was verified to leave empty
  cells, which now drop out of the row.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/format.ex` | New: `answer/2`, `render_float/1` |
| `lib/influx_elixir/client/local.ex` | `query_sql/3`, `query_influxql/3` through `Format.answer/2`; stream drops `format:`; moduledoc |
| `lib/influx_elixir/query/response_parser.ex` | Empty CSV cells omitted; moduledoc |
| `lib/influx_elixir/query/sql.ex` | Format docs |
| `test/influx_elixir/client/local/format_test.exs`, `test/support/client_contract.ex`, `test/influx_elixir/query/response_parser_test.exs`, `test/influx_elixir/client/local_test.exs` | Tests |
| `test/integration/contract_v3_core_test.exs` | `array_agg(host ORDER BY host)`: the unordered aggregate made the HTTP/Flight comparison flaky |
| `usage-rules/query.md`, `docs/guides/testing-with-local-client.md`, `CHANGELOG.md` | Updated |
