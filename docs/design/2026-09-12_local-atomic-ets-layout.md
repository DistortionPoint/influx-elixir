# `Client.Local` Atomic ETS Layout

**Date**: 2026-09-12
**Scope**: `InfluxElixir.Client.Local` storage
**Issue**: GitHub #15

---

## Verification of the report

The report: eight processes writing 60 points each to one database ended
with 159 of 480 rows stored, every call returning `{:ok, :written}`.

`store_point/3` did:

```elixir
existing = :ets.lookup(table, {:points, db, measurement})   # read
:ets.insert(table, {key, [point | existing]})               # write
```

Two writers that both read the same list and both insert lose whichever
lands first. The databases, buckets and tokens registries had the same
shape (`MapSet.put` then insert). Real issue — and a second one hiding
behind it: inserting a list of `n` points copies the list into ETS on every
write, so a bulk write is `O(n²)`. Profiling before the fix: 20,000 lines in
one `write/3` took **63 s**.

## Design

One `:ordered_set` per instance; every entry has its own key, so every
mutation is a single `:ets.insert/2` or `:ets.delete/2` and there is nothing
to read-modify-write:

| Key | Value |
|---|---|
| `{:database, name}` | `true` |
| `{:bucket, name}` | `true` |
| `{:token, id}` | token map |
| `{:point, database, measurement, seq}` | point map |

`seq` is `:erlang.unique_integer([:monotonic, :positive])`, so an
`ordered_set` scan returns points in insertion order (previously newest
first — no documented consumer relied on either; `ORDER BY` is explicit).
Reads are `:ets.select/2` match specs; `measurement_exists?/3` is a
`select/3` with limit 1; `DELETE` deletes each matched point by key, so a
write racing a delete is never dropped by a rewrite of the list.

`stop/1`, `conn.table`, the public API and every documented return shape
are unchanged. The moduledoc's "ETS Key Layout" section is updated.

## Verification

Regression tests in `local_test.exs` ("bug regression — concurrent writes
to one database"): 480 parallel writes all stored; 16 parallel
`create_database` calls all listed; a `DELETE` racing 50 writes removes
exactly its 50 matches. The full contract suites pass against Local.

```bash
mix test && mix credo --strict && mix dialyzer
```
