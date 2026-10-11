# Review of InfluxQL `SHOW TAG KEYS WHERE` cost

**Date:** 2026-10-11
**Status:** Implemented

## Context

A sweep with no open GitHub issues. It searched the library for work that grows with the
square of its input: a list appended to in a loop, a list indexed with `Enum.at/2` once per
element.

## Decisions

### `odd_time?/1` reads each token in one pass

- **What it decides.** A `SHOW TAG KEYS ... WHERE` over a measurement with no tag is refused
  by name when a `time` in the condition sits in arithmetic, beside a name, or before a
  regular expression. The engine's planning error for those is its own.
- **The defect.** Each `time` read its four neighbours with `Enum.at/2` on the token list, a
  walk of the list for each one. A condition of `n` comparisons of `time` cost a square in
  `n`.
- **The fix.** The list, padded with two `nil`s at each end, is read in windows of five.
  The window's middle token is checked with the two either side, in one pass. `time?/1` is
  false for `nil`, so the padding never counts as a `time`.
- **The bound.** The double refuses a chain deeper than 8020 units (14 a link) before this
  check runs, so the square was bounded. The fix still removes the square.

### What else the search found, and why it stays

- `Enum.at/2` on a select list, on a Flight view's data buffers, on a sorted list for a
  median, or on the parameters of a request is called once, or once per short list. None is
  per element of the input.
- `close_all/1` in `InfluxQLWhere` copies the open groups once per `(` left unclosed. The
  depth refusal bounds those groups before the condition is read.
- The size list of a SQL type appends to at most two numbers.

## Verification

- `InfluxQLCostTest` measures the reductions of a chain of 125 and of 500 `time > 0` joined
  by `AND`, against a measurement with no tag. The answer is pinned to the engine's planning
  error.
  - Before the fix, the ratio was 7.6. A line gives about four.
  - The test bounds the ratio between 2.5 and 5. It fails on the old code and passes on the
    new.
- The InfluxQL contract cases for `time = time`, `time != time` and `time > time` keep
  their refusals.
- The unit tier, coverage and every gate were run one at a time.
