# Tenth Review: Regressions of the Ninth, and Times a Client Reads

**Date**: 2026-10-04
**Scope**: `Client.Local` SQL and InfluxQL (the fixes of commit f0902fa), the
`mix test` alias, test wait bounds
**Issue**: scheduled quality sweep (no open issues). This reviews commit
f0902fa ([`2026-10-04_ninth-review`](2026-10-04_ninth-review.md)), which
agents wrote and nobody had reviewed. Defects only. The InfluxQL rules it
settled are in
[`2026-10-04_influxql-time-aggregates-and-where-calls`](2026-10-04_influxql-time-aggregates-and-where-calls.md).

---

## Problem

- **Performance.** `SQLSchema.check_order_available/2` listed every column
  of every point for any aggregate or grouped query, before knowing there was
  an `ORDER BY`: `count(*)` cost 8.8× its earlier reductions.
- **Wrong answers and raises.** InfluxQL aggregates of `time` beside another
  aggregate read every point; InfluxQL `WHERE` arithmetic on strings and
  division by zero did not follow the engine; a selector under an SQL text
  function raised.
- **Regressions.** `GRANT ALL`, `MERGE` display and `NULL - time` were
  refused, though f0902fa's parent answered them as the engine does.
- **The `mix test` alias** lost a path after a switch it did not list
  (`--no-compile`, `--force`), and ran the whole suite.
- **Wait bounds** of 5 s on events that will come (`assert_receive`,
  `Await.until`) could fail a correct test on a loaded machine.

## Decision

- **Regression discipline.** Each fix agent ran the reviewer's regression
  list on the parent commit and on its tree; nothing ends further from Core.
  Every reviewed query is now a case-table entry with Core's answer.
- **A time the engine prints to the nanosecond** (an aggregate stamped
  `time > x` + 1 ns, a `fill()` number on a time column) is answered to its
  floor microsecond. `Client.HTTP` reads every format's times (JSON, JSON
  lines and CSV, through `ResponseParser`) to the microsecond, so that is the
  answer a client of the engine gets. Refusing these, as was first done,
  refused what the engine's client is answered.
- **`mix test`** recognises a path by what it is (an existing file or
  directory, or a name ending `.exs`, with `:line` suffixes), not by where
  `OptionParser` leaves it.
- **Wait bounds** that only fail a broken test are 30 s.

## Known differences left

Three `HAVING` queries that mix a bare and a qualified unknown column report
the qualified one first; Core reports the bare one first (the same at the
parent commit).

## Verification

- Unit: 2,006 tests, three runs; coverage 91.56%; credo, dialyzer, docs (no
  warnings) and both compile environments clean.
- Integration on fresh `influxdb:3.10.1-core` (`--wal-snapshot-size 100000`)
  and 2.7, run twice: Core 646 tests, InfluxDB 2.7 90 tests, no panic;
  auth-enabled Core tokens 8 tests.
