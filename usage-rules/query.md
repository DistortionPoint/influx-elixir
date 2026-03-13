# InfluxElixir Query Rules

## Parameterized Queries
- Always use `$param` placeholders — never interpolate user input into queries
- Pass params as keyword list: `InfluxElixir.query_sql(conn, "SELECT * FROM m WHERE tag = $tag", params: [tag: "value"])`

## Query Types
- `query_sql/2,3` — v3 SQL queries, returns `{:ok, rows}` or `{:error, reason}`
- `query_sql_stream/2,3` — returns a lazy `Stream` for large result sets
- `execute_sql/2,3` — non-SELECT SQL (DELETE, INSERT INTO ... SELECT)
- `query_influxql/2,3` — legacy InfluxQL queries
- `query_flux/2` — v2 Flux queries (backwards compatibility)

## Response Formats
- Default response format is JSON
- Supported formats: `:json`, `:jsonl`, `:csv`, `:parquet`
- Use `:parquet` for S3/Athena pipeline integration

## Arrow Flight
- Use `transport: :flight` option for high-throughput queries
- Arrow Flight uses gRPC — requires separate port configuration
