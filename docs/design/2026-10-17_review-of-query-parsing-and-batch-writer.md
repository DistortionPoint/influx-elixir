# Review of query parsing and the batch writer

**Date:** 2026-10-17
**Status:** Implemented

## Context

A sweep with no open GitHub issues. A read-only review covered `ResponseParser`, the query
facades, `Writer`, `BatchWriter`, the streaming path and their unit tests. Each claim about a
server was probed on InfluxDB 3 Core 3.10.1 and InfluxDB 2.7 before anything was changed.

## Decisions

### A Flux `dateTime` column under any name

- **The bug.** `cast/3` sent a `dateTime:` cell to the JSON rule, which decodes a zoned
  RFC3339 string only under `time`, `_time`, `_start` and `_stop`. Any other `dateTime`
  column stayed a string.
- **The engine.** On 2.7, `map(fn: (r) => ({r with t: r._time})) |> keep(columns: ["_value",
  "t"])` answers `#datatype,string,long,double,dateTime:RFC3339` with `t` as
  `2023-11-14T22:13:20Z`.
- **The fix.** A `dateTime:` cell is decoded with `DateTime.from_iso8601/1` whatever its
  column's name, and falls back to the raw string when it does not parse.

### InfluxDB 3 CSV keeps a value's `\r\n`

- **The bug.** `csv_row/2` turned every `\r\n` in a value into `\n` for both CSV formats.
  The rewrite exists only to undo InfluxDB 2's Go `csv.Writer`.
- **The engine.** Core's `SELECT 'a' || chr(13) || chr(10) || 'b' AS s, 'x' || chr(10) ||
  'y' AS n` with `format: csv` is `s,n\n"a\r\nb","x\ny"\n`. Each value is sent as it is.
- **The fix.** `csv_row/3` takes the function that reads a cell's text. The Flux path passes
  `restore_newlines/1`, and InfluxDB 3's passes `Function.identity/1`.

### JSONL blank lines

- **The bug.** `parse(body, :jsonl)` split on `\n` and kept a line of only `\r`, which is
  not JSON. The streaming path (`HTTP.Stream`) already skipped whitespace-only lines.
- **The fix.** The non-streaming path skips them too. The two paths now read one body alike.

### `BatchWriter`'s request order

- **The claim.** A batch's retry is queued when its timer fires. An explicit `flush/2` or
  `write_sync/3` during the delay is queued first, so an older batch can overwrite a newer
  point of the same series and time. That ordering is the design, since an explicit flush
  waits only for the request in flight (see "Backpressure").
- **The fix.** The moduledoc said requests go "in the order the batches were taken". It now
  says that a batch waiting to retry is overtaken.

### Claims that did not hold

- **A blank line inside a batch body.** A payload ending in `\n` joins as `a\n\nb`. Core and
  2.7 both answer 204 to such a body.
- **The trace-based timer tests.** `batch_writer_test.exs` traces `:erlang.send_after` and
  `:erlang.cancel_timer` on the writer under test. The 2026-10-14 review kept this as the
  only clock-free way to read the delay of a timer. Its session is the test's own and is
  destroyed with it. The jitter checks are range checks over a random value, and an exact
  value does not exist for them.

### Left

- **Two calls per `Point` write.** `BatchWriter.write/3` asks the writer for its encode
  options, then writes. Caching them outside the writer would go stale when a named
  connection is replaced. The extra call is local and short, so it is left.
- **An empty `:json` body.** It is a `json_parse_error`. A JSON body is an array or an object, so
  an empty one is not an answer this parser can read, and an error says so.
- **A non-boolean `:gzip`.** `Writer` drops it and sends the body uncompressed, rather than
  passing it on to a client that would label an uncompressed body as gzip.
- **The streaming buffer.** A 200 body with no newline is buffered whole. Bounding it would
  need a limit option. No server sends such a body.

## Verification

- **The engines.** Every answer above was probed on Core 3.10.1 and on 2.7.
- **The parser.** `response_parser_test.exs` pins each fix with the body the server sent.
  It also tightens two pattern-match assertions to `===`.
- **The contract.** The Flux contract's new `local_divergence` test runs on both sides:
  - on the double, it pins `Client.Local: unsupported Flux function: map()`;
  - on 2.7, it pins `t` as a `DateTime`.
- **The gates.**
  - the unit tier: 21 doctests and 2403 tests, 0 failures, three times;
  - the 2.7 suite: 113 tests, 0 failures;
  - the Core suite: 751 tests, 0 failures.
