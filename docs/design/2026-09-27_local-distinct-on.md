# Client.Local: SELECT DISTINCT ON

**Date**: 2026-09-27
**Scope**: `Client.Local.SQLParser`, `Client.Local.SQLExecutor`
**Issue**: #23

---

## Problem

Issue #23 reports that `Client.Local` refuses every `SELECT DISTINCT ON`
query with `Client.Local: unsupported DISTINCT query`, while InfluxDB 3
runs it. A consumer rescued the refusal, so its test saw "no rows" rather
than a failure.

Both halves were verified. The parser's `DISTINCT` pattern read
`ON (k) k, v` as the column list and refused it. `influxdb:3-core` answers
the query.

A probe against Core, with six points over keys `k` (and `j` on one point),
pinned the semantics:

- The engine keeps the first row per distinct key tuple in `ORDER BY`
  order. `LIMIT` and `OFFSET` apply afterwards, and `WHERE` applies before.
- The output is in `ORDER BY` order.
- An `ON` column need not be selected (`SELECT DISTINCT ON (k) v`). The
  same goes for `SELECT *`.
- A row without a key column falls under the null key, which follows
  `NULLS FIRST` and `NULLS LAST` like any value.
- If there is an `ORDER BY`, it must start with the `ON` expressions in
  their order, otherwise the engine answers 400 `SELECT DISTINCT ON
  expressions must match initial ORDER BY expressions`. That includes
  `ORDER BY j, k` for `ON (k, j)` and `ORDER BY k` for `ON (k, j)`. An
  ordinal such as `ORDER BY 1` counts. The direction and `NULLS`
  placement do not matter.
- `ORDER BY` resolves against the table, not the select list. A select
  alias there is the engine's 500 `Schema error: No field named kk`.
- Aggregates or `GROUP BY` are the engine's 405, `This feature is not
  implemented: DISTINCT ON expressions with GROUP BY, aggregation or
  window functions are not supported ` (with a trailing space).
- `ON ()` is 400 `No \`ON\` expressions provided`.
- Without `ORDER BY`, the row kept for each key and the output order are
  arbitrary. Two runs of the same query returned `b, a, c` and then
  `a, c, b`.
- `DISTINCT ON (DATE_BIN(...))` works on the engine.

## Decision

- **Parser.** The `DISTINCT ON (...)` list is taken out of the text before
  the select is split. The balanced-parenthesis reader handles an `ON`
  expression that contains parentheses. What remains parses as the
  ordinary select it is: star, projection or constant.
- **Refusals.** The engine's refusals are applied in its order:
  - the 405 for aggregates or `GROUP BY` comes first, based on the select
    list only, so a `DATE_BIN` in `ORDER BY` is not mistaken for an
    aggregate;
  - then the empty-`ON` 400;
  - then the `ORDER BY` prefix rule.

  A leading `ORDER BY` term that is a select alias is left to the
  executor's column check, which answers the engine's schema error first.
- **Double's limit.** The double takes plain or quoted column names in
  `ON` and refuses an expression by name. It does not guess a
  `DATE_BIN` key.
- **Executor.** Rows are de-duplicated after ordering and before
  `apply_limit`, on both the raw path and the projected path. The key is
  read from the source point, so an unselected `ON` column works. `time`
  keys on the stored nanoseconds.
- **Column checks.** Under `DISTINCT ON`, `ORDER BY` aliases are not
  exempt from the column check, and the `ON` columns are checked too.
- `query_sql/3`'s `@doc` listed a subset from long ago (for example,
  `ORDER BY time ASC|DESC` only). It now points to the moduledoc's SQL
  section, which is kept current.

## Verification

- A new contract block, `SELECT DISTINCT ON contract`, passes on Local
  and on InfluxDB 3 Core. It covers latest-per-key, `WHERE` + `LIMIT` +
  `OFFSET`, several keys, an unselected key, the null key, `SELECT *`
  with `DESC`, and each refusal.
- The probe script compares all 31 probed queries between the two
  clients. They agree except for the unspecified no-`ORDER BY` order and
  quoted identifiers in the select list. The quoted identifiers are a
  separate gap, addressed in
  [`local-sql-identifiers`](2026-09-27_local-sql-identifiers.md).
- A Local test covers the by-name refusal of an `ON` expression, through
  `query_sql/3` and `check_sql/1`.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/sql_parser.ex` | `split_distinct_on/1`, `check_distinct_on_grouping/2`, `apply_distinct_on/2`, `distinct_on` in the query |
| `lib/influx_elixir/client/local/sql_executor.ex` | `distinct_on/3`; column references under `DISTINCT ON` |
| `lib/influx_elixir/client/local.ex` | Moduledoc; `query_sql/3` doc |
| `test/support/client_contract.ex`, `test/influx_elixir/client/local_test.exs` | Tests |
| `docs/guides/testing-with-local-client.md`, `usage-rules/query.md`, `CHANGELOG.md` | Updated |
