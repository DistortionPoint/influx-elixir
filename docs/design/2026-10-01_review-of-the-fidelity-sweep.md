# Review of the Fidelity Sweep: Tokenizer, Bound Params, Line Splitting

**Date**: 2026-10-01
**Scope**: `Client.Local` (SQL lexer, parser, executor; line protocol; Flux;
store), `Client.HTTP` params, the contract and fidelity tests
**Issue**: scheduled quality sweep (no open issues); a review of
[`2026-10-01_local-fidelity-sweep-and-optional-decimal`](2026-10-01_local-fidelity-sweep-and-optional-decimal.md),
which agents wrote and nobody had reviewed

---

## Problem

Two independent reviews read the previous commit and its tests. Each
finding below was confirmed against InfluxDB 3 Core 3.10.1 or InfluxDB
2.7.

**SQL text.**
- Local answered queries the engine's tokenizer refuses: an unterminated
  `'…'`, an unterminated `"…"` or an unterminated comment.
- A quote inside a comment (`/* it's */`) re-paired the quotes and
  dropped the `WHERE`, so every row came back.
- A trailing `;` was refused.
- A literal starting with a combining mark was sliced by grapheme and
  matched nothing.
- Non-ASCII identifiers were refused.
- Planning errors came in the wrong order. The engine reports the
  select list's calls, operators and aggregates before `WHERE`, then
  `ORDER BY`, with a negation last.

**Parameters.**
- The `\u{E000}` marker for UInt64 params leaked into error bodies, and
  it missed `"time"`.
- A boolean param against an integer column returned `[]`. The engine
  gives a type error.
- Map and list params were stringified.
- A Decimal NaN made `Client.HTTP` send invalid JSON.
- A `"$name"` key bound on Local but binds nothing on the engine.

**Line protocol.**
- A `"` anywhere in a line toggled quote state across the line break,
  so `m,t=a"b f=1i 1\nm f=2i 2` lost the second line. Both engines
  store both lines.
- A quoted measurement lost its quotes.
- v2 writes were quadratic in shard groups: 8.6 s for 40k points.
- Typical lines parsed slowly, and bare lines were 50% slower than
  before the rewrite (both measured against the old commit in a
  worktree).

**Flux.** Rows sorted on microsecond-truncated `_time`, so `first()` and
`last()` were swapped for points less than 1 µs apart.

**Tests.**
- Fidelity files duplicated the new contract modules almost entirely.
- Some tests could not fail:
  - a delete/rewrite stress test that only exercised round 1;
  - an "int64 is in int64 range" assertion.
- Some tests drove internal functions (`matches_all?`, `where_plan`,
  `Flux.parse`).
- Several helpers were defined inside `describe` or `quote` blocks.
- The compile gate ran only in the dev env, so `test/support` warnings
  shipped in 0.1.39.

## Rejected or not reproduced

- **The `:global` locks.** They work as intended: about 4 µs a token, the
  write path never takes them for an existing database, and they are free
  after a raise, a throw or a kill.
- **The InfluxQL lower bound.** The greatest-lower-bound logic agrees
  with Core in 12 variants.
- **Core's write path stopping after a fuzzed payload.** Twice, Core's
  write path stopped accepting writes after heavy fuzzing ("error writing
  wal file: oneshot channel closed"). The named payload did not
  reproduce it on a fresh instance, so it is not claimed as an engine
  bug.

## Decision

- **SQL lexer (`SQLLexer.scrub/1`, new).** It runs before parsing:
  - removes `--` comments and nested `/* */` comments;
  - strips a trailing `;`;
  - rewrites `$$…$$` and `$tag$…$tag$` dollar strings to plain literals;
  - answers an unterminated literal, identifier or comment with the
    engine's `TokenizerError`, at the character line and column the
    engine names. That message is in Rust's Debug format, so a `"`
    inside it is escaped.

  An empty statement is the planner's 400, and two statements are the
  engine's 405.
- **Bound params.** `$name` is a node wherever a value stands.
  - A pure `bind/2` types each value as the engine types the request
    JSON: a non-negative integer is `UInt64`.
  - It answers type and unbound-placeholder errors.
  - The text substitution, the marker and `beside_time?` are gone.
  - `InfluxElixir.Client.QueryParams` (new) normalizes params for both
    clients. Non-finite Decimals and values that have no JSON form give
    `{:error, {:invalid_param, name, reason}}`.
- **Errors.** `SQLError` holds the shared bodies. `check_plan` uses the
  measured rank order.
- **Line splitting.** It is Go's `scanLine`, which both engines use:
  - a backslash skips the next byte;
  - a quote toggles only after an `=` that no comma has closed.

  Each engine's escape rules are applied in one pass. The lenient second
  parser is gone.
- **InfluxDB 2 shard groups.** Local keeps a per-shard-group schema and
  reports the earliest failing group. The group list is a MapSet.
- **Fidelity found by fuzzing.** v3 error line numbering and the
  schema-error echo now match the engine. v2 measurements that the engine
  accepts but never returns are modelled.
- **Parse speed.**
  - A payload of 2,000 lines or more is parsed in a short-lived process
    spawned with a heap sized for the result. An exception is raised
    again in the caller.
  - The first version set `min_heap_size` on the caller and forced a GC
    there. That was replaced, because a library must not change the GC
    settings of the process that calls it.
  - Name scanning is hand-rolled.
- **Flux.** Rows sort on stored nanoseconds.
- **Tests.**
  - Each fact is pinned once, in a contract module that runs on Local and
    on the engines.
  - Fidelity files keep only whole-shape unit tests of public functions.
  - Stress tests use 12 to 16 tasks.
  - The optional-dependency check walks the AST.
  - The gate list now includes `MIX_ENV=test mix compile --force
    --warnings-as-errors`.

## Verification

- **Integration.**
  - Core: 227 tests.
  - InfluxDB 2.7: 48 tests.
  - Auth-enabled Core tokens: 8 tests.
  - Unit: 1,739 tests, three runs.
  - Credo, dialyzer, docs, and both compile environments are clean.
- **Parse timings** (100k lines; old commit in a worktree, current code
  with the spawned parse):

  | Lines | Old | Current |
  |-------|-----|---------|
  | Bare | 223–332 ms | about 130 ms |
  | Typical | 1,752–1,792 ms | about 540 ms |

  A v2 write across 40k shard groups dropped from 8.6 s to 0.2 s.
- **Differential runs** against both engines: about 70 hand-written
  payloads plus mutation fuzzing. The only differences left are
  refusals by name.
