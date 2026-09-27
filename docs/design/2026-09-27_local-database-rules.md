# Client.Local: Database Resolution and InfluxDB 3's Database Rules

**Date**: 2026-09-27
**Scope**: `Client.Local` database handling; new `Client.Local.DatabaseRules`
**Issue**: scheduled quality sweep (no open GitHub issues)

---

## Problem

`Client.HTTP` and `Client.Local` resolved databases differently from the
same config:

| Config | `Client.HTTP` | `Client.Local` |
|--------|---------------|----------------|
| `databases: ["a", "b"]` | default `"a"` (`init_connection/1`) | default `"default"` |
| no `:database`, no `:databases` | `{:error, :no_database_specified}` | wrote to and queried `"default"` |

A comment in `HTTP.init_connection/1` claimed to "mirror Client.Local",
but the two did not agree. The guide called the config "a true drop-in",
yet only `database:` plus `databases:` behaved the same on both clients.
Code that forgot `database:` passed against the double and failed
against the server.

Probing `influxdb:3-core` also found that the double ignored the engine's
own database rules:

- **No database.** `write_lp` without `db` is 400
  `missing query parameter 'db'`, which the HTTP client never sends: it
  refuses first. `query_sql` without `db` is 400 as well. `query_influxql`
  without `db` is 400
  `must specify a 'db' parameter, or provide the database in the InfluxQL
  query`, except `SHOW DATABASES`, which works.
- **Names.** Checked in this order:
  1. an empty name is `db name cannot be empty`;
  2. a first character that is not an ASCII letter or digit is `db name
     did not start with a number or letter`;
  3. any character outside `[A-Za-z0-9_-/]` is `invalid character in
     database or rp name: ...`;
  4. a `/` that does not split the name into two non-empty parts (`x/`,
     `a//b`, `a/b/c`) is `db name with invalid retention policy, ...`.

  All four are 400s with a JSON body. `a/b` is a valid, listed database
  name, and so is `a/_b`. There is no length limit (200 characters were
  accepted). A write that would create the database applies the same
  rules.
- **Limit.** Core holds 5 databases besides `_internal`. A sixth is 422
  `Adding a new database would exceed limit of 5 databases`, whether
  created or written to. An existing database passes, dropping one frees
  a slot, and a bad name is still its 400 at the limit.
- **Missing database.** A query against it is 404
  `{"error":"query error: database not found: <name>"}`. For SQL this comes
  before parsing, for any statement. InfluxQL parses first, so a syntax
  error still wins there. `SHOW DATABASES` needs no database.
- **`_internal`.** A fresh server lists `_internal`. Writing to or creating
  it fails the name rules. Deleting it is 500 `cannot delete internal db`.
  It holds system tables.

Two weaker findings came up on the way:

- The Local conn map's `:databases` was a start-time snapshot that never
  changed, and seven tests asserted on it instead of on behaviour.
- `influxql_select` passed the caller's `format:` to its inner SQL query,
  so with `:csv` InfluxQL aggregated strings.

## Decision

- **No implicit database.** `Local.start/1` takes
  `database || first(databases)` as the default, as HTTP does, and creates
  no `"default"`. `resolve_database/2` returns
  `{:error, :no_database_specified}` when there is none. The InfluxQL path
  maps that to the engine's 400, and `SHOW DATABASES` is answered before
  it.
- **`Client.Local.DatabaseRules`** holds the name rules and the Core
  limit:
  - `check_new/3` serves `create_database/3` and v3 writes;
  - `check_start!/2` raises `ArgumentError` in `start/1`, because a setup
    that cannot run against the server should not pass against the double;
  - the limit applies to `:v3_core` only (Enterprise's limit was not
    verified);
  - the `:v2` profile, where the names are buckets, is unchanged.
- **Missing database** is checked:
  - in `query_sql/3`, after `format` (the engine parses the request body
    first) and before the SQL;
  - in `execute_sql/3`, before the statement;
  - in `query_influxql/3`, after the statement.
- **`_internal`** is added to `list_databases/1` and `SHOW DATABASES`
  (sorted, as the engine lists). Deleting it is the 500. Querying it is
  refused by name, because the double does not model its system tables.
- **`conn.databases` is removed.** The seven tests now assert through
  `list_databases/1` and real writes.
- The inner InfluxQL query drops `format:` and names its database.

This is a breaking change for consumers' tests that relied on
`"default"`, and the CHANGELOG says so under **Changed**. Each test that
breaks was passing against the double for code that fails against the
server.

## Verification

- A new contract block, `database rules contract`, passes on `Client.Local`
  and on InfluxDB 3 Core. It covers the missing-database 404 for SQL and
  InfluxQL, the four name rules in order for both create and write, and
  `_internal` in the list, in `SHOW DATABASES` and refusing deletion.
- `DatabaseRulesTest` covers every probed name, the limit and its
  interplay.
- The full unit suite and both integration suites pass.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/database_rules.ex` | New |
| `lib/influx_elixir/client/local.ex` | Resolution, rules, 404, `_internal`, InfluxQL statement/database order, inner `format:` |
| `lib/influx_elixir/client.ex`, `config.ex`, `connection.ex` | Docs |
| `lib/influx_elixir/write/writer.ex`, `admin/tokens.ex`, `admin/buckets.ex` | Examples that did not run |
| `test/influx_elixir/client/local/database_rules_test.exs`, `test/support/client_contract.ex`, `test/influx_elixir/client/local_test.exs`, `test/influx_elixir/write/batch_writer_test.exs` | Tests; weak `BatchWriter` tests (asserting only `:ok`) rewritten to check what was stored |
| `usage-rules/testing.md`, `docs/guides/testing-with-local-client.md`, `CHANGELOG.md` | Updated |
