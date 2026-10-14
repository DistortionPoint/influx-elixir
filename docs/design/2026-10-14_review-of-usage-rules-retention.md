# Review of the usage rules on retention

**Date:** 2026-10-14
**Status:** Implemented

## Context

A sweep with no open GitHub issues. It continues the review of the shipped usage rules
(`2026-10-12_review-of-coverage-gaps.md`, `2026-10-13_review-of-consumer-docs.md`) and
read `usage-rules/testing.md` against the testing guide.

## Decisions

### Retention is applied, not ignored

- **What the rule said.** `usage-rules/testing.md` said the double "stores no retention,
  so nothing expires in tests".
- **What the double does.** The guide's Retention section, verified against Core, and
  `retention_visibility_test.exs` say otherwise. The double keeps the retention and
  applies it as InfluxDB 3 does:
  - a write is never refused for a point's age;
  - a query hides a 10-minute chunk of a table once its newest point is older than the
    period.
- **The risk.** A consumer following the old rule would expect an old fixture point to
  stay visible, and a test that wrote one would find it gone.
- **The rule now.** It states the behaviour, and tells a test to write a point at least
  ten minutes past the retention when it wants the point gone.

### Checked, and right as written

The other claims of `usage-rules/testing.md` agree with the guide:
- no implicit default database, and `{:error, :no_database_specified}` without one;
- named tokens and their 409 and 404 answers;
- `health/1`'s shape on each server;
- the database name rules and Core's limit of five databases.

## Verification

- The rule was read against the guide's Retention section and
  `test/influx_elixir/client/local/retention_visibility_test.exs`.
- `mix docs` builds with no warnings.
