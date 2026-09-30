# Client.Local: InfluxQL WHERE, SHOW TAG VALUES, SQL Regexes, Untimed Writes

**Date**: 2026-09-30
**Scope**: `Client.Local.InfluxQL`, `Client.Local` InfluxQL and write paths, `SQLParser`/`SQLExecutor`
**Issue**: scheduled quality sweep (no open issues)

---

## Problem

A comparison of common InfluxQL queries between `Client.HTTP` (against
`influxdb:3-core`) and `Client.Local` found no wrong answers in the
queries it answered. It did find these refused by name:

- `=~` and `!~`;
- `time > now() - 30m`;
- double-quoted identifiers in `WHERE`;
- `SHOW TAG VALUES`.

Probing the engine's semantics for those showed that Local's InfluxQL
`WHERE`, which it runs through its SQL engine, gave wrong answers where
InfluxQL and SQL differ:

| `WHERE` | InfluxDB 3 | Local before |
|---------|------------|--------------|
| `host != 'h1'` | keeps points without `host` | dropped them (SQL null) |
| `host = ''` | the points without `host` | nothing |
| `host > 'h0'`, `host >= 'h1'` | false | string comparison |
| `NOT host = 'h1'` | 400 `error in InfluxQL statement: parsing error: ... at pos N. Parsing Error: Nom("host = 'h1'", Tag)` | answered |
| `w != 10` with `w` missing on a point | the point is dropped | the same |
| `v =~ /1/` on a field | false | refused |

InfluxQL reads a *tag* a point lacks as the empty string; a missing
*field* stays null. Regular expressions are unanchored, case-sensitive,
and honour `(?i)`. An invalid pattern is a 500 `Invalid regex`.

`SHOW TAG VALUES` works like this:

- It gives one row per distinct value, sorted by measurement, key and
  value (byte order, `H1` before `h1`).
- It adds a row without `"value"` when a point in range lacks the key. A
  measurement without that tag column has no rows.
- Only the last 24 hours count by default: a value 23 hours old is
  listed and one 25 hours old is not. A `WHERE` on `time` replaces the
  window.
- `WITH KEY = k`, `!= k`, `=~ /re/`, `!~ /re/` and `IN (...)` select the
  keys.
- `LIMIT` applies per measurement, in an order that looked arbitrary.

**Untimed writes.** One test broke after the change, and the cause was
older. On *both* engines, every untimed line of one write request gets
the same timestamp. Five untimed `u,k=old` lines leave one row, the last
(`v=5`), and differing fields merge (`v=1,w=2`). Local stamped each point
separately and kept five rows.

**SQL regexes.** DataFusion SQL has `~`, `!~`, `~*` and `!~*`:
unanchored, with a null unknown. A non-string column is `type_coercion
... Cannot infer common argument type for regex operation Int64 ~ Utf8`
(400), and an invalid pattern is `Optimizer rule 'simplify_expressions'
failed ... Invalid regex` (500). Local's SQL had none of them.

## Decision

- **SQL.** Add `:regex` and `:not_regex` where-clauses, compiled once at
  parse time (with `i` for `*`), with the engine's two error texts. The
  engine's regexes are Rust's; Erlang's PCRE also accepts backreferences
  and lookaround, which the docs note.
- **InfluxQL `WHERE`.** `InfluxQL.where_sql/2` tokenizes the clause,
  leaving string and regex literals intact, and writes SQL:
  - a tag regex becomes `tag ~ 're'`;
  - a regex on a field, or an ordering comparison on a tag, becomes an
    always-false predicate;
  - durations of whole seconds become `INTERVAL 'N seconds'` (a
    sub-second duration is refused by name);
  - quoted identifiers are exact.

  `parse/1` answers `NOT` with the engine's parse error, including its
  position and remainder. `Client.Local` runs the SQL over points whose
  missing tags are filled with `""`, then drops the filled values from
  the rows. A stored tag value is never empty, because line protocol
  forbids it.
- **`SHOW TAG VALUES`.** `InfluxQL.parse_show_tag_values/1` and
  `key_listed?/2` handle the statement and its key filter, and
  `Client.Local` runs the same filled-tag SQL per measurement. The user's
  `WHERE` is parenthesised and ANDed with the 24-hour window unless it
  names `time`. `LIMIT` and `OFFSET` are refused by name.
- **Untimed writes.** `Client.Local.write/3` stamps a write's untimed
  lines with one `Store.now_ns()` after parsing. Tests that counted
  several untimed points of one series now give them timestamps, and one
  test was rewritten to pin the rule.

## Verification

- 27 InfluxQL `SELECT`s and 14 `SHOW TAG VALUES` statements through both
  clients give identical results, including the four wrong answers
  above.
- 10 SQL regex queries give identical results, except the known
  qualified field list in a schema error, which tests match by prefix.
- Untimed lines behave the same on v3 and v2.
- New contract blocks pass on Local and the engines:
  - `query_influxql/3 — WHERE and SHOW TAG VALUES contract` (Core);
  - "untimed lines of one write are one point per series" (every
    profile).

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/influxql.ex` | `where_sql/2`, tokenizer, `NOT`, `parse_show_tag_values/1`, `key_listed?/2`, `mentions_time?/1`, moduledoc |
| `lib/influx_elixir/client/local.ex` | Filled-tag InfluxQL SQL run, `SHOW TAG VALUES`, `stamp_untimed/1`, docs |
| `lib/influx_elixir/client/local/sql_parser.ex`, `sql_executor.ex` | Regex operators |
| `lib/influx_elixir/client/local/store.ex` | Doc |
| `test/support/client_contract.ex`, `test/influx_elixir/client/local_test.exs`, `test/influx_elixir/query/sql_stream_test.exs` | Tests and fixtures |
| `docs/guides/testing-with-local-client.md`, `usage-rules/query.md`, `usage-rules/write.md`, `CHANGELOG.md` | Updated |
