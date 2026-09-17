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
- Payloads over 1KB are automatically gzip-compressed

## Direct Writes
- Use `InfluxElixir.write/2,3` for immediate single-request writes; pass `database:` in opts or set it on the connection
- Every write emits `[:influx_elixir, :write, :start | :stop | :exception]` telemetry
- Prefer the batch writer for high-throughput scenarios

## Schema
- A column's kind (tag, or integer / unsigned / float / string / boolean field) is fixed by the first write that names it, per database and measurement; a later write with another kind is rejected line by line ("invalid column type for column 'v', expected …, got …") on the server and on `Client.Local` alike — keep field types consistent in fixtures
- A rejected line does not fail the batch: the other lines are stored and the call returns `{:error, %{status: 400, body: json}}` with `"partial write of line protocol occurred"` and one `data` entry per bad line — treat a write error as "some lines were dropped", not "nothing was written"
- `time` is a reserved column, a key cannot be both a tag and a field, integers must fit in 64 bits (`u` for unsigned), an empty payload is a 400
