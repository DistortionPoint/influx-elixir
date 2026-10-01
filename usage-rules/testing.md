# InfluxElixir Testing Rules

## LocalClient Setup
- Set `config :influx_elixir, :client, InfluxElixir.Client.Local` in `config/test.exs`
- LocalClient is NOT a mock — it stores data in ETS and responds like real InfluxDB
- Each test process gets isolated ETS tables for `async: true` safety
- Each store starts with an empty schema, so a test's first write to a measurement fixes its column types: to catch a writer that sends the wrong type (production refuses it with `invalid column type`), seed a point with production's types in `setup`, stamped where queries never look (e.g. `0`)
- There is no implicit "default" database: name one with `database:` (or `databases:`, whose first entry is the default, as over HTTP) — without one, writes and queries are `{:error, :no_database_specified}` on both clients
- Tokens are named: `create_token(conn, "ci", expiry_secs: 3600)` makes an admin token (`permissions: ["db:*:read"]` a resource token, Enterprise only — Core answers 404), `delete_token(conn, "ci")` deletes it; a taken name is the server's 409 and an unknown one its 404, from `Client.Local` too. A server started `--without-auth` refuses every token call (405); the double has no auth
- A v3 database's `retention:` is a duration string (`"30d"`, `"1h 30m"`), not seconds; the double refuses anything else as the engine does, but stores no retention, so nothing expires in tests
- `health/1` answers in the server's shape: `%{"status" => "pass"}` on InfluxDB 3 (its `/health` is a plain `OK`), InfluxDB 2's JSON (`name`, `message`, `status`, `checks`, `version`, `commit`) on v2
- Database names follow InfluxDB 3's rules (ASCII letters, digits, `_`, `-`, one `/`; starting with a letter or digit) and the `:v3_core` profile holds at most 5 databases, as Core does; a query against a missing database is the engine's 404, and `list_databases/1` includes `_internal`

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
