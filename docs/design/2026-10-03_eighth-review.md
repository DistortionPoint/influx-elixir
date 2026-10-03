# Eighth Review: Defects in 0.1.41

**Date**: 2026-10-03
**Scope**: `Client.Local` InfluxQL transforms and wildcards, SQL parsing and
planning, retention reads; the `mix test` alias; the contract case tables
**Issue**: scheduled quality sweep (no open issues). This reviews commit
1f5d13c ([`2026-10-03_seventh-review`](2026-10-03_seventh-review.md)),
released as 0.1.41 before anyone reviewed it.

---

## Problem

The previous seven sweeps each reviewed the commit before, fixed what it
found, and added features; each fix commit was then itself unreviewed and the
next review found defects in it. This sweep fixes defects only.

**Released defects (0.1.41), each a regression from a by-name refusal in
0.1.40:**
- `derivative(v, 0s)`, `elapsed(v, 0s)` and `moving_average(v, 0)` raised
  `ArithmeticError`, and float overflow in the transforms raised.
- `count(/re/)`, `mode(*)`, `elapsed(*)` returned `[]` where Core answers:
  a function missing from the wildcard table expanded to nothing.
- SQL `left()`/`right()`, `HAVING` on an alias and `1_000` got engine-shaped
  errors Core does not give; InfluxQL accepted `host = /re/`, regex flags and
  `percentile(/re/, n)`, which Core rejects.
- A retention database's `count(*)` cost 7× the reductions of a plain one.

**Tests.** The `mix test` alias ran the whole suite for an absolute or `./`
path and no integration tests for an `--include` of their tag without a
path. 134 "refusable" cases accepted any refusal, so a regression to
"refused" would pass. About 300 line-protocol error texts were pinned only
against the double.

## Decision

- **Refuse by name what cannot be matched**, as 0.1.40 did; model a shape
  only when every case was read from Core. An empty wildcard expansion is a
  refusal, never `[]`.
- **Transforms** validate their arguments at parse with Core's bodies and
  answer a null on float overflow; integer forms wrap.
- **Retention** keeps a marker per 10-minute chunk, so a read with nothing
  expired returns the points untouched.
- **`mix test`** prepends the unit paths only when no path (in any form), no
  `--failed`/`--stale` and no integration tag selects the tests.
- **Refusable tables** pin their refusal count (`Check.check_ratchet/3`):
  above the pin a case regressed, below it one is answered and moves to the
  strict table.
- **Core image** pinned to `influxdb:3.10.1-core`: about 50 cases pin
  DataFusion error bodies of that version, which the double must reproduce
  exactly.

## Engine bug

Core panicked with `timestamp wraparound` four times this week, each time
under agent probing or concurrent, killed suite runs; afterwards its write
path hangs until restart. Not reported upstream from here. (A sequential
suite run did trigger it later; the cause, a forced snapshot of a point near
the largest timestamp, is in
[`2026-10-04_ninth-review`](2026-10-04_ninth-review.md).)

## Known differences left

`stddev` and `integral` can differ from Core in the last digit (Core's
partition merge); `mode()` with tied counts is refused (hash order).

## Verification

- Unit: 1,985 tests, three runs; coverage 90.81%; credo, dialyzer, docs (no
  warnings) and both compile environments clean.
- Integration on fresh `influxdb:3.10.1-core` and 2.7, run twice: Core 643
  tests, InfluxDB 2.7 95 tests, auth-enabled Core tokens 8 tests; Core did
  not panic.
