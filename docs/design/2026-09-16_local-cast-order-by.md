# `Client.Local` `CAST`, `::TYPE` and Multi-Term `ORDER BY`

**Date**: 2026-09-16
**Scope**: `Client.Local.SQLParser` expressions and `ORDER BY`, `Client.Local` evaluator
**Issue**: GitHub #20 ("REGRESSION in 0.1.24: Client.Local rejects CAST(col AS INTEGER) in WHERE")

---

## Verification of the report

The reported query, against InfluxDB 3 Core with `level` written as a tag
(`"5"`, `"20"`, `"100"`):

| Query | Engine | 0.1.23 | 0.1.24 |
|---|---|---|---|
| `WHERE CAST(level AS INTEGER) <= 20` | `"5"`, `"20"` | **`{:ok, []}`** | 400 `unsupported WHERE clause` |
| `WHERE level <= '20'` | `"20"`, `"100"` (lexical) | same | same |

The 0.1.24 rejection is real. The "regression" is not: 0.1.23's `AND`-only
splitter read `CAST(level AS INTEGER)` as the name of a column, looked it up,
found nothing and matched no rows — the 59 tests that passed on 0.1.23 were
passing on an empty result. 0.1.24's boolean-expression parser turned that
silent wrong answer into a refusal, which is the behaviour the double is
for; the missing piece was `CAST` itself.

The rest of `CAST`'s surface, recorded from the engine before implementing:

| Query | Engine |
|---|---|
| `CAST(level AS BIGINT | INT)`, `level::INTEGER` | as `INTEGER` |
| `CAST(level AS DOUBLE) <= 20.5` | numeric |
| `CAST(qty AS VARCHAR) = '2'` | text |
| `SELECT CAST(level AS INTEGER) AS lvl ... ORDER BY lvl` | 5, 20, 100 |
| `ORDER BY CAST(level AS INTEGER)`; `MAX(CAST(level AS INTEGER))` | ordered; 100 |
| `CAST(price AS INTEGER)` with 2.7 | 2 (truncation) |
| `CAST(qty AS DOUBLE)` | 1.0 |
| `CAST(level AS INTEGER) * 2 <= 40`; `... BETWEEN 5 AND 20`; `CAST(...) + qty` | as expected |
| `CAST('abc' AS INTEGER)`, `CAST('2.5' AS INTEGER)`, `CAST(time AS INTEGER)`, `CAST(level AS BOOLEAN)` | HTTP 200 with an **empty body**: the connection is closed mid-response; `Client.HTTP` returns `{:error, {:connection_error, %Mint.TransportError{reason: :closed}}}` |
| `ORDER BY p.price, r.n` | both terms applied (the double applied only the first — found on the way) |

## Design

**`CAST` is an expression node.** `{:cast, expr, :integer | :float |
:string}` joins the expression AST, parsed by the same recursive-descent
parser aggregates, projections and `WHERE` comparands already share, so it
works in every position at once. `col::TYPE` is rewritten to `CAST(col AS
TYPE)` before tokenising. Field references now resolve tags as well as
fields (a tag is a column). The evaluator converts as the engine does:
text to a number only when the whole string is one, float to integer by
truncation, number to text by rendering, null stays null. `BOOLEAN` and
`TIMESTAMP` targets are outside the subset and refused at parse time.

**A failing cast is a run-time error.** It is thrown from the evaluator
and caught once in `execute_select/4` — the same path a `LIKE` over a
number already took — and returned as `{:error, {:connection_error,
:closed}}`, the shape the HTTP client returns for the engine's dropped
connection. Reproducing the engine's failure mode, however unhelpful, is
what keeps a test that passes here from failing in production.

**`ORDER BY` is a list.** `order_by` is `[{target, direction}]` where a
target is a column, an output alias or `{:expr, ast}`; one stable
multi-key sort with a direction per key serves raw rows, projected rows,
grouped rows and `DISTINCT`. Grouped rows have no source point to evaluate
an expression against, so an expression term there is refused.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/sql_parser.ex` | `{:cast, _, _}` node, `cast_type/1`, `::` rewrite, `BETWEEN` / `LIKE` expression operands, multi-term `parse_order_by` |
| `lib/influx_elixir/client/local.ex` | `cast/2`, `eval_expr` over tags, `sort_by_keys/2`, run-time error catch in `execute_select/4` |
| `test/influx_elixir/client/local_test.exs` | Regression block: the reported query, every table row, multi-term ordering |
| `test/support/client_contract.ex` | `cast_tests`, run against Local and the server |
| `docs/guides/testing-with-local-client.md`, `usage-rules/query.md`, `CHANGELOG.md` | Updated |

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
