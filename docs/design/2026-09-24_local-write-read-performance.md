# `Client.Local` Read and Write Performance; Escaped Backslashes

**Date**: 2026-09-24
**Scope**: `Client.Local` duplicate merging, `LineProtocolParser` fast paths and escapes
**Issue**: scheduled quality sweep

---

## Problem

**Reads.** The duplicate-point fix (2026-09-23) merged every read: a
map keyed by `{measurement, tags, timestamp}` over all of a
measurement's points. Timed on 100k points (minimum of seven runs): ETS
read 37 ms, merge 126 ms, whole `COUNT` query 164 ms — the merge was about
three quarters of the query, for measurements that almost never hold a
duplicate.

**Writes.** 50k points took about 2 s; the parser alone 1.6 s (32 µs per
line). Microbenchmarks per call:

| Operation | Time |
|---|---|
| `unescape_tag` replace chain on `"host"` | 1,250 ns |
| `:binary.match(str, "\\")` | 70 ns |
| `String.slice(v, 0..-2//1)` | 540 ns |
| `binary_part(v, 0, byte_size(v) - 1)` | 4 ns |

The four splitters (lines, parts, commas, first `=`) scan byte by byte
even when a token has no quote or backslash.

**Escapes (found by the new tests).** Probed against InfluxDB 3 and 2.7:

| Line | InfluxDB 3 | InfluxDB 2.7 | Double before |
|---|---|---|---|
| `e s="ends\\",v=1i` | stored, `s` = `ends\` | — | 400 (`\"` read as an escaped quote, next field swallowed) |
| `bs\\,t=a v=1i` | 400 `Measurements, tag keys and values, and field keys may not end with a backslash` | 204, measurement `bs\,t=a` | 204, measurement `bs\,t=a` |
| `bt,k\\=a v=2i` | 400, same message | 400 `missing tag value` | 400 `Expected tag value` |
| `bv,t=a\\ v=1i` | 400, same message | 400 `invalid tag format` | — |
| `bf k\\=1i` | 400, same message | 400 `invalid value` | 400 `No fields were provided` |

## Decision

- `store_point/3` inserts `{:series_time, db, m, tags, ts}` with
  `insert_new`; when it already exists it inserts
  `{:duplicates, db, m}`. Reads merge only when that marker exists. The
  marker is never removed except with the database, so a stale one only
  costs a merge that changes nothing; `DELETE` and `delete_database/2`
  remove the index keys they orphan.
- `split_lines`, `split_line_parts`, `split_unescaped_comma`,
  `split_first_unescaped_comma` and `split_first_unescaped_equals` use
  `:binary.split/3` when the text has no quote or backslash — the same
  result, since only those bytes change how it splits. Unescaping is
  skipped when there is no backslash (and, for a measurement, no quote).
  Suffix and quote removal use `binary_part/3`.
- The comma, first-comma (v3) and first-`=` scans take `\\` whole. A
  measurement (v3), tag key, tag value or field key whose raw form ends in
  a backslash is refused with InfluxDB 3's message. Under `:v2` the
  measurement split keeps `\\,` as an escaped comma, as InfluxDB 2 does.

| Measured (minimum of 5 runs) | Before | After |
|---|---|---|
| 50k-point write | 1,962 ms | 697 ms |
| 200 writes of 20 lines | 40 ms | 16 ms |
| `COUNT` over 50k points | 88 ms | 19 ms |
| `parse_lines`, 50k lines | 1,606 ms | 373–450 ms |

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local.ex` | series-time index and duplicates marker; merge only when marked; cleanup in `DELETE` / `delete_database/2`; docs |
| `lib/influx_elixir/client/local/line_protocol_parser.ex` | `plain?/2` fast paths; byte slices; `\\` in comma/`=` scans; trailing-backslash rule |
| `test/influx_elixir/client/local_test.exs` | escapes block (careful splitter paths, trailing backslash on both dialects) |
| `test/support/client_contract.ex` | trailing backslash and escaped backslash in `write_rule_tests` |
| `docs/guides/testing-with-local-client.md`, `usage-rules/write.md`, `CHANGELOG.md` | Updated |

## Verification

```bash
mix format --check-formatted && mix compile --warnings-as-errors
mix test                      # three runs, 0 failures
mix credo --strict && mix dialyzer && mix docs
# both engines (docs/design/README.md one-liners):
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration   # 102/0
mix test test/integration/contract_v2_test.exs --include v2 --include integration             # 23/0
```
