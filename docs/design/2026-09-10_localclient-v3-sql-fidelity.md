# LocalClient InfluxDB v3 SQL Fidelity: Ordered Aggregates and Literal Typing

**Date**: 2026-09-10
**Scope**: `InfluxElixir.Client.Local` — make the SQL subset reject what InfluxDB v3 rejects and type literals the way DataFusion does
**Issues**: GitHub #12, #13
**Supersedes**: `2026-03-17_localclient-first-last-aggregates.md`

---

## Problem

`Client.Local` is the documented drop-in test double for `Client.HTTP`. Its value
is that a query which passes against it behaves the same against InfluxDB v3.
Two behaviours broke that promise, and both were confirmed against a live
InfluxDB 3 Core (`influxdb:3-core`, `/api/v3/query_sql`) before any code changed.

### 1. Ordered aggregates use the wrong dialect (#13)

| SQL | real v3 engine | `Client.Local` (before) |
|---|---|---|
| `last_value(price ORDER BY time) AS price` | works | 400 `unsupported column expression` |
| `last_value(price) AS price` | works, **arbitrary row** | 400 |
| `LAST(price, time) AS price` | `Invalid function 'last'` | accepted |

`FIRST`/`LAST` are InfluxQL selectors. DataFusion has `first_value`/`last_value`
with an optional `ORDER BY` inside the call. Because the double and the engine
accepted disjoint syntax, a consumer could not write a "latest value per group"
query that passed both tests and production. The repository's own contract suite
(`test/support/client_contract.ex`) was red against the real engine on exactly
these two tests.

### 2. Quoted literals were re-typed (#12)

`parse_where_value/1` stripped the quotes from `'08338636'` and passed the content
through `Integer.parse`, producing `8338636`. `WHERE repcode = $rc` with a bound
string param therefore never matched a zero-padded string tag, while the real
engine matched it. The comment defending the coercion (`amount >= '1000.00'` must
not become a string comparison) was itself wrong: DataFusion casts the *numeric*
column to Utf8 in that comparison, so on the real engine `'500.0' >= '1000.00'`
is true and both rows come back.

### 3. Rejections read like server errors

`unsupported column expression: ...` sent the reporter to the InfluxDB docs
before the double's source.

## Design

### Ordered aggregates

* `@aggregate_functions` becomes `AVG SUM COUNT MIN MAX FIRST_VALUE LAST_VALUE`.
* New `@ordered_agg_pattern` parses
  `first_value(field [ORDER BY col [ASC|DESC]]) AS alias` (and `last_value`).
  The `ORDER BY` group is optional in the grammar only so a missing one can be
  reported specifically.
* Direction folds into the existing `{:ordered_aggregate, :first | :last, field,
  ordering, alias}` tuple at parse time: `:first` means "point with the smallest
  ordering value", `:last` the largest. `first_value(... DESC)` therefore parses
  to `:last`, `last_value(... DESC)` to `:first`. The executor
  (`compute_ordered_aggregate/4`) is unchanged.
* `first_value`/`last_value` **without** `ORDER BY` is rejected. DataFusion
  returns an arbitrary group member (observed: the middle of three points);
  defaulting to time order would certify a non-deterministic query.
* `FIRST(`/`LAST(` are kept in the aggregate *detection* list
  (`@influxql_only_functions`) purely so they reach `parse_single_column/1` and
  get a rejection that names the v3 spelling, instead of a generic parse failure.
* Plain aggregates accept exactly one argument; `AVG(x, y)` was silently accepted
  before and is not SQL.

### Literal typing

* `parse_where_value/1`: a quoted literal is returned as a string. Only bare
  literals go through `coerce_value/1`.
* `compare/3`: a string comparand against a non-string actual compares
  `to_string(actual)` — the DataFusion cast-to-Utf8 rule. Elixir renders `500.0`
  as `"500.0"` and `5` as `"5"`, matching Arrow's rendering for the common cases.
* `:in`/`:not_in` reuse `compare/3` per value so the same rule applies.
* Time conditions are unaffected: `to_nanoseconds/1` already parsed
  integer-as-string.

### Error prefix

Every parser rejection is built by `local_error/1` and carries the body prefix
`Client.Local: `. Line-protocol write rejections keep their existing bodies —
those mirror what the real write endpoint returns.

### Param substitution (found during review)

`resolve_params/2` did a sequential `String.replace/3` per param, so `$h` was
rewritten inside `$hmin` and a substituted string containing `$min` could be
re-substituted. It is now one `Regex.replace/3` over `\$\w+` with a map lookup.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local.ex` | Parser, comparison, params, error prefix, moduledoc |
| `test/influx_elixir/client/local_test.exs` | Rewritten ordered-aggregate tests, new literal-typing and param tests |
| `test/support/client_contract.ex` | `first_value`/`last_value` contract, new `literal_tests` group |
| `docs/guides/testing-with-local-client.md` | Ordered aggregates, literal typing, param warning |
| `docs/design/2026-03-17_localclient-first-last-aggregates.md` | Superseded banner |
| `CHANGELOG.md` | Unreleased entries |

## Verification

```bash
docker run -d --rm --name influx3_verify -p 8181:8181 influxdb:3-core \
  influxdb3 serve --node-id node0 --object-store memory --without-auth
mix test
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration
mix credo --strict
mix dialyzer
mix format --check-formatted
```

The integration run is the proof: the same contract assertions pass against
`Client.Local` and against the real engine.
