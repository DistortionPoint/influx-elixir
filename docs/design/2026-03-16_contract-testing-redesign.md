# Contract Testing Redesign

**Date**: 2026-03-16
**Scope**: Shared contract tests proving LocalClient and real InfluxDB produce identical results

---

## Problem

The current integration tests have separate assertion logic for LocalClient vs HTTP client.
There is no mechanism to prove they behave identically. Consuming apps cannot trust
LocalClient as a faithful test double without this proof.

## Solution: Shared Contract Tests

One set of assertions runs against **both** backends:

1. `test/support/client_contract.ex` — shared ExUnit case template defining ALL assertions
2. LocalClient contract runners (CI, no external deps):
   - `test/influx_elixir/client/contract_local_v3_core_test.exs` — LocalClient with `profile: :v3_core`
   - `test/influx_elixir/client/contract_local_v3_enterprise_test.exs` — LocalClient with `profile: :v3_enterprise`
   - `test/influx_elixir/client/contract_local_v2_test.exs` — LocalClient with `profile: :v2`
3. Real InfluxDB contract runners (tagged `:integration`, require running instances):
   - `test/integration/contract_v3_core_test.exs` — HTTP client against real v3 Core
   - `test/integration/contract_v3_enterprise_test.exs` — HTTP client against real v3 Enterprise
   - `test/integration/contract_v2_test.exs` — HTTP client against real v2

If LocalClient (per-profile) and the matching real InfluxDB backend pass the **same**
assertions → LocalClient is proven faithful for that profile. Consuming apps configure
LocalClient with the profile matching their production InfluxDB and get accurate test behaviour.

## Contract Coverage

Every Client behaviour callback gets contract assertions, gated by profile:

| Callback | Contract Group | Profiles |
|---|---|---|
| `health/1` | Health | all |
| `write/3` | Write | all |
| `query_sql/3` | Query SQL | v3_core, v3_enterprise |
| `query_sql_stream/3` | Query SQL Stream | v3_core, v3_enterprise |
| `execute_sql/3` | Execute SQL | v3_core, v3_enterprise |
| `query_influxql/3` | InfluxQL | v3_core, v3_enterprise |
| `create_database/3` | Database Admin | v3_core, v3_enterprise |
| `list_databases/1` | Database Admin | v3_core, v3_enterprise |
| `delete_database/2` | Database Admin | v3_core, v3_enterprise |
| `create_bucket/3` | Bucket Admin | v2 |
| `list_buckets/1` | Bucket Admin | v2 |
| `delete_bucket/2` | Bucket Admin | v2 |
| `create_token/3` | Token Admin | v3_enterprise |
| `delete_token/2` | Token Admin | v3_enterprise |
| `query_flux/3` | Flux Query | v2 |

## Architecture

```
test/support/
  client_contract.ex                    # ExUnit case template with __using__ macro
                                        # Accepts: client_module, profile, setup_fn

test/influx_elixir/client/
  local_test.exs                        # KEPT — LocalClient-specific tests (ETS lifecycle, isolation)
  contract_local_v3_core_test.exs       # use ClientContract, client: Local, profile: :v3_core
  contract_local_v3_enterprise_test.exs # use ClientContract, client: Local, profile: :v3_enterprise
  contract_local_v2_test.exs            # use ClientContract, client: Local, profile: :v2

test/integration/
  contract_v3_core_test.exs             # use ClientContract, client: HTTP, profile: :v3_core
  contract_v3_enterprise_test.exs       # use ClientContract, client: HTTP, profile: :v3_enterprise
  contract_v2_test.exs                  # use ClientContract, client: HTTP, profile: :v2
```

### Capability Profiles

Not all backends support all operations. Each backend declares a **profile** that
determines which operations are available:

| Profile | Write | SQL | InfluxQL | Flux | DB CRUD | Bucket CRUD | Tokens |
|---|---|---|---|---|---|---|---|
| `:v3_core` | yes | yes | yes | no | yes | no | no |
| `:v3_enterprise` | yes | yes | yes | no | yes | no | yes |
| `:v2` | yes | no | no | yes | no | yes | no |

**LocalClient enforces its configured profile.** When a consuming app starts LocalClient,
they pass `profile: :v3_core` (or `:v3_enterprise`, `:v2`). Operations outside that profile
return `{:error, :unsupported_operation}` — matching what would happen against the real backend.

This prevents consuming apps from accidentally writing tests that pass against LocalClient
but fail in production because their real InfluxDB version doesn't support the operation.

```elixir
# Consuming app's test setup — matches their production InfluxDB version
{:ok, conn} = Local.start(databases: ["myapp_test"], profile: :v3_core)

# This works — v3_core supports SQL
Local.query_sql(conn, "SELECT * FROM cpu", database: "myapp_test")

# This returns {:error, :unsupported_operation} — v3_core has no Flux
Local.query_flux(conn, "from(bucket: \"myapp_test\") |> range(start: -1h)")
```

**For our contract tests**, each runner passes the matching profile:
- `contract_local_v3_core_test.exs` → `profile: :v3_core`
- `contract_local_v3_enterprise_test.exs` → `profile: :v3_enterprise`
- `contract_local_v2_test.exs` → `profile: :v2`

This means LocalClient contract tests run **three times** — once per profile — proving
fidelity against each real backend.

Contract tests use `@tag :profile_xxx` so each test only runs against profiles that support it.

### Setup Contract

Each "using" module provides a `setup` callback that returns:
- `conn` — connection keyword list
- `database` — test database name (created fresh per test or per suite)

The contract template handles the rest.

---

## Checklist

### Phase 1: LocalClient Profile Enforcement
Profile enforcement must exist before the contract template can gate tests by profile.

- [ ] 1.1 — Add `profile:` option to `Local.start/1` (`:v3_core`, `:v3_enterprise`, `:v2`)
- [ ] 1.2 — Default profile is `:v3_core` (most common use case)
- [ ] 1.3 — Unsupported operations return `{:error, :unsupported_operation}` based on profile
- [ ] 1.4 — Update existing `local_test.exs` to pass `profile:` where needed (keep passing)

### Phase 2: Shared Contract Template (ALL assertions)
All contract assertions go in one file. Every callback in the Client behaviour is covered.

- [ ] 2.1 — Create `test/support/client_contract.ex` ExUnit case template skeleton
- [ ] 2.2 — Health contract assertions (all profiles)
- [ ] 2.3 — Write contract: valid LP, bad DB, malformed LP, gzip (all profiles)
- [ ] 2.4 — Database admin contract: create, list, delete (v3_core, v3_enterprise)
- [ ] 2.5 — Query SQL contract: empty result, LIMIT, ORDER BY, WHERE (v3_core, v3_enterprise)
- [ ] 2.6 — Write + query round-trip: int, float, string, bool, large int (v3_core, v3_enterprise)
- [ ] 2.7 — Query SQL stream contract (v3_core, v3_enterprise)
- [ ] 2.8 — Execute SQL contract: DELETE FROM (v3_core, v3_enterprise)
- [ ] 2.9 — InfluxQL contract: SHOW DATABASES, SHOW MEASUREMENTS, SHOW TAG KEYS (v3_core, v3_enterprise)
- [ ] 2.10 — Bucket admin contract: create, list, delete (v2)
- [ ] 2.11 — Flux query contract (v2)
- [ ] 2.12 — Token admin contract: create, delete (v3_enterprise)

### Phase 3: LocalClient Contract Runners
These prove LocalClient conforms to each profile's contract. Run in CI, no external deps.

- [ ] 3.1 — Create `test/influx_elixir/client/contract_local_v3_core_test.exs`
- [ ] 3.2 — Create `test/influx_elixir/client/contract_local_v3_enterprise_test.exs`
- [ ] 3.3 — Create `test/influx_elixir/client/contract_local_v2_test.exs`
- [ ] 3.4 — Verify all contract tests pass against LocalClient (all 3 profiles)

### Phase 4: Profile Rejection Tests
Verify each profile correctly REJECTS operations it does NOT support.
These run only against LocalClient (real backends already reject natively).

- [ ] 4.1 — v3_core rejects: `query_flux`, `create_bucket`, `list_buckets`, `delete_bucket`, `create_token`, `delete_token`
- [ ] 4.2 — v3_enterprise rejects: `query_flux`, `create_bucket`, `list_buckets`, `delete_bucket`
- [ ] 4.3 — v2 rejects: `query_sql`, `query_sql_stream`, `execute_sql`, `query_influxql`, `create_database`, `list_databases`, `delete_database`, `create_token`, `delete_token`

### Phase 5: Real InfluxDB Contract Runners
Same contract, now against real backends. Tagged `:integration` + version tag, excluded from CI.

- [ ] 5.1 — Create `test/integration/contract_v3_core_test.exs` (tagged `:v3_core`, `:integration`)
- [ ] 5.2 — Create `test/integration/contract_v3_enterprise_test.exs` (tagged `:v3_enterprise`, `:integration`)
- [ ] 5.3 — Create `test/integration/contract_v2_test.exs` (tagged `:v2`, `:integration`)

### Phase 6: Cleanup
- [ ] 6.1 — Remove old `test/integration/contract_test.exs` (replaced by new contract runners)
- [ ] 6.2 — Remove old `test/integration/v3_core_test.exs` (replaced by contract runner)
- [ ] 6.3 — Remove old `test/integration/v3_enterprise_test.exs` (replaced by contract runner)
- [ ] 6.4 — Remove old `test/integration/v2_test.exs` (replaced by contract runner)
- [ ] 6.5 — Prune `local_test.exs`: remove tests now covered by contract, keep LocalClient-specific tests (ETS lifecycle, start/stop, instance isolation, gzip decompression internals)
- [ ] 6.6 — Run `mix quality` — all checks pass
- [ ] 6.7 — Run `mix test` — all tests pass, 0 failures

### Phase 7: Documentation
Consuming apps need to know how to use LocalClient correctly with profiles.

- [ ] 7.1 — `@moduledoc` on `Local` — explain profiles, show setup example, list supported operations per profile
- [ ] 7.2 — `@moduledoc` on `ClientContract` — explain how consuming apps can run the contract against their own adapters
- [ ] 7.3 — `@doc` on `Local.start/1` — document `profile:` option, valid values, default, what happens on unsupported operation
- [ ] 7.4 — Hex docs guide: `docs/guides/testing-with-local-client.md` — full walkthrough for consuming apps:
  - How to add `influx_elixir` as a test dependency
  - How to configure LocalClient with the correct profile
  - How to set up `test_helper.exs` and `config/test.exs`
  - How to use the contract template to verify their own adapters
  - Example test module showing a complete consuming app test setup
  - What happens when you pick the wrong profile (and why that's a feature)
- [ ] 7.5 — Update top-level README testing section to reference the guide
- [ ] 7.6 — Run `mix docs` — verify guide renders correctly

---

## Design Decisions

### Why ExUnit Case Template (not shared module with test functions)?

ExUnit case templates (`__using__` macro) let us define `describe` blocks and `test` blocks
that get injected into the using module. This means:
- Tests show up with the correct module name in output
- Tags from the using module apply correctly
- Setup/teardown from the using module works naturally
- No need for manual test registration

### Why capability tags instead of separate contract modules per feature?

One contract module with profile-gated tests keeps ALL assertions in one place.
Adding a new assertion means adding it once. If a backend doesn't support a feature,
the test is simply excluded by tag — not silently missing.

### What happens to `local_test.exs`?

`local_test.exs` is **kept but pruned** (Phase 6.5). Tests that duplicate contract
assertions are removed. Tests that are LocalClient-specific remain:
- ETS lifecycle (start/stop/cleanup)
- Instance isolation (two LocalClient instances don't share state)
- Gzip decompression internals
- Profile enforcement edge cases

These test LocalClient's implementation, not the Client behaviour contract.

### How does the v3 Core runner handle WAL flush delay?

Real InfluxDB v3 may need time to flush WAL before data is queryable.
The contract template's write+query tests include a configurable sleep
(0ms for LocalClient, 500ms for real InfluxDB) passed via the setup callback.
