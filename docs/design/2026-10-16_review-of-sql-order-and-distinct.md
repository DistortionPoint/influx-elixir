# Review of SQL ordering and DISTINCT

**Date:** 2026-10-16
**Status:** Implemented

## Context

A sweep with no open GitHub issues. A read-only review of `SQLPlan` and `SQLExecutor`
reported two wrong answers and a sort that evaluated its key at every comparison. Each was
probed on Core 3.10.1 and on the double before it was changed. The sweep also read the unit
tests for partial assertions.

## Decisions

### An `ORDER BY` on a grouped column the select list leaves out

- **The bug.**
  - A grouped query's rows hold only what the select list names. `ORDER BY host` with only
    `sum(n)` selected read `host` from rows that had no such key, so every comparison was a
    tie.
  - The groups kept the order `Enum.group_by/2` gave them, which is ascending for a few
    keys. `ORDER BY host DESC` came back ascending, and a `LIMIT` kept the wrong group.
- **The engine.** Over the contract fixture, Core answers
  `SELECT sum(n) AS s FROM main GROUP BY host ORDER BY host DESC` with 21, 22, 18. The double
  answered 18, 22, 21.
- **The fix.**
  - Each group's row carries the values of the grouped columns that the `ORDER BY` names and
    the select list does not, while the rows are sorted.
  - It drops them before `LIMIT`.
  - A name the select list gives an output is still read from the output, as before.
- **Pinned in the SQL contract:**
  - `ORDER BY host DESC`;
  - the same with `LIMIT 1 OFFSET 1`;
  - `GROUP BY host, region ORDER BY region DESC, host` with `host` selected.
- **Left.** An alias that shadows a grouped column (`sum(n) AS host ... ORDER BY host`) is
  still refused by name, as it was before.

### `SELECT DISTINCT time`: times less than a microsecond apart

- **The bug.** `execute_distinct_query/2` compared the values a row prints, and a printed time
  is whole microseconds. Points at 1000 ns and 1500 ns made one row.
- **The engine.** Core returns two rows.
- **The fix.**
  - Rows are told apart, and sorted, by `SQLRow.sort_value/2`: a time in nanoseconds.
  - Each row prints from one of its points.
  - The sort was over `DateTime` structs in term order, and is now over integers.
- **Pinned in the SQL executor contract:** `SELECT DISTINCT time ... ORDER BY time` over
  1000 ns and 1500 ns gives two rows.

### An `ORDER BY` key read once per row

- **The cost.**
  - `SQLSort.sort_by_keys/2` had a one-key path that read the key at every comparison. Its
    comment assumed a key was a field read.
  - An expression key is evaluated by `SQLEval`.
  - Over 6000 rows, `ORDER BY abs(n - 3000)` cost 6.5M reductions.
- **The fix.**
  - The one-key path is gone. Every sort reads its keys once and sorts the pairs: 1.3M
    reductions for the same query.
  - `ORDER BY n` went from 1.5M to 1.0M.
  - `ORDER BY time DESC` went from 0.28M to 0.35M. Those rows are already in time order, so
    they need few comparisons.
- **One comparison less.** `value_before?/3` compared two values up to three times. It now
  compares them once, and a second time only when the first says they may tie.

### Tests made exact

- **Prefix matches compared whole.**
  - `format_test.exs`: the refusals of `:parquet` and of formats the client cannot write, and
    the missing table (Core's text, probed).
  - `invalid_utf8_test.exs`: the serde error of a precision that is not UTF-8, with Core's full
    list of variants (probed).
- **Partial map matches compared whole.**
  - `buckets_test.exs`: a bucket's retention rule.
  - `invalid_utf8_test.exs`: an `io` query's answer.
- **Warm-up matches compared with `===`.**
  - `database_rules_test.exs`: a fresh store's database list.
  - `sql_cost_test.exs`: two warm-up answers.
- **Left.** Matches stay partial where the values are generated, such as token ids and bucket
  timestamps, and where the text is another library's (Jason's encoder error).
- **A test moved.** The cost test of an `UPDATE`'s arithmetic (2026-10-15) belongs with the
  other DML costs, so it moved to `sql_dml_cost_test.exs`. `sql_cost_test.exs` names that file,
  and its moduledoc is rewrapped.

### Reported, and left

- **One helper for the three sorts.** `apply_order_by/2`, `order_projected/3` and
  `apply_order_by_rows/3` differ in how a key reads a row. A shared helper would need the
  same three readers, so little would be shorter.
- **`SQLPlan.column_types/2`.** It is computed by up to three callers, and is a full scan
  only when a wanted column is null in every row. A modest gain, left.
- **`plan_gates/1`.** It has four short `case`s of one shape, and folding them gains little.

## Verification

- **Core 3.10.1.** Every answer above was probed on Core 3.10.1.
  - The Core contract suite ran with the new cases: 750 tests, 0 failures.
  - A first run failed 12 tests because the probe databases had filled Core's limit of five.
    They were deleted and the suite run again.
- **The unit tier.** 21 doctests and 2393 tests, 0 failures, three times and once with coverage
  (94.29%). No changed line is missed.
- **The other gates.** Format, both compiles, credo and dialyzer pass.
