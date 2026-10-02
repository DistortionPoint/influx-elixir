# Local SQL: the Simplifier, the Interval Analysis and a Performance Regression

**Date**: 2026-10-02
**Scope**: `Client.Local` SQL: what the engine's simplifier removes from a
`WHERE`, the interval analysis (casts, a division by zero, arithmetic on a
column), a decimal compared with a float, integer literals past `UInt64`,
`AND`/`OR` over a batch, `ORDER BY` aliases, the scale of `round`/`trunc`,
statements that start no statement, and the cost of a query at 100,000
points
**Issue**: scheduled quality sweep (no open issues). Reviews
[`2026-10-02_fourth-review`](2026-10-02_fourth-review.md) (b98d373 plus the
fixes after it).

---

## Problem

**Performance.** Against b98d373 at 100,000 points `SELECT *` was 37%
slower, a numeric `WHERE ... AND` 22%, `ORDER BY ... LIMIT` 130% and a grouped
aggregate 60% (reductions, which do not move with the machine's load). The
causes were work done for every query that only some need:

- `resolve_ordinals/2` read every point's columns before checking that an
  `ORDER BY` position is there;
- `response_row/1` rebuilt every row to write a `UInt64` or a decimal;
- `SQLRange.column_types/3` made a second pass over the points for types the
  store already holds;
- `value_order/2` and the aggregates' `add/2` went through `SQLNumber` for
  two integers or two floats, and the comparison had an extra call per row.

**Fidelity** (all against InfluxDB 3 Core, the numbers below by `curl`):

- `CAST(j AS INT|BIGINT|SMALLINT|TINYINT) > 5 AND ... < 3` is the interval
  error (`comparable, lhs:Null, rhs:Int64`; `UInt64` for an unsigned column)
  when the integers fit the type; Local answered `[]`. `CAST(u AS BIGINT) =
  -5` is `Arrow error: Cast error: Casting from Int64 to Null not
  supported` (500); Local closed the connection.
- `u / 2 > 1e21` is a 500 from the optimizer: `Invalid argument error: 1000...
  is too large to store in a Decimal128 of precision 35`, or `Cast error:
  Cannot cast to Decimal128(35, 15). Overflowing on 1.8e23`; Local answered.
- `u >= 18446744073709551616` compares as `Float64` (`u = max` matches);
  Local compared exactly.
- The simplifier removes `x AND false`, `x OR true`, `A AND (A OR B)` and the
  like, `x = x` and `x IS NULL` of a constant, a comparison with a NULL
  literal, and a NULL conjunct; what it removes never runs. Local ran it.
- `col = lit AND 1/0 = 1` is the interval error for every row; Local closed.
- An arithmetic comparison of a column beside a bound on it that leaves no
  value (`f * 2 > 10 AND f < 3`) is an internal 500 in the interval
  arithmetic; Local answered `[]`.
- `SELECT i AS a ... ORDER BY a + 1` sorts by the output item (an output
  name beats a column of the same name); Local failed with a schema error.
- `trunc(f, n)` reads `n` as an `Int32` and wraps; `round(f, n)` closes the
  connection past `Int32`.
- `FOO bar` is `SQL error: ParserError("Expected: an SQL statement, found:
  FOO at Line: 1, Column: 1")` (400); Local said 405.

## Design

**Performance** (`sql_schema.ex`, `sql_range.ex`, `sql_executor.ex`,
`sql_sort.ex`, `sql_aggregate.ex`, `sql_row.ex`, `sql_condition.ex`).
The columns are read only when an `ORDER BY` position is there; the
interval analysis takes a column's type from the store's kind and reads the
points only for a column the store has no kind for (a CTE's); the final
rows of a `SELECT *` carry their `UInt64`s as numbers from the start, and any
other row is rebuilt only when it holds a tuple, an infinity or a map;
integers of one type and floats that are not zero compare directly.

**Maintainability.** `SQLExpr.children/1`, `map_children/2`, `any?/2` and
`find_value/2` replace the hand-written `{:neg | :op | :cast | :call}`
recursion in `SQLFold`, `SQLBind`, `SQLTyping`, `SQLSchema` and
`SQLExpr.columns/1`. `SQLNumber.type_name/1` (dead) is gone; `compute/2`,
`null_placement/1` and `unknown_schema?/1` are private
(`SQLSort.value_before?/3` is used by `SQLAggregate` and stays public).
`comparison_clause/4` is split by what stands beside `time`.

**The simplifier** (`SQLSimplify`). The parser keeps the `WHERE` as written
in binary `AND`/`OR`/`NOT` nodes beside the conjunction list (`where_tree`,
parentheses kept: absorption is syntactic on binary nodes, and `X AND Y AND
(K OR X)` is `(X AND Y) AND (K OR X)`, which absorbs nothing). After the
planner's checks and the constant casts (those see the whole text, as the
engine does) the tree is given the predicates the query now has, simplified,
and flattened back; a `WHERE` the rules do not change is left as it is. A NULL
conjunct keeps the comparisons of `time` (the scan still takes its range from
them: `time > NULL AND time > X AND time < Y` is the empty-range 500) and the
constants. In a select list an operation with a NULL literal operand is NULL
when the other operand reads a column.

**The interval analysis** (`SQLBoundsExpr`, in `SQLBounds`):

- a `CAST` of an integer column to an integer type is removed when every
  integer compared with fits the type, and the column's own type names the
  error;
- an unsigned column's cast against a negative number (int or float) is
  the Arrow error for `=`, `<`, `<=` and `IN`; the other operators close
  the connection; beside another conjunct it is refused by name (the engine
  answers with the interval error for the type of the other conjunct);
- `=` or a one-element `IN` of an expression with an integer division by
  zero, beside bounds on every column it reads, is the interval error of the
  first bound (the engine's body names the first bound conjunct): not a
  call (`abs(1/0)` closes), not `%`, not a column the other conjuncts do not
  bound;
- `+` and `-` of a constant on a column are read as bounds that come after
  the others (the error body is the first bare bound's, and two such
  comparisons alone answer `[]`); `*`, `/` and a negation whose solved
  interval leaves no value with the other bounds are refused by name, since
  the engine's body depends on the operation and the order.

**A decimal and a float** (`SQLDecimal`). An expression over an `Int64` and a
`UInt64` is a decimal; its comparison with a float literal casts the literal
to `Decimal128(P, 15)` at planning, wherever the comparison stands (`AND
false` and `LIMIT 0` too). `P` is 35 for `/` and `%`, 36 for `+` and `-`, 38
for `*` of two columns or integers; the body is the float times `1e15` as the
engine computes it, with 15 decimals, until the product no longer fits 127
bits, then the cast error naming the float as Rust prints it. Any other shape
is refused. A float column past `1e20` against a decimal is a run-time failure
the double refuses (its limit depends on the precision).

**Integer literals** past `UInt64` and `Int64` are doubles (`SQLLiteral`).

**`AND`/`OR` over a batch** (`SQLCondition.filter/2`). Probed on tables of
up to 20,000 rows: the engine runs the right operand of an `AND` over the
rows the left selects when that is at most a fifth of the batch (and not at
all when none), otherwise over the whole batch; an `OR` runs it over the
whole batch unless the left is true everywhere. The batches do not follow the
rows (a small table is split into all rows but the last, and the last), so
whether a row the left leaves out fails the query is not something to model.
A `WHERE` whose skipped operand fails for such a row is refused by name; a
constant that fails, in a predicate, fails exactly when a row reaches it and
is left to the row-by-row evaluation, except a conjunct that reads no column,
which the engine runs whatever precedes it.

**The rest.** An `ORDER BY` expression reads a select item's output name as
that item. A `*` beside other select items is refused by name (`SELECT *, i`
is the engine's duplicate-name error). `trunc(x, n)` wraps `n` to `Int32`;
`round(x, n)` closes the connection past it. A first word, number, string
or `*` that starts no statement is the parser error at its line and column
(`SQLStatement`); `COMMIT`, `ROLLBACK`, `START TRANSACTION`, `SET x = v`,
`PREPARE`, `DEALLOCATE` and `EXECUTE` are the planner's `Statement not
supported`.

## Not modelled, and why

- **Row order without `ORDER BY`.** Core sorts what it reads by the tags in
  the order they were first written and then by time, but a run of rows
  comes out in the order of the blocks that hold them: the same rows written
  in separate requests, or the same query with a tag filter, came back in
  another order. Local keeps time order; the guide says to ask for an order.
- **`SELECT *, expr`.** The engine answers; Local refuses by name.
- **`CAST(f AS INT) > 5` over a float column** closed the connection in one
  probe (a value near `1e30`); it was not isolated and is not modelled.

## Verification

Every body above was read from a Core at `localhost:8181`
(`influxdb3 serve --object-store memory`, see
[`README.md`](README.md)) with the query shapes the contract tests use; the
contract suites pin them with `===` against Local, and the same tests run
against the engine in the integration suites. The benchmark is
`tmp/`-local; reductions at 100,000 points, b98d373 against this change,
are in the commit message.
