# InfluxElixir Write Rules

## Batch Writer
- Batch writers are managed by the library's supervision tree — add `batch_writer: [...]` to the connection config, do not start `InfluxElixir.Write.BatchWriter` directly
- Configure `batch_size` (default 5,000) and `flush_interval_ms` (default 1,000) per connection; `database:` on the writer is the flush target
- `batch_writer:` options are validated when the writer starts (positive `batch_size` and `flush_interval_ms`, known keys only): a bad one fails `add_connection/2` (or application start) with a `NimbleOptions.ValidationError` naming the option, and leaves nothing registered
- 4xx responses are discarded and counted as errors; 5xx and transport errors are retried with exponential backoff up to `max_retries` (default 3)
- Use `InfluxElixir.flush/1` to force an immediate flush
- Stopping the writer (application shutdown, `InfluxElixir.remove_connection/1`) writes the buffer and any batch still being retried, once each, within the writer's `shutdown:` (default 5,000 ms); a failure there is logged and the data dropped
- `BatchWriter.write/3` and `write_sync/3` encode a `Point` in the caller: an invalid point returns `{:error, reason}` (as from `LineProtocol.encode/1`) and the writer keeps everything else it holds
- Use `InfluxElixir.stats/1` to retrieve batch writer statistics (`total_writes`, `total_errors`, `total_bytes`)

## Line Protocol
- Use `InfluxElixir.point/3` to build points and `InfluxElixir.Write.LineProtocol.encode/1` to encode them — do not construct line protocol strings manually
- Tags are automatically sorted lexicographically by key
- Field types are inferred: integers get the `i` suffix, floats use the shortest exact representation (`1.0e-20` is valid), strings are double-quoted, booleans are `true` / `false`
- `encode/1` refuses a point no server accepts, with a tagged error: an empty or newline-carrying measurement, tag key, tag value or field key (`{:invalid_tag_value, key, value}` etc.), the reserved tag key `time` (`{:reserved_tag_key, "time"}`), a name ending in a backslash (both versions refuse it, escaped or not), a measurement starting with `#` (a comment line: both versions drop it silently inside a batch), and a field value that is not an integer, float, string or boolean or is an integer outside 64 bits — a newline outside a quoted string value would otherwise split the line and store a bogus second point
- Pass the write's precision to the encoder (`LineProtocol.encode(points, precision: :millisecond)`): a `DateTime` timestamp is written in that unit, truncated; without it, in nanoseconds, which a write with `precision: :second` refuses as out of range. An integer timestamp is taken as already in the write's unit. `BatchWriter` does this itself with its `write_opts` precision
- A timestamp must fit in a signed 64-bit count of nanoseconds once scaled (`precision: :second` allows up to 9223372036); InfluxDB 3 answers `timestamp, N, out of range for precision: Second` and InfluxDB 2 `time outside range ...`, as does `Client.Local`
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
- Every line of one write that has no timestamp gets the same one, the request's time: lines of one series in one payload are one point (fields merged, the last write wins), on both servers and `Client.Local` — give each point its own timestamp when they are separate readings
- Send `\n` line endings: InfluxDB 3 refuses a CRLF line (``Found trailing content: `\r` ``), and InfluxDB 2 refuses it after a number but stores a string field before it with its closing quote (`s="x"\r` is `x"`); `Client.Local` answers both ways, and only spaces and tabs make a line blank
- A tab outside a quoted string is refused by InfluxDB 3 with a message that depends on where it stands (`Expected at least one space character, ...`, `Tag set malformed: ...`, `No fields were provided`, `... Found trailing content: ...`) and stored by InfluxDB 2; `Client.Local` answers each as the engine does. A leading tab is whitespace, `\<tab>` keeps the backslash and the tab, and a tab inside a quoted string value is fine
- `accept_partial: false` (InfluxDB 3) makes a write all-or-nothing: the first bad line rejects the payload and nothing is stored — use it when a half-written batch is worse than none; the error body is `"line protocol parsing error"` with one line under `"data"` (not the partial-write list). `no_sync: true` acknowledges before the WAL is persisted, so a query right after may not see the points yet. Both work the same on `Client.Local`
