---
trigger: always_on
description: Core InfluxElixir project rules, architecture, hygiene, and workflow standards
---

# InfluxElixir Project Rules

## Execution & Repository Hygiene

1. **Batch Operations**: Always batch parallel tool calls, file reads, searches, and edits in a single turn whenever possible (except test runs, which are strictly sequential — one at a time).
2. **Clean Root Directory**: NEVER save working files, scratch scripts, temporary markdowns, or test files to the root folder.
3. **Temporary Files**: NEVER use the system `/tmp` directory. Always use the project's `tmp/` directory (`/Volumes/Dev/development/influx-elixir/tmp/`, which is gitignored) and clean up temporary subdirectories after use.
4. **Native Tooling Only**: NEVER use Perl or Python. Use Elixir, Mix tasks, or built-in tools for all scripting, data inspection, and code manipulation. Use file edit tools (`replace_file_content` / `write_to_file`) for multi-line edits in `CHANGELOG.md` and docs — never inline `~S"""` heredoc scripts.
5. **Check Before Creating Files**: Always check if a target path already exists before creating a new file (especially `*_test.exs`), and compare unit test counts before and after changes so an existing test file is never accidentally overwritten.
6. **Fix All Bugs Found**: Fix every bug discovered during a pass immediately in the same pass — never just report it or defer it as a follow-up.
7. **Never Ask What Rules Answer**: Do not ask the user option-menu questions when project rules, existing design docs, or real InfluxDB engine behavior already answer the question. Treat settled issues as settled.
8. **Standing Rules Discipline**: Never add references to individual work items or single design documents in standing rule files (`CLAUDE.md`, `AGENTS.md`, `.agents/rules/*.md`).
9. **Domain Reference**: Consult [`usage-rules.md`](file:///Volumes/Dev/development/influx-elixir/usage-rules.md) and [`usage-rules/`](file:///Volumes/Dev/development/influx-elixir/usage-rules/testing.md) (`testing.md`, `write.md`, `query.md`) for detailed `InfluxElixir` and `Client.Local` behaviour rules.
10. **Workspace Scope Boundary**: Never inspect or read files from sibling repositories outside `/Volumes/Dev/development/influx-elixir` unless explicitly instructed to do so by the user.

## Test & Quality Command Execution

- Run `mix` commands directly (never via `mise exec --`):
  - Unit tests with coverage: `MIX_ENV=test mix test --cover` (or `mix test --cover`)
  - Unit tests: `mix test`
  - Single test file / line: `mix test test/path/to/test.exs` / `mix test test/path/to/test.exs:123`
  - Test-env compilation: `MIX_ENV=test mix compile --force --warnings-as-errors`
  - Full quality check: `mix quality`
- Note: In non-interactive shells where `~/.zshrc` has not been sourced yet, ensure `~/.zshrc` is sourced in the persistent terminal session so `mix`, `elixir`, and `erl` are on `PATH`.

## Docker & External Services

- **NEVER run `docker` or `docker-compose` commands** (`docker ps`, `docker run`, `docker exec`, `docker stop`, `docker-compose`, etc.). The user manages all Docker containers externally.
- To check if a service is available or to probe engine behavior, use `curl` against the running endpoints; if a container needs starting, restarting, or reconfiguring, ask the user.
- Standard local dev services:
  - **InfluxDB v2** (`http://localhost:8086`): token `dev-influx-token-123456789`, org `dev-influx`, bucket `metrics`
  - **InfluxDB v3 Core** (`http://localhost:8181`)
  - **InfluxDB v3 Enterprise (Trading)** (`http://localhost:8182`)
  - **InfluxDB v3 Enterprise (Analytics)** (`http://localhost:8183`)

## Git, Releases & Documentation Hygiene

- **Git & CI Safety**: **NEVER** push to git (`git push` is strictly forbidden — the user handles all pushes; do not run or offer `git push`). Never commit to git without explicit user confirmation.
  - **CRITICAL**: Pushing to `main` triggers `.github/workflows/ci.yml`, which automatically bumps the patch version in `mix.exs`, dates `CHANGELOG.md`, commits back to `main`, and publishes a new release to Hex.pm.
  - **Doc-Only Commits**: Any commit containing only documentation or markdown changes must include `[skip ci]` in the commit message so CI does not cut an empty Hex release.
  - **Sync Before Sweeps**: Before starting a sweep or updating `CHANGELOG.md`, run `git fetch` and `git log HEAD..origin/main` to check if CI published a `Release v...` commit and reconcile `(unreleased)` markers.
  - **Commit Carries Everything**: When committing (with user confirmation), stage the entire working tree (`git add -A`) so pre-existing working tree changes are never left behind.
  - **One PR for All Open Issues**: When resolving open GitHub issues, resolve all open issues in a single PR rather than proposing to split by risk.
- **Docs Are First-Class**: Stale documentation, `README.md`, `CHANGELOG.md`, or `usage-rules/` entries are bugs and must be fixed immediately alongside code changes.

## Project Overview & Context

`influx_elixir` (`InfluxElixir`) is a production-grade Elixir client library for InfluxDB supporting v2.x and v3.x (Core and Enterprise) via a behaviour-driven architecture with zero global state.
- **Repository**: `https://github.com/DistortionPoint/influx-elixir`
- **Primary Consuming Workloads**:
  1. High-throughput trading system (real-time market data ingestion + SQL/Flux analytics).
  2. Postgres-to-InfluxDB migration tool (high-throughput batch writing + Arrow Flight verification queries).

### Core Architectural Principles

- **Behaviour-Driven Client (`InfluxElixir.Client`)**:
  - `InfluxElixir.Client.HTTP` — Production Finch-based HTTP/1.1 & HTTP/2 client (plus `InfluxElixir.Flight.Client` for Arrow Flight SQL over gRPC/HTTP2).
  - `InfluxElixir.Client.Local` — Real ETS-backed in-memory implementation of InfluxDB v2 and v3 (Line Protocol v2/v3 parser, SQL parser/planner/executor, InfluxQL parser/planner/executor, Flux parser/evaluator, databases, buckets, retention, and tokens).
- **NO Mocking Libraries**: Never use `Mox`, `Bypass`, or any mocking library. All tests use `InfluxElixir.Client.Local` and/or real InfluxDB instances via shared contract tests.
- **Zero Global State**: Every operation takes an explicit `connection` as its first argument. Multiple connections to different InfluxDB instances run concurrently under `InfluxElixir.Supervisor`.
- **Structured Error Handling**: All fallible functions return `{:ok, result}` or `{:error, %InfluxElixir.Error{}}`. Never raise exceptions for control flow.

## Code Quality Gates

All code must pass every check in `mix quality` and CI with zero warnings or issues (always run test and Dialyzer gates sequentially, one at a time, from the main agent only):

- `mix compile --warnings-as-errors` — Zero dev compiler warnings.
- `MIX_ENV=test mix compile --force --warnings-as-errors` — Zero test-env compiler warnings (`test/support/` only compiles in `:test`).
- `mix format --check-formatted` — Formatted per `.formatter.exs`.
- `mix credo --strict` — Zero Credo issues (see `.credo.exs`):
  - Every public function must have `@spec` and `@doc`; every module must have `@moduledoc`.
  - Unused variables must have meaningful names (`_reason`, `_conn`), never bare `_`.
  - `alias` statements must be alphabetical, one module per line (no `alias Foo.{Bar, Baz}`), and separated from `require`/`import`/`use` by a blank line.
  - No `TODO` or `FIXME` comments (`TagTODO` exits with status 2).
  - Max cyclomatic complexity: 12; max nesting depth: 3; max line length: 98.
- `mix dialyzer` — Zero Dialyzer warnings.
- `mix sobelow --config` — Zero security findings.
- `MIX_ENV=test mix test --cover` — 95%+ test coverage target (90% minimum enforced in `mix.exs`).
