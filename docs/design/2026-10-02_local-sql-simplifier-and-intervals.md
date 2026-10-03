# Local SQL: the Simplifier, the Interval Analysis and a Performance Regression

**Date**: 2026-10-02
**Scope**: `Client.Local` SQL: what the engine's simplifier removes from a
`WHERE`, the interval analysis (casts, a division by zero, arithmetic on a
column), a decimal compared with a float, integer literals past `UInt64`,
the order the engine runs the operands of an `AND`/`OR` in (a fresh write
against a persisted table), literal and parenthesised operands, `ORDER BY`
aliases, the scale of `round`/`trunc`, statements that start no statement
(and the tokens the engine prints for them), and the cost of a query at
100,000 points
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

**Found when the first draft of the batch rule was reviewed** (all against
Core):

- The batch refusal ran the operands the left side leaves out and turned
  *any* throw from them into the refusal, a refusal of the double or a NaN
  included: `total > 0 AND used / total > 0.5` over a row of `total = 0` was
  refused (26 of 33 idioms of a guard corpus), though the engine answers.
- It refused a tag guard (`host = 'h1' AND 100 / n > 1`), which the engine
  answers in a fresh write and in a persisted table alike, and answered a
  guard that stands after the failing operand (`100 / n > 1 AND host = 'h1'`)
  with the closed connection the engine does not give.
- The rule it stated, a fifth of the batch, held for a fresh write only.
- `u + 1 > 5 AND u < 3` and `i + 1.5 > 5 AND i < 3` were the interval error
  (the engine answers `[]`); `i / 0 = 1 AND i > 0` had the comparison's body
  where the engine's is the division's; `i / 0 = 1 AND i < 5` was an error
  where the engine closes the connection.
- `1 IS NULL`, `'a' IN (...)`, `NULL IS NULL` and `(n + 1) > 5` were a column
  named `1`, a refusal or a schema error.
- `@@x`, `1e5`, `0x1f`, `'a''b'`, `N'x'`, `b'1'`, `E'x'`, `U&'x'` named the
  wrong token; `X'1f'` as a statement start was refused; `UPDATE` and `GRANT`
  alone were a DML body and a 405; `(SELECT ...)` was refused.

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

**`AND`/`OR` over a batch** (`SQLBatch`, called by `SQLCondition.filter/2`).
Whether an operand that fails for some row (`100 / n` for `n = 0`, an
overflowing `abs`) fails the query when another operand leaves that row out
depends on the state the table is read in, so a conjunction is not run row
by row. Probed on tables of 10, 100 and 10,000 rows, read as `EXPLAIN` shows
the plan and then again after Core had persisted the same data:

- **A fresh write** (`RecordBatchesExec`). A conjunct that reads only tag
  columns, or tags and `time`, is applied by the scan below the
  deduplication, so it leaves a row out for every other conjunct, in
  whatever place it stands. The other conjuncts run in the written order
  over batches the engine cuts (a table is not cut where its rows are): the
  right side of an `AND` runs over the whole batch, or over the rows the left
  side selects when that is *under a fifth of the batch* (`n > 5` selecting
  68% is run over the whole batch and fails; `usage > 99` selecting 3 of 100
  answers), and over none when the left side selects none. A conjunct that
  reads no column (`100 / 0 > 1`) is run whatever precedes it.
- **A persisted table** (`DataSourceExec`, Parquet). The conjuncts are row
  filters, each run over the rows the ones before it kept, **ordered by the
  compressed size of the columns they read**: a conjunct over a tag column
  first (`host = 'h1' AND 100 / n > 1` answers, and so does the other order);
  one over a subset of another's columns before it (`ti > 0 AND ui * 100 / ti
  > 50` answers, and so does `ui * 100 / ti > 50 AND ti > 0`); two over the
  same columns in the written order (`n > 5 AND 100 / n > 1` answers on
  persisted data though it selects 68%, `100 / n > 1 AND n > 5` fails); any
  other pair in an order that depends on sizes the double does not know
  (`usage > 99 AND 100 / n > 1` fails over persisted data whatever `usage`
  selects, `total > 0 AND 1000 / ti > 1` too). `time` is not cheap
  (`time > X AND 100 / n > 1` fails over persisted data and answers over a
  fresh one).

The same data therefore answers in one state and closes the connection in the
other (`n > 0 AND 100 / n > 1`: closed fresh, 7,800 rows persisted), and the
earlier rule of this document, *"the right operand runs over the rows the left
selects when that is at most a fifth of the batch"*, was a fresh-write rule
presented as the engine's; `n > 5` selecting 68% still answered on persisted
data.

The double answers a `WHERE` only when the outcome is the same in both states,
and refuses the rest by name. Each conjunct is evaluated for each row without
stopping at its first failure (`probe`), giving a value (true, false, null)
and what evaluating it does: fails, may fail by how the engine runs the
operands inside it (an `OR` whose first side is true skips a second one that
fails; the engine runs it over the whole batch), is refused by the double, or
is an error the engine raises at planning. Then, for each row that no
tag-only conjunct leaves out:

- a row that reaches the failing conjunct in both states (no conjunct before
  it leaves it out, and none the engine may run before it) fails the query;
- a row left out in both is no failure: that needs a conjunct the engine runs
  first leaving it out in a persisted table (a tag, a subset of the columns,
  the same columns before) and, in a fresh write, no row at all selected by
  the conjuncts before the failing one (its density is then zero) or a
  `time`/tag conjunct leaving it out;
- anything else makes the outcome differ, and is refused.

So `host = 'h1' AND 100 / n > 1` (tag), `100 / n > 1 AND host = 'h1'`,
`host IN ('a', NULL) AND 100 / n > 1` and `n IS NULL AND 100 / n > 1` (the
same column, no row selected) answer, `n < 5 AND 100 / n > 1` (a zero row is
selected) closes the connection, and `n > 0 AND 100 / n > 1`, `total > 0 AND
ui * 100 / ti > 50`, `ui * 100 / ti > 20 AND ti > 0`, `n NOT BETWEEN NULL
AND 5 AND 100 / n > 1`, `host = 'h1' AND NULL AND 100 / 0 > 1` and
`n = NULL AND 100 / 0 > 1` are refused (each closes a fresh write and answers
a persisted table, except the two with `100 / 0`, which close the fresh one
and answer the persisted one at no row).

A refusal of the double itself, or a NaN, in a conjunct a row does not reach
is not a failure (it was refused, with `total > 0 AND used / total > 0.5`
over a row of `total = 0`, because the evaluation of the skipped operand
refused its comparison of the NaN of `0.0 / 0`). A NaN a row does reach is
still refused by name: the engine orders a NaN by its sign (`0.0 / 0` is
positive on the aarch64 Core that was probed, where `NaN > 0.5` is true, and
`-(0.0 / 0)` is negative), and the sign of a NaN a division produces is the
CPU's, not the engine's: an x86-64 build gives the other.

A guard corpus (33 idioms, `total` zero on 10% of the rows, 10, 100 and
10,000 rows) drove the rule: before, 26 of 33 were refused whose answer
Core gives on a fresh write (all of the float idioms); after, none, and the
seven that remain refused are the integer guards that close a fresh write.

**Arithmetic in the interval analysis, corrected** (`SQLBoundsExpr`). Probed
over every operation, type and literal kind (`u`, `i`, `f` columns,
`+ - * /`, either order, int and float constants, `> 100` and `> 100.5`):

- an unsigned column's arithmetic is a decimal's and is **never** solved
  (`u + 1 > 5 AND u < 3` is `[]`, as are `u - 1`, `1 + u`, `>=`, `=`,
  `u * 2`, `u / 2`, `u + 0`), and an integer column's with a float constant
  is a float's (`i + 1.5 > 5 AND i < 3` is `[]`; `i + 1 > 5.5 AND i < 3` is
  solved and is the interval error);
- what the optimizer removes before it reads an expression is gone: a double
  negation, `(i)`, and `* 1`, `/ 1` (the integer one for an integer column
  compared with integers, either one beside a float column): `u * 1 > 100
  AND u < 3` is the bare bound's error, `lhs:Null, rhs:UInt64`; compared
  with a float (`u * 1 > 100.5`) the cast stays and the answer is `[]`;
- a cast of an `Int64` column to `Int64` is no cast, so `CAST(i AS BIGINT) +
  1 > 100 AND i < 3` is solved (`lhs:Int64, rhs:Null`); a narrower cast is
  not looked through.

**A division by zero that forces a column** (`SQLBoundsExpr.forced/2`,
`SQLBounds.divzero/2`). `E / 0 = c` (or `IN (c)`) forces the dividend to zero
for the analysis: `i / 0 = 1` forces `i = 0`, `(i + 1) / 0 = 1` forces `i =
-1`, `(i * 2) / 0 = 1` forces `i = 0`. It fails the analysis when the bounds
of the column leave that value out, in either order; when they hold it the
rows are read (an integer division by zero closes the connection; a float's
is infinity and answers). Verified: `i / 0 = 1 AND i > 0` (empty) fails and
`AND i >= 0`, `< 5`, `<= 0`, `> -1`, `= 0`, `BETWEEN -5 AND 5`, `IN (1, 2)`,
`> 0.5` (a float literal is no bound of an integer column) close the
connection; `i > 0 AND i / 0 = 1` fails and `i >= 0 AND i / 0 = 1` closes. An
unsigned column divides as a decimal and closes (`u / 0 = 1 AND u > 0`); a
float column fails (`f / 0 = 1 AND f > 0`, `f / 0.0`) and answers `[]` when
the bounds hold zero (`f >= 0`); an integer column divided by `0.0` answers.
The body is `Intervals must have the same data type for division, lhs:Null,
rhs:<type>` when the division of a bare column (a cast of an `Int64`
column included) stands before every comparison, and otherwise the first
comparison's interval error, as before (`1 / 0 = 1 AND i > 0`, `(i + 1) /
0 = 1 AND i > 0`, `u > 0 AND i / 0 = 1 AND i > 0` is the `UInt64` one). A
dividend that is a product, a negation or contains the division
(`2 * i / 0`, `-i / 0`, `i / 0 + 1`) fails in words of its own
(`multiplication, lhs:Int64, rhs:Null`, `Can not run arithmetic negative on
scalar value NULL`) and is refused by name.

**Operands.** A literal on the left of `IS [NOT] NULL`, `[NOT] BETWEEN`,
`[NOT] IN`, `LIKE`, a match is the constant it is (`1 IS NULL AND ...` is
`[]`, `NULL IS NULL` holds for every row, `1 IN (v, 2)` compares); it was
read as a column named `1`, and answered `Schema error: No field named "1"`
(an engine-shaped body the engine does not give). A parenthesis that opens a
predicate groups conditions only when what follows its closing one is the
end, a closing parenthesis, `AND` or `OR`; otherwise it belongs to the
predicate's text (`(n + 1) > 5`, `(n) IS NULL`, `((n) > 5)`: refused before).

**Statements** (`SQLStatement`, `SQLParser`). A text that starts no statement
is `Expected: an SQL statement, found: <token>`, the token as the engine's
tokenizer prints it: a prefixed string with the prefix in capitals and its
quotes undoubled (`N'x'`, `b'1'` is `B'1'`, `'a''b'` is `'a'b'`), `0x1f` as
`X'1f'` (`0X1F` is `0`), a number as written to its last digit (`1e5`, `1.e5`,
`.5`; `1e` is `1`), `@@x`, `$a`, `$$x$$`, `#a`, `!=` as `<>`, with the line and
column after leading whitespace and comments. A first token whose printing
was not read from Core (an operator that might be a longer one) is refused by
name. A statement word alone, or with a `;`, is the parser's `Expected: <what
it needs>, found: EOF` (or `found: ; at Line: 1, Column: n`): `UPDATE` needs an
identifier, `GRANT` a privilege keyword, and `BEGIN`, `COMMIT`, `SHOW` and the
rest answer as the engine does (a table of all 63 words). A query in
parentheses (`(SELECT ...)`, nested) is the query; one followed by `ORDER BY`,
`LIMIT` or `OFFSET` is refused by name. Leading and trailing empty
statements (`;;SELECT ...;`) were already read.

**Structure.** `SQLWhere` (the boolean structure) and `SQLPredicate` (one
predicate's text, 660 lines of operand and clause reading) replace the 875
line `SQLWhere`; `SQLQualifier` (table qualifiers and `CROSS JOIN`) and
`SQLDistinctOn` leave the parser (861 to under 700 lines). `SQLWhere.exprs/1`
and `columns/1` read a node's expressions through `SQLExpr.children/1` and
replace the tuple-flattening walkers of `SQLCondition` and `SQLBounds`.
`SQLCondition` evaluates; `SQLBatch` is the engine's evaluation order.

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
- **A NaN a row reaches in a comparison.** The engine orders a NaN by its
  sign; the sign of `0.0 / 0` is the CPU's (positive on the aarch64 Core
  probed: `(0.0 / 0) > 1` is true, `-(0.0 / 0) > 1` false; an x86-64 build
  gives the other), so the double refuses the comparison by name rather than
  be right on one CPU. It is no longer refused in a conjunct a row does not
  reach.
- **A guard whose time bound selects no row.** `time > X AND 100 / n > 1`
  answers over a persisted table when `X` is past every row (the file is
  pruned by its statistics) and fails when some row is kept; the double
  cannot tell the file layout, and refuses it.
- **Arithmetic on two columns in the interval analysis** (`i + i > 100 AND
  i < 3` is the interval error, `u + u` another, `f + f` another); the double
  answers `[]`. A narrower cast inside arithmetic (`CAST(v AS INT) + 1`) is
  not looked through either.
- **A tag of high cardinality in a persisted table.** The rule that a tag
  conjunct is run first there holds for tags of 4 and 10 values over 100 and
  10,000 rows (it follows from the compressed sizes); a tag whose column is
  bigger than the failing one's (one value per row) was not probed over a
  persisted table, since Core stopped accepting writes while it was set up.
- **`CAST(f AS INT) > 5` over a float column** closed the connection in one
  probe (a value near `1e30`); it was not isolated and is not modelled.

## Verification

Every body above was read from a Core at `localhost:8181`
(`influxdb3 serve --object-store memory`, see
[`README.md`](README.md)) with the query shapes the contract tests use; the
contract suites pin them with `===` against Local, and the same tests run
against the engine in the integration suites. The fresh-against-persisted
rule was read by `EXPLAIN` (a persisted table plans a `DataSourceExec` over
Parquet files with the predicates in its `predicate=`, a fresh one a
`RecordBatchesExec` below a `FilterExec`) and by running one corpus over a
freshly written table and over persisted tables of the same shape; Core
persists a table only after a snapshot, which a table written once does not
reach for an hour. The expectations of the new contract tests were checked
on Core tables of the same shapes (the guard idioms, the tag guards, the
`NULL` shapes, the interval bodies, the statement tokens); the integration
suites run the tests themselves. The benchmark is
`tmp/`-local; reductions at 100,000 points, b98d373 against this change,
are in the commit message.

---

## Addendum: the sixth review's SQL changes

**Guarded division.** `SQLBatch.filter/2` probed every row for a failing
operand. It now decides from the data: a conjunction is guarded only when a
divisor holds `0` or `-1`, a negation or `abs` meets the `Int64` minimum, a
`round`/`trunc` scale leaves `Int32`, or a cast or call can fail on a value
present. Otherwise it is the plain filter. A guarded query splits the rows
into risk-free ones (the tag guard decides them) and risky ones. Reductions
at 2,000 points, min of 3, against the commit before: guarded division
235,170 against 236,059; the same selecting 93,130 against 187,995; `OR` guard
253,436 against 291,734; plain `WHERE` 104,863 against 125,317. A table with a
zero in every row costs more than before (about 300K against 24K) because
the engine's failure is now computed instead of guessed.
`SQLCondition` no longer calls `SQLBatch`, which breaks the runtime cycle
between them; the executor calls `SQLBatch.filter/2`.

**Engine-shaped errors.** `SQLSyntax` is a token recogniser that returns the
parser's own message (`Expected: an expression, found: EOF`, `Expected: end
of statement, found: X at Line: L, Column: C`, ...) for a statement the
engine's parser rejects, and gives up (`:ok`) on a construct it does not read.
It was fuzzed over about 3,600 mutated queries against Core. A `WHERE` that is
no boolean, `LIKE` over `time` and `GROUP BY ()` (405, "Empty tuple not
supported yet") carry the planner's bodies. `iox.t` and `public.iox.t` resolve
to the table, another schema or catalog is "table '...' not found";
`information_schema.tables|columns|schemata` and `SHOW TABLES|COLUMNS` are
modelled, pinned to Core 3.10.1.

**Expressions.** `SQLExpr` reads a full boolean grammar (`CASE`, `IN`,
`BETWEEN`, `LIKE`, `IS [NOT] NULL|TRUE|FALSE|DISTINCT FROM`, `||`, `::`);
`SQLExprType`, `SQLExprCheck`, `SQLScalarCheck` and `SQLCoerce` give the
planner's type and coercion errors; `SQLScalar` evaluates the string and math
functions. Aggregates inside expressions and `HAVING` are placeholders
(`__agN__`) evaluated per group (`SQLAggExpr`). Core facts found on the way:
a column name is never parenthesised (`ag.n + Int64(1) * ag.x - Int64(1)`);
`pow` overflow, a negative `pow` exponent, `substr` with a negative length and
an integer division by zero close the connection; `IS DISTINCT FROM` swallows
a following `AND`/`OR` into its right operand; a JSON NaN or infinity is
`null` with the key present.

**Still refused** (listed in the guide): the date and time functions
(`date_trunc`, `extract`, `INTERVAL` arithmetic, the string `date_bin`),
`date_bin_gapfill`, `approx_percentile_cont`, windows, joins other than
`CROSS JOIN`, set operations, subqueries, `VALUES`, `ROLLUP`/`CUBE`, table
functions and the `system.*` tables. `var_*`/`stddev*` can differ from the
engine in the last digit: its result depends on how it splits the rows into
batches (merging two halves of eleven values gave six different last digits).
