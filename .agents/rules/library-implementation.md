---
trigger: glob
globs:
  - "lib/**/*"
description: Library implementation rules, optional dependency constraints, and Credo/Dialyzer standards for lib/
---

# Library Implementation Rules (`lib/`)

## 1. Module & Function Design

- **Explicit Connection**: Every client and facade function takes `connection` as its first argument. Never store connections or configuration in `Application` env or process dictionaries.
- **Error Tuples**: Return `{:ok, result}` or `{:error, %InfluxElixir.Error{}}`. Do not raise exceptions for expected runtime/input/engine errors.
- **No Heuristic Binary Parsing**: Never use heuristic byte scanning or pattern guessing when parsing binary protocols (Arrow Flight, FlatBuffers, Protobuf, Arrow IPC). Always parse strictly according to the format specification (e.g., reading FlatBuffers vtable offsets and Protobuf wire tags).
- **Documentation & Typespecs**:
  - Every module in `lib/` must have `@moduledoc` (or `@moduledoc false` for internal implementation modules).
  - Every public function must have `@doc` and `@spec`.
  - Do not place concrete struct literals in `@spec` if Credo's `SpecWithStruct` flags them; use the module's `@type t` (e.g., `InfluxElixir.Error.t()`, `InfluxElixir.Write.Point.t()`).

## 2. Optional Dependencies (`InfluxElixir.OptionalDependencyTest`)

- [`test/influx_elixir/optional_dependency_test.exs`](file:///Volumes/Dev/development/influx-elixir/test/influx_elixir/optional_dependency_test.exs) parses the AST of every file in `lib/**/*.ex`.
- For any dependency marked `optional: true` in `mix.exs`:
  - **NEVER** match `%OptionalMod{}` at compile time (even through an `alias`). Match `%{__struct__: OptionalMod}` instead.
  - **NEVER** `import`, `require`, or `use` an optional dependency module in `lib/`.

## 3. Strict Credo Conventions (`.credo.exs`)

- **Aliases**:
  - Alphabetical order required (`Credo.Check.Readability.AliasOrder`).
  - No multi-aliases (`alias Foo.{Bar, Baz}` is forbidden; write separate `alias` lines).
  - Separate `use`, `import`, `require`, and `alias` blocks with a blank line (`SeparateAliasRequire`).
- **Variables & Predicates**:
  - Unused variables must be named meaningfully (`_conn`, `_opts`, `_reason`); bare `_` is forbidden (`UnusedVariableNames`).
  - Predicate functions must end with `?` and must NOT start with `is_` (`PredicateFunctionNames`).
  - Zero-arity `def`/`defp` definitions must NOT have parentheses (`def foo do`, not `def foo() do`).
- **Complexity & Formatting**:
  - Max cyclomatic complexity: 12 (`CyclomaticComplexity`).
  - Max nesting depth: 3 (`Nesting`).
  - Max line length: 98 characters (`MaxLineLength`).
  - No `TODO` or `FIXME` comments (`TagTODO` fails with exit status 2).
  - No `IO.inspect`, `IO.puts`, or `dbg` in committed code.

## 4. `Client.Local` Fidelity Principles

- `InfluxElixir.Client.Local` must faithfully mirror real InfluxDB v2 (`2.7`) and v3 Core (`3.10.1-core`) semantics across:
  - Line Protocol (`lib/influx_elixir/write/line_protocol.ex`, `lib/influx_elixir/client/local.ex`)
  - SQL parser, planner, and executor (`lib/influx_elixir/client/local/sql*.ex`)
  - InfluxQL parser, planner, and executor (`lib/influx_elixir/client/local/influxql*.ex`)
  - Flux parser and evaluator (`lib/influx_elixir/client/local/flux*.ex`)
- When modifying `Client.Local` behaviour, always check [`usage-rules/testing.md`](file:///Volumes/Dev/development/influx-elixir/usage-rules/testing.md), [`usage-rules/write.md`](file:///Volumes/Dev/development/influx-elixir/usage-rules/write.md), and [`usage-rules/query.md`](file:///Volumes/Dev/development/influx-elixir/usage-rules/query.md) to ensure documented consumer contracts remain accurate.
