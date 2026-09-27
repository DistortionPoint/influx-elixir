# Client.Local: SQL Identifier Case and Quoting

**Date**: 2026-09-27
**Scope**: `Client.Local` SQL; new `Client.Local.SQLIdentifiers`
**Issue**: found while verifying #23 (`SELECT DISTINCT ON ("k") "k"` was refused)

---

## Problem

DataFusion normalises identifiers. The parser matched names exactly as
written and had no notion of quoting. Probing `influxdb:3-core` with a tag
`Host`, a field `Val`, and tables `Cpu` and `cpu`:

| SQL | InfluxDB 3 | `Client.Local` before |
|-----|------------|-----------------------|
| `SELECT K FROM c` | `[{"k": "a"}]` | 500 `No field named K` |
| `SELECT Host FROM c` | 500 `No field named host` | `[{"Host": "h1"}]` |
| `SELECT "Host", "Val" FROM c` | `[{"Host": "h1", "Val": 1}]` | 400 unsupported column |
| `SELECT v AS V FROM c` | `[{"v": 2}]` | `[{"V": 2}]` |
| `SELECT AVG(v) AS Avg_V FROM c` | `[{"avg_v": 2.0}]` | `[{"Avg_V": 2.0}]` |
| `SELECT "Val" AS "Mixed Case" FROM c` | `[{"Mixed Case": 1}]` | 400 |
| `WHERE "Host" = 'h1'` | matches | 400 unsupported WHERE |
| `WHERE k = "hello"` | 500 `No field named hello` | matched the string `hello` |
| `SELECT * FROM Cpu` | table `cpu` | table `Cpu` |
| `GROUP BY K`, `WITH W AS (...) ... FROM w`, `FROM c AS C ... C.v` | folded | case-sensitive |
| `WHERE k = $X` | `$X` is case-sensitive (`$x` is another) | the same |

Queries the server refuses passed against the double, and the other way
round. A consumer with a mixed-case tag, or one who wrote a string in
double quotes, had tests that proved nothing. Some of these cases pinned
this in the double's own suite ("double-quoted WHERE value parsed as
string").

## Decision

`SQLIdentifiers.normalize/1` rewrites the text once, before
`SQLParser.parse_select/2` reads it:

- A `'...'` literal is copied untouched, doubled quotes included.
- A `$name` placeholder is copied untouched. A number is copied whole,
  so `1E5` keeps its exponent.
- An unquoted word is lower-cased. Keywords are lower-cased too, which is
  harmless because every parser pattern is case-insensitive.
- A `"..."` identifier that is a plain word, and not a word the parser
  reads as structure, is written back bare with its case kept, because
  the parser folds nothing. Any other quoted identifier (containing a
  space, a dot, or a keyword such as `"order"`) keeps its quotes.
  Projection aliases now accept a quoted name (`AS "Mixed Case"`). The
  measurement pattern already accepted a quoted table.
- InfluxQL identifiers are case-sensitive, and its `WHERE` is run through
  the SQL engine. That path calls `parse_select/2` with
  `identifiers: :exact`, so it is not folded.

One consequence: a `Client.Local:` refusal echoes the query as the parser
saw it, with identifiers folded.

## Verification

- A new contract block, `SQL identifier contract`, passes on Local and on
  InfluxDB 3 Core. It covers folding and quoting in `SELECT`, `WHERE` and
  `ORDER BY`, aliases folded unless quoted, a mixed-case table name folded
  to another table, and `"..."` as a column.
- The probe script now agrees with the engine on every row of the table
  above.
- `SQLIdentifiersTest` covers the pass directly: literals, doubled quotes,
  placeholders, exponents, intervals, subscripts, and quotes that must stay.
- The pinned test "double-quoted WHERE value parsed as string" was
  rewritten to assert the engine's answer.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/sql_identifiers.ex` | New |
| `lib/influx_elixir/client/local/sql_parser.ex` | `parse_select/2` normalises; quoted projection aliases |
| `lib/influx_elixir/client/local.ex` | InfluxQL path `:exact`; moduledoc |
| `test/influx_elixir/client/local/sql_identifiers_test.exs`, `test/support/client_contract.ex`, `test/influx_elixir/client/local_test.exs` | Tests |
| `docs/guides/testing-with-local-client.md`, `usage-rules/query.md`, `CHANGELOG.md` | Updated |

## Follow-up (same day): DELETE, and when a table exists

The next sweep found two paths the change above did not reach.

- **Enterprise `DELETE`.** `execute_sql/3` matched `DELETE FROM <name>`
  on the raw text and parsed its `WHERE` separately:
  - `DELETE FROM "Cpu"` took the measurement to be `"Cpu"`, quotes
    included;
  - `DELETE FROM Cpu` did not fold the name to `cpu`;
  - the `WHERE` compared names case-sensitively.

  The statement is now normalised with `SQLIdentifiers.normalize/1`
  before it is matched, and a quoted measurement is unwrapped. (There
  was no Enterprise server to test against; the rules are DataFusion's,
  as for `SELECT`.)
- **Table existence.** The SQL executor's `point_source` answered "table
  not found" for a measurement with no points, so an Enterprise `DELETE`
  of every row turned the table into an error. The engine's catalog
  keeps a table once it exists, and DataFusion answers a table with no
  rows with `[]`. `point_source` now asks the schema (`Store.table?/3`).
  On Core, whether a rejected write leaves its table behind was checked
  against the engine: a rejected line's columns stay (`t5,a=b` registers
  `a`), and Local already matched that.

  One Core oddity was not copied: a table whose only line was rejected
  for a `time` tag exists with no columns, and the engine answers 500
  `table should have a time column`. Local answers "table not found".

Both are covered by `execute_sql/3 — DELETE` tests. The new tests fail
against the previous `local.ex` and pass with the change.
