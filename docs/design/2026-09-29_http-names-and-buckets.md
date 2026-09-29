# HTTP Client: Name Encoding, Bucket Pages and Org Scope

**Date**: 2026-09-29
**Scope**: `Client.HTTP` URL building, `list_buckets/1`, the bucket lookup behind `delete_bucket/2`
**Issue**: scheduled quality sweep (#24 open, awaiting a decision; no other issues)

---

## Problem

Three defects in the HTTP client, each reproduced against `influxdb:2.7`.

1. **Encoding.** Every query-string value was built with `URI.encode/1`,
   which leaves `&`, `+`, `=` and `#` as they are:

   | bucket | before | now |
   |--------|--------|-----|
   | `a&b` | 404 `bucket "a" not found` (written to `a` when it exists) | written to `a&b` |
   | `c+d` | 404 `bucket "c d" not found` | written to `c+d` |
   | `e#f` | 404 `bucket "e" not found` (the rest is a URL fragment) | written to `e#f` |
   | `g h`, `i=j`, `k%20l`, `m?n` | written | written |

   The same construction built the org in writes, Flux queries and org
   lookups, the v3 `db` in writes and database deletes, the precision,
   and the bucket and token IDs in paths.
2. **Pages.** `GET /api/v2/buckets` answers 20 buckets by default and at
   most 100 a page (a `limit` of 101 is a 400). `list_buckets/1` read only
   the first page. On a server with 26 buckets it returned 20, and a v2
   contract test that looked up a bucket it had just created failed once
   the container held more than 20 buckets.
3. **Org scope.** The name-to-ID lookup behind `delete_bucket/2` queried
   `/api/v2/buckets?name=`, without the org, and took the first match. With
   a bucket `shared` in both `dev-influx` and another org, deleting
   `shared` through a `dev-influx` connection removed the other org's
   bucket and left `dev-influx`'s. `list_buckets/1` also spanned every org
   the token could read.

## Decision

- **`query_value/1`** (`URI.encode_www_form/1`) for every query-string
  value, and **`path_segment/1`** (unreserved characters only) for every
  path segment.
- **`list_buckets/1`** reads pages of 100 with `limit` and `offset` until
  a page comes back short, scoped with `org=` when the connection's `:org`
  is set. A connection with `org: ""` still spans every org it can read.
- **The lookup** adds `org=` too. Scoped to an org, the server answers a
  missing name with 404 `bucket "x" not found` instead of an empty list.
  The client maps that to its documented `bucket not found: x`, which the
  contract asserts. A 404 for the org itself (`organization name "x" not
  found`) is passed through, because it is not a missing bucket.

## Verification

- **Probes.** All seven awkward bucket names and the v3 names `a/b` and
  `a/_b` round-trip: write, query, delete. 110 new buckets list as 137
  unique buckets. The cross-org delete removes only the connection's own
  bucket.
- **Contract tests**, run on Local and InfluxDB 2.7:
  - a bucket named `contract a&b+c#d=e N` is written to, read back
    through Flux, and deleted by name;
  - 101 buckets are all listed.
- **v3 contract test:** a `name/autogen` database is written, queried and
  dropped.
- **v2-only integration test:** a second org gets a same-named bucket
  through the raw API, and `delete_bucket/2` leaves it untouched.
- Against the previous client, the new v2 tests fail. So does the
  retention test, which is the page-size bug showing on a well-used
  container.

## Files Modified

| File | Change |
|------|--------|
| `lib/influx_elixir/client/http.ex` | `query_value/1`, `path_segment/1`, paged and org-scoped `list_buckets/1`, org-scoped lookup, moduledoc |
| `lib/influx_elixir/admin/buckets.ex` | Doc |
| `test/support/client_contract.ex`, `test/integration/contract_v2_test.exs` | Tests |
| `CHANGELOG.md` | Updated |
