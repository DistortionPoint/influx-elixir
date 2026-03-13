# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`influx_elixir` is an open-source Elixir client library for InfluxDB v3 (with v2 compatibility). It provides HTTP-based write, query, and admin APIs using modern Elixir dependencies (Finch, Jason, Telemetry). This is a **library** (not an application) — it is designed to be consumed as a dependency by other Elixir projects.


## Essential Commands

**ABSOLUTE RULES**:
***THIS IS ELIXIR. It is Functional, Parallel, and Concurrent. You CAN NOT treat this like Python, Ruby, or Javascript.
1. ALL operations MUST be concurrent/parallel in a single message
2. Prefer Agents over MCPs
3. **NEVER save working files, text/mds and tests to the root folder**
4. ALWAYS organize files in appropriate subdirectories
5. ALWAYS do CI Checks before COMMIT
6. NEVER PUSH without confirmation
7. ALL Credo issues must pass. Not just some, not just critical, ALL.
8. ALL tests must pass. 0 Failures allowed.
9. NEVER USE THE SYSTEM TMP (/tmp) USE APPLICATION TMP (tmp/)
10. NEVER USE PERL
11. There is no such thing as a Pre-existing test Failure

**DEEP ELIXIR ARCHITECTURE**:
1. https://variantsystems.io/blog/beam-otp-process-concurrency
2. https://medium.com/@EliasWalyBa/what-elixir-taught-me-about-design-patterns-0ee9363bd52a
3. ../docs Various Elixir Books

### Development
```bash
mix deps.get            # Fetch dependencies
mix compile             # Compile the library
iex -S mix              # Start interactive shell with library loaded
```

### Testing & Quality
```bash
mix test                    # Run tests
mix test --cover            # Run tests with coverage
mix quality                 # Run all quality checks (format, credo, dialyzer, sobelow)
mix credo --strict          # Code analysis
mix dialyzer                # Type checking
mix format                  # Format code
```

### Publishing
```bash
mix hex.build               # Build hex package (dry run)
mix hex.publish              # Publish to hex.pm
mix docs                    # Generate ExDoc documentation
```

## Architecture

### Library Structure
This is a library, not an OTP application. Key distinctions:
- **No `application.ex`** supervision tree started by default
- Consumers start their own Finch pools and optionally supervised batch writers
- All modules are designed for embedding into consumer supervision trees

### Module Organization
```
lib/influx_elixir.ex                    # Public API facade
lib/influx_elixir/
├── client.ex                           # HTTP client (Finch wrapper)
├── connection.ex                       # Named connection manager
├── config.ex                           # Connection configuration
├── write/
│   ├── line_protocol.ex                # Line protocol encoder
│   ├── point.ex                        # Point struct
│   ├── writer.ex                       # Direct write (single request)
│   └── batch_writer.ex                # GenServer batch writer with flush/retry
├── query/
│   ├── sql.ex                          # v3 SQL query builder + executor
│   ├── sql_stream.ex                   # Streaming JSONL query results
│   ├── influxql.ex                     # v3 InfluxQL query executor
│   ├── flux.ex                         # v2 Flux query executor (compat)
│   └── response_parser.ex             # JSONL/CSV/JSON response parsing
├── admin/
│   ├── databases.ex                    # v3 database CRUD
│   ├── buckets.es                      # v2 bucket CRUD (compat)
│   ├── tokens.ex                       # v3 token management
│   └── health.ex                       # Health/ping checks
└── telemetry.ex                        # Telemetry event emission
```

### Key Patterns
1. **HTTP-Only (initially)**: Finch-based HTTP client, no Arrow Flight gRPC yet
2. **Batch Writer GenServer**: Optional supervised process for buffered writes with flush/retry
3. **Parameterized Queries**: SQL/InfluxQL with `$param` placeholders — no string interpolation
4. **Streaming Results**: Lazy `Stream` from JSONL responses for large result sets
5. **Multi-Instance Support**: Named connections to multiple InfluxDB instances
6. **Telemetry Integration**: Standard `[:influx_elixir, :write|:query, :start|:stop|:exception]` events

### Dependencies
- **Finch** — HTTP client (Mint + NimblePool)
- **Jason** — JSON encoding/decoding
- **NimbleCSV** — CSV parsing (query responses)
- **Telemetry** — Observability
- **NimbleOptions** — Config validation (optional)

No legacy deps. No hackney, poolboy, or HTTPoison.

## Testing Strategy

- Unit tests for line protocol encoding, point construction, response parsing
- Integration tests against a real InfluxDB v3 instance (tagged, skippable)
- **NO MOCKING** — never use Mox, Bypass, or any mocking library
- Integration tests against a real InfluxDB v3 instance
- Test helpers for consumers to use in their own test suites
- 95%+ coverage target

## Code Quality Requirements

### Coverage & Documentation
- **Test Coverage**: Minimum 95% for all new code
- **Documentation**: All public functions must have `@doc` and `@spec`
- **Formatting**: Always run `mix format` before committing

### Elixir-Specific Standards
- **Line Length**: 98 characters maximum
- **Indentation**: 2 spaces, no tabs
- **Error Handling**: Use tagged tuples (`{:ok, result}` or `{:error, reason}`)
- **Pattern Matching**: Prefer pattern matching over conditional logic
- **Pipe Usage**: Use pipes `|>` for readability when chaining 3+ operations

### Library-Specific Standards
- **No side effects on load**: Library must not start processes or make connections on compile/load
- **Configurable**: All behavior configurable by the consumer, no hardcoded defaults that can't be overridden
- **Minimal dependencies**: Only add deps that are truly necessary
- **Backwards compatibility**: Follow semantic versioning strictly

## Critical Development Principles

### Test-First Completion Standard
**CRITICAL: Work is NOT complete until ALL tests pass - no exceptions**
- Maintain green test suite at all times
- Test failures provide immediate feedback on current changes
- Never mark work as complete with failing tests
- Run `mix test` before considering any task done

### Definition of "Done"
**CRITICAL: Work is only considered complete when ALL of the following criteria are met:**

1. **All tests are passing** - Run `mix test` and ensure 100% test pass rate
2. **Credo passes** - Run `mix credo --strict` with no warnings or errors
3. **Dialyzer passes** - Run `mix dialyzer` with no critical type errors
4. **Code is formatted** - Run `mix format` before committing
5. **Documentation** - All public functions have `@doc` and `@spec`

### Work Principles
1. **Minimal Task Granularity**: Create smallest possible subtasks to preserve context
2. **Single Responsibility**: Each subtask accomplishes one specific goal
3. **Temporary Script Cleanup**: Delete all temporary scripts before completing work
4. **Clear Communication**: Ask for clarification rather than making assumptions

## Document Driven Design (DDD) Philosophy
- **Documentation First**: All implementation must be preceded by approved design documentation
- **Living Documentation**: Documentation evolves with the codebase and remains current
- **Collaborative Design**: Design documents created through User-Assistant collaboration
- **Implementation Traceability**: Every line of code maps back to design requirements

## Documentation Standards

The project maintains comprehensive documentation in the `/docs` directory. Each subdirectory contains a README.md with specific guidelines.

### Documentation Structure
- **`/docs/architecture/`** - System design, technical specs, decision records
- **`/docs/design/`** - Collaborative design documents and implementation planning
- **`/docs/api/`** - API reference, endpoints, integration guides
- **`/docs/development/`** - Setup instructions, coding standards, testing

### Design Document Format
Design documents follow the naming convention: `YYYY-MM-DD_design-topic-name.md`
- Use the template at `/docs/design/templates/design-document-template.md`
- Include matching code samples in `YYYY-MM-DD_design-topic-name/` directory
- Follow the collaborative design workflow (initiation → design → planning → review → implementation)

### Documentation Guidelines
- Use kebab-case for filenames (e.g., `line-protocol-encoding.md`)
- Include working code examples
- Keep synchronized with implementation
- Add README.md in each new directory
- Test all instructions before documenting
- Use consistent heading structure (H1 for title, H2 for sections)

### No Build Process Required
Documentation is static Markdown - no special build tools needed. View directly in GitHub or any Markdown viewer.
