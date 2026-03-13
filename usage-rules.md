# InfluxElixir Usage Rules

## Connection Setup
- Always start a Finch pool before using InfluxElixir
- Use named connections for multi-instance support
- Configure `api_version: :v3` (default) or `:v2` for legacy instances

## Writing Data
- All write operations go through the `InfluxElixir` facade module
- Use `InfluxElixir.point/3` to construct points (measurement, tags, fields)
- Use `InfluxElixir.write/2` for direct writes, `InfluxElixir.write/3` with connection name for multi-instance
- Batch writers are managed internally by the supervision tree — configure via application config, not direct GenServer interaction
- Integer fields are suffixed with `i` in line protocol — the library handles this

## Querying Data
- All query operations go through the `InfluxElixir` facade module
- Always use parameterized queries with `$param` placeholders — never interpolate
- Use `InfluxElixir.query_sql_stream/3` for large result sets (returns lazy Stream)
- Use `InfluxElixir.query_sql/3` for bounded result sets

## Testing
- Configure `:influx_elixir, :client` to use the LocalClient in `config/test.exs` — no real InfluxDB needed
- Use `InfluxElixir.TestHelper.setup_local/1` in test setup for isolated per-test state
- LocalClient stores data in ETS and responds like a real InfluxDB server
- Run integration tests against real InfluxDB with `--include integration` tag

## Error Handling
- All operations return `{:ok, result}` or `{:error, reason}` tuples
- Write errors include `:non_retryable` (4xx) or `:retryable` (5xx) classification
