# `SQLParser`: One Splitter for the SELECT

**Date**: 2026-09-16
**Scope**: `InfluxElixir.Client.Local.SQLParser` dispatch
**Issue**: scheduled quality sweep (refactoring)

---

## Problem

Every feature added to the parser since the extraction (#12 through #20)
brought its own regex for the same job — find the table after `FROM` and
cut the statement around it:

| Site | Regex |
|---|---|
| `SELECT *` dispatcher | `@measurement_pattern` |
| column-list dispatcher | `@columns_select_pattern` |
| `DISTINCT` dispatcher | `@distinct_pattern` |
| aggregate dispatcher | `parse_aggregate_from/1`, `extract_after_from/1`, the `SELECT (.+?) FROM` in `parse_select_columns/1` |
| clause check | `@first_from` |
| `distinct_query?/1`, `star_query?/1` | two more |

Eight patterns, four spellings of "a quoted or escaped measurement name",
and a bug fixed in one had to be fixed in the others (the escaped-space
measurement handling already differed between them: `\S+` in the
`DISTINCT` pattern, `(?:[^\s\\]|\\.)+` elsewhere).

## Design

`split_select/1` applies one named-capture pattern —
`SELECT [DISTINCT] <columns> FROM <table> <rest>` — and returns
`%{distinct, columns, table, rest}`. The dispatcher chooses the query
shape from those parts (`distinct`, `columns == "*"`, `aggregate_query?`)
and each builder receives the table and `rest` it used to extract itself.
The clause check reads `rest` from the same splitter. The alias stripper
and the `CROSS JOIN` splitter keep their own patterns: they rewrite the
text rather than cut it, and run before the split.

No behaviour changes; the 496 `Client.Local` tests and the contract suite
against the server are the proof.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/sql_parser.ex` | `@select_pattern`, `split_select/1`, dispatchers take the split; six regexes and two helpers removed |
| `CHANGELOG.md` | Changed entry |

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
