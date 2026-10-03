# Sixth Review: Over-Refusal, Package Contents, Contract Coverage

**Date**: 2026-10-02
**Scope**: `Client.Local` (refusals of queries the engine answers, InfluxQL
`GROUP BY time` and select-list arithmetic, module layout), the Hex package,
the contract and Local test files
**Issue**: scheduled quality sweep (no open issues). This reviews commit
2b7b801 ([`2026-10-02_fifth-review`](2026-10-02_fifth-review.md)), which
agents wrote and nobody had reviewed. The engine rules it settled are in
[`2026-10-02_local-sql-simplifier-and-intervals`](2026-10-02_local-sql-simplifier-and-intervals.md)
and
[`2026-10-02_influxql-planner-and-module-split`](2026-10-02_influxql-planner-and-module-split.md).

---

## Problem

**The double refused queries the engine answers.** A refusal is as bad as
a wrong answer for the query it refuses: the test that needs it cannot use
the double.
- `total > 0 AND used / total > 0.5` was refused whenever a row held 0/0:
  a NaN comparison, which the double refuses, in an operand the row never
  reaches was read as an engine failure. A realistic guard corpus had 26
  false refusals per table.
- Every InfluxQL `OR` that named an unsigned field was refused.
- InfluxQL regular expressions on string fields matched nothing, and
  `GROUP BY time(...)`, `fill()`, `median`, `spread`, `stddev` and
  select-list arithmetic, all common on dashboards, were refused.

**Whether the engine fails a guarded division is not a property of the
query.** `n > 0 AND 100 / n > 1` closes the connection on a freshly written
table and answers 7,800 rows once the same data is persisted. The double
can only answer where both states agree.

**The package.** `files:` sat outside `package()` in `mix.exs`, so every
release shipped Hex's default list: the dialyzer PLT and `.formatter.exs`
went out, the usage rules did not.

**Tests.**
- About 25 describes in the Local tests restated contract facts, and about
  30 engine facts (write conflicts, lifecycle errors, SQL and Flux results)
  were asserted against the double alone, so no engine ever checked them.
- Five BatchWriter regressions passed the suite: the timer not restarting,
  the retry delay ignored, both jitters ignored, an unexpected message
  crashing the writer.
- A Flight test's "closed" port could be taken by another async test's
  listener before the connection, so the connection hung instead of being
  refused.
- `local_divergence` and `engine_bug` tags were consumed by nothing; five
  tests branched on the client untagged.

**Layout.** About 80 internal modules sat flat under `client/local/` and
all appeared in the published docs; `local.ex` was 2,593 lines.

## Decision

- **Refusal only where the engine is not deterministic.** A skipped
  operand counts as failing only when it fails on the engine (an integer
  division by zero, an overflow), never for a refusal of the double. A tag
  conjunct that leaves the failing rows out answers in either order. The
  fresh-versus-persisted rule is in the simplifier document. After the
  change the guard corpus has no false refusal on fresh tables.
- **NaN comparisons stay refused.** The sign of a NaN a division produces
  is the CPU's; this Core (arm64 under Rosetta) orders it as positive, an
  x86-64 engine need not.
- **InfluxQL** checks are columns of the point, so `OR` combines them;
  `GROUP BY time` buckets are a lazy stream (a default window of 1.45M
  buckets answers with `LIMIT`).
- **Package**: `files:` is under `package()`; the built package holds
  `lib/`, the README, LICENSE, CHANGELOG and the usage rules.
- **Layout**: `client/local/` has `sql/`, `influxql/`, `line_protocol/`,
  `flux/`, `store/`, `write/`, `admin/`, `shared/`; `Client.Local` is the
  facade; internal modules are `@moduledoc false` and the published ones
  are grouped by role.
- **Tests**:
  - Engine facts live in contracts (`WriteRules`, `SQLAggregates`,
    `SQLExpressions`, `Flux` are new), run on both tiers; the Local test
    file is split into seven files of what only the double has.
  - New BatchWriter tests fail under each of the five regressions (checked
    by applying each to a copy of the library).
  - `ClosedPort` is port 1, below the range the system hands out for port
    0.
  - `contract_tags_test.exs` fails when a contract test branches on the
    client without a `local_divergence` tag, or has the tag without a
    branch. `mix test <dir> --only engine_bug` lists the engine-bug pins
    for an engine upgrade.

## Accepted compromise

The BatchWriter timer and jitter tests read the writer's timer reference
and trace `:erlang.send_after`. A timer restart cannot be seen from outside
without waiting on the clock, which is the race the earlier rewrite
removed.

## Verification

- Unit: 3,095 tests, three runs (about 7 s each); credo, dialyzer, docs
  (no warnings) and both compile environments clean; `mix hex.build`
  lists only the intended files.
- Integration on fresh servers, run twice: Core 571 tests, InfluxDB 2.7 77
  tests; auth-enabled Core tokens 8 tests.
- Differential runs against Core: a 33-idiom guard corpus at 10, 100 and
  10,000 rows, fresh and persisted; about 1,000 InfluxQL statements.
