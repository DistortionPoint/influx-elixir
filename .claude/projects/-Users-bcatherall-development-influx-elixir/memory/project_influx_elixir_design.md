---
name: influx-elixir-design-context
description: InfluxElixir library design decisions — naming, LocalClient pattern, UsageRules, consuming app requirements
type: project
---

The library is `influx_elixir` / `InfluxElixir` (NOT influx_ex or influxdb3).

**Why:** The design doc was written by another app that didn't know the final naming. All references should use influx_elixir/InfluxElixir.

**Key architectural decisions:**
- Behaviour-based Client adapter: `InfluxElixir.Client` behaviour with `HTTP` (Finch) and `Local` (ETS) implementations
- LocalClient is a REAL implementation, not a mock — stores data in ETS, parses line protocol, responds like real InfluxDB
- Contract tests run same assertions against both LocalClient and real InfluxDB to prove fidelity
- UsageRules (`{:usage_rules, "~> 1.2", only: :dev}`) ships `usage-rules.md` + `usage-rules/` subdirectory with hex package for consuming app LLM agents
- The "Requirements From Consuming Application" section is a real app telling us what it needs — do not remove it

**Two known consuming apps:**
1. Trading system (dp_crypto_management) — real-time writes, bounded queries
2. Data migration app — Postgres to InfluxDB, millions of rows, needs Arrow Flight for bulk transport

**How to apply:** Always use influx_elixir naming. Testing approach = LocalClient for fast unit tests + real InfluxDB for integration/contract tests. No mocking ever. Arrow Flight is required from day one, not deferred.
