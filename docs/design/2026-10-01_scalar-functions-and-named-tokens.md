# Scalar Functions in Local SQL; Tokens by Name

**Date**: 2026-10-01
**Scope**: `Client.Local` SQL (`SQLParser`, `SQLExecutor`, new `SQLFunctions`);
token management (`Client.HTTP`, `Client.Local`, `Admin.Tokens`, new
`Admin.TokenRequest`)
**Issue**: #25, plus the token mismatch recorded in
[`2026-09-30_writer-timer-csv-gzip-restart`](2026-09-30_writer-timer-csv-gzip-restart.md)

---

## Problem

**#25.** `WHERE abs(amount) >= $threshold` runs on InfluxDB 3, but
`Client.Local` 0.1.37 refused it ("unsupported WHERE clause"). Before
that, it read `abs(amount)` as a column name and returned no rows.

The claim was verified against Core 3.10.1, along with the rest of the
class:
- `abs`, `round`, `floor` and `ceil` work in `WHERE`, on either side of a
  comparison, in `BETWEEN` and in `IN`.
- They also work in the select list, in `ORDER BY` and inside
  aggregates (`sum(abs(x))`).
- `abs` keeps the argument's type: `Int64` stays `Int64`, `UInt64` stays
  `UInt64`.
- `round`, `floor` and `ceil` return `Float64`. `round` rounds half away
  from zero, and `round(x, n)` takes an integer scale, so
  `round(1234.5678, -2)` is `1200.0`.
- A null argument gives null.

The errors are planning errors: they fail the query even when `WHERE`
matches no rows. Their wording depends on where the call stands:

| Clause | Body |
|--------|------|
| `WHERE` | `type_coercion\ncaused by\nError during planning: <head> No function matches the given name and argument types '<f>(<types>)'. You might need to add explicit type casts.\n\tCandidate functions:\n\t<candidates>` |
| `ORDER BY` | `type_coercion\ncaused by\nError during planning: <head>` |
| select list, aggregate | `Error during planning: <head> No function matches …` |

The heads are:
- for `abs`:
  - `Function 'abs' expects NativeType::Numeric but received NativeType::String`;
  - `Function 'abs' expects 1 arguments but received 2`;
  - `'abs' does not support zero arguments`;
- for `round`, `floor` and `ceil`:
  `Failed to coerce arguments to satisfy a call to 'round' function: coercion from <types> to the signature … failed`.

The Arrow types named are:
- `Utf8` for a string field;
- `Dictionary(Int32, Utf8)` for a tag;
- `Boolean`;
- `Timestamp(ns)`;
- `Int64`, `UInt64` and `Float64` for numbers.

`floor(x, n)` and `ceil(x, n)` are 405
`This feature is not implemented: FLOOR with scale is not supported`.

The same probes turned up three more gaps in Local:
- `abs(x) IS NULL` and `abs(x) IN (…)` were refused.
- `1 < f` was read as a column named `1`, which is the engine's schema
  error for a query the engine answers.

**Tokens.** The library called `POST /api/v3/configure/token` with
`{"description", "permissions"}`, and `DELETE /api/v3/configure/token/{id}`.

Core 3.10.1 answers both with 404 when auth is on, and with 405
`endpoint disabled, started without auth` when it is off. The
Enterprise 3.11.5 CLI's own requests were captured with a listener; no
license was needed:

| CLI | Request |
|-----|---------|
| `create token --admin --name a1 --expiry 1d` | `POST /api/v3/configure/token/named_admin` `{"token_name":"a1","expiry_secs":86400}` |
| `create token --permission "db:db1,db2:read,write" --permission "system:*:read" --name t1 --expiry 10d` | `POST /api/v3/enterprise/configure/token` `{"token_name":"t1","permissions":[{"resource_type":"db","resource_names":["db1","db2"],"actions":["read","write"]},{"resource_type":"system","resource_names":["*"],"actions":["read"]}],"expiry_secs":864000}` |
| `delete token --token-name t1` | `DELETE /api/v3/configure/token?token_name=t1` |

Core with auth answers as follows:
- **Create:** 201 with
  `{"id","name","token":"apiv3_<86 chars>","hash":<128 hex>,"created_at":"…T…\.mmmZ","expiry":<same form>|null}`.
- **Ids:** they start at 1 (the operator token `_admin` is 0) and are
  never reused. A failed create spends no id.
- **Taken name:** 409 `token name already exists, NAME`, including for
  `_admin`.
- **Bad `expiry_secs`:**
  `400 serde json error: <what>, expected u64 at line 1 column N`, where
  N is the byte before the closing brace.
- **Resource-token endpoint:** 404 `Not found`.
- **Delete:**
  - success is 200;
  - an unknown name is 404 `the requested resource was not found: NAME`;
  - `_admin` is 405 `cannot delete operator token`.

## Decision

- **Functions.**
  - **Parsing.** The expression grammar gains
    `{:call, :abs | :round | :floor | :ceil, args}`, with
    case-insensitive names, any number of comma-separated arguments, and
    nesting. That one change reaches every place an expression stands.
  - **Checking.** `SQLFunctions.check/3` builds the planner's error from
    the arguments' types, per clause. The executor checks every call
    against the table's column types after the schema check and before
    filtering, in planner order: `WHERE`, then the select list, then
    `ORDER BY`.
  - **Evaluation.** `SQLFunctions.call/2` evaluates calls with null
    propagation.
- **Operands.** `IS [NOT] NULL` and `[NOT] IN` take any operand. A wider
  pattern applies only when its left side parses as one, so text inside a
  string literal (`s = 'a IN (b)'`) still compares. A comparison with a
  literal on the left is turned around.
- **Tokens.** This is breaking, which semver allows for 0.x, and the old
  API never worked against a server.
  - `create_token(conn, name, opts)` without `:permissions` makes an
    admin token.
  - With `:permissions` (the CLI's `type:names:actions` strings) it makes
    a resource token.
  - `:expiry_secs` sets an expiry.
  - `delete_token(conn, name)` deletes by name.
  - `Admin.TokenRequest` builds the CLI's exact bodies, keys in its order
    (`Jason.OrderedObject`), for HTTP to send and for Local to compute
    error positions from.
  - Local supports admin tokens on `:v3_core` as well. Resource tokens
    are `:v3_enterprise` only; elsewhere they get Core's 404.
- **Token tests.** They move to `InfluxElixir.TokenContract`. They run
  against Local, and against an auth-enabled Core on port 8183 through
  `test/integration/tokens_v3_core_auth_test.exs`; the shared contract's
  servers run without auth.

**Not verified:** the response to a resource-token create. Running
Enterprise needs a license. The documentation says so, and Local assumes
the admin-token shape.

## Verification

- **Issue #25 query.** The query and 40 other function forms answer
  identically through `Client.HTTP` against Core and through
  `Client.Local`, error bodies included. The one exception is the known
  qualified field list in schema errors.
- **Function contract.** The new block "scalar functions — contract"
  (5 tests) passes on Local and Core, and all 5 fail on the old Local.
- **Token contract.** "tokens — contract" (8 tests) passes on Local
  `:v3_core`, on Local `:v3_enterprise`, and against Core with auth.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/sql_functions.ex` (new) | Evaluation, types, planning errors |
| `lib/influx_elixir/client/local/sql_parser.ex` | `:call` expressions, operand patterns, literal-left comparisons |
| `lib/influx_elixir/client/local/sql_executor.ex` | Call evaluation, `check_function_calls/2`, `IS NULL`/`IN` operands |
| `lib/influx_elixir/admin/token_request.ex` (new) | Token request bodies |
| `lib/influx_elixir/client/http.ex`, `lib/influx_elixir/client/local.ex`, `lib/influx_elixir/client/local/store.ex` | Tokens by name |
| `lib/influx_elixir/admin/tokens.ex`, `lib/influx_elixir.ex`, `lib/influx_elixir/client.ex` | Token API and docs |
| `test/support/token_contract.ex` (new), `test/integration/tokens_v3_core_auth_test.exs` (new), `test/support/integration_helper.ex`, `test/test_helper.exs` | Token tests |
| `test/support/client_contract.ex` | Function contract; token block moved |
| `test/influx_elixir/admin/tokens_test.exs`, `test/influx_elixir_test.exs`, `test/influx_elixir/client/profile_rejection_test.exs`, `test/influx_elixir/client/local_test.exs` | Updated |
| `CHANGELOG.md`, `docs/guides/testing-with-local-client.md`, `usage-rules/testing.md`, `docs/design/README.md` | Updated |
