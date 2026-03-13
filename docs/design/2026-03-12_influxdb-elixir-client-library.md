# InfluxDB v3 Elixir Client Library — Design & Findings Document

**Date**: 2026-03-12
**Updated**: 2026-03-13
**Status**: Draft
**Version**: 2.0
**Package**: `influx_elixir` | **Module**: `InfluxElixir`
**Purpose**: Planning document for a new open-source Elixir client library targeting InfluxDB v3. Captures the current state analysis, v3 research, and architectural decisions to guide a standalone library build.

---

## Implementation Checklist

### Phase 0: Project Bootstrap
- [ ] 0.1 — `.tool-versions` created (Elixir 1.18.4-otp-28, Erlang 28.0.2, Node 22.17.1)
- [ ] 0.2 — `mise install` — runtimes installed and verified
- [ ] 0.3 — `mix new . --module InfluxElixir --sup` — project scaffolded
- [ ] 0.4 — `mix.exs` configured (deps, aliases, hex package, usage_rules)
- [ ] 0.5 — `.formatter.exs` configured (line_length: 98)
- [ ] 0.6 — `.credo.exs` configured (strict mode, all checks)
- [ ] 0.7 — `.gitignore` configured
- [ ] 0.8 — CI pipeline (`.github/workflows/ci.yml`) — quality + publish jobs
- [ ] 0.9 — Directory structure created with empty module stubs
- [ ] 0.10 — `mix deps.get && mix compile` — clean compilation
- [ ] 0.11 — `mix quality` passes (format, credo, dialyzer)
- [ ] 0.12 — `mix test` — default test passes
- [ ] 0.13 — `mix usage_rules.sync` — AGENTS.md generated

### Core: Client Behaviour & Adapters
- [ ] `InfluxElixir.Client` — behaviour definition with all callbacks
- [ ] `InfluxElixir.Client.HTTP` — Finch-based production implementation
- [ ] `InfluxElixir.Client.Local` — ETS-backed in-memory test implementation
- [ ] Config-driven implementation switching (`config :influx_elixir, :client`)

### Core: Facade Module
- [ ] `InfluxElixir` — public API facade, delegates to client behaviour
- [ ] `point/3` — construct a Point struct
- [ ] `write/2`, `write/3` — write points (via client)
- [ ] `query_sql/2`, `query_sql/3` — SQL query (supports `transport: :http | :flight`)
- [ ] `query_sql_stream/2`, `query_sql_stream/3` — streaming SQL query
- [ ] `execute_sql/2`, `execute_sql/3` — non-SELECT SQL (DELETE, INSERT INTO ... SELECT)
- [ ] `query_influxql/2`, `query_influxql/3` — InfluxQL query
- [ ] `query_flux/2` — v2 Flux compat
- [ ] `create_database/2`, `list_databases/1`, `delete_database/2` — v3 admin
- [ ] `create_bucket/2`, `list_buckets/1`, `delete_bucket/2` — v2 admin
- [ ] `create_token/2`, `delete_token/2` — v3 token management
- [ ] `health/1` — health check
- [ ] `flush/1` — force batch writer flush
- [ ] `stats/1` — batch writer statistics
- [ ] `add_connection/2`, `remove_connection/1` — dynamic connection management

### Supervision Tree
- [ ] `InfluxElixir.Application` — OTP Application entry point
- [ ] `InfluxElixir.Supervisor` — top-level `:one_for_one` (manages ConnectionSupervisors)
- [ ] `InfluxElixir.ConnectionSupervisor` — per-connection `:rest_for_one` (Finch pool + BatchWriters)
- [ ] Dynamic connection add/remove via `Supervisor.start_child/2`
- [ ] Crash isolation verified: connection crash does not affect siblings

### Write Path
- [ ] `InfluxElixir.Write.Point` — Point struct (measurement, tags, fields, timestamp)
- [ ] `InfluxElixir.Write.LineProtocol` — line protocol encoder
  - [ ] Tag sorting (lexicographic by key)
  - [ ] Field type encoding (integer `i` suffix, quoted strings, booleans)
  - [ ] Escaping (spaces, commas, equals in keys/values)
  - [ ] Multi-point newline delimiters
  - [ ] Gzip when payload > 1KB
  - [ ] Large integer fidelity (> 2^53 round-trip)
- [ ] `InfluxElixir.Write.Writer` — direct single-request write
- [ ] `InfluxElixir.Write.BatchWriter` — GenServer batch writer
  - [ ] Configurable batch_size, flush_interval_ms, jitter_ms
  - [ ] Dual flush triggers (batch size OR timer)
  - [ ] Retry with exponential backoff + jitter (5xx/network only, not 4xx)
  - [ ] Backpressure handling (bounded buffer)
  - [ ] `no_sync` per-write override
  - [ ] Hibernation after flush (memory optimization)
  - [ ] Stats tracking (total writes, errors, bytes)

### Query Path
- [ ] `InfluxElixir.Query.SQL` — v3 SQL query builder + executor
  - [ ] Parameterized queries (`$param` placeholders)
  - [ ] Format options (`:json`, `:jsonl`, `:csv`, `:parquet`)
  - [ ] `transport: :http | :flight` option
- [ ] `InfluxElixir.Query.SQLStream` — streaming JSONL query results (lazy Stream)
- [ ] `InfluxElixir.Query.InfluxQL` — v3 InfluxQL query executor
- [ ] `InfluxElixir.Query.Flux` — v2 Flux query executor (compat)
- [ ] `InfluxElixir.Query.ResponseParser` — JSONL/CSV/JSON/Parquet response parsing
  - [ ] Type coercion (timestamps -> DateTime, numbers -> proper types)

### Arrow Flight
- [ ] `InfluxElixir.Flight.Client` — Arrow Flight gRPC client
- [ ] `InfluxElixir.Flight.Reader` — Arrow IPC record batch decoder
- [ ] `InfluxElixir.Flight.Proto` — generated protobuf modules (Flight.proto)
- [ ] Integration with `query_sql/3` via `transport: :flight` option

### Admin
- [ ] `InfluxElixir.Admin.Databases` — v3 database CRUD (`/api/v3/configure/database`)
- [ ] `InfluxElixir.Admin.Buckets` — v2 bucket CRUD (compat)
- [ ] `InfluxElixir.Admin.Tokens` — v3 token management (`/api/v3/configure/token`)
- [ ] `InfluxElixir.Admin.Health` — health + ping checks

### Telemetry
- [ ] `InfluxElixir.Telemetry` — event emission
  - [ ] `[:influx_elixir, :write, :start | :stop | :exception]`
  - [ ] `[:influx_elixir, :query, :start | :stop | :exception]`
  - [ ] Metadata: database, point_count, bytes, compressed_bytes, transport

### Testing
- [ ] `InfluxElixir.TestHelper` — test setup helpers for consuming apps
- [ ] LocalClient: line protocol parsing
- [ ] LocalClient: ETS storage with per-process isolation
- [ ] LocalClient: database create/list/delete
- [ ] LocalClient: SQL query (WHERE, ORDER BY, LIMIT, `$param`)
- [ ] LocalClient: correct error formats (400, 404 matching real InfluxDB)
- [ ] LocalClient: gzip decompression on writes
- [ ] LocalClient: timestamp precision handling
- [ ] Contract tests (`test/integration/contract_test.exs`)
  - [ ] Same assertions against both LocalClient and real InfluxDB
  - [ ] All field types round-trip
  - [ ] Large integer round-trip
  - [ ] Error format matching
- [ ] Unit tests via LocalClient (95%+ coverage target)
- [ ] Integration tests tagged `:integration` (excluded from CI)

### UsageRules
- [ ] `usage-rules.md` — main rules for consuming apps
- [ ] `usage-rules/write.md` — write sub-rules
- [ ] `usage-rules/query.md` — query sub-rules
- [ ] `usage-rules/testing.md` — testing sub-rules
- [ ] `files:` in mix.exs includes usage-rules in hex package
- [ ] `mix usage_rules.sync` generates AGENTS.md

### Documentation & Publishing
- [ ] README.md
- [ ] CHANGELOG.md
- [ ] LICENSE (MIT)
- [ ] ExDoc configuration
- [ ] `@doc` and `@spec` on all public functions
- [ ] CI auto-publishes to Hex.pm on push to main

---

## Library Name: `influx_elixir`

**Decision**: `influx_elixir` / `InfluxElixir`

The library is named `influx_elixir` with the top-level module `InfluxElixir`. This follows Elixir naming conventions, is descriptive, and distinguishes this library from stale v2 packages on Hex.pm.

### Context: Names Considered

| # | Package Name | Module Name | Notes |
|---|-------------|-------------|-------|
| 1 | `influxdb3` | `InfluxDB3` | Matches official SDK naming. Version-locked. |
| 2 | `influx3_ex` | `Influx3Ex` | Elixir convention + version. |
| 3 | `influxdb_client` | `InfluxDB.Client` | Generic, professional. |
| 4 | **`influx_elixir`** | **`InfluxElixir`** | **Selected. Clear, idiomatic Elixir naming.** |
| 5 | `influx_core` | `InfluxCore` | Matches v3 "Core" edition. Could confuse with InfluxDB internals. |

---

## Phase 0: Project Bootstrap

This section covers the initial Elixir project setup before any library code is written.

### 0.1 Project Generation

```bash
mix new . --module InfluxElixir --sup
```

The `.` scaffolds in the current directory (repo already exists with CLAUDE.md, docs, git history). Generated with `--sup` because this library manages its own supervision tree. Multiple named connections each require isolated Finch pools and BatchWriter GenServers with independent crash boundaries. The consuming app starts the library's top-level supervisor as a child in their own tree:

```elixir
# In the consuming app's application.ex
children = [
  {InfluxElixir,
    connections: [
      trading: [host: "influx-trading:8086", token: "...", default_database: "prices"],
      analytics: [host: "influx-analytics:8086", token: "...", default_database: "indicators"]
    ]}
]
```

### 0.2 mix.exs Configuration

```elixir
defmodule InfluxElixir.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/DistortionPoint/influx-elixir"

  def project do
    [
      app: :influx_elixir,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      preferred_cli_env: preferred_cli_env(),

      # Hex.pm
      name: "InfluxElixir",
      description: "Elixir client library for InfluxDB v3 with v2 compatibility",
      package: package(),
      source_url: @source_url,
      docs: docs(),

      # UsageRules
      usage_rules: usage_rules(),

      # Include usage-rules files in hex package
      files: [
        "lib",
        "mix.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        "usage-rules.md",
        "usage-rules/**/*"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {InfluxElixir.Application, []}
    ]
  end

  defp deps do
    [
      # Runtime — HTTP
      {:finch, "~> 0.18"},
      {:jason, "~> 1.4"},
      {:nimble_csv, "~> 1.2"},
      {:telemetry, "~> 1.0"},
      {:nimble_options, "~> 1.0"},

      # Runtime — Arrow Flight
      {:grpc, "~> 0.11"},
      {:protobuf, "~> 0.12"},

      # Dev/Test
      {:usage_rules, "~> 1.2", only: :dev},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "sobelow --config"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end

  defp preferred_cli_env do
    [
      quality: :test
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["bcatherall"]
    ]
  end

  defp docs do
    [
      main: "InfluxElixir",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [:usage_rules]
    ]
  end
end
```

### 0.3 Directory Structure (Initial)

```
influx_elixir/
├── lib/
│   ├── influx_elixir.ex                    # Public API facade
│   └── influx_elixir/
│       ├── application.ex                  # OTP Application — starts top-level supervisor
│       ├── supervisor.ex                   # Top-level supervisor (manages ConnectionSupervisors)
│       ├── connection_supervisor.ex        # Per-connection supervisor (Finch pool + BatchWriters)
│       ├── client.ex                       # Client behaviour definition
│       ├── client/
│       │   ├── http.ex                     # Production Finch-based implementation
│       │   └── local.ex                    # In-memory LocalClient for testing
│       ├── connection.ex                   # Named connection manager
│       ├── config.ex                       # Connection configuration
│       ├── write/
│       │   ├── line_protocol.ex            # Line protocol encoder
│       │   ├── point.ex                    # Point struct
│       │   ├── writer.ex                   # Direct write (single request)
│       │   └── batch_writer.ex             # GenServer batch writer
│       ├── query/
│       │   ├── sql.ex                      # v3 SQL query builder + executor
│       │   ├── sql_stream.ex               # Streaming JSONL query results
│       │   ├── influxql.ex                 # v3 InfluxQL query executor
│       │   ├── flux.ex                     # v2 Flux query executor (compat)
│       │   └── response_parser.ex          # JSONL/CSV/JSON response parsing
│       ├── flight/
│       │   ├── client.ex                   # Arrow Flight gRPC client
│       │   ├── reader.ex                   # Arrow IPC record batch decoder
│       │   └── proto/                      # Generated protobuf modules (Flight.proto)
│       ├── admin/
│       │   ├── databases.ex                # v3 database CRUD
│       │   ├── buckets.ex                  # v2 bucket CRUD (compat)
│       │   ├── tokens.ex                   # v3 token management
│       │   └── health.ex                   # Health/ping checks
│       ├── telemetry.ex                    # Telemetry event emission
│       └── test_helper.ex                  # Helpers for consuming app tests
│
├── test/
│   ├── influx_elixir/
│   │   ├── client/
│   │   │   └── local_test.exs              # LocalClient behaviour verification
│   │   ├── write/
│   │   │   ├── line_protocol_test.exs
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
│   ├── integration/                        # Against real InfluxDB (tagged)
│   │   ├── write_integration_test.exs
│   │   ├── query_integration_test.exs
│   │   └── contract_test.exs               # Proves LocalClient matches real server
│   ├── support/
│   │   └── influx_case.ex                  # Shared test case template
│   └── test_helper.exs
│
├── usage-rules.md                          # Usage rules for consuming apps
├── usage-rules/
│   ├── write.md                            # Sub-rule: writing data
│   ├── query.md                            # Sub-rule: querying data
│   └── testing.md                          # Sub-rule: testing with LocalClient
│
├── mix.exs
├── .formatter.exs
├── .credo.exs
├── .tool-versions                          # Mise: elixir, erlang, nodejs versions
├── .gitignore
├── README.md
├── LICENSE
├── CHANGELOG.md
├── CLAUDE.md
├── AGENTS.md                               # Generated by usage_rules
└── .github/workflows/ci.yml
```

### 0.4 Configuration Files

**.tool-versions** (Mise manages runtime versions):
```
elixir 1.18.4-otp-28
erlang 28.0.2
nodejs 22.17.1
```

**.formatter.exs:**
```elixir
[
  inputs: ["{mix,.formatter,.credo}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  line_length: 98
]
```

**.credo.exs:**
Strict mode enabled. Key customizations:
- `strict: true`
- `MaxLineLength`: 120 (not default 98 — formatter handles 98, Credo allows breathing room)
- `CyclomaticComplexity`: max 12
- `Nesting`: max 3
- `TagTODO`: exit_status 2 (fails CI)
- `MapInto`: disabled
- `LazyLogging`: disabled
- Controversial checks enabled: `Specs`, `SeparateAliasRequire`, `UnusedVariableNames` (force: `:meaningful`), `IoPuts`, `NegatedIsNil`, `MultiAliasImportRequireUse`
- Excluded paths: `_build/`, `deps/`, `node_modules/`, `docs/`
- Full config is verbose — see the actual `.credo.exs` file for complete check list

**.gitignore:**
```
/_build/
/cover/
/deps/
/doc/
/.fetch
erl_crash.dump
*.ez
*.beam
/tmp/
*.swp
*.swo
priv/plts/
```

### 0.5 CI Pipeline (.github/workflows/ci.yml)

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  quality:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        otp: ['28.0']
        elixir: ['1.18']
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          otp-version: ${{ matrix.otp }}
          elixir-version: ${{ matrix.elixir }}
      - run: mix deps.get
      - run: mix compile --warnings-as-errors
      - run: mix format --check-formatted
      - run: mix credo --strict
      - run: mix dialyzer
      - run: mix test --cover

  # No integration job in CI — all CI tests use LocalClient.
  # Integration tests (--include integration) run locally against
  # a real InfluxDB instance to verify LocalClient fidelity.

  publish:
    runs-on: ubuntu-latest
    needs: quality
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.GH_PAT }}
      - uses: erlef/setup-beam@v1
        with:
          otp-version: '28.0'
          elixir-version: '1.18'
      - run: mix deps.get
      - name: Auto-increment patch version
        run: |
          current=$(mix eval 'IO.puts(Mix.Project.config()[:version])' | head -1)
          IFS='.' read -r major minor patch <<< "$current"
          new_version="$major.$minor.$((patch + 1))"
          sed -i "s/@version \"$current\"/@version \"$new_version\"/" mix.exs
          echo "VERSION=$new_version" >> $GITHUB_ENV
      - name: Publish to Hex.pm
        run: mix hex.publish --yes
        env:
          HEX_API_KEY: ${{ secrets.HEX_API_KEY }}
      - name: Commit version bump and tag
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add mix.exs
          git commit -m "Release v${{ env.VERSION }}"
          git tag "v${{ env.VERSION }}"
          git push origin main --tags
      - name: Create GitHub release
        run: gh release create "v${{ env.VERSION }}" --generate-notes
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

The `publish` job runs on every push to `main` after quality passes. It auto-increments the patch version in `mix.exs`, publishes to Hex.pm, commits the version bump, tags, and creates a GitHub release. Every merge to main = a new release. `HEX_API_KEY` and `GH_PAT` are set as organization-level secrets on DistortionPoint.

### 0.6 Bootstrap Sequence

1. Create `.tool-versions` with Elixir/Erlang/Node versions (see 0.4 above)
2. `mise install` — install runtimes (Elixir, Erlang, Node)
3. Verify: `elixir --version` / `erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().'`
4. `mix new . --module InfluxElixir --sup` (scaffolds in existing repo)
5. Replace generated `mix.exs` with the config above
6. Create remaining directory structure with empty module stubs (`defmodule ... end`)
7. `mix deps.get`
8. `mix compile` — verify clean compilation
9. `mix format`
10. `mix credo --strict` — verify zero warnings
11. `mix test` — verify default test passes
12. `mix usage_rules.sync` — generate AGENTS.md from dependency rules
13. `git add . && git commit -m "Initial project setup"`

---

## UsageRules Integration

### What UsageRules Does

`usage_rules` (v1.2.5) is a config-driven dev tool that manages LLM agent guidance files. It serves two purposes for this library:

1. **For this project's development**: Syncs usage rules from our dependencies into `AGENTS.md`, giving Claude Code (and other LLM agents) accurate guidance for using Finch, Jason, Telemetry, etc.
2. **For consuming applications**: When apps add `influx_elixir` as a dependency, they can sync our usage rules into their own agent files, giving their LLM agents accurate guidance for using `influx_elixir`.

### Setup in mix.exs

Already shown in Phase 0.2 above. The key configuration:

```elixir
# In project/0
usage_rules: usage_rules(),
files: ["lib", "mix.exs", "README.md", "LICENSE", "usage-rules.md", "usage-rules/**/*"]

# Private function
defp usage_rules do
  [
    file: "AGENTS.md",
    usage_rules: [:usage_rules]
  ]
end

# In deps/0
{:usage_rules, "~> 1.2", only: :dev}
```

### Publishing Usage Rules for Consumers

When a consuming app runs `mix usage_rules.sync` and includes `:influx_elixir` in their usage_rules config, these files are pulled in:

**`usage-rules.md`** (root-level, main rules):
```markdown
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
```

**`usage-rules/write.md`** (sub-rule for write-heavy consumers):
```markdown
# InfluxElixir Write Rules

## Batch Writer
- Batch writers are managed by the library's supervision tree — configure in application config, do not start directly
- Configure `batch_size` (default 5,000) and `flush_interval_ms` (default 1,000) per connection
- Use `no_sync: true` for fire-and-forget writes where occasional data loss is acceptable
- Use `no_sync: false` (default) for writes that must be confirmed
- Use `InfluxElixir.flush/1` to force an immediate flush on a named connection

## Line Protocol
- Tags are sorted lexicographically by key automatically
- Gzip is applied automatically when payload > 1KB
- Large integers (> 2^53) round-trip faithfully through line protocol
```

**`usage-rules/query.md`** (sub-rule for query patterns):
```markdown
# InfluxElixir Query Rules

## SQL Queries (v3)
- Always use parameterized queries: `InfluxElixir.query_sql(:conn_name, "SELECT * FROM t WHERE col = $val", params: %{val: x})`
- Never build SQL strings with string interpolation
- Use `format: :jsonl` (default) for streaming, `:json` for small results, `:csv` for export

## Streaming
- `query_sql_stream/3` returns a lazy `Stream` — constant memory regardless of result size
- Always consume streams or they will hold open HTTP connections
```

**`usage-rules/testing.md`** (sub-rule for testing guidance):
```markdown
# InfluxElixir Testing Rules

## LocalClient for Unit Tests
- Set `config :influx_elixir, :client, InfluxElixir.Client.Local` in `config/test.exs`
- All `InfluxElixir.*` facade calls work identically — the implementation swap is invisible to your code
- LocalClient is a full in-memory implementation — it parses line protocol, stores points, and responds to queries
- Safe for `async: true` tests — each test gets isolated state via process-keyed ETS tables

## Integration Tests
- Tag integration tests with `@tag :integration`
- Exclude by default in test_helper.exs: `ExUnit.configure(exclude: [:integration])`
- Run with: `mix test --include integration`
- Requires `INFLUX_HOST` and `INFLUX_TOKEN` environment variables

## Contract Tests
- The same test suite runs against both LocalClient and real InfluxDB
- This ensures LocalClient stays faithful to real server behavior
```

### Development Workflow with UsageRules

```bash
# Sync dependency rules into AGENTS.md (run after deps change)
mix usage_rules.sync

# Look up docs for a dependency module
mix usage_rules.docs Finch

# Search docs across all dependencies
mix usage_rules.search_docs "streaming response"
```

### How Consuming Apps Use Our Rules

In the consuming app's `mix.exs`:
```elixir
usage_rules: [
  file: "AGENTS.md",
  usage_rules: [:influx_elixir, "influx_elixir:write", "influx_elixir:testing"]
]
```

Or load all sub-rules:
```elixir
usage_rules: [:influx_elixir, "influx_elixir:all"]
```

---

## LocalClient: In-Memory InfluxDB for Fast Tests

### Why a LocalClient

Testing against a real InfluxDB instance is **correct** but **slow**. Network round-trips, Docker startup, database creation/teardown — all add seconds to every test run. For a library with 95%+ coverage target, this would mean painfully slow test suites.

The solution: **`InfluxElixir.Client.Local`** — a full in-memory implementation of the client behaviour that stores data in ETS tables, parses real line protocol, and responds with real InfluxDB response formats.

This is NOT mocking. There is no Mox, no Bypass, no fake HTTP server. It is a **real implementation** of the `InfluxElixir.Client` behaviour that happens to store data in ETS instead of sending HTTP requests. It understands line protocol, it stores points, it can query them back.

### Architecture: Behaviour-Based Adapter Pattern

```
InfluxElixir.Client (behaviour)
├── InfluxElixir.Client.HTTP    — Production: Finch HTTP requests to real InfluxDB
└── InfluxElixir.Client.Local   — Testing: ETS-backed in-memory storage
```

**The behaviour defines the contract:**

```elixir
defmodule InfluxElixir.Client do
  @moduledoc """
  Behaviour for InfluxDB client implementations.
  """

  @type connection :: term()
  @type query_result :: {:ok, [map()]} | {:error, term()}
  @type write_result :: {:ok, :written} | {:error, term()}

  # Write
  @callback write(connection, binary(), keyword()) :: write_result()

  # Query — v3 SQL (transport: :http | :flight selected via opts)
  @callback query_sql(connection, binary(), keyword()) :: query_result()
  @callback query_sql_stream(connection, binary(), keyword()) :: Enumerable.t()
  @callback execute_sql(connection, binary(), keyword()) :: {:ok, map()} | {:error, term()}

  # Query — v3 InfluxQL
  @callback query_influxql(connection, binary(), keyword()) :: query_result()

  # Query — v2 Flux (compat)
  @callback query_flux(connection, binary(), keyword()) :: query_result()

  # Admin — v3 databases
  @callback create_database(connection, binary(), keyword()) :: :ok | {:error, term()}
  @callback list_databases(connection) :: {:ok, [map()]} | {:error, term()}
  @callback delete_database(connection, binary()) :: :ok | {:error, term()}

  # Admin — v2 buckets (compat)
  @callback create_bucket(connection, binary(), keyword()) :: :ok | {:error, term()}
  @callback list_buckets(connection) :: {:ok, [map()]} | {:error, term()}
  @callback delete_bucket(connection, binary()) :: :ok | {:error, term()}

  # Admin — v3 tokens
  @callback create_token(connection, binary(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback delete_token(connection, binary()) :: :ok | {:error, term()}

  # Health
  @callback health(connection) :: {:ok, map()} | {:error, term()}
end
```

**All library modules use the behaviour, never a concrete implementation directly.** The implementation is selected via configuration.

### LocalClient Implementation

```elixir
defmodule InfluxElixir.Client.Local do
  @moduledoc """
  In-memory InfluxDB client for fast testing.

  Stores data in ETS tables keyed by the calling process,
  enabling safe `async: true` tests with full isolation.

  Parses real line protocol on write, stores points as maps,
  and responds with real InfluxDB response formats on query.
  """

  @behaviour InfluxElixir.Client

  # ETS table per test process: :"influx_local_#{inspect(pid)}"
  # Stores: {database, measurement, tags, fields, timestamp}
end
```

### What the LocalClient Must Do

The LocalClient is a **real implementation**, not a stub. It must:

| Capability | Detail |
|-----------|--------|
| **Parse line protocol** | Accept the same binary format as real InfluxDB. Validate measurement, tags, fields, timestamp. Reject malformed input with the same error format InfluxDB returns. |
| **Store points in ETS** | Per-process ETS tables. Points stored as structured maps with proper types (integers, floats, strings, booleans). |
| **Handle databases** | Create, list, delete databases. Reject writes to non-existent databases (same as real InfluxDB). |
| **Respond to SQL queries** | Parse basic SQL WHERE clauses, ORDER BY, LIMIT. Support `$param` parameter substitution. Return results in the same map format as the JSONL response parser produces. |
| **Return correct status codes** | Write success = `{:ok, :written}`. Unknown database = `{:error, %{status: 404, ...}}`. Malformed line protocol = `{:error, %{status: 400, ...}}`. |
| **Support gzip** | Accept gzipped write bodies, decompress, and store normally. |
| **Handle timestamps** | Store and query with proper timestamp precision handling. |
| **Isolate per-process** | Each test process gets its own ETS state. `async: true` safe. |

### What the LocalClient Does NOT Do

- No SQL aggregation functions (`avg`, `sum`, `date_bin`, etc.) — these test InfluxDB's engine, not our library
- No complex JOIN or subquery support
- No Arrow Flight / gRPC simulation
- No WAL / durability semantics
- No `no_sync` distinction (all writes are immediately visible)

If a test needs aggregation or complex SQL, it should be tagged `:integration` and run against real InfluxDB.

### Process Isolation with ETS

```elixir
# Each test process gets an isolated namespace
defp table_name do
  :"influx_local_#{inspect(self())}"
end

# In test setup:
setup do
  {:ok, conn} = InfluxElixir.Client.Local.start(databases: ["test_db"])
  on_exit(fn -> InfluxElixir.Client.Local.stop(conn) end)
  {:ok, conn: conn}
end
```

This means tests using LocalClient can run with `async: true` — each test process has completely independent state.

### Contract Tests: Proving Fidelity

The critical question: **how do we know the LocalClient behaves like real InfluxDB?**

Answer: **Contract tests** — the same test module runs against both implementations.

```elixir
defmodule InfluxElixir.ContractTest do
  @moduledoc """
  Tests that run against BOTH LocalClient and real InfluxDB.
  Proves that LocalClient responses match real server responses.
  """

  # Runs against LocalClient (always, fast)
  describe "contract: LocalClient" do
    setup do
      {:ok, conn} = InfluxElixir.Client.Local.start(databases: ["contract_db"])
      on_exit(fn -> InfluxElixir.Client.Local.stop(conn) end)
      {:ok, conn: conn, impl: :local}
    end

    # ... shared test cases ...
  end

  # Runs against real InfluxDB (tagged :integration, slow)
  @tag :integration
  describe "contract: HTTP" do
    setup do
      conn = InfluxElixir.Client.HTTP.connect(
        host: System.get_env("INFLUX_HOST"),
        token: System.get_env("INFLUX_TOKEN")
      )
      # Create ephemeral test database
      :ok = InfluxElixir.Client.HTTP.create_database(conn, "contract_db")
      on_exit(fn -> InfluxElixir.Client.HTTP.delete_database(conn, "contract_db") end)
      {:ok, conn: conn, impl: :http}
    end

    # ... same shared test cases ...
  end
end
```

The shared test cases cover:
- Write a point, read it back, verify exact match
- Write multiple points, query with WHERE, verify filtering
- Write with all field types (integer, float, string, boolean), verify round-trip
- Write large integers (> 2^53), verify exact round-trip
- Query with `$param` parameters, verify substitution
- Query with ORDER BY and LIMIT, verify ordering
- Write to non-existent database, verify error format matches
- Send malformed line protocol, verify error format matches
- Health check response format

### Configuration: Switching Implementations

```elixir
# config/config.exs (default: production HTTP client)
config :influx_elixir, :client, InfluxElixir.Client.HTTP

# config/test.exs (test: LocalClient)
config :influx_elixir, :client, InfluxElixir.Client.Local
```

Library code resolves the implementation at runtime:

```elixir
defmodule InfluxElixir do
  defp client do
    Application.get_env(:influx_elixir, :client, InfluxElixir.Client.HTTP)
  end

  def write(conn, points, opts \\ []) do
    client().write(conn, points, opts)
  end
end
```

### Test Helper for Consuming Apps

The library ships a test helper that consuming apps can use:

```elixir
# In consuming app's test/test_helper.exs:
InfluxElixir.TestHelper.setup_local()

# Or in individual test modules:
use InfluxElixir.TestCase
```

This is exposed via the `usage-rules/testing.md` sub-rule so consuming apps' LLM agents know how to set up tests correctly.

### Testing Pyramid

```
                    /\
                   /  \     Integration Tests (tagged :integration)
                  /    \    — Real InfluxDB via Docker (local only, NOT in CI)
                 /------\   — Contract tests prove LocalClient fidelity
                / Local  \  — Run explicitly: mix test --include integration
               / Client   \
              /   Tests     \  Unit Tests (default, fast)
             /               \ — LocalClient for write/query/admin
            /                 \— Pure function tests for encoding/parsing
           /___________________\— async: true, no external deps
```

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

## Consuming Application Analysis (Migration Context)

This section documents the consuming application's current InfluxDB usage. This is **not** code that lives in this library — it is the context that informs what the library must support.

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

### Decision 1: HTTP + Arrow Flight (Both Required)

- **Rationale**: HTTP (JSON/JSONL/CSV) is sufficient for the trading app's workloads (point lookups, bounded time ranges, streaming). However, a second consuming application requires bulk data migration from Postgres to InfluxDB — millions of rows — where Arrow Flight's zero-copy columnar transfer is essential for performance. Both transports must be first-class.
- **HTTP**: Default transport. JSONL streaming for large result sets. Simpler to use for typical query patterns.
- **Arrow Flight**: gRPC-based transport returning streaming Apache Arrow record batches. Used for bulk data operations where serialization overhead matters. Requires `elixir-grpc/grpc` + Arrow IPC decoding.
- **Implementation**: The `InfluxElixir.Client` behaviour includes both HTTP and Flight query paths. Consumers choose per-query: `InfluxElixir.query_sql(:conn, sql, transport: :http)` (default) or `transport: :flight`. The facade abstracts the transport — same result format regardless of transport used.

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
- **Events**: `[:influx_elixir, :write, :start | :stop | :exception]`, `[:influx_elixir, :query, :start | :stop | :exception]`

### Decision 6: Server-Side Aggregation via Processing Engine

- **Context**: v2 used Flux tasks for server-side data aggregation (e.g., rolling up raw prices into OHLCV candles at multiple timeframes). v3 replaces Flux tasks with the Processing Engine (Python plugins triggered on WAL flush, on cron schedule, or on demand).
- **Options considered**:
  1. **Elixir-side aggregation**: Pull raw data out to Elixir GenServers, aggregate, write back. Full control but adds network round-trips and load on both Elixir and InfluxDB.
  2. **Processing Engine (Python plugins)**: Aggregation runs inside InfluxDB's process, operates directly on data without network overhead. Python is isolated to declarative aggregation logic only.
  3. **Scheduled SQL queries via Elixir (Quantum)**: Elixir triggers `INSERT INTO ... SELECT ... GROUP BY time(5m)` on a schedule. Middle ground — SQL is clean but still has network round-trip.
- **Decision**: Performance is the driving factor. For pure data aggregation (OHLCV rollups, downsampling), the Processing Engine is the right tool — the data never leaves InfluxDB. This is functionally identical to how Flux tasks worked in v2: server-side scheduled data processing. The Python is limited to simple, declarative aggregation logic — not application business logic.
- **Elixir's role**: Elixir handles everything that IS business logic — signal generation, risk management, strategy execution. InfluxDB handles what IS data plumbing — rollups, downsampling, retention.
- **Library implication**: The client library should support deploying and managing Processing Engine plugins via the InfluxDB API if management endpoints are available. At minimum, provide documentation on how to set up aggregation plugins alongside the Elixir application.

### Decision 7: Behaviour-Based Client Adapter (LocalClient)

- **Rationale**: Testing against real InfluxDB is correct but slow. A behaviour-based adapter pattern lets us ship a `LocalClient` that stores data in ETS and responds identically to real InfluxDB. Contract tests verify fidelity. No mocking libraries.
- **Implementation**: `InfluxElixir.Client` behaviour with `HTTP` and `Local` implementations. Config-driven selection. Per-process ETS isolation for `async: true` tests.
- **Guarantee**: Contract tests run the exact same assertions against both LocalClient and real InfluxDB. If LocalClient diverges from real behavior, CI catches it.

### Decision 8: Facade Pattern — Single Public Entry Point

- **Rationale**: Consumers should never need to reach into submodules. `InfluxElixir` is the only module consumers interact with. Internal modules (`Client.HTTP`, `Client.Local`, `Write.BatchWriter`, etc.) are implementation details.
- **Implementation**: `InfluxElixir` delegates to internal modules. Public API includes:
  - **Write**: `point/3`, `write/2`, `write/3`
  - **Query (v3)**: `query_sql/2`, `query_sql/3` (accepts `transport: :http | :flight`), `query_sql_stream/2`, `query_sql_stream/3`, `execute_sql/2`, `execute_sql/3`
  - **Query (v3 InfluxQL)**: `query_influxql/2`, `query_influxql/3`
  - **Query (v2 Flux)**: `query_flux/2`
  - **Admin (v3)**: `create_database/2`, `list_databases/1`, `delete_database/2`
  - **Admin (v2)**: `create_bucket/2`, `list_buckets/1`, `delete_bucket/2`
  - **Admin (tokens)**: `create_token/2`, `delete_token/2`
  - **Health**: `health/1`
  - **Batch writer**: `flush/1`, `stats/1` — these operate on the library's built-in `BatchWriter` layer that sits above the `Client` behaviour, so they work regardless of which client implementation is used
  - **Connections**: `add_connection/2`, `remove_connection/1`
- **Exception**: The `InfluxElixir.Client` behaviour is public for consumers who need custom client implementations. `InfluxElixir.TestHelper` is public for test setup in consuming apps. Internal library tests (e.g., contract tests) may call client implementations directly — this is intentional and does not apply to consuming app code.
- **Arrow Flight transport**: Selected per-query via the `transport: :http | :flight` option, not via separate facade functions. The `Client` behaviour callbacks handle both transports internally — `query_sql/3` receives the transport option and routes accordingly.

### Decision 9: UsageRules for LLM Agent Guidance

- **Rationale**: LLM agents (Claude Code, Copilot, etc.) need accurate guidance for using libraries. `usage_rules` is the standard Elixir tool for this. Publishing usage rules with the hex package means consuming apps automatically get correct guidance.
- **Implementation**: `usage-rules.md` + `usage-rules/` directory shipped with hex package. Sub-rules for write, query, and testing patterns.

---

## Supervision Tree Architecture

The library manages its own supervision tree. The consuming app starts it as a child — the library handles everything below that.

### Tree Structure

```
InfluxElixir.Application
└── InfluxElixir.Supervisor (top-level, :one_for_one)
    │
    ├── InfluxElixir.ConnectionSupervisor (:trading)    ← :rest_for_one
│   ├── Finch pool (:trading_finch)                 ← HTTP connection pool
│   ├── InfluxElixir.Write.BatchWriter (:trading, "prices")
│   ├── InfluxElixir.Write.BatchWriter (:trading, "candles")
    │   └── InfluxElixir.Write.BatchWriter (:trading, "strategy_trades")
    │
    ├── InfluxElixir.ConnectionSupervisor (:analytics)  ← :rest_for_one
    │   ├── Finch pool (:analytics_finch)
    │   ├── InfluxElixir.Write.BatchWriter (:analytics, "indicators")
    │   ├── InfluxElixir.Write.BatchWriter (:analytics, "signals")
    │   └── InfluxElixir.Write.BatchWriter (:analytics, "backtests")
    │
    └── (additional connections added dynamically)
```

### Why This Structure

| Design Choice | Rationale |
|--------------|-----------|
| **Top-level `:one_for_one`** | Connection crash isolation. Trading connection dying must NOT restart analytics connection. |
| **Per-connection `:rest_for_one`** | If a Finch pool crashes, all BatchWriters under that connection must restart (they depend on the pool). But a single BatchWriter crash does NOT take down the pool or sibling writers. |
| **Finch pool per connection** | Each InfluxDB instance gets its own HTTP connection pool with independent sizing, timeouts, and failure state. |
| **BatchWriter per connection+database** | Independent flush cycles, retry state, and backpressure per database. A stalled flush on `prices` must not block `strategy_trades`. |

### Key Modules

**`InfluxElixir.Application`** — OTP Application entry point:
```elixir
defmodule InfluxElixir.Application do
  use Application

  @impl true
  def start(_type, _args) do
    connections = Application.get_env(:influx_elixir, :connections, [])
    InfluxElixir.Supervisor.start_link(connections: connections)
  end
end
```

**`InfluxElixir.Supervisor`** — Top-level supervisor:
```elixir
defmodule InfluxElixir.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    connections = Keyword.fetch!(opts, :connections)

    children =
      Enum.map(connections, fn {name, config} ->
        {InfluxElixir.ConnectionSupervisor, Keyword.put(config, :name, name)}
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

**`InfluxElixir.ConnectionSupervisor`** — Per-connection supervisor:
```elixir
defmodule InfluxElixir.ConnectionSupervisor do
  use Supervisor

  def start_link(config) do
    name = Keyword.fetch!(config, :name)
    Supervisor.start_link(__MODULE__, config, name: via(name))
  end

  @impl true
  def init(config) do
    name = Keyword.fetch!(config, :name)
    finch_name = :"influx_elixir_#{name}_finch"

    children = [
      # Finch pool MUST start first — BatchWriters depend on it
      {Finch, name: finch_name, pools: finch_pools(config)},
      # BatchWriters started per-database (if configured)
      # Can also be added dynamically via DynamicSupervisor
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

### Consumer Usage

```elixir
# config/config.exs
config :influx_elixir, :connections,
  trading: [
    host: "influx-trading:8086",
    token: "...",
    default_database: "prices",
    pool_size: 10,
    batch_writers: [
      prices: [database: "prices", batch_size: 5_000, no_sync: true],
      candles: [database: "candles", batch_size: 5_000],
      trades: [database: "strategy_trades", batch_size: 1_000, no_sync: false]
    ]
  ],
  analytics: [
    host: "influx-analytics:8086",
    token: "...",
    default_database: "indicators",
    pool_size: 5,
    batch_writers: [
      indicators: [database: "indicators", batch_size: 5_000, no_sync: true],
      signals: [database: "signals", batch_size: 5_000, no_sync: true]
    ]
  ]
```

The library starts automatically via OTP application. No manual supervisor wiring needed in the consuming app — just configuration.

### Dynamic Connection Management

For cases where connections need to be added/removed at runtime:

```elixir
# Add a new connection at runtime
InfluxElixir.add_connection(:backtest, host: "localhost:8086", token: "...")

# Remove a connection (stops its entire subtree)
InfluxElixir.remove_connection(:backtest)
```

This uses `Supervisor.start_child/2` and `Supervisor.terminate_child/2` on the top-level supervisor.

---

## Library Module Architecture

```
influx_elixir/
├── lib/
│   ├── influx_elixir.ex                    # Public API facade
│   ├── influx_elixir/
│   │   ├── application.ex                  # OTP Application entry point
│   │   ├── supervisor.ex                   # Top-level supervisor (:one_for_one)
│   │   ├── connection_supervisor.ex        # Per-connection supervisor (:rest_for_one)
│   │   │
│   │   ├── client.ex                       # Client behaviour definition
│   │   ├── client/
│   │   │   ├── http.ex                     # Production: Finch HTTP to real InfluxDB
│   │   │   └── local.ex                    # Testing: ETS-backed in-memory
│   │   ├── connection.ex                   # Named connection manager (multi-instance)
│   │   ├── config.ex                       # Connection configuration + validation
│   │   │
│   │   ├── write/
│   │   │   ├── line_protocol.ex            # Line protocol encoder
│   │   │   ├── point.ex                    # Point struct
│   │   │   ├── writer.ex                   # Direct write (single request)
│   │   │   └── batch_writer.ex             # GenServer batch writer with flush/retry
│   │   │
│   │   ├── query/
│   │   │   ├── sql.ex                      # v3 SQL query builder + executor
│   │   │   ├── sql_stream.ex               # Streaming JSONL query results (lazy Stream)
│   │   │   ├── influxql.ex                 # v3 InfluxQL query executor
│   │   │   ├── flux.ex                     # v2 Flux query executor (compat)
│   │   │   └── response_parser.ex          # JSONL/CSV/JSON response parsing
│   │   │
│   │   ├── admin/
│   │   │   ├── databases.ex                # v3 database CRUD
│   │   │   ├── buckets.ex                  # v2 bucket CRUD (compat)
│   │   │   ├── tokens.ex                   # v3 token management
│   │   │   └── health.ex                   # Health/ping checks
│   │   │
│   │   ├── telemetry.ex                    # Telemetry event emission
│   │   └── test_helper.ex                  # Helpers for consuming app tests
│
├── test/
│   ├── influx_elixir/
│   │   ├── client/
│   │   │   └── local_test.exs              # LocalClient behaviour verification
│   │   ├── write/
│   │   │   ├── line_protocol_test.exs
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
│   ├── integration/                        # Against real InfluxDB (tagged)
│   │   ├── write_integration_test.exs
│   │   ├── query_integration_test.exs
│   │   └── contract_test.exs              # Same tests, both implementations
│   ├── support/
│   │   └── influx_case.ex                  # Shared test case template
│   └── test_helper.exs
│
├── usage-rules.md                          # Main usage rules for consumers
├── usage-rules/
│   ├── write.md
│   ├── query.md
│   └── testing.md
│
├── mix.exs
├── .formatter.exs
├── .credo.exs
├── .tool-versions                          # Mise: elixir, erlang, nodejs versions
├── .gitignore
├── README.md
├── LICENSE
├── CHANGELOG.md
├── CLAUDE.md
├── AGENTS.md                               # Generated by usage_rules
└── .github/workflows/ci.yml
```

### Dependencies

```elixir
defp deps do
  [
    # Runtime — HTTP
    {:finch, "~> 0.18"},           # HTTP client
    {:jason, "~> 1.4"},            # JSON encoding/decoding
    {:nimble_csv, "~> 1.2"},       # CSV parsing (query responses)
    {:telemetry, "~> 1.0"},        # Observability
    {:nimble_options, "~> 1.0"},   # Config validation

    # Runtime — Arrow Flight
    {:grpc, "~> 0.11"},            # gRPC client for Arrow Flight
    {:protobuf, "~> 0.12"},        # Protobuf encoding (Flight protocol)

    # Dev only
    {:usage_rules, "~> 1.2", only: :dev},
    {:ex_doc, "~> 0.34", only: :dev, runtime: false},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
  ]
end
```

Zero legacy deps. Zero mocking libs. HTTP + gRPC. Everything modern and maintained.

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
InfluxElixir.query_sql(client, "SELECT * FROM prices WHERE time > now() - interval '1 hour'")

# Parameterized query (safe from injection)
InfluxElixir.query_sql(client,
  "SELECT * FROM prices WHERE symbol = $symbol AND time > $start",
  params: %{symbol: "BTC-USD", start: ~U[2026-03-12 00:00:00Z]}
)

# With format option
InfluxElixir.query_sql(client, query, format: :jsonl)  # :json | :jsonl | :csv | :parquet
```

Response: parsed into list of maps (from JSONL) or raw string (CSV/Parquet).

### Streaming SQL Query

```elixir
# Returns a lazy Stream — parses JSONL chunks as they arrive
stream = InfluxElixir.query_sql_stream(client,
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
InfluxElixir.execute_sql(client,
  "DELETE FROM candles WHERE timeframe = '1m' AND time < $cutoff",
  params: %{cutoff: ~U[2026-02-10 00:00:00Z]},
  database: "candles"
)

# INSERT INTO ... SELECT — used for server-side aggregation fallback
InfluxElixir.execute_sql(client, """
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
InfluxElixir.query_influxql(client,
  "SELECT mean(price) FROM prices WHERE symbol = $symbol AND time > now() - 1h GROUP BY time(5m)",
  params: %{symbol: "BTC-USD"}
)
```

### Database Management

```elixir
InfluxElixir.create_database(client, "prices", retention_period: "30d")
InfluxElixir.list_databases(client)
InfluxElixir.delete_database(client, "prices")
```

### v2 Compatibility

```elixir
# Configure for v2
client = InfluxElixir.client(host: "localhost", token: "...", api_version: :v2, org: "myorg")

# Write uses /api/v2/write
InfluxElixir.write(client, points, bucket: "prices")

# Query uses /api/v2/query with Flux
InfluxElixir.query_flux(client, ~s|from(bucket: "prices") |> range(start: -1h)|)
```

---

## Feature Matrix

| Feature | Instream (v2) | InfluxElixir Target |
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
| Arrow Flight gRPC | No | **Yes (bulk data transport)** |
| Parquet response format | No | **Yes (raw binary for S3/Athena/Explorer)** |
| Streaming query results | No | **Yes (lazy Stream from JSONL)** |
| SQL DELETE/INSERT INTO | No | **Yes (execute_sql for non-SELECT)** |
| Large integer fidelity | Unknown | **Yes (Money-precision round-trip)** |
| Processing Engine management | No | **Yes (if API exists, else docs)** |
| LocalClient for testing | No | **Yes (ETS-backed, no mocking)** |
| UsageRules for consumers | No | **Yes (usage-rules.md shipped with package)** |

---

## Performance Targets

Based on InfluxDB v3 recommendations and consuming application requirements:

| Metric | Target |
|--------|--------|
| Write throughput | 50,000+ points/second (batched, gzipped) |
| Write latency (batch) | < 100ms per batch flush |
| Query latency (simple) | < 50ms for recent data (< 1hr window) |
| Query latency (aggregate) | < 500ms for daily aggregations |
| Memory (batch buffer) | < 10MB for 10,000 point buffer |
| Connection pool | Configurable, default 10 connections |
| Gzip ratio | 3-5x compression on line protocol |
| LocalClient test speed | < 1ms per write/query operation |

---

## Requirements From Consuming Application

These are the specific needs from a real-world consuming application (trading system). These requirements **directly inform what the library must support** — they represent concrete use cases, not hypotheticals.

### Write Requirements

| Requirement | Data Type | Volume | Database | Plan |
|-------------|-----------|--------|----------|------|
| Price tick writes | `prices` measurement | ~40 pts/sec (4 exchanges x 10 symbols) | `prices` | Existing |
| Orderbook snapshots | `orderbooks` measurement, top 20 levels per symbol | ~400 pts/sec (20 levels x 10 symbols, every 30s) | `prices` | Existing |
| OHLCV candle writes | `candles` measurement at 6 timeframes | ~1 pt/sec (server-side aggregation writes) | `candles` | 020 |
| Indicator snapshots | `indicators` measurement, 12+ indicators per symbol | ~20 pts every 30s (10 symbols x 2 per flush) | `indicators` | 021 |
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
- [ ] Telemetry events: `[:influx_elixir, :write, :start | :stop | :exception]` with metadata (database, point_count, bytes, compressed_bytes)
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
- [ ] Result mapping to Elixir maps with proper type coercion (timestamps -> DateTime, numbers -> Decimal/float)
- [ ] Database selection per query (queries hit different databases)
- [ ] **Streaming query API**: `query_sql_stream(conn, sql, opts)` returning a `Stream` that lazily parses JSONL response chunks. Critical for backtest data loading (loading 6+ months of candle data into memory all at once is not feasible). Also useful for large equity curve queries.
- [ ] **SQL DELETE support**: `execute_sql(conn, sql, opts)` for non-SELECT statements. Needed for candle retention cleanup.
- [ ] **INSERT INTO ... SELECT support**: General SQL execution covers this. Needed as fallback for Elixir-side candle aggregation.

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
  - Raw prices -> 1m candles (cron every 1m or WAL flush trigger)
  - 1m -> 5m, 15m, 1h candles (cron at respective intervals)
  - 1h -> 4h, 1d candles (cron at respective intervals)
- [ ] **Plugin health monitoring**: if the library can query plugin status, expose it through the health check API so the application can detect stalled aggregation

### Multi-Instance & Multi-Database Support

The consuming application requires **two separate InfluxDB v3 instances** — one for mission-critical trading data, one for analytics/signals. The library must support connecting to multiple independent InfluxDB instances simultaneously.

#### Connection Overhead & Recommended Limits

Each named connection carries real resource cost. Use HTTP/2 for all connections (mandatory for Arrow Flight, beneficial for HTTP too — single multiplexed TCP connection vs 50 HTTP/1 connections).

**Per named connection memory breakdown:**

| Component | Memory | Notes |
|-----------|--------|-------|
| Finch HTTP/2 pool (1x1) | 1–2.5 MB | Primarily TCP socket buffers. HTTP/2 multiplexes over single connection. |
| BatchWriter GenServer (5K buffer) | 2.5–3 MB | Scales with point size and buffer depth. Hibernate after flush to reclaim heap. |
| gRPC channel (Arrow Flight) | 1–2.5 MB | HTTP/2 based, single multiplexed connection. Only if Flight is configured. |
| ConnectionSupervisor + Registry | ~10 KB | Negligible. |
| **Total per connection** | **4.5–8.5 MB** | Without Flight: 4.5–5.5 MB. With Flight: 6–8.5 MB. |

**Recommended limits:**

| Available Memory | Max Named Connections | Use Case |
|-----------------|----------------------|----------|
| 64 MB | 3–5 | Small/embedded deployments |
| 128 MB | 7–12 | Typical single-app server |
| 256 MB | 20–25 | Multi-instance production |
| 512 MB+ | 50+ | Enterprise, many isolated instances |

**Recommended default maximum: 20 named connections.** Enforced via NimbleOptions validation with an override escape hatch (`max_connections: 50`).

**Critical optimizations (applied by default):**
- **HTTP/2 pools**: `size: 1, count: 1, protocol: :http2` — saves 50x memory vs HTTP/1 defaults
- **BatchWriter hibernation**: Return `:hibernate` after flush — saves 20–40% heap per writer
- **Socket buffer tuning**: Configurable `sndbuf`/`recbuf` to reduce TCP overhead from 2.5 MB to 256 KB per connection

**Library requirements**:
- [ ] **Named client connections**: Support multiple named clients, each pointing to a different InfluxDB instance with independent host/token/config
  ```elixir
  # Application config
  config :influx_elixir, :connections,
    trading: [host: "influx-trading:8086", token: "...", default_database: "prices"],
    analytics: [host: "influx-analytics:8086", token: "...", default_database: "indicators"]
  ```
- [ ] **Per-connection batch writers**: Each named connection gets its own batch writer GenServer with independent flush cycles, retry state, and backpressure
- [ ] **Connection routing on write**: `InfluxElixir.write(:trading, points, database: "candles")` — first arg selects the instance
- [ ] **Connection routing on query**: `InfluxElixir.query_sql(:analytics, query, database: "signals")` — same pattern
- [ ] **Independent health checks**: Each connection has its own health status. Trading instance down != analytics instance down.
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

---

## Open Questions

1. ~~**Library name**~~: **Resolved** — `influx_elixir` / `InfluxElixir`
2. ~~**Arrow Flight priority**~~: **Resolved** — include from the start. Second consuming app (Postgres→InfluxDB data migration, millions of rows) requires bulk transport.
3. ~~**v2 compat scope**~~: **Resolved** — Full v2 support. This library will be used to migrate from v2 to v3, so everything needed for that migration must work: v2 write API, Flux queries, bucket CRUD, and data export/import. Org-scoped auth is handled by the `api_version: :v2` config option, which automatically adds the `org=` parameter to v2 API URLs.
4. ~~**Processing Engine integration**~~: Addressed — see Processing Engine Requirements section above. Library will support management API if v3 exposes endpoints, else provide documentation and example plugins.
5. ~~**Parquet response parsing**~~: **Resolved** — Required. Parquet query responses enable direct export to S3 for AWS Athena consumption, plus Nx/Explorer integration. The library must support `format: :parquet` on queries and return raw Parquet binary that can be written directly to S3 or parsed via Explorer.
6. ~~**v3 Enterprise vs Core**~~: **Resolved** — Must work on both. The library will be used with both Core and Enterprise. API is identical, only limits differ. Documentation should note Enterprise-specific limits (higher DB counts, table counts, etc.).
7. **LocalClient SQL subset**: Initial scope: WHERE with `=`, `>`, `<`, `>=`, `<=`, `AND`; ORDER BY; LIMIT; `$param` substitution. No aggregation functions, no JOINs. Tag complex queries as `:integration`. Will evolve as the system evolves.

---

**Document Status**: Draft v2 — added Phase 0 bootstrap, UsageRules, LocalClient
**Last Updated**: 2026-03-13
**Next Steps**: Review and approve design, then begin Phase 0 bootstrap implementation
