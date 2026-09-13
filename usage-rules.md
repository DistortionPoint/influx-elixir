# InfluxElixir Usage Rules

## Connection Setup
- Configure connections under `config :influx_elixir, :connections`; the library is an OTP application and starts a supervisor with a Finch pool per connection — do not start Finch yourself
- `host:` is a bare hostname; `scheme:` and `port:` are separate options
- Configure `api_version: :v3` (default) or `:v2` for InfluxDB 2.x — a v2 server accepts the v3 write path with `200` but stores nothing
- HTTP connection configs are validated at startup; unknown keys (e.g. `default_database:`) are errors — the key is `database:`
- Use named connections for multi-instance support; add or remove them at runtime with `InfluxElixir.add_connection/2` and `remove_connection/1`

## Writing Data
- All write operations go through the `InfluxElixir` facade module
- Use `InfluxElixir.point/3` to construct points (measurement, tags, fields)
- Use `InfluxElixir.write/2,3` for direct writes; the first argument is a connection name or connection term
- Batch writers are managed internally by the supervision tree — configure via `batch_writer:` in the connection config, not direct GenServer interaction
- Integer fields are suffixed with `i` in line protocol — the library handles this

## Querying Data
- All query operations go through the `InfluxElixir` facade module
- Always use parameterized queries with `$param` placeholders (a map) — never interpolate
- Use `InfluxElixir.query_sql_stream/3` for large result sets (returns lazy Stream)
- Use `InfluxElixir.query_sql/3` for bounded result sets
- `time` values are `DateTime` with microsecond precision

## Testing
- Configure `:influx_elixir, :client` to use the LocalClient in `config/test.exs` — no real InfluxDB needed
- Use `InfluxElixir.TestHelper.setup_influx/1` in test setup for isolated per-test state
- LocalClient stores data in ETS and responds like a real InfluxDB server; concurrent writers are safe
- Run integration tests against real InfluxDB with `--include integration` tag

## Error Handling
- All operations return `{:ok, result}` or `{:error, reason}` tuples
- HTTP failures are `{:error, %{status: integer, body: binary}}`; transport failures are `{:error, {:connection_error, reason}}` with `:pool_timeout` when no connection could be checked out in time
- Streaming queries raise `InfluxElixir.StreamError` (with a `:kind`) when enumerated
