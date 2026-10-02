# Local Write Concurrency, Parse Memory, v2 Retention and Mixed Field Types

**Date**: 2026-10-02
**Scope**: `Client.Local` (store, line protocol parser, Flux, v2 writes and
buckets) and the fidelity and contract tests for them
**Issue**: scheduled quality sweep (review findings)
**Supersedes**: the parse-speed bullet of
[`2026-10-01_review-of-the-fidelity-sweep`](2026-10-01_review-of-the-fidelity-sweep.md)
(a spawned parse for the whole payload)

---

## Problem

Each finding was reproduced before the change, and each engine fact was
read from InfluxDB 2.7 (docker `influxdb:2.7`, a temporary bucket) or
InfluxDB 3 Core.

- **Concurrent writes collapsed.** One writer of 2,500 lines took 22 ms;
  8 concurrent writers of the same series took 2.1 s, 32 took 16.5 s and 50
  timed out at 60 s. `store_point` did an `insert_new` and an `insert` per
  point on an `:ordered_set` with no write concurrency.
- **The spawned parse was unbounded.** `presized/2` gave a process a heap
  sized for the whole payload: 1,071 MB of extra memory for 200k lines and
  8.7 GB for eight payloads at once. Nothing tied the process to its
  caller, so it ran on after the caller died.
- **v2 mixed field types.** A field `f` that is `1i` in week A, `2i` in B,
  `3.5` in C and `4i` in D reads as A and B only on 2.7; Local also returned
  D. The cut is per measurement and field across all tag sets: with
  `t=a,b f=1i` in A, `t=a f=2.5` in B and `t=b f=3i` in C, 2.7 returns only
  A's two rows.
- **`delete_bucket/2` left the points and the per-group schema behind.** A
  bucket created again returned the old points, and a write of another
  field type was a 422.
- **Local ignored a v2 bucket's retention.** On 2.7 a point older than
  `now - retention` is a 422, and the other points are written.
- **Flux reads were slow:** `flux_typed` asked the store for a column's
  kind and built a map entry for every point and field.

## Design

**Store.** `Store.store_points/3` writes a payload's points with one
`:ets.insert/2` of a list. The `series_time` keys are claimed by one
`:ets.insert_new/2` of a list, which is all-or-nothing; only when it fails
(another writer holds a key) are the keys claimed singly to find which
measurements need the `duplicates` marker. Repeats inside the payload are
found with a map (a map the same size as the key list means none) and mark
their measurement. The key is `{:series_time, db, measurement, timestamp,
tags}`: the timestamp comes before the tag map because ordered-set
comparison of maps was half the cost of the claim. The table is created
with `write_concurrency: true`. `:global.trans` stays for tokens and the
database limit: a spin lock in the table would leak when its holder is
killed. `store_point/3` is `store_points/3` of one point.

**Parser.** The lines are parsed 10k at a time. A full chunk runs in a
process of its own with `min_heap_size` of 1M words and sends its result
back once; a smaller chunk runs in the caller. A parsed line measured 37
(bare) to 94 words (four tags and three fields), so 100 words a line holds a
chunk without a collection. The process ends with its chunk, so it cannot
outlive a dead caller by more than that chunk. Parsing in the caller
without a process was tried: 100k typical lines took 0.8 s against 0.3 s,
because the caller's heap grows by a fraction and is copied whole at each
step. A failure in the process is raised again in the caller.

**Flux types.** `flux_cutoffs/3` asks the store once per measurement,
group and field, then per `{measurement, field}` takes the first group in
time order whose kind differs from the earliest touched group's and reads
nothing from it onward. `Flux.run/2` builds a point's series key and shared
columns once, not once per field.

**Buckets.** `Store.delete_bucket/2` deletes the points, columns, series
index and duplicate markers, as `drop_database/2` does.

**Retention.** A v2 write computes `now - retention` once. A point before it
is dropped before any shard group sees it: it registers no field and is
dropped whatever else is wrong with it. If no group dropped anything, the
write is the 422 below; if one did, that group's message replaces it
(verified, with the retention drops not counted):

```
failure writing points to database: partial write: dropped N points outside
retention policy of duration 2h0m0s - oldest point <key> at <time> dropped
because it violates a Retention Policy Lower Bound at <now - retention>,
newest point <key> at <time> dropped because it violates a Retention
Policy Lower Bound at <now - retention> dropped=N for database: <bucket id>
for retention policy: autogen
```

The key is the measurement and the tags sorted by key, with line
protocol's escapes; times are Go's RFC 3339 with the zeros of the fraction
trimmed; on a tie the first point of the payload is both the oldest and the
newest; the duration is Go's, in hours (`48h0m0s` for two days). A v3
database's `retention:` is still checked and not applied.

## Which Failing Group Speaks

When several shard groups fail in one InfluxDB 2.7 write, the engine reports
one of them, and which one varies between identical writes: `m v=1i 5` then
`m time=1` against a stored float `v` gave "field type conflict" (the 1970
group) 10 times in 12 and "invalid field name" (the current week's group)
2 times. The double always reports the earliest group's drop, the common
answer; the contract accepts any failing group's message from the engine
and pins the earliest from the double.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/local/store.ex` | `store_points/3`, `write_concurrency`, series key order, `delete_bucket/2` clears data |
| `lib/influx_elixir/client/local/line_protocol_parser.ex` | chunked parse; `presized/2` removed |
| `lib/influx_elixir/client/local/flux.ex` | series key and shared columns built once per point |
| `lib/influx_elixir/client/local.ex` | batched stores, retention, mixed-type cut-off, docs |
| `test/influx_elixir/client/local/influxql_flux_lp_fidelity_test.exs` | new tests; contract duplicates removed; 4 and 8 task stress tests |
| `test/support/contract/influxql_flux_lp_contract.ex` | read-backs, cut-off, retention and bucket tests |
| `CHANGELOG.md` | entries |

## Verification

- Writes (`tmp/` script, 2,500 lines of one series): serial 22 → 15-20 ms;
  8 writers 2,118 → 45-69 ms; 32 writers 16,497 → 181-253 ms; 50 writers
  15,954 (60 s timeout before the change, in the report) → 356-561 ms;
  100k lines 640 → 700-750 ms.
- Parse, 100k lines in a fresh process, best of 8: typical 322 → 270-300
  ms, bare 152 → 125-156 ms. Memory, 200k lines: +1,071 MB → +287 MB;
  eight at once: +8,755 MB → +1,579-2,283 MB (the results alone are about
  250 MB each).
- Flux, 100k points: `flux_typed` 250 → 41 ms, `Flux.run` 490 → 295 ms.
- The engine facts above were each checked on 2.7 with a temporary bucket
  and deleted.
- `mix test`, `mix credo --strict`, `mix dialyzer`,
  `mix compile --warnings-as-errors` and
  `MIX_ENV=test mix compile --force --warnings-as-errors` pass.
