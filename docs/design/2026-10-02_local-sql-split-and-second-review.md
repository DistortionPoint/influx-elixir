# Local SQL: Module Split and the Second Review's Findings

**Date**: 2026-10-02
**Scope**: `Client.Local` SQL (parser split, params, lexer, time comparands,
Int64 arithmetic, `round`), InfluxQL numbers and series order, contract-test
assumptions, HTTP timeout tests
**Issue**: scheduled quality sweep (no open issues). This reviews commit
20829c7. The write-path half of the same review is in
[`2026-10-02_local-write-concurrency-retention-and-mixed-types`](2026-10-02_local-write-concurrency-retention-and-mixed-types.md).

---

## Problem

An independent review of 20829c7 compared about 170 probes against
InfluxDB 3 Core 3.10.1 and 2.7. A separate test review checked that the
tests deleted in that commit stayed covered: 12 of 14 did, and 2 facts
were restored.

**SQL defects confirmed against Core:**
- **Huge numbers.** An integer or Decimal parameter beyond a double
  raised `ArithmeticError`. The engine gives a 400
  `number out of range at line 1 column N`. `params: nil` also raised.
- **Int64 arithmetic.** It did not wrap: `y + 9223372036854775807` with
  `y = 1` gave 2^63, where the engine gives the minimum.
- **Lexer.**
  - `E'a\'b'` gave a false TokenizerError.
  - `"ho""st"` and `"$h"` compared as strings and returned `{:ok, []}`,
    where the engine gives the 500 "No field named".
- **Time comparands.**
  - An unreadable `time` string got a 400 that blamed an integer. The
    engine gives the optimizer's 500 Arrow parse error.
  - `time = NULL` was refused; the engine matches no rows.
- **`round`.** It dropped the sign of a zero result.

**InfluxQL:**
- A series without the `GROUP BY` tag came first; the engine lists it
  last.
- `5e20` was accepted; the engine gives a parse error.

**Size.** `sql_parser.ex` was 3,027 lines and about 340 functions.

**Two contract assumptions were wrong:**
- **Row order without `ORDER BY`.** One test asserted it, and Core
  returned another order.
- **The reporting shard group.** When several InfluxDB 2 shard groups
  fail, the engine does not always report the earliest. The same write
  gave "field type conflict" (the 1970 group) 10 times in 12 and
  "invalid field name" (the current week's group) twice.

**A flaky test.** An HTTP timeout test failed under full-suite load. Its
5 s wait was also equal to Finch's 5 s default pool timeout, so it could
not tell a right precedence from a wrong one.

## Decision

- **Split the parser.** `SQLParser` stays the entry point (694 lines),
  with these modules beside it:

  | Module | Holds |
  |--------|-------|
  | `SQLLexer` | Comments, statements, dollar strings, E-strings |
  | `SQLMask` | Quote masking, with the options InfluxQL needs |
  | `SQLLiteral` | Quoting, literal typing, identifier rendering |
  | `SQLTime` | Arrow timestamp reading, `now()`, intervals |
  | `SQLExpr` | Arithmetic expressions |
  | `SQLSelect` | Aggregate select lists |
  | `SQLWhere` | `WHERE` predicates |
  | `SQLClauses` | `GROUP BY` and `ORDER BY` |
  | `SQLLimit` | `LIMIT` and `OFFSET` |
  | `SQLBind` | Parameter binding |

  InfluxQL uses `SQLMask`, and the line protocol uses
  `Format.render_decimal`, so no duplicate masker or float renderer is
  left.
- **Params.** `QueryParams` reads numbers the way serde_json does. It
  takes the first digits that fit a u64, then scales them. The
  out-of-range error and the float values both follow from that.
  `params: nil` is accepted. A bad key or shape returns `{:invalid_param,
  ...}`.
- **Arithmetic.** `+`, `-`, `*` and negation wrap to Int64.
  `MIN / -1` closes the connection.
- **Lexer.** `E'…'` strings take the engine's escapes. A double-quoted
  token is always a column, printed the way the engine prints names.
- **Time comparands.** An unreadable `time` string is kept in the plan
  and raised as the optimizer's 500 after the planner's type errors, in
  the engine's order. `NULL` comparisons are three-valued.
- **`round`.** A zero result keeps its sign.
- **InfluxQL.** The number grammar is `\d*\.\d+` or `\d+`, with an
  optional sign. Anything else is the engine's parse error, with the
  engine's position and remaining text. A series without the tag sorts
  last.
- **Contract assumptions.**
  - Queries that assert multiple rows say `ORDER BY time`.
  - The shard-group drop table lists every message the engine may
    give. The double must give the first (the earliest group); the
    engine may give any.
  - Tests that intentionally diverge on Local are tagged
    `:local_divergence`.
  - Every contract `quote` uses `location: :keep`.
- **HTTP timeout tests.** Each wait is now well under the timeout that a
  wrong precedence would apply, and well over the one under test:
  - receive timeout: 20 s against a 30 s or longer wrong timeout;
  - pool timeout: 3 s against Finch's 5 s default.

  The black-hole listener takes a backlog of 128.

## Verification

- **Integration.**
  - Core: 249 tests.
  - InfluxDB 2.7: 63 tests, run three times.
  - Auth-enabled Core tokens: 8 tests.
- **Unit tests.** 2,029, run 6 times under full load after the timeout
  fix.
- **Other gates.** Credo, dialyzer, docs, and both compile environments
  are clean.
- **Engine probes.** Each body pinned by the new contract tests was
  read from Core or 2.7 first.
