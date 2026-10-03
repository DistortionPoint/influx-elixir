# Ninth Review: The Core Panic, Regressions in the 0.1.41 Fixes, Test Tiers

**Date**: 2026-10-04
**Scope**: `Client.Local` SQL and InfluxQL (the defect fixes for 0.1.41),
the integration server configuration, the `mix test` alias, the contract
case tables and the refusal ratchet
**Issue**: scheduled quality sweep (no open issues). This reviews commit
1b8ff04 ([`2026-10-03_eighth-review`](2026-10-03_eighth-review.md)), the
unreleased fixes for 0.1.41, which agents wrote and nobody had reviewed.
Defects only; no features.

---

## Problem

**The InfluxDB 3 Core panic.** Core panicked with `timestamp wraparound`
again, this time during a plain sequential suite run, and its writes hung
until restart. Three isolated servers settled the cause: a server holding a
point near the largest timestamp panics when it takes the snapshot it forces
after three times `--wal-snapshot-size` WAL files; a server with ordinary or
near-smallest timestamps snapshots normally. The contracts write such points
on purpose (the engine accepts them). The 10 ms WAL flush the one-liners had
adopted made a suite reach the forced snapshot within one run.

**Regressions in 1b8ff04**, each confirmed on Core:
- SQL read `INTO` and `AS` written as column names as clauses, and resolved a
  qualified `HAVING`/`ORDER BY` name (`cpu.c`) as a select alias;
- `left(NULL, 1.5)` answered rows where Core errors;
- `selector_max(...) || 'a'`, `derivative(mean(nosuch))` and some malformed
  InfluxQL select lists raised;
- a `min(time)` beside another InfluxQL aggregate was dropped, and
  `WHERE - host` was a planner error where Core answers `[]`.

**Number tokens** (`1L`, `0XFF`) were read four different ways, one per SQL
reader.

**Tests.** The documented `mix test --include integration --include v3_core`
selects every server's suite (they share the `integration` tag); the alias
missed `--only=v2` and paths outside `test/`. The refusal ratchet counted
refusals, so a regression and an improvement together passed. About 40
line-protocol cases were pinned two or three times. An error position inside
a measurement name normalised to a valid one.

## Decision

- **Integration servers** start with `--wal-snapshot-size 100000`: the same
  2,000 writes with a near-largest timestamp then take no forced snapshot
  and do not panic. Writes stay fast (10 ms flush).
- **Regressions** fixed to Core's bodies; shapes that cannot be pinned are
  refused by name. One `SQLIdentifiers.take_number/1` serves every SQL reader.
- **`mix test`** reads its arguments with `OptionParser`, as `mix test` does.
  One server's suite is `mix test --only v3_core`.
- **The ratchet** pins the set of refused cases per table
  (`Contract.SQLScalarRefusals`); any other return from a case check fails.
- **Line protocol** facts live in `ClientContract.LineProtocolCases`, checked
  for duplicates with the measurement name normalised; the 10,000-line chunk
  payloads run against both engines.

## Verification

- Unit: 1,993 tests, three runs; coverage 90.95%; credo, dialyzer, docs (no
  warnings) and both compile environments clean.
- Integration on fresh `influxdb:3.10.1-core` (with `--wal-snapshot-size
  100000`) and 2.7, run twice: Core 639 tests, InfluxDB 2.7 90 tests, no panic
  and no forced snapshot; auth-enabled Core tokens 8 tests.
- The token suite also found the engine printing a whole-second time with no
  fraction (`…:53Z`), which the contract and the double now follow.
