# Flight Reader: Every Arrow Type InfluxDB 3 Returns

**Date**: 2026-09-26
**Scope**: `Flight.Reader`, `Query.ResponseParser`, `Client.Local` selectors
**Issue**: scheduled quality sweep

---

## Problem

The reader knew Int, UInt, Float32/64, Bool, Utf8 and Timestamp. Any
other column got `type_id 0`, two buffers, and `nil` in every row — so it
disappeared from the row map. Compared with HTTP on `influxdb:3-core`:

| Query | HTTP | Flight before |
|---|---|---|
| `selector_last(v, time) AS sl` | `%{"sl" => %{"time" => …, "value" => 10.0}}` | `%{}` |
| `array_agg(host)`, `[1, 2, 3]` | lists | `%{}` |
| `time - LAG(time) OVER (...)` | `"PT60S"` | `%{}` |
| `concat(host, '-', s)` (Utf8View) | `"a-x"` | column missing |
| `CAST(time AS DATE)` | `"2023-11-14"` | `%{}` |
| `CAST(v AS DECIMAL(10,2))` | `1.5` | `%{}` |
| `CAST(host AS BYTEA)` | `"61"` | `%{}` |
| `{'a': 1, 'b': 'x'}` | map | `%{}` |
| `INTERVAL '1 day'` | `"1 days"` | `%{}` |

The reader also ignored the RecordBatch field nodes and gave every column
the batch's length, which cannot describe a nested column, and did not
read `variadicBufferCounts`, which view types need.

Over HTTP, a timestamp inside a struct stayed a string: `ResponseParser`
coerced top-level values only.

## Decision

- Schema fields carry a `kind` and their `children` (Field slot 5). The
  flat types the reader always handled keep their decoders (`:primitive`);
  the rest are decoded by kind. A dictionary-encoded field (slot 4) is
  refused.
- A batch is decoded through a cursor over its field nodes, buffers and
  variadic buffer counts, depth-first as Arrow lays them out. A message
  without nodes (the hand-built test fixtures) gives each column the
  batch's length, as before.
- Each type decodes to what HTTP returns: strings for Utf8View/LargeUtf8,
  lowercase hex for binary, `YYYY-MM-DD` for dates, the engine's duration
  text (`P0D`, `[-]PT<seconds>[.<fraction>]S`, verified on five values),
  numbers for decimals, maps for structs (null members left out, as in a
  row), lists for lists.
- Interval (its text rendering is not pinned down), Time, Map, Union,
  FixedSizeBinary, RunEndEncoded, list views and compressed bodies are
  `{:error, {:unsupported_arrow_type, type, column}}`.
- `ResponseParser.coerce_types/1` recurses into maps and lists (not into
  structs such as `DateTime`).
- `Client.Local` accepts `selector_*(field, time)` without a subscript
  and returns the engine's `%{"time" => DateTime, "value" => v}`.

## Verification

13 engine responses (frames and the HTTP rows) are recorded in
`test/fixtures/flight` and decoded by `reader_fixtures_test.exs`; 12
equal the HTTP rows and the Interval one is the named error. The v3
integration suite compares Flight with HTTP live on structs, lists,
durations, Utf8View, dates and decimals, and the contract suite checks
the selector struct on Local and the engine (108/0).

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/flight/reader.ex` | `field_kind/4`, children, nodes/variadic/compression, `decode_field/3`, `decode_kind/5`, `render_duration/1`; moduledoc |
| `lib/influx_elixir/query/response_parser.ex` | nested coercion |
| `lib/influx_elixir/client/local/sql_parser.ex`, `sql_executor.ex` | selector struct |
| `lib/influx_elixir/write/batch_writer.ex` | `:no_sync` naming note |
| `test/fixtures/flight/*.etf`, `test/influx_elixir/flight/reader_fixtures_test.exs` | New |
| `test/influx_elixir/flight/reader_test.exs`, `local_test.exs`, `response_parser_test.exs`, `client_contract.ex`, `contract_v3_core_test.exs` | Updated |
| `usage-rules/query.md`, `CHANGELOG.md` | Updated |
