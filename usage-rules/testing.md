# InfluxElixir Testing Rules

## LocalClient Setup
- Set `config :influx_elixir, :client, InfluxElixir.Client.Local` in `config/test.exs`
- LocalClient is NOT a mock — it stores data in ETS and responds like real InfluxDB
- Each test process gets isolated ETS tables for `async: true` safety

## Test Helpers
- Use `InfluxElixir.TestHelper.setup_influx/1` in test setup blocks
- This creates isolated ETS tables and cleans them up after the test

## Contract Tests
- Contract tests run the same assertions against both LocalClient and real InfluxDB
- This proves LocalClient fidelity without mocking
- Run contract tests locally with `mix test --include integration`

## No Mocking
- Never use Mox, Bypass, or any mocking library with InfluxElixir
- The LocalClient IS the test implementation — it behaves like real InfluxDB

## Two Tiers
- `InfluxElixir.Client.Local.check_sql/1` tells you before running whether a query is inside the double's SQL subset; it returns the same `Client.Local:` 400 error `query_sql/3` would — use it to `flunk/1` with a reason rather than silently excluding a test
- Queries outside the subset (CTEs, joins, window functions, `median`, ...) go in a tagged integration tier against a real InfluxDB via `InfluxElixir.Client.HTTP`; the library's own tier reads `INFLUX_V3_CORE_HOST` / `INFLUX_V3_CORE_PORT` (defaults `localhost` / `8181`) and skips when the server is unreachable
- Real servers ingest asynchronously: wait (`query_delay`) between a write and the query that reads it; `Client.Local` needs no wait
