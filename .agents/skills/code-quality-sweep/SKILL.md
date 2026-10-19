---
name: code-quality-sweep
description: Run the complete InfluxElixir quality gate suite (warnings-as-errors compile, format check, strict Credo, Dialyzer, Sobelow, unit & contract tests, and 95%+ coverage verification). Use before finishing any implementation, refactoring, or review task.
---

# Code Quality Sweep & Verification Skill

Every change in `influx_elixir` must pass all static analysis, security, formatting, unit, and contract test gates with zero warnings or errors.

> [!IMPORTANT]
> - Run test and Dialyzer commands **strictly sequentially, one at a time**, from the main agent only. Subagents must NEVER run `mix test` or `mix dialyzer`.

## 1. Full Quality Gate Sequence

### Step 1: Compile with Warnings as Errors (Dev & Test)

Always run both dev and `:test` compilation (`test/support/` only compiles in `:test`):

```bash
mix compile --warnings-as-errors
MIX_ENV=test mix compile --force --warnings-as-errors
```

### Step 2: Check Formatting

```bash
mix format --check-formatted
```

If formatting fails, run:

```bash
mix format
```

### Step 3: Strict Credo, Dialyzer, and Sobelow (`mix quality`)

```bash
mix quality
```

*(Or run individually: `mix credo --strict`, `mix dialyzer`, `mix sobelow --config`)*

Common Credo failure causes in this repo (`.credo.exs`):
- Missing `@spec` or `@doc` on a public function, or missing `@moduledoc`.
- Concrete struct `%Mod{}` used inside `@spec` instead of `Mod.t()`.
- Bare `_` unused variable instead of meaningful `_reason` / `_conn`.
- Non-alphabetical `alias` order, multi-alias `alias Foo.{Bar, Baz}`, or missing blank line between `use`/`import`/`require` and `alias`.
- `TODO` or `FIXME` comment left in code.
- Cyclomatic complexity > 12, nesting depth > 3, or line length > 98.

### Step 4: Unit Tests & Coverage (`95%+` target, `90%` minimum floor)

```bash
MIX_ENV=test mix test --cover
```

Note: Bare `mix test` / `MIX_ENV=test mix test --cover` uses [`InfluxElixir.MixTestArgs`](file:///Volumes/Dev/development/influx-elixir/mix/test_args.ex) to run only the fast unit tier (`test/influx_elixir` and `test/mix`), including the AST meta-tests:
- `test/influx_elixir/contract_tags_test.exs`
- `test/influx_elixir/contract_case_tables_test.exs`
- `test/influx_elixir/optional_dependency_test.exs`
- `test/mix/test_args_test.exs`

### Step 5: Contract Test Suites (`Client.Local`)

When any code under `lib/influx_elixir/` or `test/support/` is touched, also run the contract tiers against `Client.Local` (one run at a time):

```bash
mix test \
  test/integration/contract_v3_core \
  test/integration/contract_v2 \
  test/integration/contract_v3_enterprise \
  test/integration/tokens_v3_core_auth_test.exs
```
