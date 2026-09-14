# `Client.Local` CTEs, Projected Expressions and Table Qualifiers

**Date**: 2026-09-15
**Scope**: `Client.Local.SQLParser`, `Client.Local` executor, contract suite, testing guide
**Issue**: GitHub #18 (follow-up to #17)

---

## Verification of the report

Both claims replayed against InfluxDB 3 Core (`influxdb:3-core`,
`--object-store memory --without-auth`) with four quotes rows before any
change:

| Query | Engine | Double before |
|---|---|---|
| `SELECT (bid + ask) / 2 AS mid, time FROM q` | rows; a row with null `ask` has no `mid` key | 400 `unsupported SQL` |
| `SELECT (bid + ask) / 2 AS mid FROM q ORDER BY mid DESC` | `{}`, 6.0, 3.0, 2.0 | 400 |
| `SELECT bid * 2 FROM q` | column named `q.bid * Int64(2)` | 400 |
| `WITH w AS (SELECT bid, time FROM q) SELECT DATE_BIN(INTERVAL '1 minute', w.time) AS time, MAX(w.bid) AS hi FROM w GROUP BY DATE_BIN(INTERVAL '1 minute', w.time)` | one row per minute | 400 `missing GROUP BY DATE_BIN` |
| `WITH w AS (SELECT (bid + ask) / 2 AS mid, time FROM q WHERE ask IS NOT NULL) SELECT DATE_BIN(...), selector_first(mid, time)['value'] AS open, MAX(mid) AS high FROM w GROUP BY DATE_BIN(...)` | candles | 400 |
| `WITH w AS (...), x AS (SELECT provider, MAX(bid) AS mb FROM w GROUP BY provider) SELECT * FROM x` | two rows, no `time` key | 400 |
| `SELECT t.bid FROM q t WHERE t.provider = 'b'` | rows | 400 |
| `SELECT * FROM w CROSS JOIN q` | joined rows | **rows from `w` alone** |
| `SELECT bid FROM q UNION SELECT ask FROM q` | union | **`UNION` taken as a table alias** |

Both reported constructs are real. The report's diagnosis of the second —
"it is the `w.` prefix that stops the GROUP BY matching" — is only half of
it: with the prefix accepted, `FROM w` still named a table the double did
not have, because the double had no CTEs at all. Fixing the qualifier alone
would have swapped one 400 for another. The last two rows were found while
probing: the tail of a query after the table name was never validated, so a
join or set operation was silently answered from the first table — a wrong
result rather than a refusal, the worst class of divergence for a test
double.

## Design

**Statement = CTEs + one SELECT.** `parse_select/1` splits a leading
`WITH name AS ( ... )[, ...]` list by balanced-parenthesis scanning, parses
each body and the final query with the existing single-select parser, and
returns the main query with `ctes: [{name, parsed_query}]`. The executor
materialises the CTEs in order — each over the store or an earlier CTE —
turning every result row into a point whose non-`time` columns are fields
(the tag/field distinction is storage detail the next query cannot see), and
the final query reads from a CTE by name before it looks for a measurement,
as SQL scoping requires.

**Qualifiers.** One table per query, so a qualifier adds nothing: the
parser drops the alias from `FROM q AS w` / `FROM q w` and every
`q.`/`w.` prefix outside string literals before dispatching. Keywords that
can follow a table name are never read as an alias.

**Projected expressions.** `parse_projection_column/1` accepts
`<expr> AS alias` through the same expression parser aggregates use. An
expression without an alias is refused: DataFusion names it after its own
rendering (`q.bid * Int64(2)`), which the double will not guess. Rows are
projected first and then ordered, so `ORDER BY` can name a projected alias
as well as any source column.

**Refuse what cannot run.** After the CTEs are split off, a single query
must contain one `SELECT`, none of `JOIN | UNION | EXCEPT | INTERSECT |
HAVING | OFFSET | OVER | QUALIFY`, and only `WHERE` / `GROUP BY` / `ORDER
BY` / `LIMIT` after the table. Anything else is a `Client.Local: unsupported
SQL construct <NAME>` 400 — the honest answer the double gives for
everything else it cannot express, and what `check_sql/1` reports so the
query can go to the integration tier.

Rejected: emulating `median` and `CROSS JOIN` for the full production query
in #17. The double's job is the subset it can run faithfully; the guide's
integration-tier section covers the rest.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/sql_parser.ex` | `split_ctes`, `take_balanced`, `parse_single_select`, `strip_table_qualifiers`, `check_clauses`, expression projections, `ctes` in `parsed_query` |
| `lib/influx_elixir/client/local.ex` | `execute_query` materialises CTEs; `execute_select` reads CTE or store; `rows_to_points`; `execute_projection_query` / `project_point` / `order_projected`; `point_to_row` omits a nil time; moduledoc |
| `test/influx_elixir/client/local_test.exs` | Regression block for #18 (every table row, plus the construct refusals) |
| `test/support/client_contract.ex` | `cte_tests`: projected expression, qualified DATE_BIN CTE, candle shape, chained CTEs and aliases — run against Local and the server |
| `docs/guides/testing-with-local-client.md`, `usage-rules/query.md` | "Projected Expressions, CTEs and Table Aliases" |
| `CHANGELOG.md` | Fixed entries |

## Verification

```bash
mix format --check-formatted && mix compile --warnings-as-errors
mix test                      # three runs, 0 failures
mix credo --strict && mix dialyzer && mix docs
docker run -d --rm --name influx3_verify -p 8181:8181 influxdb:3-core \
  influxdb3 serve --node-id node0 --object-store memory --without-auth
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration
docker stop influx3_verify
```
