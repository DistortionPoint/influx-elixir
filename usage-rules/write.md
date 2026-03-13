# InfluxElixir Write Rules

## Batch Writer
- Batch writers are managed by the library's supervision tree — configure in application config, do not start directly
- Configure `batch_size` (default 5,000) and `flush_interval_ms` (default 1,000) per connection
- Use `InfluxElixir.flush/1` to force an immediate flush
- Use `InfluxElixir.stats/1` to retrieve batch writer statistics

## Line Protocol
- Use `InfluxElixir.point/3` to build points — do not construct line protocol strings manually
- Tags are automatically sorted lexicographically by key
- Field types are inferred: integers get `i` suffix, strings are quoted, booleans are `t`/`f`
- Payloads over 1KB are automatically gzip-compressed

## Direct Writes
- Use `InfluxElixir.write/2` for immediate single-request writes
- Prefer batch writer for high-throughput scenarios
