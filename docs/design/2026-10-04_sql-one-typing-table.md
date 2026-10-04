# One Typing Table for `Client.Local` SQL, and the Twelfth Review's Defects

**Date**: 2026-10-04
**Scope**: `lib/influx_elixir/client/local/sql/` (`sql_expr_type.ex`,
`sql_typed.ex`, `sql_common_type.ex`, `sql_plan.ex`, `sql_expr_check.ex`,
`sql_agg_type.ex`, `sql_bind.ex`, `sql_dml*.ex`, `sql_grant.ex`, `sql_where.ex`,
`sql_mask.ex`), the SQL case tables under `test/support/contract/`
**Issue**: scheduled quality sweep. This fixes the defects found in commit
b04c320 ([`2026-10-04_eleventh-review`](2026-10-04_eleventh-review.md)).
**Supersedes**: the typing described in the eleventh review ("one typing
pass"), which kept three tables.

---

## Problem

Three modules typed an expression, each in its own flavour: `SQLFunctions` (no
booleans, no `CASE`, `Float64` for every function it did not know),
`SQLExprType` (booleans, `CASE`, `COALESCE`, but no `NULL`), and a third in
`SQLPlan` (`NULL` as `Null`). A node typed by one was invisible to a check
written for another, which is why `-(n < 1)` answered, `abs(coalesce(n, 1)) +
's'` named `Float64` where Core says `Int64`, and `u + NULL` (typed `UInt64`
by the eleventh review) let a coercion-phase error pre-empt a planner-phase
one. The memo was a 256-entry list searched linearly.

Evidence, each verified on Core 3.10.1 (`influxdb:3.10.1-core`):

- `HAVING abs(y) > 1` with `y = max(s)` raised `ArgumentError`
  (`:erlang.abs("str3")`); Core is the `abs expects Numeric` 400. A `HAVING`
  alias was untyped, so `y + 1 > 1`, `y > true` and `y + 's'` answered `[]`.
- A negation or unary plus of a boolean, `LIKE`, `IN`, `||`, `COALESCE`,
  `NULLIF`, `CASE` was not refused (`Negation only supports numeric ...`).
- `HAVING count(*) > $1` answered `[]` unbound: `placeholders/1` skipped the
  `HAVING` map. Core meets the placeholders in the order of its plan (`WHERE`,
  aggregates, `HAVING`, select list, `ORDER BY`, `OFFSET`, `LIMIT`).
- `SELECT s AS usage ... ORDER BY usage + 1` typed `usage` as the table's
  `Float64` column; Core reads the select item. `ORDER BY abs(usage)` raised.
- A leading `;` before `INSERT`/`UPDATE` raised `FunctionClauseError`; about 9%
  of random `UPDATE` statements were refused and some answered wrongly.
- `time IS [NOT] DISTINCT FROM '2023-10-01'` was refused for every string;
  Core compares the text as a timestamp.
- `u + NULL` and `time - NULL` pre-empted errors HEAD~1 got right; `SELECT
  DISTINCT ... HAVING ... ORDER BY upper(host)`, a selector beside a
  differently-ordered selector, and `GRANT ROLE r TO bob` were refused or
  worded wrongly.
- A 900-term `HAVING count(*) + ... + count(*)` took 618 ms: every part of the
  expression rebuilt the aggregates' scope.

## Design

**One table.** `SQLExprType.node_type/4` is the only place a type is decided.
`type_of/4` reads it with a memo; `known_type/4` is the same with `Null` read as
"not known" for the checks that never refuse a null (`SQLExprCheck`,
`SQLAggType`); `constant_type/1` is the column-free view `SQLEval` asks. The
types of the aggregates, the arithmetic with a `Null` (`NULL + NULL` is
`Int64`, `NULL + 1.5` `Float64`) and the common type of `CASE`/`COALESCE`/
`GREATEST`/`NULLIF` (`SQLCommonType`) are all rules of that table.
`SQLFunctions` lost its typing and `SQLNullType` its `constant_type` and
`arithmetic`.

**Two typings, as the engine has two.** The planner types an expression as it
builds the plan; the type coercion types it again once the operands are
coerced, and wraps its errors as `type_coercion`. They differ for a `CASE`
only: the planner's type is that of the first result that is not `NULL`
(`WHERE CASE WHEN n > 1 THEN 1 ELSE 2.5 END` is refused as returning `Int64`,
`CASE ... END + 's'` names `Int64`), the coerced type is the common one. A
memo entry is `{coerced, planned}`; `phase` selects. The select list checks an
operator against the planned types (unwrapped error), then the coerced types
(wrapped).

**An exact memo.** `SQLTyped` is a map keyed by the node, per set of column
types: the scope of an expression over aggregates (`{columns, memo, nulls}`) is
made once for its set of aggregates and shared by all its parts. Scopes are a
list, not a map, because a map would hash the aggregates' long list for every
part; the parts share the one term, which a list compares by identity.

**Error order.** `SQLPlan.check_items/3` keeps the ranks of the eleventh review
and adds the engine's phases:

- the planner's unwrapped errors end the check where they stand;
- in the select list, an error wrapped as `type_coercion` is deferred to
  position 2.5 (after the `WHERE`'s, before the `ORDER BY`'s): `SELECT n LIKE
  'x', ('s' OR n)` is the `OR` error, `... WHERE abs(s) > 1` the `abs` one;
- the optimizer's errors (position 5), a struct converted to text (10) and a
  closed connection (11) come after; the double's refusals of what the engine
  computes without an error (`SQLError.late_refusal/1`: a `CASE` condition cast,
  text beside a timestamp, number and text in `COALESCE`) come last, so they
  never hide an error;
- the operand of a `||` is typed when the planner builds the plan, so every
  operator and call under one fails unwrapped, a `WHERE`'s before the select
  list's and an `ORDER BY`'s after (`{:planned, item}`);
- a difference of a null and `time` (`Duration(ns)`) is refused where it is
  used, not before every other error;
- a `WHERE` that is one typed expression that is no boolean is the planner's
  first error (`Cannot create filter with non-boolean predicate`), found before
  the select list and the `ORDER BY`, and also when `LIMIT 0`.

**`HAVING` and `ORDER BY` names.** A select alias a `HAVING` reads is typed by
the item it names (`SQLAggType.output_types/3`; a table column of the name still
wins, verified); an `ORDER BY` name that is a select item's output is that item
(`SQLClauses.output_items/2`, shared with the executor).

**Parameters.** `SQLBind.plan_order/1` lists the parts of a query in the order
the planner meets their placeholders, and includes the `HAVING`.

**`IS [NOT] DISTINCT FROM`.** Its right operand is the rest of the expression
down to `OR` (`1 IS DISTINCT FROM 2 OR true` is `1 IS DISTINCT FROM (2 OR
true)`, an `Int64 OR Boolean` error). A text literal beside `time` is read as a
timestamp (`SQLTime.timestamp_ns/1`): compared by nanoseconds when it reads, the
optimizer's 500 when it does not; a text column is refused (Core closes).

**`COALESCE`, `NULLIF`, `GREATEST`, `LEAST` of a number and text** are typed as
the number (the text is cast, `coalesce('s', u)` is a `UInt64`); a text literal no
number is written with is the optimizer's `Cannot cast string` 500, the rest is
a late refusal.

**`UPDATE`/`INSERT`.** A recursive operand parser replaces the token matching
(`SQLDmlExpr`, `SQLDmlOperand`, `SQLDmlPlan`, `SQLDmlName`); a leading `;` is
blanked before tokenizing. See the module docs for the verified order of
checks.

**`GRANT ROLE`, `DATABASE ROLE`, grantees `SHARE`/`APPLICATION`/`DATABASE ROLE`**
are worded as the engine does.

**Cost.** `SQLWhere.append/2` ran two regular expressions over the whole
predicate for every character, `SQLMask.balanced/1` masked the rest of the text
for every aggregate call, and the aggregates' names were looked up as columns
in every row: all linear now.

**Case tables.** 152 cases were added with Core's answer (translated from `cpu`
to the fixture, table names substituted, run on Core); the real duplicates the
test review found were removed (`log` as `:raw` beside `:sel`, `INSERT` in two
spellings, `(main)` and `( main )`, `n = 1;` and `n = 1 ;`, `1e1`/`1E1`,
`USE`/`Use`); the system-table lists (`SHOW TABLES`, `information_schema`,
`SHOW COLUMNS` of `system.*`) moved to `SQLCatalogCases.catalog_core/0`, which
only a `:v3_core` profile runs, and user-table forms (`table_schema = 'iox'`)
stand in `catalog/0`.

## Follow-up: the fuzz regressions and the `UPDATE` coverage

The first pass left 27 random queries further from Core than the parent commit.
Each now has Core's answer (or a pinned refusal) in `SQLScalarCases.errors/0`
and `errors_refusable/0`, translated to the fixture tables. What decided them,
each verified on Core:

- **Tags beside numbers.** `coalesce(host, 1)`, `greatest(host, n)` is
  `Dictionary(Int32, Int64)` (`SQLCommonType`): the operators report it by that
  name; arithmetic and `LIKE` with it, and a function of it, are Core's closed
  connection or an error the double does not word, so they are refused by name
  (late for the arithmetic and the `LIKE`).
- **An `Int64` with a `UInt64`** in `COALESCE`, `NULLIF`, `GREATEST`, `LEAST`
  (and the results of a `CASE`) is a `Decimal128`. `coalesce(y, -1)` over a
  `UInt64` sum answers as Core does: `SQLCoerce` casts each such argument to an
  internal `:decimal` cast, so the evaluator computes with the decimals of
  `SQLNumber`. A `UInt64` beside a `Float64` stays refused (late).
- **Error order inside one predicate** (all verified): the `AND`, `OR` and the
  operators and calls under them are found left to right (`logical_ops`), before
  the errors of the operators that type their operands late (`IN`, `BETWEEN`,
  `LIKE`, `CASE`, `NOT`, `IS TRUE`); the coercion of the results of a `CASE` to
  one type comes after the errors around it; a bad condition does not change the
  type a `CASE` has for what stands around it (the planner's); a `CASE` whose
  results are text and a timestamp is a timestamp once coerced; a call among the
  later results of a `CASE` is found by the type coercion but keeps the planner's
  words; a negation of a type it does not support is found last (the physical
  plan), after the `HAVING` filter check.
- **Words**: the arguments of a function the type coercion coerces differently
  from the written ones are worded by the first sentence; `IN` lists print as
  `IN ([a, b])` in a filter's text; `length(x)` names its argument as the query
  wrote it (`length(coalesce(cpu.s, Utf8("a")))`) and a cast under it is refused.

Bugs the work found and fixed (all existed in the parent commit): a `WHERE` that
compared two columns, one a boolean (`ok = s`, `u >= ok`), answered `[]`; `NULL
IN (true, 1)` answered where Core finds no common type; an `IN`, a `BETWEEN` or a
`LIKE` beside `time` and an unsigned or narrow number was not an error; `NOT 0`
under `IS NULL` raised; `UPDATE ... LIKE ... ESCAPE 'xx'`, `AS 1`, `UPDATE main
'a' SET`, `v.` and `INSERT ... VALUES (...),` read differently from Core;
`INSERT` into a table with a column list did not count the rows.

The `UPDATE`/`INSERT` modules are covered by the contract cases alone (no test
of the modules): about 640 statements were run on Core and on the double, the
ones that agree are in `SQLCatalogCases.syntax/0`, the ones the double refuses
by name in `syntax_refusable/0` with a pin in `SQLScalarRefusals.syntax/0`. The
branches no statement could reach (the `UPDATE` printing of `NOT`, `IN`,
`BETWEEN`, `LIKE`, `IS TRUE`; the closed connection and the `type_coercion` of a
planned operand; an unclosed `INSERT` group read as a count) were deleted. A
function name Core does not know is answered with a suggestion that is not stable
from one run to the next (`Did you mean 'tz'?` or `'iszero'?`), so only the names
with a single near neighbour are cases.

## Files Modified

| File | Change |
|------|--------|
| `lib/.../sql/sql_expr_type.ex`, `sql_typed.ex`, `sql_common_type.ex` | the one table, the exact memo, the common types (tag of numbers, decimal) |
| `lib/.../sql/sql_functions.ex`, `sql_null_type.ex` | typing removed |
| `lib/.../sql/sql_plan.ex`, `sql_schema.ex` | scopes, phases, deferral, planned items, filter check, `logical_ops`, comparison operands |
| `lib/.../sql/sql_expr_check.ex`, `sql_scalar_check.ex`, `sql_error.ex` | two-pass checks, late refusals, `CASE` condition cast, text cast, `IN`/`LIKE` of tags and nulls |
| `lib/.../sql/sql_agg_type.ex`, `sql_clauses.ex`, `sql_executor.ex`, `sql_bind.ex` | aliases, `ORDER BY` names, placeholder order, `DISTINCT ... HAVING ... ORDER BY expr` |
| `lib/.../sql/sql_expr.ex`, `sql_eval.ex`, `sql_time.ex`, `sql_cast.ex`, `sql_coerce.ex`, `sql_compare.ex`, `sql_fold.ex` | `IS DISTINCT FROM`, `time` and text, the internal decimal cast, names and filter texts |
| `lib/.../sql/sql_dml*.ex`, `sql_query.ex`, `sql_grant.ex`, `sql_statement.ex` | `UPDATE`/`INSERT`, `GRANT ROLE` |
| `lib/.../sql/sql_where.ex`, `sql_mask.ex`, `sql_select.ex`, `sql_parser.ex` | linear parsing, selector names |
| `test/support/contract/sql_*_cases.ex`, `sql_scalar_refusals.ex`, `sql_scalar_contract.ex`, `sql_parser_contract.ex` | the cases above, the Core-only catalog, `HAVING` parameters |
| `test/influx_elixir/contract_case_tables_test.exs` | pins of the removed duplicates taken out |
| `CHANGELOG.md` | entry |

## Verification

- `mix test`: 2049 tests, 0 failures; `mix test --cover`: 92.08%, and 100% for
  `SQLDml`, `SQLDmlExpr`, `SQLDmlOperand`, `SQLDmlPlan` and `SQLDmlName`.
- `mix credo --strict` clean; `mix format --check-formatted` clean;
  `MIX_ENV=test mix compile --force --warnings-as-errors` clean; `mix dialyzer`
  clean.
- `mix test --only v3_core` against Core 3.10.1: 3383 tests, 0 failures.
- Reductions on a 3,000-point table against the parent commit: `SELECT *` -0.0%,
  `WHERE` -0.3%, `count(*)` +2.7%, `GROUP BY` +0.1%, `CASE` +0.2%, `HAVING`
  -28%; 600 `WHERE` terms, 300 `CASE` arms: unchanged; 400 added terms 3.5 M
  reductions (135 M before); 300 `HAVING` terms 27 M (55 M).
- Random expressions (select list, `WHERE`, `ORDER BY`, `HAVING`), each compared
  with Core and with the parent commit. The first set (5,898 queries, the one
  that found the 27): answered as Core 3,468 before, 4,409 now; a different error
  from Core 891 before, 29 now (the rest is refused by name); raised 10 before,
  0 now; **no query is further from Core than the parent commit**. Two sets
  generated afterwards, not used to tune anything: 7,036 queries answered as
  Core 4,076 before, 5,229 now (different 1,109 before, 40 now, raised 7 before,
  0 now) and 4,677 queries 2,804 before, 3,509 now (different 753 before, 30 now,
  raised 7 before, 0 now); nine in each are further than the parent commit
  (three that were answered and are refused by name now, two that were answered
  and give a different error, four that were refused and give a different
  error). They are the known residue: an error of a nested expression whose
  order against another error of the same expression has not been pinned (a
  `CASE` operand beside a `NOT` of a result; a call beside an `IN` list), and
  `Decimal128` messages the double refuses to word.
