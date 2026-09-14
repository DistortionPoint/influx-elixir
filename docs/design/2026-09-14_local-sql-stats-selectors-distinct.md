# `Client.Local` Statistical Aggregates, Selectors, Multi-Column DISTINCT and Null Omission

**Date**: 2026-09-14
**Scope**: `InfluxElixir.Client.Local`, `Client.Local.SQLParser`, `Query.ResponseParser`, testing guide
**Issue**: GitHub #16, #17

---

## Verification of the reports

Both issues claimed queries that InfluxDB 3 accepts were `Client.Local:` 400s
in the double. Every claim was replayed against InfluxDB 3 Core
(`influxdb:3-core`, `--object-store memory --without-auth`) with three rows
`value = 10, 20, 30` before anything was changed:

| Query | Engine | Double before |
|---|---|---|
| `STDDEV(value)` / `STDDEV_SAMP` | `10.0` | 400 `invalid aggregate` |
| `STDDEV_POP(value)` | `8.16496580927726` | 400 |
| `VAR(value)` / `VAR_SAMP` | `100.0` | 400 |
| `VAR_POP(value)` | `66.66666666666667` | 400 |
| `VARIANCE(value)` | planning error | 400 (correct) |
| `SUM(value * value)`, `AVG(value / 2)`, `MAX(value - 1)` | `1400.0`, `10.0`, `29.0` | 400 `invalid aggregate` |
| `SUM(ivalue / 2)` with `ivalue = 3` | `1` (integer division) | — |
| `selector_first(value, time)['value']`, `['time']` | value / timestamp | 400 |
| `SELECT DISTINCT provider, symbol` | 2 rows | 400 `unsupported DISTINCT` |
| `ORDER BY bucket DESC` (a `DATE_BIN` alias) | sorted | 400 |
| `STDDEV` over one row | column absent | `nil` present |
| empty group | `{"n": 0}` only | every column `nil` |
| `SUM(value / 0)` (float) | IEEE `inf`, rendered `null`, counted by `COUNT` | — |
| `SUM(ivalue / 0)` (integer) | execution error | — |

Both reports were real. Item 3 of #17 (documentation of the integration
tier) was also real: the guide had no section on running against a server.

A fourth defect surfaced while running the new contract tests against the
server: over HTTP the engine renders every timestamp column as a zone-less
string (`"2023-11-14T22:12:00"`), and `Query.ResponseParser` decoded only
columns named `time` / `_time` / `_start` / `_stop`. A `DATE_BIN(...) AS
bucket` alias was a `DateTime` from `Client.Local` and over Flight, but a
string over HTTP JSON — the class of divergence the double exists to
prevent.

## Design

**Parser** (`SQLParser`). The aggregate column pattern accepts the
statistical function names and captures the whole argument, which a small
recursive-descent parser turns into an expression AST
(`{:field, name} | {:lit, n} | {:op, :+ | :- | :* | :/, l, r}`) with the
usual precedence; a token that is not a number, identifier, operator or
parenthesis, unbalanced parentheses and trailing tokens are rejected, so
`AVG(a, b)` and `AVG(value +)` stay `Client.Local:` errors. Selectors are one
pattern, `selector_(first|last|min|max)(field, ordering)['value'|'time'] AS
alias`. `DISTINCT` takes a column list. `ORDER BY` captures `{column,
direction}` for any column, not just `time`.

**Executor** (`Client.Local`). Aggregates evaluate the expression per point
(a missing field or non-numeric operand is null and is skipped; two integer
operands divide with `div/2`), then fold: sample variance needs at least
two values, `COUNT` is always a count. Selectors pick the point by ordering
column or by field and return its value or its timestamp as a `DateTime`.
Rows are assembled with `put_column/3`, which drops a null, so a row never
carries a `nil` value — matching the engine's JSON. `ORDER BY` sorts on the
projected column (with `time` mapped to the `DATE_BIN` alias when one
exists) using a `DateTime`-aware comparator in either direction.

`check_sql/1` exposes the parser's verdict without executing, so a consumer
test can `flunk/1` with the double's reason and cover the query in its
integration tier.

**Response parser**. JSON carries no column types, so decoding is by shape:
a string matching InfluxDB 3's zone-less rendering
`YYYY-MM-DDTHH:MM:SS[.fraction]` is a timestamp under any key; the zoned
RFC3339 form (what v2 emits) is decoded only under the well-known time
keys, as before. The trade-off — a *string field* holding exactly the
zone-less shape is also decoded — is documented in the moduledoc.

**Rejected**: emulating IEEE infinity for float division by zero. Erlang
has no float infinity; the double yields null and the guide's "Key
Differences" records the engine's behaviour (infinity rendered as JSON
`null`, counted by `COUNT`; integer division by zero fails the query).

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/sql_parser.ex` | Statistical aggregates, expression parser, selector pattern, multi-column `DISTINCT`, `ORDER BY {column, dir}` |
| `lib/influx_elixir/client/local.ex` | `check_sql/1`, expression evaluation, variance/stddev, selectors, null omission, generalised `ORDER BY`, moduledoc |
| `lib/influx_elixir/query/response_parser.ex` | Shape-based timestamp decoding under any key |
| `lib/influx_elixir/connection.ex` | Doc link to a hidden function removed (ExDoc warning) |
| `mix.exs` | `LICENSE` added to ExDoc extras (README link warning) |
| `test/influx_elixir/client/local_test.exs` | Regression blocks for #16 and #17, `check_sql/1`, integer division |
| `test/influx_elixir/query/response_parser_test.exs` | Aliased timestamp columns; zoned strings outside time keys stay strings |
| `test/support/client_contract.ex` | Stats / expression / selector / `ORDER BY` alias / multi-column `DISTINCT` contract tests, run against Local and the server |
| `docs/guides/testing-with-local-client.md` | Aggregate section, `check_sql/1`, integration tier, key differences |
| `usage-rules/query.md`, `usage-rules/testing.md` | Timestamp typing, null omission, two-tier testing |
| `CHANGELOG.md` | Fixed / Added entries |

## Verification

```bash
mix format --check-formatted && mix compile --warnings-as-errors
mix test                      # three runs, 0 failures
mix credo --strict && mix dialyzer && mix docs   # no warnings
docker run -d --rm --name influx3_verify -p 8181:8181 influxdb:3-core \
  influxdb3 serve --node-id node0 --object-store memory --without-auth
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration
docker stop influx3_verify
```

The new contract tests pass unchanged against `Client.Local` and against
InfluxDB 3 Core, including the `DateTime` typing of `selector_*['time']`
over HTTP.
