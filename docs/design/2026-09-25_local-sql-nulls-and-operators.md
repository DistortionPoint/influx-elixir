# `Client.Local` SQL: NULL Semantics, LIKE Escapes and Operators

**Date**: 2026-09-25
**Scope**: `SQLExecutor` WHERE evaluation, sorting and `DISTINCT`; `SQLParser` LIKE, predicates, expressions and `ORDER BY`
**Issue**: scheduled quality sweep

---

## Problem

A differential run of 46 queries from the documented SQL subset against
`influxdb:3-core` (five points: tags with and without `rack`, integer,
float, string and boolean fields, some missing) found 8 differences; a
follow-up of 24 more found the rest. Silent wrong answers:

| Query | InfluxDB 3 | Double before |
|---|---|---|
| `WHERE NOT (rack = '1')` | rows with another rack | also the row without a rack |
| `WHERE NOT (v > 0)` | `a` | `a`, `b` (v null) |
| `ORDER BY rack` (string with nulls) | nulls last | nulls first |
| `ORDER BY rack DESC` | nulls first | nulls last |
| `GROUP BY rack ORDER BY rack` | null group last | null group first |
| `SELECT DISTINCT b ORDER BY b` | `false, true, %{}` | `false, true` |
| `WHERE s LIKE 'al\%%'` | `al%pha` | none |

Refused although valid: `WHERE b`, `WHERE NOT b`, `n % 3`, `v % 2`,
`-n`, `ORDER BY v NULLS FIRST`, `HAVING`.

The WHERE evaluator was two-valued (`compare(nil, ...)` was `false`, so
`NOT` made it `true`). Sorting used Erlang term order, where `nil` is an
atom: after numbers, before strings, between `false` and `true`.

## Decision

- **Three-valued logic.** Conditions return `true | false | nil`; a
  comparison, `BETWEEN`, `LIKE` or `IN` with a null operand is `nil`;
  `AND`, `OR` and `NOT` follow Kleene logic; a row is kept only when the
  predicate is `true`. `matches_all?/2` (also used by `DELETE`) keeps its
  boolean contract.
- **Null placement.** `ORDER BY` terms carry `:asc | :desc` (nulls last /
  first) or `{dir, :nulls_first | :nulls_last}`; the comparator places
  nulls before comparing values.
- **DISTINCT** keeps the all-null combination as `%{}`.
- **LIKE** treats `\x` as a literal `x`.
- **Predicates and operators.** A bare column is `{:truthy, col}`: a
  boolean value is the result, null is unknown, anything else is the
  engine's planning error ("Cannot create filter with non-boolean predicate
  't.n' returning Int64"). `%` (`rem/2` for integers, `:math.fmod/2` for
  floats, the dividend's sign) and unary minus (`{:neg, expr}`) join the
  expression grammar.
- `HAVING` remains refused by name: it needs expressions over aggregates.

## Verification

All 32 targeted and 30 regression queries return identical results on
InfluxDB 3 and the double. The contract suite gains
`null_semantics_tests`, run against Local and `influxdb:3-core` (104
tests, 0 failures).

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/sql_executor.ex` | `eval_all/2`, `eval_node/2` three-valued; `{:truthy, _}`; null placement; `:rem`, `{:neg, _}`; DISTINCT |
| `lib/influx_elixir/client/local/sql_parser.ex` | LIKE escapes; bare boolean predicate; `%` and unary minus; `NULLS FIRST/LAST`; `t:direction/0` |
| `lib/influx_elixir/client/local.ex` | moduledoc |
| `test/influx_elixir/client/local_test.exs` | nulls and operators block |
| `test/support/client_contract.ex` | `null_semantics_tests` |
| `docs/guides/testing-with-local-client.md`, `usage-rules/query.md`, `CHANGELOG.md` | Updated |

```bash
mix format --check-formatted && mix compile --warnings-as-errors
mix test                      # three runs, 0 failures
mix credo --strict && mix dialyzer && mix docs
docker run -d --rm --name influx3_verify -p 8181:8181 influxdb:3-core \
  influxdb3 serve --node-id node0 --object-store memory --without-auth
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration
docker stop influx3_verify
```
