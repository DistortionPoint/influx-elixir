# InfluxElixir Query Rules

## Parameterized Queries
- Always use `$param` placeholders — never interpolate user input into queries
- Pass params as a map: `InfluxElixir.query_sql(conn, "SELECT * FROM m WHERE tag = $tag", params: %{tag: "value"})`
- A string param is a string on the server: `'08338636'` keeps its leading zero, and comparing a string against a numeric field is a text comparison — bind numbers as numbers

## Query Types
- `query_sql/2,3` — v3 SQL queries, returns `{:ok, rows}` or `{:error, reason}`
- `query_sql_stream/2,3` — returns a lazy `Stream` for large result sets; each row is the same map `query_sql/3` returns (timestamps are `DateTime`s); failures raise `InfluxElixir.StreamError` when the stream is enumerated
- `execute_sql/2,3` — non-SELECT SQL (DELETE, INSERT INTO ... SELECT)
- `query_influxql/2,3` — legacy InfluxQL queries. InfluxQL rows are not SQL rows: each carries `"iox::measurement"` and `"time"`, rows come in time order, aggregates are named `mean`, `count`, `sum`, ... (`COUNT(*)` gives `count_<field>`) with `time` at the epoch unless a lone selector returns its point, `LIMIT` applies per `GROUP BY` series, and an unknown column or measurement is `{:ok, []}` — on the server and `Client.Local` alike. `Client.Local` refuses `GROUP BY time(...)`, regular expressions and `fill()` by name
- `query_flux/2,3` — v2 Flux queries; rows are long format (`_field` / `_value` per field) with `_start`, `_stop` and a `table` per series (measurement, tags, field order). `range()` is required on the server and `Client.Local` alike. `Client.Local` applies `range`, `filter` (`and`/`or`/`not`, every comparison), `first`/`last`/`min`/`max`, `mean`/`sum`/`count`, `limit` and `yield`, and refuses any other stage (`aggregateWindow`, `pivot`, `group`, `sort`, ...) with a 400 naming it — it never skips one

## Results
- A `time` is stored to the nanosecond: `ORDER BY time` and a literal such as `'…:20.0000002Z'` compare the full value even though the returned `DateTime` stops at the microsecond
- Rows are maps with string keys; every timestamp column — `time`, Flux `_time`, a `DATE_BIN(...) AS bucket` alias, `selector_*(...)['time']`, `MAX(time)` — is a `DateTime` with microsecond precision on every client and transport; compare with `DateTime.compare/2` or a six-digit sigil
- A null column is absent from the row, not present as `nil` (`COUNT` is `0`, never null), over HTTP and `transport: :flight` alike; assert with `refute Map.has_key?(row, "col")`
- `AVG`, `SUM`, `COUNT`, `MIN`, `MAX`, `STDDEV[_SAMP|_POP]`, `VAR[_SAMP|_POP]` accept field arithmetic (`SUM(price * volume)`); `VARIANCE` does not exist in v3 SQL
- Selectors: `selector_first|last|min|max(field, time)['value' | 'time'] AS alias`; the InfluxQL `FIRST()`/`LAST()` are not v3 SQL
- `WHERE time` compares only with a quoted ISO-8601 datetime or date, or `now() +/- INTERVAL 'N unit'`; a bare integer or integer param is a planning error on the server and is rejected by `Client.Local` too — bind a `DateTime`
- `COUNT(DISTINCT col)`, `MIN(time)` / `MAX(time)` (a `DateTime`) and `WHERE col IS [NOT] NULL` work on both clients; `AVG(time)` and arithmetic on `time` do not
- `WHERE` supports `AND` / `OR` / `NOT` / parentheses (AND binds tighter), `<>`, `[NOT] BETWEEN`, `[NOT] LIKE` / `ILIKE`; a string tag against a bare number compares lexically on both clients (`rack > 3` does not match `"10"`) — quote the literal or compare numbers to numeric fields
- `CAST(col AS INTEGER | DOUBLE | VARCHAR)` and `col::TYPE` work in `WHERE`, projections, aggregates and `ORDER BY` on both clients — cast a numeric tag before comparing it numerically; a cast that cannot be performed makes InfluxDB 3 Core drop the connection, which both clients report as `{:error, {:connection_error, _}}`
- `GROUP BY` and `ORDER BY` items may be select aliases or 1-based positions (`GROUP BY bucket, host`, `ORDER BY 2 DESC`), and `GROUP BY DATE_BIN(...), host` gives a row per bucket per host, on the server and `Client.Local` alike
- `ORDER BY` accepts several terms, each with its own direction, and expressions
- `Client.Local` also runs projected arithmetic with an alias (`(bid + ask) / 2 AS mid`), non-recursive `WITH` CTEs read in order, `alias.column` qualifiers, `median()`, `CROSS JOIN` (broadcast a one-row CTE; a column on both sides is refused as ambiguous) and arithmetic on either side of a `WHERE` comparison; other joins, set operations, subqueries, `HAVING` and window functions are rejected by name — cover those against a real server
- `LIMIT n OFFSET m` pages through ordered rows on both clients (either order; `OFFSET` beyond the end is an empty result)
- A bare word is a column reference on both clients; a column no row has, named in any clause, is the engine's schema error (HTTP 500), not an empty or unsorted result — quote string literals
- Default response format is JSON; `:jsonl`, `:csv` and `:parquet` (raw binary) are also supported

## Arrow Flight
- Use `transport: :flight` on `InfluxElixir.query_sql/3` for high-throughput queries (HTTP client only)
- Arrow Flight uses gRPC on its own port: set `flight_port:` on the connection (or per call); InfluxDB 3 Core serves it on 8181 with `tls: false`
- `params:` are not supported over Flight — the call returns `{:error, :params_unsupported_over_flight}`
