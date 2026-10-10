# Review of Client.Local's store, write path and admin

**Date:** 2026-10-10
**Status:** Implemented

## Context

A sweep with no open GitHub issues. This pass covers the parts of `Client.Local` around its
query engines:
- `store/`, `write/`, `line_protocol/`, `admin/` and `shared/`;
- the `Client.Local` facade;
- `TestHelper`;
- the unit tests of all of these.

Every finding was checked against the code. A finding that depends on what the server does
was checked against a real server: InfluxDB 2.7 (2.7.12) or Core 3.10.1.

## Decisions

### Fixed

- **`create_bucket` stored any `retention:` value, and the next write raised.** For example,
  `retention: nil` led to an `ArithmeticError` in the retention check. InfluxDB 2.7 handles
  these values as follows (all verified):
  - A string or a float is a 400: Go cannot unmarshal it into `int64`. The double refuses
    these by name.
  - A negative value is a 422, `expiration seconds cannot be negative`.
  - JSON `null` is read as 0, which `Client.HTTP` sends for `retention: nil`.
- **Creating a bucket that already exists overwrote its retention.**
  - InfluxDB 2.7 answers a 422 conflict, `bucket with name X already exists`, and keeps the
    bucket as it was. `Client.HTTP` takes the conflict as `:ok`.
  - The double now does the same. Its check uses one `insert_new`, so concurrent creates
    cannot race.
  - The engine's order is the value's type, then its sign, then the name, then the hour's
    minimum. So for an existing bucket, a retention under an hour is `:ok`, not the 500.
- **A write racing a drop left its points behind.** A write that found its database, and
  then lost it to `delete_database` or `delete_bucket` while it parsed and stored its points,
  left those points with no database registered. A database later created under that name
  showed them.
  - After storing, a write now checks its target.
  - On InfluxDB 3 a write creates the database it names, so the database is created again,
    as if the write came after the drop.
  - On InfluxDB 2 a write never creates a bucket. What the write stored is removed, and the
    write gets the engine's 404.
  - `delete_bucket` now takes the lock that `delete_database` and the check take.
- **Using a stopped connection raised an ETS `ArgumentError`.** This covers a connection
  after `stop/1` and one whose starting process has exited. Every operation now refuses it
  by name, `Client.Local: the connection is stopped`, as `Client.HTTP` names a pool that is
  not running.
- **A connection `start/1` did not return raised a `FunctionClauseError`.** Examples are
  `Client.HTTP`'s keyword config, an atom, or `nil`, under `config :influx_elixir, :client,
  Client.Local`. The check that finds a stopped connection now refuses these by name too.
- **`start/1` accepted an `:org` that is not a string.** `list_buckets` then raised while
  hashing it. `:org` is now checked like `:databases` and `:database`.
- **The line protocol scanner copied a tuple of every physical line.** From the first error
  on, that tuple went to each 10,000-line chunk's process and came back. Errors are now
  echoed once, in the caller, after every chunk is parsed.
- **A refused line typed the wrong fields.** On a partial write, Core types a refused line's
  fields in the line's order, up to the one it refuses (verified). The double walked the
  fields in name order. For example, with `a` an integer, Core types `b` as float for
  `m b=1,a=2.0,c=1` and leaves `c` untyped. The double typed neither, because it met `a`
  first. The v3 parser now records the line's field order for a point with more than one
  field, and the order is dropped before the point is stored. Tags are still checked before
  fields, in name order, which no test showed to differ.
- **Docs and duplication.**
  - `write/3`'s doc said a missing database is a 404. That is true only on `:v2`; InfluxDB 3
    creates the database.
  - The capability lists of the two v3 profiles are now one list.

### Verified as the engine does, and left

These were reported as defects, and Core 3.10.1 does the same:
- **On an atomic write (`accept_partial=false`) a refused line types nothing.** A new
  contract test pins it, beside the partial-write case above. The review assumed the double
  typed the earlier fields; that test showed it did not.
- **A write whose every line is refused still creates its database.** Core answers 400 and
  lists the database. This is not pinned: a contract test would spend one of Core's five
  databases.

### Tests

- **New tests.**
  - The two Core contract tests above.
  - Bucket retention values and existing buckets.
  - A stopped connection, through every operation and a stream, and one whose starting
    process has exited.
  - A non-string `:org`.
  - Writes racing a drop, on v3 and v2. Each round starts a 2,000-line write and a drop
    together. With the fix turned off both tests failed in 3 of 3 runs; with it, both pass.
- **Exact values where weak assertions stood.**
  - Retention messages, now built in full by a helper.
  - Database-name rule messages.
  - Listings.
  - Lock messages.
  - The `TestHelper` planning error.
  - A bucket id.
  - The 409 token bodies.
- **Smaller fixes.**
  - A `SHOW RETENTION POLICIES` assertion replaces a false comment that said the double
    keeps no retention.
  - `Task.await` calls use the shared bound, not the 5 s default.
  - A misleading test name was corrected.
- **Doctests.** The examples in `Config`, and those of `Connection.api_version/1`, now run.
  The other `Connection` examples put a fixed name in the shared registry, so they stay
  unrun.

Not covered by a test: a v3 write whose dropped database cannot be created again (Core's
five taken while the write ran). The write then returns that error and removes what it
stored; reaching it needs a drop and four creates to land inside one write.

## Verification

The unit tier, coverage and every gate were run one at a time, plus the Core integration
suite twice and the v2 suite twice, on fresh servers; see the commit.
