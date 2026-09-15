# `Client.Local` WHERE as a Boolean Expression

**Date**: 2026-09-15
**Scope**: `Client.Local.SQLParser` WHERE parsing, `Client.Local` filter and comparison
**Issue**: scheduled quality sweep

---

## Problem

Probing the double with ordinary predicates against InfluxDB 3 Core
(`influxdb:3-core`, `--object-store memory --without-auth`; tags `host`,
`rack` = "1","2",—,"4","10"; field `v` = 1.0, 2.5, 3.0, 4.0, 5.0):

| Query | Engine | Double before |
|---|---|---|
| `v > 3 OR v < 2` | a, d, e | **c, d** (predicate read as `v > "3 OR v < 2"`) |
| `(host = 'a' OR host = 'b') AND v > 2` | b | **[]** |
| `host = 'a' OR host = 'b' AND v > 2` | a, b (AND binds tighter) | **[]** |
| `NOT host = 'a'` | b, c, d, e | **[]** |
| `v <> 1.0` | b, c, d, e | **[]** (split on `<`) |
| `LIMIT 0` | [] | **all rows** |
| `LIMIT -1` | 400 "LIMIT must be >= 0" | **all rows** |
| `rack = 2` | b (literal rendered as text) | [] |
| `rack > 3` | d (lexical: "10" < "3") | **a, b, d, e** (term order) |
| `rack >= 10` | b, d, e | **[]** |
| `v BETWEEN 2 AND 3`, `NOT BETWEEN` | b, c / a, d, e | 400 (honest) |
| `host LIKE 'a%'`, `ILIKE`, `NOT LIKE`, `'_'` | as SQL | 400 (honest) |
| `v LIKE '1%'` | 400 "no common type … in LIKE" | — |

Every bold cell is a query the engine runs and the double answered with
different rows — the class of divergence a test double must never have.
The `AND`-only splitter dates from the first version of the parser; the
term-order comparison of a string column against a number was the mirror
image of the #12 fix (a string literal against a numeric column), never
applied in this direction.

## Design

**Grammar.** The WHERE text is tokenised into grouping parentheses, the
keywords `AND` / `OR` / `NOT` and predicate text, then parsed by recursive
descent: `expr := term (OR term)*`, `term := factor (AND factor)*`,
`factor := NOT factor | '(' expr ')' | predicate`. Parentheses inside a
predicate (`IN (...)`, `now()`) and keywords inside one (`NOT IN`,
`NOT LIKE`, the `AND` of `BETWEEN a AND b`) stay in its text; string
literals are opaque. The result keeps the existing shape — a conjunction
list — with `{:or, branches}` and `{:not, conjunction}` nodes inside it, so
every executor path (raw, projection, aggregate, distinct, CTE) filters
through one `matches_all?/2` and nothing else changed.

**Predicates.** `<>` joins the operator table; `[NOT] BETWEEN` becomes
`{:between | :not_between, key, {low, high}}` (time comparands parsed as
elsewhere); `[NOT] LIKE` / `ILIKE` compile to an anchored regex (`%` →
`.*`, `_` → `.`, everything else escaped; `ILIKE` case-insensitive).
`LIKE` over a numeric value is a planning error on the engine and can only
be discovered per value here, so it is thrown out of the filter and
returned as the same 400.

**Comparison.** A string column against a numeric literal renders the
literal as text and compares lexically — the engine's coercion, verified
above — mirroring the existing rule for a string literal against a numeric
column.

**LIMIT.** `0` is a valid limit (no rows). A negative or non-numeric limit
is refused before parsing, with the engine's wording.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/sql_parser.ex` | `tokenize_where`, `where_or/and/factor`, `where_node` type, `<>`, `BETWEEN`, `LIKE`, `check_limit` |
| `lib/influx_elixir/client/local.ex` | `apply_where` over nodes with error propagation, `between`/`like` predicates, string-vs-number comparison, moduledoc |
| `test/influx_elixir/client/local_test.exs` | Regression block for every table row |
| `test/support/client_contract.ex` | `where_tests`, run against Local and the server |
| `docs/guides/testing-with-local-client.md`, `usage-rules/query.md` | "WHERE Clauses", literal typing |
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
