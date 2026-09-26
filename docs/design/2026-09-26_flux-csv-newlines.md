# Flux CSV: Newlines Inside Values

**Date**: 2026-09-26
**Scope**: `Query.ResponseParser` CSV cells
**Issue**: scheduled quality sweep

---

## Problem

Probing `query_flux/3` against `influxdb:2.7` (multiple yields, empty
results, `pivot`, `keep`, runtime and compile errors, quoted commas and
quotes all parsed correctly) found one divergence. The raw response for a
value `"l1\nl2"`:

```
,_result,0,"l1\r\nl2"\r\n
```

InfluxDB 2 writes its CSV with Go's `csv.Writer` in CRLF mode, which
rewrites every `\n` inside a quoted field as `\r\n`, and drops a bare `\r`
(`"t\rx"` arrives as `tx`). A stored string field `s="l1\nl2"` therefore
read back as `"l1\r\nl2"` over `Client.HTTP`, while `Client.Local`
returned `"l1\nl2"` — a test passing on the double would fail in
production.

## Decision

`ResponseParser` replaces `\r\n` with `\n` in every CSV cell before
typing it. An unquoted cell cannot contain a line break, so only quoted
values are affected. The result is the stored value exactly, except for a
value that contained `\r` itself: the server has dropped that `\r`
before the parser sees it, so it cannot be restored.

## Verification

A v2 contract test writes `s="l1\nl2"` and reads it back with Flux: it
passes on `Client.Local` and on InfluxDB 2.7, and fails on 2.7 without
the change (`"l1\r\nl2"`). A `ResponseParser` unit test covers the raw
CSV.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/query/response_parser.ex` | `restore_newlines/1`; moduledoc |
| `test/influx_elixir/query/response_parser_test.exs`, `test/support/client_contract.ex` | tests |
| `CHANGELOG.md` | Updated |
