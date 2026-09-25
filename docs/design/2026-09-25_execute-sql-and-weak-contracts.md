# `execute_sql` Answers and Weak Contract Assertions

**Date**: 2026-09-25
**Scope**: `Client.Local.execute_sql/3` and `query_sql/3`, `Client.HTTP.execute_sql/3`, contract assertions
**Issue**: scheduled quality sweep (test audit)

---

## Problem

An audit for weak assertions found 12 in the contract suite:
`assert {:error, _reason}`, `assert is_map(result)`, `assert is_list(...)`.
A contract test exists to fail when the double and the engine differ; one
that accepts any error cannot. Probing each against `influxdb:3-core`:

| Call | InfluxDB 3 Core | Double before |
|---|---|---|
| `execute_sql("DELETE FROM m")` | 400 `Error during planning: DML not supported: Delete` | `{:error, :delete_not_supported}` |
| `execute_sql("INSERT INTO m (time, v) VALUES (...)")` | 400 `... DML not supported: Insert Into` | `{:ok, %{"rows_affected" => 0}}` |
| `execute_sql("UPDATE m SET v = 2")` | 400 `... DML not supported: Update` | same |
| `execute_sql("CREATE TABLE x (id INT)")` | 400 `... DDL not supported: CreateMemoryTable` | same |
| `CREATE VIEW` / `CREATE DATABASE` / `DROP TABLE` / `DROP VIEW` | 400 `DDL not supported: CreateView / CreateCatalog / DropTable / DropView` | same |
| `ALTER TABLE ...`, `TRUNCATE m` | 405 `This feature is not implemented: Unsupported SQL statement: <sql>` | same |
| `execute_sql("SELECT * FROM m")` | rows | `{:ok, %{"rows_affected" => 0}}` |
| `query_sql("INSERT ...")` | the same 400 (one endpoint) | 400 `Client.Local: unsupported SQL` |

`Client.HTTP.execute_sql/3` returned a `SELECT`'s rows as decoded JSON,
timestamps as strings, and its spec said `{:ok, map()}`. The facade, the
`Query.SQL` docs and the usage rules recommended `execute_sql` for
"DELETE, INSERT INTO ... SELECT".

Other weak unit tests: `SQL.query` with params asserted `{:ok, _}` on a
fixture with one host, so it passed whether the placeholder bound or
not; two BatchWriter tests ended on a `wait_until` with no assertion.

## Decision

`Client.Local` classifies a statement by its leading keyword:
`SELECT | WITH | EXPLAIN | SHOW | DESCRIBE | (` is a query (run as one;
what the double does not model is refused by name there); `DELETE` runs
on `:v3_enterprise` (unchanged, not verifiable without an Enterprise
server) and is the DML error otherwise; `INSERT`, `UPDATE`, `CREATE ...`,
`DROP ...` get the engine's planning errors; anything else its 405.
`query_sql/3` sends a non-query through `execute_sql/3`, as the engine
answers both from `/api/v3/query_sql`. `Client.HTTP.execute_sql/3` types
row lists with `ResponseParser.coerce_types/1`; the callback returns
`{:ok, map() | [map()]}`.

Contract tests now assert the engine's status and body: the Core
`execute_sql` answers (and `SELECT` rows equal to `query_sql/3` rows,
which checks the HTTP coercion on the engine), a 400 for malformed line
protocol, a 404 for a missing v2 bucket, the missing-table message, and
`rows_affected` for the Enterprise `DELETE`. The weak unit tests assert
what the call did.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local.ex` | `statement_kinds/0`, `statement_kind/1`, `execute_sql/3`, `run_query/4` |
| `lib/influx_elixir/client/http.ex` | `execute_sql/3` coerces rows |
| `lib/influx_elixir/client.ex`, `lib/influx_elixir.ex`, `lib/influx_elixir/query/sql.ex` | spec and docs |
| `test/support/client_contract.ex` | exact assertions |
| `test/influx_elixir/client/local_test.exs`, `test/influx_elixir_test.exs`, `test/influx_elixir/query/sql_test.exs`, `test/influx_elixir/write/batch_writer_test.exs` | tests rewritten to the engine's answers; weak tests strengthened |
| `usage-rules/query.md`, `CHANGELOG.md` | Updated |

## Verification

```bash
mix format --check-formatted && mix compile --warnings-as-errors
mix test                      # three runs, 0 failures
mix credo --strict && mix dialyzer && mix docs
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration   # 104/0
mix test test/integration/contract_v2_test.exs --include v2 --include integration             # 23/0
```
