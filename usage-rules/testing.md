# InfluxElixir Testing Rules

## LocalClient Setup
- Set `config :influx_elixir, :client, InfluxElixir.Client.Local` in `config/test.exs`
- LocalClient is NOT a mock — it stores data in ETS and responds like real InfluxDB
- Each test process gets isolated ETS tables for `async: true` safety

## Test Helpers
- Use `InfluxElixir.TestHelper.setup_local/1` in test setup blocks
- This creates isolated ETS tables and cleans them up after the test

## Contract Tests
- Contract tests run the same assertions against both LocalClient and real InfluxDB
- This proves LocalClient fidelity without mocking
- Run contract tests locally with `mix test --include integration`

## No Mocking
- Never use Mox, Bypass, or any mocking library with InfluxElixir
- The LocalClient IS the test implementation — it behaves like real InfluxDB
