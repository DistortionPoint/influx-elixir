# Review of the consumer-facing docs

**Date:** 2026-10-13
**Status:** Implemented

## Context

A sweep with no open GitHub issues. It follows the review of the shipped usage rules on
2026-10-12 (`2026-10-12_review-of-coverage-gaps.md`). This pass read the README and the
usage rules against the facade and the batch writer, the two places a consumer starts.

## Decisions

### Fixed in the usage rules

- **`point/3`'s arguments.** `usage-rules.md` gave them as "measurement, tags, fields".
  The facade takes `point(measurement, fields, opts)`, and the tags and the timestamp
  are options (`tags:`, `timestamp:`). An agent following the rule would pass the tags
  as the fields.
- **Which failures the batch writer retries.** `usage-rules/write.md` said every 4xx is
  discarded. The writer's classifier, its module doc and the README all retry 408 and
  429 with the 5xx statuses and transport errors.

### Checked, and right as written

- **The README.** Every call it shows exists with that arity:
  - `point/3`, `write/2`, `write_batched/2,3`, `flush/1`, `stats/1`, `query_sql/3`;
  - `TestHelper.setup_influx/1`, which takes `databases:` and `profile:`.

  Its retry list (network errors, 5xx, 408, 429) is the classifier's.
- **`flush/1` and `flush/2`.** The usage rules and the README name different arities.
  Both are right, because `flush/2`'s timeout has a default.
- **A pool timeout.** It is `{:error, {:connection_error, :pool_timeout}}`, as
  `usage-rules.md` says. The HTTP client's tests pin it.
- **The batch writer's bare `:timeout` and `:pool_timeout`.** No client of the library
  returns either from a write. They stay retryable all the same: the `:client` setting
  takes any module that implements `InfluxElixir.Client`, whose `write/3` may answer any
  `{:error, term()}`.

## Verification

- Each claim was read against the facade (`lib/influx_elixir.ex`), `BatchWriter`'s
  `classify/1` and the HTTP client's `classify_finch_error/1`.
- `mix docs` builds with no warnings.
