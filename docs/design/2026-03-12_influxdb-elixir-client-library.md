# InfluxDB v3 Elixir Client Library — Design & Findings Document

**Date**: 2026-03-12
**Status**: Draft
**Version**: 1.0
**Purpose**: Planning document for a new open-source Elixir client library targeting InfluxDB v3. Captures the current state analysis, v3 research, and architectural decisions to guide a standalone library build.

---

## Library Naming Options

`influx_ex` is taken on Hex.pm (v0.3.1, stale v2 library). All of the following are **available** as of 2026-03-12:

| # | Package Name | Module Name | Notes |
|---|-------------|-------------|-------|
| 1 | `influxdb3` | `InfluxDB3` | Clear, version-targeted. Matches official client naming (e.g., `influxdb3-python`). |
| 2 | `influx3_ex` | `Influx3Ex` | Elixir convention (`_ex` suffix) + version. |
| 3 | `influxdb_client` | `InfluxDB.Client` | Generic, professional. Could feel like an official client. |
| 4 | `influx_client` | `InfluxClient` | Shorter variant. Clean. |
| 5 | `influx_wire` | `InfluxWire` | Evokes "wire protocol" — line protocol + HTTP. Distinctive. |
| 6 | `influx_connect` | `InfluxConnect` | Action-oriented. |
| 7 | `influx_stream` | `InfluxStream` | Evokes streaming writes/queries. Could confuse with Instream. |
| 8 | `influxdb3_client` | `InfluxDB3.Client` | Most explicit — version + purpose. Slightly verbose. |
| 9 | `influx_core` | `InfluxCore` | Matches InfluxDB v3 "Core" edition naming. |
| 10 | `time_flux` | `TimeFlux` | Creative, brandable. Less discoverable for search. |

**Recommendation**: `influxdb3` — matches official SDK naming convention (`influxdb3-python`, `influxdb3-go`, `influxdb3-java`, etc.), immediately communicates v3 targeting, clean and short.

---

## Why This Library Needs to Exist

### No Elixir Client for InfluxDB v3

There are **5 official InfluxDB v3 client libraries** (Python, Go, Java, JavaScript, C#). None for Elixir. The only Elixir library in the ecosystem is **Instream**, which targets v2 and has critical issues.

### Instream Is Not Viable

| Problem | Detail |
|---------|--------|
| **Stale** | Last release April 2024. 11 open issues with no activity. |
| **hackney dependency** | Old Erlang HTTP/1.1 client. Known connection leak issues. No HTTP/2. |
| **poolboy dependency** | Connection pooling library unmaintained since 2015. |
| **No gzip writes** | Losing up to 5x write throughput. Open issue #55, unfixed. |
| **No parameterized queries** | Flux injection risk. Open issue #82, unfixed. |
| **No management APIs** | No bucket/task/notification support. Users bypass Instream with raw HTTP. |
| **Flux-only queries** | Flux is deprecated and removed in v3. Instream cannot query v3 at all. |
| **No v3 support** | Open issue #83 requesting v3 support. No response from maintainer. |

### InfluxDB v3 Is GA and the Future

- **InfluxDB 3 Core** (open source, MIT/Apache 2.0): GA since April 2025.
- Docker `latest` tag switches to v3 Core on April 7, 2026.
- v3 is a ground-up Rust rewrite with fundamentally different architecture.
- Flux is gone. SQL and InfluxQL are the query languages.
- The Elixir ecosystem has zero support for this.

---

## InfluxDB v3 Architecture Overview

### Storage Engine: FDAP Stack (Rust)

```
Write Path:                          Query Path:
Line Protocol → Router/Ingester      SQL/InfluxQL → Querier
                    ↓                                ↓
                   WAL              DataFusion (SQL engine on Arrow)
                    ↓                                ↓
               Object Store         Parquet files + live Ingester data
              (Parquet files)
```

- **F**light — Apache Arrow Flight gRPC transport for query results
- **D**ataFusion — SQL query engine (Rust)
- **A**rrow — In-memory columnar data format
- **P**arquet — On-disk columnar storage (replaces TSM)

### Key v3 Changes from v2

| Aspect | v2 | v3 |
|--------|----|----|
| Storage engine | TSM (Go) | Parquet/Arrow (Rust) |
| Query language | Flux (primary), InfluxQL | **SQL** (primary), InfluxQL. Flux is gone. |
| Write protocol | Line protocol | Line protocol (unchanged) |
| Write API | `/api/v2/write` | `/api/v3/write_lp` (new) + v2 compat |
| Query API | `/api/v2/query` (Flux) | `/api/v3/query_sql`, `/api/v3/query_influxql` (new) |
| Query transport | HTTP (CSV response) | HTTP (JSON/JSONL/CSV/Parquet) + Arrow Flight gRPC |
| Organization concept | Required | Gone (Core/Enterprise) |
| Buckets | Buckets | Renamed to "databases" |
| Tasks (scheduled) | Flux tasks | Processing Engine (Python plugins, server-side) |
| Checks/notifications | Built-in | Gone (use external tools) |
| Built-in UI | Yes | Gone (use Grafana etc.) |
| High cardinality | Performance cliff | No cardinality limit (Parquet handles it) |
| Compression | Optional | Parquet columnar compression by default |
| Limits | — | Core: 5 DBs, 2K tables, 500 cols/table. Enterprise: 100 DBs, 10K tables, configurable. |

### What Stays the Same

- **Line protocol write format**: Identical wire format. Same `measurement,tag=val field=val timestamp` syntax.
- **Bearer token authentication**: Same header format.
- **v2 write compatibility endpoint**: `/api/v2/write?bucket=DB` still works.
- **InfluxQL**: Supported natively in v3.

---

## v3 API Reference

### Write API

**v3 endpoint (recommended):**
```http
POST /api/v3/write_lp?db=DATABASE&precision=auto
Authorization: Bearer TOKEN
Content-Type: text/plain
Content-Encoding: gzip

measurement,tag1=val1,tag2=val2 field1=1.0,field2="str",field3=42i 1630424257000000000
```

Parameters:
- `db` (required): database name
- `precision`: `auto` (default), `nanosecond`, `microsecond`, `millisecond`, `second`
- `accept_partial` (boolean, default true): accept partial writes on schema conflicts
- `no_sync` (boolean, default false): respond before WAL persistence (fire-and-forget mode)

Response: 204 on success, 400 with JSON error body on failure.

**v2 compatibility endpoint:**
```http
POST /api/v2/write?bucket=DATABASE&precision=ns
```

**v1 compatibility endpoint:**
```http
POST /write?db=DATABASE&precision=ns
```

All three accept identical line protocol.

### Query APIs

**SQL query:**
```http
POST /api/v3/query_sql?db=DATABASE&format=jsonl
Authorization: Bearer TOKEN
Content-Type: application/json

{
  "q": "SELECT * FROM prices WHERE symbol = $symbol AND time > now() - interval '1 hour'",
  "params": {"symbol": "BTC-USD"}
}
```

**InfluxQL query:**
```http
POST /api/v3/query_influxql?db=DATABASE&format=jsonl
Authorization: Bearer TOKEN
Content-Type: application/json

{
  "q": "SELECT mean(price) FROM prices WHERE symbol = $symbol AND time > now() - 1h GROUP BY time(5m)",
  "params": {"symbol": "BTC-USD"}
}
```

Response formats: `json`, `jsonl` (streaming, preferred for large results), `csv`, `pretty`, `parquet`

**Arrow Flight gRPC** (high-performance alternative):
- `DoGet()` RPC with SQL or InfluxQL
- Returns streaming Arrow record batches
- Requires HTTP/2 and Arrow IPC decoding

### Database Management

```http
POST   /api/v3/configure/database              -- create (body: {"db": "name", "retention_period": "30d"})
GET    /api/v3/configure/database              -- list
DELETE /api/v3/configure/database?db=name      -- delete
```

### Token Management

```http
POST   /api/v3/configure/token/admin              -- create named admin token
POST   /api/v3/configure/token/admin/regenerate   -- regenerate operator token
DELETE /api/v3/configure/token                     -- delete token
```

Query tokens via SQL: `SELECT * FROM system.tokens`

### Health

```http
GET /health     -- returns JSON {"status": "pass"}
GET /api/v2/ping -- returns 204 (v2 compat)
```

---

## Current Codebase Analysis (What Needs Replacing)

### Modules That Touch InfluxDB

| Module | Lines | What It Does | Library Used |
|--------|-------|-------------|--------------|
| `InfluxConnection` | 9 | `use Instream.Connection` — that's it | Instream |
| `Writer` | 892 | Batching GenServer, point building, retries, error handling | Instream (write only) |
| `Query` | 668 | Raw Flux string building, response parsing | Instream (query only) |
| `BucketManager` | 325 | Bucket CRUD, health checks | **HTTPoison** (bypasses Instream) |
| `Setup` | 310 | Bucket creation, retention policies, downsampling TODOs | HTTPoison via BucketManager |
| `Series` | 146 | Instream measurement schema definitions | Instream |
| `Config` | ~100 | InfluxDB URLs, auth headers, bucket names | None (pure config) |
| `InfluxDBAdapter` | 250 | StorageAdapter behaviour implementation | Delegates to Writer/Query |
| `MetricsStorage` | 612 | Metrics-specific write/query wrappers | Delegates to Writer/Query |
| `TimeSeries` | 690 | Public context API, delegates to storage modules | Delegates |

**Total**: ~4,000 lines touching InfluxDB, but most is application-specific. The library boundary is roughly Writer + Query + BucketManager + Connection + Series = ~2,040 lines that directly call Instream or HTTP.

### What the Writer Actually Does (Keep This Pattern)

The Writer GenServer is well-designed and should inform the library's batch writer:
- Async writes via `GenServer.cast` (fire-and-forget)
- Per-bucket pending write buffers
- Dual flush triggers: batch size (1000) OR timer (1000ms)
- Retry with exponential backoff (3 retries, `delay * (attempt + 1)`)
- Error classification: client (4xx, non-retryable) vs server (5xx, retryable)
- Mock mode for tests (skips actual writes)
- Stats tracking (total writes, errors, bytes)

### What the Query Module Does (Must Change for v3)

Currently builds raw Flux strings with string interpolation:
```elixir
"""
from(bucket: "#{bucket}")
  |> range(start: #{format_time(start)})
  |> filter(fn: (r) => r.symbol == "#{symbol}")
"""
```

This must become parameterized SQL:
```elixir
%{
  q: "SELECT * FROM prices WHERE symbol = $symbol AND time >= $start",
  params: %{symbol: symbol, start: start}
}
```

### What BucketManager Does (API Changes for v3)

Currently uses HTTPoison to call v2 bucket API. Must change to:
- v3: `/api/v3/configure/database` endpoints
- "Buckets" → "Databases" terminology
- Retention policies in database creation, not separate configuration
- Token management via `/api/v3/configure/token/*`

---

## Library Design Decisions

### Decision 1: HTTP-Only (No Arrow Flight Initially)

- **Rationale**: The JavaScript official client uses HTTP-only and works fine. Arrow Flight requires gRPC + Arrow IPC decoding — significant complexity for marginal gain at our throughput levels. HTTP query API supports JSONL streaming which handles large results well.
- **Future**: Arrow Flight can be added as an optional module later if query throughput becomes a bottleneck. The `elixir-grpc/grpc` package (v0.11.5, mature) makes this feasible when needed.

### Decision 2: Finch as HTTP Client

- **Rationale**: Finch (built on Mint + NimblePool) is the modern Elixir HTTP client. HTTP/2 support, efficient connection pooling, well-maintained. Already a standard dependency in Phoenix projects.
- **Eliminates**: hackney, poolboy, HTTPoison — three stale/legacy deps.

### Decision 3: Support Both v2 and v3 APIs

- **Rationale**: Many users are still on v2 and will migrate over time. The write format (line protocol) is identical. Query and management APIs differ. Support both via configuration.
- **Implementation**: API version as config option. Write path works on both. Query path has v2 (Flux) and v3 (SQL/InfluxQL) modules. Management path has v2 (buckets) and v3 (databases) modules.

### Decision 4: Built-in Batch Writer GenServer

- **Rationale**: Every serious InfluxDB user needs batched writes. The official Python/Go clients include batch writers. Making this first-class avoids every user reimplementing it.
- **Implementation**: Optional GenServer with configurable batch_size, flush_interval, jitter, retry logic, backpressure handling.

### Decision 5: Telemetry Integration

- **Rationale**: Standard Elixir observability. Emit events for writes, queries, errors, retries.
- **Events**: `[:influx_ex, :write, :start | :stop | :exception]`, `[:influx_ex, :query, :start | :stop | :exception]`

### Decision 6: Server-Side Aggregation via Processing Engine

- **Context**: v2 used Flux tasks for server-side data aggregation (e.g., rolling up raw prices into OHLCV candles at multiple timeframes). v3 replaces Flux tasks with the Processing Engine (Python plugins triggered on WAL flush, on cron schedule, or on demand).
- **Options considered**:
  1. **Elixir-side aggregation**: Pull raw data out to Elixir GenServers, aggregate, write back. Full control but adds network round-trips and load on both Elixir and InfluxDB.
  2. **Processing Engine (Python plugins)**: Aggregation runs inside InfluxDB's process, operates directly on data without network overhead. Python is isolated to declarative aggregation logic only.
  3. **Scheduled SQL queries via Elixir (Quantum)**: Elixir triggers `INSERT INTO ... SELECT ... GROUP BY time(5m)` on a schedule. Middle ground — SQL is clean but still has network round-trip.
- **Decision**: Performance is the driving factor. For pure data aggregation (OHLCV rollups, downsampling), the Processing Engine is the right tool — the data never leaves InfluxDB. This is functionally identical to how Flux tasks worked in v2: server-side scheduled data processing. The Python is limited to simple, declarative aggregation logic — not application business logic.
- **Elixir's role**: Elixir handles everything that IS business logic — signal generation, risk management, strategy execution. InfluxDB handles what IS data plumbing — rollups, downsampling, retention.
- **Library implication**: The client library should support deploying and managing Processing Engine plugins via the InfluxDB API if management endpoints are available. At minimum, provide documentation on how to set up aggregation plugins alongside the Elixir application.

---

## Library Module Architecture

```
influx_ex/
├── lib/
│   ├── influx_ex.ex                    # Public API (write, query, query_stream, execute_sql, manage)
│   ├── influx_ex/
│   │   ├── client.ex                   # HTTP client (Finch wrapper, per-connection)
│   │   ├── connection.ex              # Named connection manager (multiple instances)
│   │   ├── config.ex                  # Connection configuration
│   │   │
│   │   ├── write/
│   │   │   ├── line_protocol.ex        # Line protocol encoder
│   │   │   ├── point.ex               # Point struct (measurement, tags, fields, timestamp)
│   │   │   ├── writer.ex              # Direct write (single request)
│   │   │   └── batch_writer.ex        # GenServer batch writer with flush/retry
│   │   │
│   │   ├── query/
│   │   │   ├── sql.ex                 # v3 SQL query builder + executor
│   │   │   ├── sql_stream.ex          # Streaming JSONL query results (lazy Stream)
│   │   │   ├── influxql.ex            # v3 InfluxQL query executor
│   │   │   ├── flux.ex                # v2 Flux query executor (compat)
│   │   │   └── response_parser.ex     # JSONL/CSV/JSON response parsing
│   │   │
│   │   ├── admin/
│   │   │   ├── databases.ex           # v3 database CRUD
│   │   │   ├── buckets.ex             # v2 bucket CRUD (compat)
│   │   │   ├── tokens.ex              # v3 token management
│   │   │   └── health.ex              # Health/ping checks
│   │   │
│   │   └── telemetry.ex               # Telemetry event emission
│   │
│   └── influx_ex/
│       └── application.ex             # Optional supervision tree (for batch writer)
│
├── test/
│   ├── influx_ex/
│   │   ├── write/
│   │   │   ├── line_protocol_test.exs  # Encoding correctness
│   │   │   ├── point_test.exs
│   │   │   ├── writer_test.exs
│   │   │   └── batch_writer_test.exs
│   │   ├── query/
│   │   │   ├── sql_test.exs
│   │   │   ├── sql_stream_test.exs
│   │   │   ├── influxql_test.exs
│   │   │   └── response_parser_test.exs
│   │   └── admin/
│   │       ├── databases_test.exs
│   │       └── health_test.exs
│   ├── integration/                    # Against real InfluxDB instance
│   │   ├── write_integration_test.exs
│   │   └── query_integration_test.exs
│   └── test_helper.exs
│
├── mix.exs
├── README.md
├── LICENSE                             # MIT or Apache 2.0
└── .github/workflows/ci.yml
```

### Dependencies

```elixir
defp deps do
  [
    {:finch, "~> 0.18"},           # HTTP client
    {:jason, "~> 1.4"},            # JSON encoding/decoding
    {:nimble_csv, "~> 1.2"},       # CSV parsing (query responses)
    {:telemetry, "~> 1.0"},        # Observability
    # Optional
    {:nimble_options, "~> 1.0"},   # Config validation
  ]
end
```

Zero legacy deps. Everything modern and maintained.

---

## Core Module Specifications

### Point Struct

```elixir
defstruct [:measurement, :tags, :fields, :timestamp]

# measurement: string (required)
# tags: %{string => string} (optional, sorted lexicographically on encode)
# fields: %{string => integer | float | string | boolean} (at least one required)
# timestamp: DateTime.t() | integer (optional, InfluxDB assigns server time if nil)
```

### Line Protocol Encoder

Encodes Point structs to InfluxDB line protocol:
```
measurement,tag1=val1,tag2=val2 field1=1.0,field2="str",field3=42i,field4=true 1630424257000000000
```

Rules:
- Tags sorted lexicographically by key (InfluxDB performance recommendation)
- String field values quoted, others not
- Integer fields suffixed with `i`
- Boolean fields as `true`/`false` (no quotes)
- Spaces, commas, equals in measurement/tag keys/values must be escaped
- Multi-point writes: newline-delimited in single request body
- Gzip the body when > 1KB

### Batch Writer GenServer

```elixir
# Configuration
%{
  database: "my_db",
  batch_size: 5_000,          # InfluxDB recommended: 5,000-10,000
  flush_interval_ms: 1_000,   # Flush every second even if batch not full
  jitter_ms: 0,               # Random delay added to flush interval
  max_retries: 3,
  retry_base_delay_ms: 1_000,
  retry_max_delay_ms: 30_000,
  gzip: true,
  write_timeout_ms: 10_000,
  precision: :nanosecond,
  no_sync: false              # v3: respond before WAL persistence
}
```

API:
- `write(point_or_points)` — async cast, buffered
- `write_sync(point_or_points)` — sync call, waits for flush confirmation
- `flush()` — force immediate flush
- `stats()` — return write statistics

Error handling:
- 4xx (client error): non-retryable, log and discard, emit telemetry error event
- 5xx (server error): retryable with exponential backoff + jitter
- Network error: retryable
- `accept_partial: true` means partial schema conflicts are accepted (204 returned)

### SQL Query Module

```elixir
# Simple query
InfluxEx.query_sql(client, "SELECT * FROM prices WHERE time > now() - interval '1 hour'")

# Parameterized query (safe from injection)
InfluxEx.query_sql(client,
  "SELECT * FROM prices WHERE symbol = $symbol AND time > $start",
  params: %{symbol: "BTC-USD", start: ~U[2026-03-12 00:00:00Z]}
)

# With format option
InfluxEx.query_sql(client, query, format: :jsonl)  # :json | :jsonl | :csv | :parquet
```

Response: parsed into list of maps (from JSONL) or raw string (CSV/Parquet).

### Streaming SQL Query

```elixir
# Returns a lazy Stream — parses JSONL chunks as they arrive
# Critical for loading large datasets (backtest candle history, equity curves)
stream = InfluxEx.query_sql_stream(client,
  "SELECT * FROM candles WHERE symbol = $symbol AND time >= $start ORDER BY time ASC",
  params: %{symbol: "BTC-USD", start: ~U[2025-09-01 00:00:00Z]},
  database: "candles"
)

# Process lazily — constant memory regardless of result size
stream
|> Stream.each(fn row -> process_candle(row) end)
|> Stream.run()

# Or collect into list when you know the result is bounded
candles = Enum.to_list(stream)
```

Implementation: Uses Finch's streaming response support. Parses JSONL line-by-line as chunks arrive from the HTTP response body.

### SQL Execute (Non-SELECT Statements)

```elixir
# DELETE — used for retention cleanup
InfluxEx.execute_sql(client,
  "DELETE FROM candles WHERE timeframe = '1m' AND time < $cutoff",
  params: %{cutoff: ~U[2026-02-10 00:00:00Z]},
  database: "candles"
)

# INSERT INTO ... SELECT — used for server-side aggregation fallback
InfluxEx.execute_sql(client, """
  INSERT INTO candles
  SELECT date_bin('5 minutes', time) AS time, symbol, '5m' AS timeframe,
         first(open) AS open, max(high) AS high, min(low) AS low,
         last(close) AS close, sum(volume) AS volume
  FROM candles WHERE timeframe = '1m' AND time >= $start AND time < $end
  GROUP BY date_bin('5 minutes', time), symbol
  """,
  params: %{start: start_time, end: end_time},
  database: "candles"
)
```

Response: `{:ok, %{rows_affected: integer}}` or `{:error, reason}`.

### InfluxQL Query Module

```elixir
# InfluxQL for v2-style aggregate queries
InfluxEx.query_influxql(client,
  "SELECT mean(price) FROM prices WHERE symbol = $symbol AND time > now() - 1h GROUP BY time(5m)",
  params: %{symbol: "BTC-USD"}
)
```

### Database Management

```elixir
InfluxEx.create_database(client, "prices", retention_period: "30d")
InfluxEx.list_databases(client)
InfluxEx.delete_database(client, "prices")
```

### v2 Compatibility

```elixir
# Configure for v2
client = InfluxEx.client(host: "localhost", token: "...", api_version: :v2, org: "myorg")

# Write uses /api/v2/write
InfluxEx.write(client, points, bucket: "prices")

# Query uses /api/v2/query with Flux
InfluxEx.query_flux(client, ~s|from(bucket: "prices") |> range(start: -1h)|)
```

---

## Feature Matrix

| Feature | Instream (v2) | New Library Target |
|---------|--------------|-------------------|
| InfluxDB v2 support | Yes | Yes (compatibility mode) |
| InfluxDB v3 support | No | **Yes (primary target)** |
| Line protocol writes | Yes | Yes |
| Gzip compression | No | **Yes** |
| Batch writer GenServer | No (user builds) | **Yes (built-in)** |
| SQL queries (v3) | No | **Yes** |
| InfluxQL queries | No | **Yes** |
| Flux queries (v2) | Yes | Yes (v2 compat only) |
| Parameterized queries | No | **Yes** |
| Database management (v3) | No | **Yes** |
| Bucket management (v2) | No | **Yes** |
| Token management (v3) | No | **Yes** |
| Health checks | Ping only | **Full health + ping** |
| HTTP client | hackney (stale) | **Finch (modern)** |
| Connection pooling | poolboy (stale) | **NimblePool via Finch** |
| HTTP/2 | No | **Yes (via Finch)** |
| Telemetry | No | **Yes** |
| Arrow Flight gRPC | No | Future optional module |
| Streaming query results | No | **Yes (lazy Stream from JSONL)** |
| SQL DELETE/INSERT INTO | No | **Yes (execute_sql for non-SELECT)** |
| Large integer fidelity | Unknown | **Yes (Money-precision round-trip)** |
| Processing Engine management | No | **Yes (if API exists, else docs)** |
| Test helpers | No | **Yes (mock mode, assertions)** |

---

## Performance Targets

Based on InfluxDB v3 recommendations and trading system requirements:

| Metric | Target |
|--------|--------|
| Write throughput | 50,000+ points/second (batched, gzipped) |
| Write latency (batch) | < 100ms per batch flush |
| Query latency (simple) | < 50ms for recent data (< 1hr window) |
| Query latency (aggregate) | < 500ms for daily aggregations |
| Memory (batch buffer) | < 10MB for 10,000 point buffer |
| Connection pool | Configurable, default 10 connections |
| Gzip ratio | 3-5x compression on line protocol |

---

## Requirements From Trading System (To Be Updated)

These are the specific needs from the dp_crypto_management trading system that the library must support. This section will be updated as we review the signal-based trading plan.

### Write Requirements

| Requirement | Data Type | Volume | Database | Plan |
|-------------|-----------|--------|----------|------|
| Price tick writes | `prices` measurement | ~40 pts/sec (4 exchanges × 10 symbols) | `prices` | Existing |
| Orderbook snapshots | `orderbooks` measurement, top 20 levels per symbol | ~400 pts/sec (20 levels × 10 symbols, every 30s) | `prices` | Existing |
| OHLCV candle writes | `candles` measurement at 6 timeframes | ~1 pt/sec (server-side aggregation writes) | `candles` | 020 |
| Indicator snapshots | `indicators` measurement, 12+ indicators per symbol | ~20 pts every 30s (10 symbols × 2 per flush) | `indicators` | 021 |
| Signal scores | `signals` measurement per composite evaluation | ~10 pts/sec (10 symbols, each tick produces a signal) | `signals` | 024 |
| Risk events | `risk_events` measurement | Low volume, event-driven (rejections, circuit breaker changes) | `strategy_trades` | 025 |
| Strategy trades | `strategy_trades` measurement | Low volume, per trade entry/exit | `strategy_trades` | 027 |
| Equity curves | `strategy_equity` measurement | ~1 pt/min per active strategy | `strategy_trades` | 028 |
| Backtest equity | `backtest_equity` measurement | Burst: thousands of points flushed after backtest run | `backtests` (analytics) | 028 |
| Backtest trades | `backtest_trades` measurement | Burst: hundreds of points flushed after run | `backtests` (analytics) | 028 |
| AI audit trail | `weight_changes` measurement | Low volume, per weight adjustment | `signals` (analytics) | 029 |

**Peak steady-state write load**: ~500 points/sec (dominated by orderbook snapshots). **Burst load**: 10,000+ points in seconds (backtest flush).

**Library features needed for writes**:
- [ ] Batch writer GenServer with configurable batch_size (5,000) and flush_interval (1,000ms)
- [ ] Gzip compression (critical for orderbook burst writes)
- [ ] Per-database batch writers (5 databases need independent flush cycles)
- [ ] `no_sync: true` option for fire-and-forget writes (prices, indicators — acceptable to lose occasional points)
- [ ] `no_sync: false` for confirmed writes (trades, risk events — must not lose)
- [ ] Backpressure handling: bounded buffer, drop-oldest or block when full
- [ ] Retry with exponential backoff + jitter (server errors only, not client errors)
- [ ] Mock/test mode: skip actual writes in test environment, configurable per-writer
- [ ] Telemetry events: `[:influx_ex, :write, :start | :stop | :exception]` with metadata (database, point_count, bytes, compressed_bytes)
- [ ] **Money-precision integer support**: The `Point` struct field values support arbitrary integers. Document the pattern for Money-precision storage: field values stored as integers with a known multiplier (e.g., 10^24), decoded on read. The library does NOT need to understand Money — it just needs to faithfully round-trip large integers through line protocol without precision loss. Test: write an integer field value > 2^53, read it back, verify exact match.
- [ ] **`no_sync` per-write override**: Allow `no_sync` option per `write/3` call, not just per batch writer config. Some writes in the same database need confirmation (trades) while others don't (prices). If per-write override is not feasible, document that users should use separate batch writers per confirmation requirement.

### Query Requirements

| Query Pattern | SQL Example | Frequency | Database |
|---------------|-------------|-----------|----------|
| Latest candles (N most recent) | `SELECT * FROM candles WHERE symbol=$s AND timeframe=$tf ORDER BY time DESC LIMIT $n` | On every IndicatorEngine startup + periodically | `candles` |
| Candle range (time window) | `SELECT * FROM candles WHERE symbol=$s AND timeframe=$tf AND time >= $start AND time <= $end` | Backtest data loading, chart rendering | `candles` |
| Latest indicators | `SELECT * FROM indicators WHERE symbol=$s ORDER BY time DESC LIMIT 1` | Dashboard display | `indicators` |
| Signal history | `SELECT * FROM signals WHERE symbol=$s AND time >= $start ORDER BY time ASC` | Backtest analysis, dashboard charts | `signals` |
| Aggregate queries (windowed) | `SELECT date_bin('5 minutes', time) AS bucket, avg(price) FROM prices WHERE symbol=$s GROUP BY bucket` | IndicatorEngine multi-TF, chart rendering | `prices` |
| Risk event log | `SELECT * FROM risk_events WHERE strategy=$s ORDER BY time DESC LIMIT 100` | Risk dashboard display | `strategy_trades` |
| Equity curve | `SELECT * FROM strategy_equity WHERE strategy=$s AND mode=$m ORDER BY time ASC` | Dashboard charts, backtest comparison | `strategy_trades` |
| Trade records | `SELECT * FROM strategy_trades WHERE strategy=$s AND mode=$m ORDER BY time DESC` | Trade history display, P&L calculation | `strategy_trades` |
| Backtest equity curve | `SELECT * FROM backtest_equity WHERE backtest_id=$id ORDER BY time ASC` | Backtest results display | `backtests` |
| Candle retention cleanup | `DELETE FROM candles WHERE timeframe='1m' AND time < $cutoff` | Daily Quantum job (Plan-020.5) | `candles` |
| Candle aggregation (SQL fallback) | `INSERT INTO candles SELECT date_bin('5m', time), first(open), max(high)... FROM candles WHERE timeframe='1m' GROUP BY ...` | Quantum job if Processing Engine not used | `candles` |
| AI weight audit | `SELECT * FROM weight_changes WHERE strategy=$s ORDER BY time DESC` | AI audit trail display | `signals` |

**Library features needed for queries**:
- [ ] Parameterized SQL queries (all queries use `$param` placeholders — no string interpolation)
- [ ] JSONL response parsing (streaming, preferred for large result sets like backtest data)
- [ ] CSV response parsing (fallback)
- [ ] Query timeout configuration (default 30s, backtest queries may need longer)
- [ ] Result mapping to Elixir maps with proper type coercion (timestamps → DateTime, numbers → Decimal/float)
- [ ] Database selection per query (queries hit different databases)
- [ ] **Streaming query API**: `query_sql_stream(conn, sql, opts)` returning a `Stream` that lazily parses JSONL response chunks. Critical for backtest data loading (loading 6+ months of candle data into memory all at once is not feasible). Also useful for large equity curve queries.
- [ ] **SQL DELETE support**: `delete(conn, sql, opts)` or a general `execute_sql(conn, sql, opts)` for non-SELECT statements. Trading system needs DELETE for candle retention cleanup (Plan-020.5: delete 1m candles older than 30d, 5m/15m older than 90d). Also used for data management operations.
- [ ] **INSERT INTO ... SELECT support**: General SQL execution covers this. Needed as fallback for Elixir-side candle aggregation if Processing Engine approach is not used (Plan-020.3 Option B). Example: `INSERT INTO candles SELECT date_bin('5 minutes', time) AS time, first(open), max(high), min(low), last(close), sum(volume) FROM candles WHERE timeframe='1m' GROUP BY date_bin('5 minutes', time), symbol`

### Admin Requirements

- [ ] Database CRUD via `/api/v3/configure/database` (create with retention_period, list, delete)
- [ ] Startup verification: create databases if missing (idempotent)
- [ ] Health check: `GET /health` for monitoring integration
- [ ] Token management (optional, for multi-user scenarios)

### Processing Engine Requirements

- [ ] **Plugin management API** (if v3 exposes HTTP endpoints for it):
  - `deploy_plugin(conn, name, source_code, trigger_config)` — deploy a Python plugin
  - `list_plugins(conn)` — list deployed plugins with status
  - `enable_plugin(conn, name)` / `disable_plugin(conn, name)` — toggle
  - `delete_plugin(conn, name)` — remove
  - `get_plugin_logs(conn, name, opts)` — retrieve execution logs for debugging
- [ ] **If no management API exists**: provide comprehensive documentation and example plugin files for manual setup
- [ ] Plugin definitions for OHLCV candle aggregation cascade:
  - Raw prices → 1m candles (cron every 1m or WAL flush trigger)
  - 1m → 5m, 15m, 1h candles (cron at respective intervals)
  - 1h → 4h, 1d candles (cron at respective intervals)
- [ ] **Plugin health monitoring**: if the library can query plugin status, expose it through the health check API so the application can detect stalled aggregation

### Multi-Instance & Multi-Database Support

The trading system requires **two separate InfluxDB v3 instances** — one for mission-critical trading data, one for analytics/signals. The library must support connecting to multiple independent InfluxDB instances simultaneously.

**Library requirements**:
- [ ] **Named client connections**: Support multiple named clients, each pointing to a different InfluxDB instance with independent host/token/config
  ```elixir
  # Application config
  config :influx_ex, :connections,
    trading: [host: "influx-trading:8086", token: "...", default_database: "prices"],
    analytics: [host: "influx-analytics:8086", token: "...", default_database: "indicators"]
  ```
- [ ] **Per-connection batch writers**: Each named connection gets its own batch writer GenServer with independent flush cycles, retry state, and backpressure
- [ ] **Connection routing on write**: `InfluxEx.write(:trading, points, database: "candles")` — first arg selects the instance
- [ ] **Connection routing on query**: `InfluxEx.query_sql(:analytics, query, database: "signals")` — same pattern
- [ ] **Independent health checks**: Each connection has its own health status. Trading instance down ≠ analytics instance down.
- [ ] **Independent failure handling**: A crash or timeout on one connection must not affect the other. Separate supervision trees per connection.
- [ ] **Database management per instance**: Admin API calls target the specified instance

**Trading instance** (Enterprise, 3 databases):
- `prices` (7d) — raw ticks, orderbooks
- `candles` (1yr) — aggregated OHLCV
- `strategy_trades` (forever) — trade records, equity, risk events

**Analytics instance** (Enterprise, 4 databases):
- `indicators` (90d) — computed indicator snapshots
- `signals` (90d) — signal scores
- `backtests` (30d) — backtest equity curves and trade logs
- `metrics` (30d) — system/business metrics

**Why two instances**: Failure isolation (analytics overload can't impact trading data), independent scaling, different backup/retention strategies, different performance tuning (trading optimized for fast point writes and lookups, analytics for heavy aggregation queries).

---

## Migration Path: Current System → New Library

### Phase 1: Build the library (separate repo)
- Core write/query/admin modules
- Batch writer GenServer
- Comprehensive tests against real InfluxDB v3 instance
- Hex.pm publish

### Phase 2: Integrate into dp_crypto_management
- Replace Instream dependency with new library
- Migrate Writer.ex to use new batch writer (or wrap it)
- Migrate Query.ex from Flux strings to SQL parameterized queries
- Migrate BucketManager from HTTPoison + v2 API to new library's database management
- Remove: Instream, hackney, poolboy, HTTPoison (if only used for InfluxDB)
- Update all InfluxDB configuration (org concept gone, buckets → databases)

### Phase 3: Upgrade InfluxDB instances
- Deploy two InfluxDB v3 Enterprise instances (free Home Use license): trading + analytics
- Migrate existing data (line protocol export/import — format is identical)
- Switch application to v3 with dual-instance configuration
- Decommission v2

---

## Open Questions

1. **Library name**: `influx_ex`? `influxdb3`? `influx_client`? Should match Hex.pm naming conventions and not conflict with existing packages.
2. **Arrow Flight priority**: Build HTTP-only first and add Flight later, or include from the start?
3. **v2 compat scope**: Full v2 support or just enough for migration? (Recommendation: write compat + Flux query compat, skip v2 task/notification APIs since they're going away)
4. ~~**Processing Engine integration**~~: Addressed — see Processing Engine Requirements section above. Library will support management API if v3 exposes endpoints, else provide documentation and example plugins.
5. **Parquet response parsing**: v3 can return query results as Parquet. Worth supporting for Nx/Explorer integration? Trading system Plan-029 uses Nx for feature vectors and rolling statistics — Parquet → Nx tensor could be efficient for bulk data loading. Low priority for initial release, but worth noting as a future enhancement.
6. **v3 Enterprise vs Core**: Trading system will use Enterprise (free Home Use license). Library should work with both — the API is identical, only limits differ. No library changes needed, but documentation should note Enterprise-specific features (higher DB limits, etc.).

---

**Document Status**: Draft — awaiting review
**Last Updated**: 2026-03-12
**Next Steps**: Review alongside signal-based trading plan; update requirements section as needs are identified
