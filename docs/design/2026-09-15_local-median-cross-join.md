# `Client.Local` `median()`, `CROSS JOIN` and Expression Comparands

**Date**: 2026-09-15
**Scope**: `Client.Local.SQLParser`, `Client.Local` executor, contract suite, testing guide
**Issue**: GitHub #19 (follow-up to #17 and #18)

---

## Verification of the report

Replayed against InfluxDB 3 Core (`influxdb:3-core`, `--object-store memory
--without-auth`) before any change, with prices 1.0, 2.5, 3.0, 4.0, 100.0
(volumes 10, 20, 30, 40, 1) and integers 1..4:

| Query | Engine | Double before |
|---|---|---|
| `median(price)`, `median(volume)` | 3.0, 20.0 | 400 `unsupported column` |
| `median(price) WHERE price < 4` (odd count) | 2.5 | 400 |
| `median(n)` over 1..4, over `IN (1, 4)` | 2, 2 (integer mean) | 400 |
| `median(price) WHERE price > 1000` | `{}` | 400 |
| `median(price * 2)`; `median(time)` | 6.0; 400 planning error | 400 |
| `DATE_BIN ... median(price)` | 1.75, 4.0 | 400 |
| the issue's candle query (`CROSS JOIN ref`, `w.price <= ref.med * 3`) | two candles | 400 `unsupported SQL construct JOIN` |
| `p CROSS JOIN r` with two `r` rows | cartesian product | 400 |
| `SELECT price FROM p CROSS JOIN ref` with `price` on both sides | 500 "Ambiguous reference" | 400 |
| `WHERE price <= volume * 0.2`, `WHERE 2 * price > volume` | rows | **`price` compared with the text `"volume * 0.2"`** |
| `WHERE price = prod` | 500 "No field named prod" | **`{:ok, []}`** |
| `WHERE symbol = $sym`, unbound | 400 "No value found for placeholder with name $sym" | **`{:ok, []}`** |

Both constructs in the report are real. Two more defects surfaced on the
way: a bare word on the right of a comparison was compared as a string —
so an expression comparand, or a forgotten pair of quotes, gave silently
wrong rows — and a `nil` param rendered as the word `nil`.

## Design

**`median`** joins the aggregate table. DataFusion returns the middle
value, or for an even count the mean of the two middle values computed in
the column's type: two integers average with integer division. Verified
above; the executor sorts with the `DateTime`-aware order and does exactly
that. `median(time)` is refused by the existing Timestamp check.

**`CROSS JOIN`.** The parser takes `CROSS JOIN t [AS a]` out of the FROM
clause before the single-table parser sees it, records the right table and
its alias on the query, and drops both sides' qualifiers. The executor pairs
every left point with every right point, merging the right side's columns
in as fields, before the WHERE filter runs — which is what makes
`ref.med * 3` visible to every row. A column present on both sides cannot
be told apart once qualifiers are gone, so the join is refused with the
engine's "Ambiguous reference" wording; the engine refuses the unqualified
reference as well. `time` on both sides counts as a collision.

**Comparands.** Either side of a comparison is a column or an arithmetic
expression over columns and literals (`{:expr, ast}`, evaluated per row
with the same evaluator aggregates use); the right side may also be a
literal. A bare word is a column reference, never a string. Before the
filter runs, the columns referenced by expressions are checked against the
rows' columns and a missing one returns the engine's schema error (500,
"No field named …"), because an empty result would hide the mistake the
error exists to catch. A `nil` param renders as `NULL`, which never
matches.

Rejected: keeping bare words as strings "for convenience" — that is the
double answering a query the engine refuses.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/sql_parser.ex` | `MEDIAN`, `split_cross_join`, qualifier stripping for both sides, `parse_operand` / `parse_comparand`, `NULL` |
| `lib/influx_elixir/client/local.ex` | `median/1`, `cross_join/5` with collision check, `check_where_columns`, expression operands, moduledoc |
| `test/influx_elixir/client/local_test.exs` | Regression block for every table row |
| `test/support/client_contract.ex` | `median_join_tests`, run against Local and the server |
| `docs/guides/testing-with-local-client.md`, `usage-rules/query.md` | Candle query with `median` and `CROSS JOIN`, bare words |
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
