# Issue #24: Column Types in Client.Local

**Date**: 2026-09-28
**Scope**: testing guide, usage rules (no code change)
**Issue**: #24, "Local client accepts field-type conflicts that InfluxDB 3 rejects"

---

## Problem

The issue reports that `Client.Local` stores `m f=2i` after `m f=1.5`, where
InfluxDB 3 answers 400 `invalid column type`. It says a consumer's suite passed
while production rejected every row from a new writer that sent
`duration_ms` as an integer.

## Analysis

The repro as written does not reproduce. The double refused the conflicting
write in every case checked:

- The issue's two writes on `:v3_enterprise`, `:v3_core` and `:v2`:
  - v3: 400 `invalid column type for column 'f', expected
    iox::column_type::field::float, got iox::column_type::field::integer`.
  - v2: 422 `field type conflict`.
  - The float row is kept.
- The conflict within one batch, across tag sets, gzipped, with
  `accept_partial: false`, through `BatchWriter.write_sync/3`, and through
  a named facade connection, with and without `database:`.
- The same script on a worktree at the tag `v0.1.33`, the version the
  issue names.

The contract suite's write-rule tests assert this answer against InfluxDB 3
Core, and they also run on the Local `:v3_enterprise` profile.

The consumer's failure fits a different cause. Every `Local.start/1` begins
with an empty schema. Production's `duration_ms` was typed as a float long
ago by other writers. But in the new writer's own test, its integer write was
the table's first, so it defined the column as an integer and nothing
conflicted. The double cannot know production's schema unless the test
establishes it.

## Decision

- **No code change.** The double already answers as the engine does.
- **Documentation.** The testing guide now explains why a wrong type can
  pass in a test. Its new "Pinning production's column types" section gives
  a `setup` recipe: seed one point with production's types, stamped where
  queries never look. `usage-rules/testing.md` has the one-line rule.
- **Possible follow-up**, not done here because it adds public API: a way to
  declare columns without writing a row, for example
  `Local.start(schema: %{"db" => %{"m" => %{"f" => :float}}})`. With it, a
  seed point would not show up in unbounded queries such as `COUNT(*)`.

## Verification

Reproduction scripts ran against the current code and against `v0.1.33`. The
guide's recipe relies only on the verified behaviour: once a column is a
float, a later integer is refused.
