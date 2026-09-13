# InfluxElixir Query Rules

## Parameterized Queries
- Always use `$param` placeholders — never interpolate user input into queries
- Pass params as a map: `InfluxElixir.query_sql(conn, "SELECT * FROM m WHERE tag = $tag", params: %{tag: "value"})`
- A string param is a string on the server: `'08338636'` keeps its leading zero, and comparing a string against a numeric field is a text comparison — bind numbers as numbers

## Query Types
- `query_sql/2,3` — v3 SQL queries, returns `{:ok, rows}` or `{:error, reason}`
- `query_sql_stream/2,3` — returns a lazy `Stream` for large result sets; failures raise `InfluxElixir.StreamError` when the stream is enumerated
- `execute_sql/2,3` — non-SELECT SQL (DELETE, INSERT INTO ... SELECT)
- `query_influxql/2,3` — legacy InfluxQL queries
- `query_flux/2,3` — v2 Flux queries; rows are long format (`_field` / `_value` per field)

## Results
- Rows are maps with string keys; `time` (and Flux `_time`) is a `DateTime` with microsecond precision on every client and transport — compare with `DateTime.compare/2` or a six-digit sigil
- Default response format is JSON; `:jsonl`, `:csv` and `:parquet` (raw binary) are also supported

## Arrow Flight
- Use `transport: :flight` on `InfluxElixir.query_sql/3` for high-throughput queries (HTTP client only)
- Arrow Flight uses gRPC on its own port: set `flight_port:` on the connection (or per call); InfluxDB 3 Core serves it on 8181 with `tls: false`
- `params:` are not supported over Flight — the call returns `{:error, :params_unsupported_over_flight}`
