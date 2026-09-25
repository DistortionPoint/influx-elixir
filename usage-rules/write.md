# InfluxElixir Write Rules

## Batch Writer
- Batch writers are managed by the library's supervision tree — add `batch_writer: [...]` to the connection config, do not start `InfluxElixir.Write.BatchWriter` directly
- Configure `batch_size` (default 5,000) and `flush_interval_ms` (default 1,000) per connection; `database:` on the writer is the flush target
- 4xx responses are discarded and counted as errors; 5xx and transport errors are retried with exponential backoff up to `max_retries` (default 3)
- Use `InfluxElixir.flush/1` to force an immediate flush
- Use `InfluxElixir.stats/1` to retrieve batch writer statistics (`total_writes`, `total_errors`, `total_bytes`)

## Line Protocol
- Use `InfluxElixir.point/3` to build points and `InfluxElixir.Write.LineProtocol.encode/1` to encode them — do not construct line protocol strings manually
- Tags are automatically sorted lexicographically by key
- Field types are inferred: integers get the `i` suffix, floats use the shortest exact representation (`1.0e-20` is valid), strings are double-quoted, booleans are `true` / `false`
- `encode/1` refuses a point no server accepts, with a tagged error: an empty or newline-carrying measurement, tag key, tag value or field key (`{:invalid_tag_value, key, value}` etc.), the reserved tag key `time` (`{:reserved_tag_key, "time"}`), and a field value that is not an integer, float, string or boolean — a newline outside a quoted string value would otherwise split the line and store a bogus second point
- Payloads over 1KB are automatically gzip-compressed
- `precision:` on a write is spelled the engine's way: InfluxDB 3 takes `ns | n | nanosecond | us | u | microsecond | ms | millisecond | s | second | auto` (atom or string, case-sensitive; `auto` guesses from the magnitude) and InfluxDB 2 takes `ns | us | ms | s` plus the long names the HTTP client maps onto them — anything else is a 400 from the server and from `Client.Local` alike

## Direct Writes
- Use `InfluxElixir.write/2,3` for immediate single-request writes; pass `database:` in opts or set it on the connection
- Every write emits `[:influx_elixir, :write, :start | :stop | :exception]` telemetry
- Prefer the batch writer for high-throughput scenarios

## Schema
- A column's kind (tag, or integer / unsigned / float / string / boolean field) is fixed by the first write that names it, per database and measurement; a later write with another kind is rejected line by line ("invalid column type for column 'v', expected …, got …") on the server and on `Client.Local` alike — keep field types consistent in fixtures
- A rejected line does not fail the batch: the other lines are stored and the call returns `{:error, %{status: 400, body: json}}` with `"partial write of line protocol occurred"` and one `data` entry per bad line — treat a write error as "some lines were dropped", not "nothing was written"
- `time` is a reserved column ("'time' is a reserved column" on a new table, a column-type conflict with `iox::column_type::timestamp` on an existing one), a key cannot be both a tag and a field, integers must fit in 64 bits (`u` for unsigned), an empty payload is a 400
- Under `api_version: :v2` (and the `:v2` Local profile) a field type conflict is HTTP 422 with `dropped=N` and the other lines stored, while a parse error is HTTP 400 and nothing is stored; `time` as a field is dropped silently there
- A point with the same measurement, tag set and timestamp as an earlier one is the same point: fields merge and the later write wins per field, on the server and on `Client.Local` alike — rewriting a point is an update, not a second row
- A measurement, tag key, tag value or field key may not end in a backslash on InfluxDB 3 (the line is refused; `Client.Local` refuses it the same way); a backslash at the end of a string field value is fine when escaped (`s="x\\"`)
