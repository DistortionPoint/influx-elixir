---
trigger: glob
globs:
  - "test/**/*"
  - "mix/**/*"
description: Testing, contract test invariants, and ExUnit standards for InfluxElixir
---

# Testing & Contract Suite Rules

## 1. Test Execution Discipline (CRITICAL)

- **Coverage & Test Commands**:
  - Run coverage tests with Elixir's built-in coverage reporting: `MIX_ENV=test mix test --cover` (never external tools like ExCoveralls).
  - Run unit tests: `mix test`
  - Run a specific test file or line: `mix test test/my_test.exs` or `mix test path/to/test.exs:123`
  - Limit failures when debugging: `mix test --max-failures n`
- **One Test Run at a Time**: NEVER run more than one test process (`mix test`, `MIX_ENV=test mix test --cover`, `ExUnit`, or `mix dialyzer`) concurrently. Wait for one test run to finish completely before starting another.
- **Subagents NEVER Run Tests**: Subagents must NEVER run `mix test`, `MIX_ENV=test mix test --cover`, integration tiers, `ExUnit.start`/`ExUnit.run`, `mix run` loading test files, or `mix dialyzer`. Subagents may only edit files and run at most a single `mix compile`. Only the main agent runs test and quality suites, sequentially.
- **Test-Env Compile Gate**: Because `test/support/` is only compiled in `:test`, always verify `MIX_ENV=test mix compile --force --warnings-as-errors` when modifying `lib/` or `test/support/`.
- **Bounding Untrusted Binary Probes**: Any test or probe that feeds corrupt/untrusted counts or frames into binary parsers (e.g., Flight/FlatBuffers/Protobuf frames) must run inside a `spawn_monitor` process with `Process.flag(:max_heap_size, %{size: 5_000_000, kill: true})` so a bug cannot OOM the BEAM VM.

## 2. Test Tiers & Custom `mix test` Runner (`InfluxElixir.MixTestArgs`)

The `test` alias in `mix.exs` delegates to [`InfluxElixir.MixTestArgs`](file:///Volumes/Dev/development/influx-elixir/mix/test_args.ex):
- **Bare `mix test` (or `MIX_ENV=test mix test --cover`)**: Runs ONLY the unit tier (`test/influx_elixir` and `test/mix`) and skips compiling the 71 integration modules under `test/integration/`.
- **Selecting specific tests or integration/contract tiers**: Passing any file/directory path, `--failed`, `--stale`, an integration tag (`--include integration`, `--only v2`, `--only v3_core`, `--only v3_core_auth`, `--only v3_enterprise`), or setting `INTEGRATION=1` compiles and runs the requested suite.
- **Running contract tests against `Client.Local` (no Docker needed)**:
  - `mix test test/integration/contract_v3_core`
  - `mix test test/integration/contract_v2`
  - `mix test test/integration/contract_v3_enterprise`

## 3. Strictly No Mocking & Named Databases Only

- **NEVER** use `Mox`, `Bypass`, `:meck`, or any mocking library.
- Always test against `InfluxElixir.Client.Local` (`Local.start()` / `Local.stop(conn)`) and shared contract modules under `test/support/`.
- **NEVER Use `"default"` as a Database Name in Tests**: Tests must never use `"default"` as the database name or rely on an implicit `"default"` database fallback. Always use an explicit named test database (e.g., `"test_db"`) and pass `database: "test_db"` explicitly.
- Every test module should use `use ExUnit.Case, async: true` unless it mutates shared external state.

## 4. Meta-Test Invariants (Must Never Break)

1. **`InfluxElixir.ContractTagsTest` ([`test/influx_elixir/contract_tags_test.exs`](file:///Volumes/Dev/development/influx-elixir/test/influx_elixir/contract_tags_test.exs))**:
   - Scans the AST of every `.ex` and `.exs` file in `test/support/`.
   - **Rule**: Every test in `test/support/` that branches on the client under test (references `Local` / `Client.Local`, calls `*local?`, checks `is_map(conn)` / `is_list(conn)`, or calls a helper that branches) **MUST** be preceded by `@tag local_divergence: "reason"`.
   - **Converse Rule**: No test that does NOT branch on the client may carry `@tag local_divergence`.
   - **Floor Rule**: Never lower `@floors` or `@total_floor` in `ContractTagsTest` to make a test pass; raise floors when adding contract tests.

2. **`InfluxElixir.ContractCaseTablesTest` ([`test/influx_elixir/contract_case_tables_test.exs`](file:///Volumes/Dev/development/influx-elixir/test/influx_elixir/contract_case_tables_test.exs))**:
   - Scans every zero-arity function in every `*Cases` module (`SQLScalarCases`, `SQLCatalogCases`, `InfluxQL*Cases`, `LineProtocolCases`) and `SQLScalarRefusals`.
   - **Rule**: No normalized SQL statement, InfluxQL query, or measurement-free Line Protocol case may appear twice unless intentionally pinned in `@spelling_pins` with its exact member count and reason (`{:differs, reason}`, `{:position, reason}`, or `{:same_answer, relations, reason}`).
   - **Refusal Rule**: Every entry in `InfluxElixir.Contract.SQLScalarRefusals` must exist in its corresponding `*_refusable/0` table.

3. **`InfluxElixir.MixTestArgsTest` ([`test/mix/test_args_test.exs`](file:///Volumes/Dev/development/influx-elixir/test/mix/test_args_test.exs))**:
   - Verifies that `MixTestArgs.valued_switches/0` and `@boolean_switches` partition every documented switch of `Mix.Tasks.Test`.

## 5. Test Output & Temporary File Hygiene

- **Zero Noise**: Tests must produce clean output (`....`). Capture expected warnings/logs with `ExUnit.CaptureLog.capture_log/1` or `ExUnit.CaptureIO.capture_io/1`.
- **Temp Files**: Never use `/tmp` or `System.tmp_dir!/0`. Always create unique subdirectories under `Path.join([File.cwd!(), "tmp", "test_#{System.unique_integer([:positive])}"])` and remove them in `on_exit/1`.
- **Unused Variables**: Credo enforces meaningful unused variable names in `test/` too (`_reason`, `_conn`, never bare `_`).
