# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.42] - 2026-10-08

### Fixed
- **`Client.Local` InfluxQL: one order of parse errors, carriage returns, dotted names**: a
  stray quote or comment no longer wins over an earlier parse error (a lexer error stands only
  where the parser reaches the token), a `)` that closes nothing wins over a later bad token,
  `SELECT m. FROM m` is "expected field", a carriage return right after a keyword fails as it
  does on Core, non-ASCII letters and digits are no identifier or number characters, and
  `=~ /.*/` is answered again. Tokenizing is linear (parse reductions at 1,600 terms: 5.7M to
  1.4M). Refusals of select items name why.
- **`Client.Local` SQL: regex cost read once, IN pairs everywhere, the engine's rewrites,
  variance**: `s ~ '\x{4a}'` raised (a second reader of the pattern disagreed with the first);
  the cost of a pattern is now summed by the one reader (`SQLRegexCost`, with `SQLRegexGuard`
  beside it), 24% fewer reductions per check. An `IN` pair the engine folds to a constant is
  refused wherever a `NULL` operand shows it (an aggregate's argument, `GROUP BY`, a `HAVING`
  beside the aggregates it names, a comparison, a test, a cast, an `OR` of equalities), and
  `time`, never `NULL`, is not refused; `time IS [NOT] NULL` folds to a constant as the engine
  does (24 cases of unsigned negation are answered). Patterns the engine rewrites before it
  runs them are refused by name: an anchored literal beside `~*`, a literal backslash, `.*`.
  `format:` of invalid UTF-8 or a non-string is a refusal, not a `Jason.EncodeError`; a `WITH`
  over `length(s)` answers `3`, not `{:int, 32, 3}`; a refusal echoes the whole statement; the
  caret of `a{2,1}?` spans the `?`. The variance of ordinary floats is the corrected two-pass
  with compensated sums (51% fewer reductions; the true value, which the engine's merged
  partitions scatter around, where store-order Welford drifted 30 times further). Refusal
  reasons name the statement or the clause they are about.
- **`Client.HTTP` raised on text that is not UTF-8**: SQL, InfluxQL or Flux text, a database
  name, a bucket name or a token name that is not UTF-8 raised `Jason.EncodeError` out of
  `query_sql`, `execute_sql`, `query_influxql`, `query_flux`, `create_database`,
  `create_bucket` and `create_token`. Nothing is sent: they return `{:error,
  {:unencodable_body, message}}`, and `query_sql_stream` raises `InfluxElixir.StreamError`.
- **`Flight.Reader` allocated by a corrupt count**: a record batch's row count or field
  length, or a list column's offsets, were trusted as read, so one corrupt byte of a frame
  could build a column of billions of rows (36 of 1,950 corrupted frames went past 400 MB). A
  count the batch's body cannot hold is now `{:error, {:decode_error, _}}`, and list offsets
  are clamped to the child array. No valid frame decodes differently.
- **Connection options a request cannot use are refused up front**:
  `InfluxElixir.Config.validate/1` accepted a `:port` or `:flight_port` above 65535 and an
  empty `:host`, or one with a blank or control character; each failed later, at the first
  request, far from the option. They are now validation errors. A host that is a name, an IPv4 address, a bracketed IPv6 address or
  non-ASCII text is still accepted.
- **`ResponseParser.parse/2` raised on a body it could not read**: a CSV body that is not
  CSV (a proxy's HTML error page, a body cut off inside a quoted cell) raised
  `NimbleCSV.ParseError`, and a JSON array or JSONL line holding something other than an object
  raised `FunctionClauseError`, out of `query_sql`/`query_influxql`/`query_flux`. They are now
  `{:error, {:csv_parse_error, message}}` and `{:error, {:unexpected_json, value}}`; a streamed
  line that is not an object raises `InfluxElixir.StreamError` (`kind: :decode`) as a line
  that is not JSON already did.
- **`BatchWriter` dropped batches on 408 and 429**: every 4xx was discarded as the batch's own
  fault, including 408 (request timeout) and 429 (too many requests), which ask the client to
  try later. A batch refused while the server was busy was lost. Both are now retried like a
  5xx, with the same backoff and `:max_retries`; any other 4xx is still discarded.
- **Names and parameters that are not UTF-8**: `Local.create_token` raised on a token name
  that is not UTF-8, `delete_database` quoted the bytes into its 404, and `create_bucket`
  accepted such a name; every database, bucket and token name that is not UTF-8 is now refused
  by name. A query parameter whose name is not UTF-8 is `{:invalid_param, name,
  :unsupported_key}` for both clients (`Client.HTTP` could not have written it as JSON).
- **`Client.Local` SQL: IN pairs under NOT, regex the crate reads differently, float
  aggregates in store order**: `NOT (i IN (NULL) AND i IN (2))` and `NOT (i IN (0) AND
  i IN (1, 2))` kept three-valued logic where the engine folds the contradiction (256 rows for
  Core's 300); such pairs under `NOT`/`OR` are refused by name. `\v`, possessive quantifiers
  (`a++a`), `(?m)` or `\z` beside text with a newline, whitespace inside a counted repetition
  and huge nested repetitions are refused (they answered PCRE's matches); a non-ASCII escape
  is the engine's `unrecognized escape sequence`. The fixed scan order for float aggregates is
  gone: the engine's own float `sum` differs from run to run, and the order cost 2.5 times the
  work. `NULL = NULL` over a CTE, `OFFSET` on a one-row aggregate and `ORDER BY NULL` answer as
  the engine does; `LIKE ... ESCAPE '\'` and `LIKE 'w' || '%'` are answered again. A deep call
  nest in an `INSERT` was re-typed at every level (800 levels 28.6M to 9.7M reductions), and a
  long non-ASCII word is tokenized 5 times faster.
- **`Client.Local` InfluxQL: operators with no operand, `fill()` arguments, invalid UTF-8**:
  `WHERE f OR =~ /a/` and `(x AND )` answered `[]`; they are the engine's `invalid
  conditional expression` at the operator. A call's arguments in a `WHERE` are read as the
  engine reads them (`fill(+)` is its `Nom` failure, not the call error), the leftmost parse
  error wins across clauses, and `fill(-\f1)` is an invalid `FILL` option. InfluxQL and Flux
  text that is not valid UTF-8, and such a database name, raised `ArgumentError`; they are
  refused by name.
- **Tests: load-sensitive bounds, atoms, cost and clocks**: three tests failed under heavy load
  on Finch's 5-second pool start and checkout and a 30-second await; they no longer depend on
  either. The atom test covers Flux, line protocol, admin names and query parameters. Every
  cost test has a lower bound and pins the refusal it measures; batch-writer refutations stop
  the writer first; telemetry no longer brackets the wall clock.
- **`Client.Local` SQL: no raise on a stray character after a cast, pruning only by verified
  folds, unverified regex refused**: `n::int # a` raised `MatchError`; it is refused by name.
  `n IN (NULL, 1) AND n = 2` was counted as a one-element list and answered `[]` where the
  engine reports a negation error; lists are counted as written, `IN` lists nested one level
  right fold as the engine folds them, and NULL folds the double has not verified are refused
  by name. A regex construct the engine's crate reads differently from PCRE (`[a&&b]`,
  `(?>a)`, `\b{start}`, `\p{Greek}`, `\w` over non-ASCII text, ...) is refused by name; it
  answered PCRE's matches. `s ~ 'v' || '1'` took the text between the first and last quote
  as the pattern; it is refused. `INTERVAL '+N days'` and padded intervals are the engine's
  syntax error. A CTE no longer captures `iox.m`; a CTE's negation is pruned under an empty
  outer query. Float `sum`/`avg` and `var`/`stddev` were read in a scan order (tags, then
  time; withdrawn in the next review).
  `SELECT *` no longer counts the select list's columns over every row (+15% removed).
- **`Client.Local` InfluxQL: `fill()` behind or inside a condition, `GROUP BY` beside a
  `WHERE`, bare operands beside constants, the sign of a `fill()` number**: a `fill(` where an
  operand is wanted (`WHERE fill(1)`, `WHERE n > 1 AND fill(1)`) is Core's `invalid expression,
  the only valid function calls are ...` at the call (it answered all rows, and an
  `invalid conditional expression` at the connective); a `fill()` that follows a whole
  condition ends it, and what stands behind (`fill(2)`, `GROUP BY host`, `= 2`, any word) is
  left over from where it starts; an unclosed `fill(` is `invalid FILL option` at the end of
  the parenthesis, and of a `fill()` option and a later bad `LIMIT` / `ORDER BY` operand the
  leftmost is the error. `fill(- 1)` is minus one (a sign may stand apart from its digits).
  `WHERE c GROUP BY * LIMIT x` (and `/re/`) read the raw text of the clause it had blanked
  and answered a `Nom` error at the `GROUP`; it is the `LIMIT` error. A comparison of
  constants, and of a column the measurement lacks with a number, beside a bare operand no
  longer refuses the whole condition (Core answers `[]`; 616 of the 645 statements of the
  second corpus that 6e5b8fd had begun to refuse), a bare string beside the latter is
  refused by name (Core's `Cannot infer common argument type`), a string constant under
  `=~` / `!~` keeps no point, and `(true)` or a missing column beside a `time` comparison is
  the 500 `invalid expr stack`. `fill(n)` drops the rows no column holds a value in (`f + n`
  where one is missing), as Core does. The error of a clause is carried with its position
  (no more reading it back out of the body), and a second statement that does not parse is
  the error before the planner's `SLIMIT` 405. A 1 800-statement random corpus against Core:
  no wrong answer left that is not a refusal or Core's own clock.
- **`Client.Local` DML: linear tokenizing, no raise, refusals split by cause**: the SQL
  tokenizer read each word with a regex over the rest of the text (which validates all of it
  as UTF-8 each time), so an `UPDATE`, a `DELETE` or an `INSERT ... SELECT` of a chain of `n`
  words cost the square of `n` (1600 terms cost 7.3 times 400); it walks the word's bytes and
  costs 3.95 times. An arithmetic operator over two tags in an operand is the planner's
  `Cannot coerce arithmetic expression ...` again (it was refused by name; verified against
  Core in 2528 shapes), and a statement cut by a `;` inside a value the double cannot read
  (`INSERT INTO m (f) VALUES ((CASE WHEN n THEN 1 ; END))`) is refused by name instead of
  raising. The coarse refusals of a `WHERE` that is no boolean, of an unknown function and of
  two select items with one name say what they stopped at.
- **`Client.Local` INSERT / UPDATE / DELETE: planned in linear time, `ORDER BY` in
  calls, the names of an `INSERT ... SELECT`, one table resolver**: a chain of
  `||` was typed once for every prefix of it (100 terms: 279 ms in an `INSERT`,
  315 ms in an `UPDATE`; 400 terms: 5 s); it is typed once per link, and the
  text a chain is planned as nests no deeper than one pair of parentheses. An
  array or map literal in `VALUES` (`ARRAY[1,2]`, `[1,2][1]`, `{a: 1}`) is one
  cell and not a parse error, an `ORDER BY` inside a call
  (`first_value(n ORDER BY time)`, `count(* ORDER BY n)`) is read, and a `;`
  in the middle of a statement gives the parser's own error for the statement
  that stops short (`UPDATE m SET v = ; 1`, `INSERT INTO m (v) ; VALUES (1)`).
  The items of an `INSERT ... SELECT` are compared by name: two items with one
  name are the planner's `Projections require unique expression names ...`
  (literals, columns, aliases, operators, casts and the common calls are printed
  as the planner prints them, and an item whose name the double cannot print is
  refused by name), the errors of several items are the one error that holds
  them all (400 when each is the planner's own, else 500: `SELECT $0, host`,
  `SELECT CAST(1 AS UUID), CAST(2 AS UUID)`), `SELECT *` with no table is an
  error, a column of the table named as another item is ambiguous, an aggregate
  beside a column is refused, and the type and null-ness errors of an item come
  before the count of the items. A `CAST` to a timestamp, a `||` and a unary `+`
  find the type of their operand where they stand (a row of values that starts with
  anything but a name or a literal is the engine's `Only identifiers and literals are
  supported in tuples`, a type in the column list of a table alias that never closes is
  the parser's error at the type, a name the table lacks inside
  `CAST(v AS TIMESTAMP)` is found before the one beside it), the type of a cast
  is read before what it casts, a `TRY_CAST` types nothing it holds, an
  aggregate under a test is not typed, a placeholder has no type inside the
  operand of a `||`, a placeholder beside an operand that fails to type is
  refused, and a number above the largest `Int64` is a `UInt64`. `SQLTable`
  resolves the table of a statement and of a query (`locate/1`), lists the
  columns of the engine's own tables once (`engine_columns/2`) and words the
  not-found and compound-name errors once, so `SELECT * FROM system.nosuch` is
  the planner's `table 'public.system.nosuch' not found`. A single `INSERT` or
  `DELETE` is no longer tokenized and checked a second time before it is planned
  (an `INSERT` of 2000 rows: 108M reductions, 1.34 s, to 78M, 0.97 s). The contract asks the double for
  the system tables in either edition (`catalog_system/0`) and a real server only
  when it is a Core.
- **`Client.Local` InfluxQL: no atom from the text, the planner's order of
  errors, and the operands of `AND` / `OR`**: `SELECT v FROM m SLIMIT x` as the
  first statement of a VM raised `ArgumentError` (`String.to_existing_atom` on
  the clause word; the clause words are literals now, and `SOFFSET x` is worded
  as the `SLIMIT` clause as on Core); of two bad operands the leftmost is the
  error, and the first clause out of the engine's order is the parse error at its
  start (`... fill(null) SLIMIT 1 LIMIT 2 OFFSET 1`). The errors of rewriting
  the statement (a constant alone in parentheses, `n * (-3)`, `mixing aggregate
  and non-aggregate columns`, a transform of a field in a `GROUP BY time`) come
  before the `WHERE`'s, a select list that reads no field is empty whatever the
  `WHERE` holds (`SELECT count(host) ... WHERE host`), and the `WHERE`'s
  comparison that cannot be typed (`UInt64 >= Boolean`) comes before the select
  list's (`cannot use / between an integer and unsigned`). A field, constant or
  tag inside `AND`/`OR` is typed leaves first as the planner types it, for pairs,
  chains of three or more and groups (a pair with such an operand keeps no point;
  unsigned operands and two numbers are its `Cannot infer common argument type`
  error); `fill(n)` of a plain select fills the number columns a row lacks, of a
  selector over a string or boolean column is the engine's `no conversion`
  error; aggregates of a tag and of a boolean are the engine's coercion errors.
  The planner contract pins 432 statements of these (`InfluxQLDefectCases`).
- **`Client.Local` SQL: the order of the engine's errors, exact number folding,
  and refusals that say why**: the stages at which Core finds a query's errors
  (plan build, placeholders, the analyzer's `WHERE`, aggregate, `HAVING`, select
  and `ORDER BY`, then the optimizer and the physical plan) are one ordered table
  (`SQLStage`) in place of float ranks; an unbound `$n` is found after the
  select list's planner errors and before the analyzer's; a `HAVING`'s plan
  errors come before every `WHERE` coercion error; numbers fold pairwise with
  Core's exact types (`Int64` with `UInt64` is `Decimal128(20, 0)`, that with a
  `Float64` `Decimal128(35, 15)`), so `avg`/`sum`/`stddev` of `coalesce(tag, n)`
  answer as Core does; `IN`/`BETWEEN` with `NULL` operands, `HAVING NOT y`,
  `-3::text`, `first_value(1e3 ...)`, `BETWEEN` with `::` casts, a negation under
  a relation the optimizer proves empty and `count(DISTINCT ...)` names are Core's;
  a mid-statement `;` is the parser's error at the `;`, `DELETE FROM (` and
  `INSERT INTO t ;` are its errors, and `=>` is one token; `FROM main`, `SET
  TIME ZONE`, `?` and a `DELETE` of a subquery are refused by name. Typing a
  chain of N operators is linear again (`i+i+..` x 6400: 2.2 s to 0.63 s). The
  refusal tables pin each case's exact reason, and the ratchet compares it.
- **`Client.Local` SQL typed an expression in three ways and answered what
  Core refuses**: one table (`SQLExprType`) now decides every type, with an
  exact memo keyed by the node; `-(n < 1)`, `-coalesce(s, 'x')`, `-CASE ...`
  and a unary plus of a non-number are the `Negation only supports ...` 400;
  `abs(coalesce(n, 1)) + 's'` names `Int64`; a `HAVING` that reads a select
  alias types it (`abs(y)` of `max(s)` was an `ArgumentError`; `y + 1 > 1`
  answered `[]`) and binds its placeholders (`HAVING count(*) > $1` answered
  `[]`), which the planner meets in its own order; an `ORDER BY` name that is a
  select item's output is that item; the select list's coercion errors come
  after the planner's, the operands of a `||` fail as the planner's, and a
  `WHERE` that is one typed non-boolean expression is refused first, as on
  Core; `time IS [NOT] DISTINCT FROM '<timestamp>'` compares the instants and
  `IS DISTINCT FROM`'s right side is the rest of the expression; `COALESCE`,
  `NULLIF`, `GREATEST` and `LEAST` of a number and text are typed as the
  number; a leading `;` before `INSERT`/`UPDATE` no longer raises and `UPDATE`
  is read by an operand parser (aliases, case-sensitive targets, qualified
  field lists, `abs` of a non-number); `GRANT ROLE`, `DATABASE ROLE`, `TO
  SHARE`/`APPLICATION` are the engine's 405; `SELECT DISTINCT ... HAVING ...
  ORDER BY upper(host)` answers; a `HAVING` of 900 terms costs 24 M reductions
  (951 M).
- **`Client.Local` SQL: the random-expression regressions and the `UPDATE`
  modules' coverage**: a tag beside a number (`coalesce(host, 1)`) is
  `Dictionary(Int32, Int64)`, an `Int64` with a `UInt64` in `COALESCE`,
  `NULLIF`, `GREATEST` and `LEAST` a decimal computed as Core does, a `CASE` of
  text and a timestamp a timestamp; the errors of a predicate are found in the
  engine's order (the `AND`s, `OR`s, operators and calls left to right, the
  `NOT`, `IN`, `LIKE` and `CASE` coercions after them); `WHERE ok = s` and `WHERE
  u >= ok` (two columns, one a boolean) were answered `[]` and are the planning
  error; `NULL IN (true, 1)` is the error; `length(coalesce(s, 'a'))` is named as
  Core names it; `NOT 0` under `IS NULL` no longer raises; `INSERT ... VALUES`
  counts the rows against its column list; `UPDATE` reads a string as an alias,
  checks a `LIKE`'s escape and no longer words a trailing dot as a name. The
  `UPDATE`/`INSERT` modules are covered to 100% by contract cases with Core's
  answers.
- **`Client.Local` InfluxQL kept no point for an unsigned field beside text**
  (`u + s = 1`), where the engine's error is `Cannot coerce arithmetic
  expression UInt64 + Utf8`; `true / abs(time)` raised. Column names,
  `LIMIT`/`OFFSET` per column and the duplicate-name error now come from one
  projection plan in the engine's order: `time AS n, *` keeps the time,
  `usage AS host, top(n, host, 2)` names the tag `host_1`, and `top()` beside
  plain fields counts per column. A descending `top()`/`bottom()` tie goes
  to the later point, as on the engine.
- **`Client.Local` InfluxQL counted missing fields and compared mismatched
  kinds**: `count()` of a field the measurement lacks is omitted (it was a
  `0`), still taking its name
  (`count(nosuch), count(v)` is `count_1`); a comparison between kinds that do
  not compare (a number against a string, a boolean or a tag, strings and
  booleans in order, two tags, a regular expression against a number) keeps no
  point whatever the sides are (`abs(1) != 'x'`, `n / 0 = 'x'`, `(s) != 0`,
  `abs(n) < true`); an unsigned side against a boolean is the planner's
  `UInt64` 400; `abs()` words its errors as the planner does for a call that
  is the whole condition or part of one; `top()` and `bottom()` number the
  tag columns beside them as the engine does (`top(v, 1), host GROUP BY host`
  has `host` once; `top(v, host, 1) AS host_1 ... GROUP BY host` is the
  `Projections require unique expression names` 400), answer the points with
  no value after those that have one when a field is beside them, and answer
  the schema error for an aliased `time` or a field the measurement lacks;
  `(s)`, `+s`, `(b)` and `(host)` are the column; `*` beside a `time` column
  that takes a field's name numbers the later of the two; one typed
  arithmetic kernel serves the select list and the `WHERE`.
- **`Client.Local` InfluxQL aggregates of `time` read every point** (0.1.41).
  `max(time), count(s)` is the latest point that has an `s` (as are `first`,
  `last`, `min`, `mode` and `count(distinct(time))`, in a series, a bucket and
  beside plain columns or expressions); a series or bucket with no such point
  is not answered; `fill(0)` fills a time with the epoch; `count()` of a field
  no point holds is `0` beside another value, and `count(*)` lists every
  field of the measurement. Arithmetic with a time, a boolean or a string
  (`max(time) - min(time)`, `v + true`) is the engine's `incompatible
  operands` 400, and `abs(min(time))` answers nothing instead of a 500.
- **`Client.Local` InfluxQL `WHERE` answered strings, divisions and calls the
  engine does not**: `'a' + 'a' = 'aa'` and `s + s = 'xx'` concatenate, a
  string, boolean or tag under any other operator is null (`s + 1`, `-b`),
  `/ 0` is `0` (it closed the connection, or kept every point), `abs()` is
  computed and its misuse is the planner's 400, a sign before a string or
  boolean or a second one before a name is the parse error, a comment is
  echoed as written; every other function is refused by name (it answered
  `[]`).
- **`Client.Local` InfluxQL**: a regex with an unknown flag in `FROM`, the
  select list, `GROUP BY` or a function argument is the planner's 400 (it was
  the `WHERE` 500); `SELECT *, *` and `*` beside columns number their names;
  `top(v, host, 1) ... GROUP BY host` has `host_1`; `AS 1`, `mean((v))`,
  `mean(v + 1)` and `top(v, *::tag, 2)` are the engine's errors; `SELECT *
  ... GROUP BY /host/` has only the grouped tags; `SHOW TAG KEYS WHERE time
  != x` over a measurement with no tag is the time error; an aggregate
  stamped with a bound that is not a whole microsecond (`time >
  1700000000000000000`) answers the microsecond `Client.HTTP` reads from the
  engine.
- **`Client.Local` raised `ArithmeticError` on InfluxQL transforms** (0.1.41).
  `derivative(v, 0s)`, `elapsed(v, 0s)` and `moving_average(v, 0)` now give
  the engine's 400 ("duration argument must be positive", "moving_average
  window must be greater than 1"), and `moving_average(v, 1)` no longer
  answers. A float overflow in `cumulative_sum`, `derivative`, `difference`,
  `moving_average`, `integral`, `median` or `stddev` is a null, and integer
  `difference`/`moving_average` wrap as the engine does.
- **`Client.Local` InfluxQL returned no rows where the engine answers**
  (0.1.41): `count(/re/)`, `count(*::field)`, `mode(*)`, `mode(/re/)`,
  `elapsed(*)` and `elapsed` of a boolean field. An unknown function in a
  wildcard is now refused by name instead of answering `[]`.
- **`Client.Local` accepted InfluxQL the engine rejects** (0.1.41):
  `host = /re/`, a regex with flags, `percentile(/re/, n)`, `top` of a tag,
  a bare constant as a `SHOW … WHERE`; and refused a `SHOW TAG VALUES` `OR`
  on a missing column that 0.1.40 answered.
- **`Client.Local` SQL gave engine-shaped errors the engine does not give**
  (0.1.41) for `left()`/`right()`, a `HAVING` on an alias, a keyword alias,
  `1_000`/`1e`/`0b1`, `count(*`, `5 div 2`, `SELECT … INTO`, `USE`, and
  `SELECT 1; DELETE FROM`; these now answer or give the engine's own error.
  `selector_max(n, time) + 1`, `sum(NULL)`, `avg(NULL)` and an aggregate of
  a mistyped `CASE` give the engine's planning error, and an expression over
  `MIN(NULL)`/`MAX(NULL)` is refused by name.
- **Queries against a database with a retention were up to 7× slower**
  (0.1.41); they now cost about the same as any other database.
- **`Client.Local` InfluxQL dropped a `min(time)`/`max(time)` column**
  beside another aggregate, and `WHERE - host` was a planner error where the
  engine answers `[]` (a tag under arithmetic is null).
- **`Client.Local` SQL read `INTO` and `AS` used as column names as clauses**,
  resolved a qualified `HAVING`/`ORDER BY` name (`cpu.c`) as a select alias,
  answered `left(NULL, 1.5)` where the engine errors, and raised on
  `selector_max(...) || 'a'` and on some malformed InfluxQL select lists.
  Numbers such as `1L` and `0XFF` are read as the engine reads them (one
  definition of a number token now serves every SQL reader).
- **`Client.Local` printed a token created on a whole second as `….000Z`**;
  the engine prints `…Z` with no fraction (it is to the millisecond
  otherwise).
- **`Client.Local` SQL aggregate queries scanned every point** to list
  columns an `ORDER BY` might name, even with no `ORDER BY` (`count(*)` cost
  8.8×); they are back to their earlier cost.
- **`Client.Local` SQL raised on a selector under a text function**
  (`length(selector_first(s, time))`) and answered selector shapes the
  engine rejects (`selector_max(v, v)`, a selector in `CASE` or compared in
  `HAVING`); these are the engine's errors now. `selector_first(host, time)`
  returned no value for a tag.
- **`Client.Local` SQL refused `GRANT ALL`, `MERGE` and `NULL - time`**, which
  0.1.41 answered as the engine does, and answered `substr(NULL, 'a')`,
  `NULL || 1`, `host || n` and `count(distinct -1)` differently from the
  engine; statements the engine does not run (`CREATE SEQUENCE`, `DROP INDEX`,
  `create trigger t`) now carry its exact wording.
- **`Client.Local` SQL gave `||` the precedence of `+`**: `'a' || 1 + 2`
  answered `"a3"`; it binds like `*`, as on the engine, so that is the
  engine's coercion error. `SELECT DISTINCT … HAVING` ignored the `HAVING`.
- **`Client.Local` SQL read SQL words in `UPDATE` as columns**
  (`… SET n = CASE …` gave "No field named case"). `UPDATE`, `GRANT`,
  `REVOKE`, `DENY` and `DESC` now answer only the shapes verified against
  the engine and refuse the rest by name; `||`, `LIKE`, `IS DISTINCT FROM`
  and aggregates of a computed `NULL` follow the engine's typing.
- **`Client.Local` raised on a table name of about 4,100 characters** or a
  `LIKE` pattern past about 64,000, and an expression of hundreds of
  operators took seconds to type (900 terms: 5 s); these are refusals by name
  and a single typing pass. A `HAVING` naming a select alias several times
  read the table's columns once per name.
- **`mix test` chose the wrong tests** for an absolute or `./` path, a path
  outside `test/`, `--only=v2`, an `--include` of an integration tag
  without a path, and a path after a switch it did not know
  (`--no-compile test/x_test.exs` ran the whole suite), and an option's value
  that names a directory (`--exclude lib`) was taken for a path. The rule is
  now `mix/test_args.ex`, with its own test: known switches and their values
  are skipped, and every other argument is a path when it is one.
- **`Client.Local` InfluxQL: ties, unsigned booleans, conditions that are no
  boolean, the order of errors and quotient windows** (each verified against
  Core 3.10.1, pinned in `InfluxQLOrderCases`): `top(v, host, n)` and
  `bottom(v, host, n)` rank the points they chose by their own times, not by the
  times their series began at (`v = 9` at 5s of `b`, 6s of `c`, 8s of `a`:
  `top(v, host, 2)` is `b` and `c`; descending, `a` and `c`); an unsigned field
  or a number made of one against a boolean field, in either order and with any
  operator, is `Cannot infer common argument type for comparison operation
  UInt64 = Boolean` with no `type_coercion` prefix (it was `Int64`), a tag over
  an unsigned field (`host > u`) compares as text and keeps every point that has
  the unsigned value, and the error comes after the select list's and before
  the `LIMIT`'s; a condition that is a number made of an unsigned field (`-u`,
  `u + 1`, `abs(u)`) is `Boolean AND UInt64`, and with a `tz()` clause the
  planner's filter error (`Cannot create filter with non-boolean predicate
  'Int64(0)' returning Int64`, the arithmetic ones refused by name); a
  comparison of the `time` beside an operand that is no boolean, a boolean field
  included, is the 500 `invalid expr stack`; the operands of an expression that
  cannot be typed (`-f + time, -0.0`) are the error before the condition is
  split and before `field must contain at least one variable`, and the second
  `top()` is the error of the selectors that cannot be combined before a
  constant that follows it; `fill(none)` and `fill(linear)` of a grouping with
  nothing to aggregate are the fill error; `LIMIT` and `OFFSET` of a column that
  is a quotient (`sum(f) / count(f) ... GROUP BY time(1m)`) do not count the
  buckets where it is null.
- **Contract and unit tests of the double's own tests**: the cost test of a
  `HAVING` that names an alias compares the cost of one more reference over a
  table of 1500 and of 6000 rows (a re-read of the columns per reference costs
  3.6 times as much on the larger table; the correct code 0.8), the store-lock
  tests release or kill the holder only once the waiter is contending for the
  lock, the case-table test folds blanks beside operators and SQL comments into
  a statement's identity (not the regular expressions of InfluxQL), checks that
  a pin's spellings differ in what the pin says, and lists the SQL spellings
  still waiting to be taken out of the SQL tables, and the `mix test` switch
  list is checked against the switches `mix test` documents.

### Changed
- The integration one-liners pin `influxdb:3.10.1-core`, the version the
  exact engine bodies were verified against, and start it with
  `--wal-snapshot-size 100000`: Core 3.10.1 panics ("timestamp wraparound")
  when it snapshots a point near the largest timestamp, which the contracts
  write, and its writes then hang until restart. With a 10 ms WAL flush a
  suite reached that snapshot within one run.
- One server's integration suite is run with `mix test --only v3_core` (or
  `v2`); `--include integration` selects every server's.
- Contract case tables report every mismatch; tables that accept a refusal
  by name pin exactly which cases are refused, so a regression to "refused"
  fails naming the case. Line-protocol errors, including the 10,000-line
  chunk payloads, are pinned once, in a contract run on both engines.

## [0.1.41] - 2026-10-03

### Added
- **`Client.Local` InfluxQL: the functions and clauses dashboards send.**
  `GROUP BY *`, `/re/`, fields and `::type`, with the engine's parse errors at
  their positions (`GROUP BY time(`, `fill(previous`, a trailing comma, ...);
  `percentile`, `mode`, `top`, `bottom`, `integral`, `abs round floor ceil sqrt
  ln log pow`, the transforms `derivative`, `non_negative_derivative`,
  `difference`, `non_negative_difference`, `cumulative_sum`, `moving_average`
  and `elapsed` (of fields, and of aggregates in a `GROUP BY time`, with the
  engine's scan of the bucket before the range), `F(*)`, `F(/re/)`,
  `*::field`, `*::tag`, `/re/` columns, `FROM` with several names or `/re/`,
  `first`/`last`/`min`/`max` of booleans, `/* */` comments, `tz('UTC')`,
  `SLIMIT`/`SOFFSET` (the engine's 405) and `SHOW MEASUREMENTS | TAG KEYS |
  FIELD KEYS | TAG VALUES | RETENTION POLICIES` with `ON`, `FROM`, `WITH`,
  `WHERE`, `LIMIT` and `OFFSET`. A look-around or atomic group in a regular
  expression is the engine's 500. A Grafana-style corpus of 167 statements
  went from 62 refusals of what the engine answers to 4.
- `config :influx_elixir, :local_influxql_max_rows` (default 2,000,000) sets the
  most rows of a `GROUP BY time` series `Client.Local` will hold.
- **`Client.Local` SQL: the expressions dashboards send.** Aggregate
  arithmetic (`sum(n) / count(n)`, `max(x) - min(x)`), `HAVING`, `CASE`,
  `COALESCE`, `NULLIF`, `GREATEST`, `LEAST`, `lower`, `upper`, `length`,
  `substr`, `starts_with`, `sqrt`, `ln`, `log`, `pow` (in `WHERE` too),
  `IS [NOT] DISTINCT FROM`, `IS [NOT] TRUE`, an alias without `AS`, `SELECT`
  without `FROM`, `information_schema.tables`/`columns`/`schemata`,
  `SHOW TABLES`/`COLUMNS` and `iox.`/`public.iox.` table names, with the
  engine's names, types and errors. A 162-query dashboard corpus went from 93
  refusals of what the engine answers to 37; what stays refused is listed in
  the testing guide. Aggregates carry their result types, so `sum(n) + host`
  is the engine's coercion error; a `CASE` with a text `WHEN` compares as
  text; `n == 1`, `SELECT ALL`, `FETCH FIRST`, `OFFSET n ROWS`, backtick
  names, `FROM (t)` and `FROM a, b` are read as the engine reads them, and
  parser errors are positioned on the statement as written.
- **`Client.Local` InfluxQL `GROUP BY time(every[, offset])` with `fill()`.**
  Every bucket of the range is answered (buckets start at multiples of
  `every` from the epoch, shifted by `offset`; the range is the `WHERE`
  bounds, from the first point of the series to `now()` without them);
  `fill(null)`, `none`, `previous`, `linear` (an integer truncated toward
  zero) and a number cast to the column's type. `median`, `spread`, `stddev`
  and `count(distinct(f))` are answered, and arithmetic in the select list
  (`usage + 1`, `-n`, `sum(n) / count(n)`, `n::float`, `n::integer`), with the
  engine's column names, types and planning errors. `fill()` without a
  `GROUP BY`, `min`/`max` of strings and the engine's errors for `mean`,
  `sum`, `median`, `spread` and `stddev` of a string field are answered.
- Time comparisons: quoted times with an offset (`'… +0000'`, `+01:00`,
  `UTC`), compound durations (`1h30m`), and `+`/`-` of quoted times,
  durations, integers and `now()` (`time > '…Z' - 1h30m`, `now() - 1`,
  sub-second durations).

### Changed
- **`Client.Local`'s internals are organised by area.** `Client.Local` is the
  facade; the work is in modules under `client/local/` grouped as `sql/`,
  `influxql/`, `line_protocol/`, `flux/`, `store/`, `write/`, `admin/` and
  `shared/`. They are hidden from the HexDocs sidebar (`@moduledoc false`);
  the published modules are grouped by role. Duration units, 64-bit limits
  and column type names each have one definition, and the InfluxQL modules
  have no runtime cycles.
- **Test support.** One `InfluxElixir.TestServer` (a black-hole and a
  test-answered listener) and shared helpers for polling, telemetry and
  token shapes replace copies in several test files; tests that wrote
  untimed points now write timestamps and compare whole rows.
- **Test suite layout.** Each contract runs as per-part async modules
  (`test/influx_elixir/client/contract_local/<profile>/`,
  `test/integration/contract_<profile>/`): `mix test` takes 8-10 s instead
  of 27-41 s, and a plain `mix test` no longer compiles the integration
  modules (`INTEGRATION=1`, or an explicit `test/integration` path, includes
  them). The integration one-liners start Core with
  `--wal-flush-interval 10ms`, since a write is answered when the WAL
  flushes: the Core suite takes 18 s instead of 8½ minutes.

### Fixed
- **`Client.Local` discarded a v3 database's `retention:`.** On Core a
  database created with `retention_period: "1h"` accepts a point of any age
  (204, whatever `accept_partial` says) and hides expired data from SQL,
  InfluxQL and `SHOW TAG VALUES`, a 10-minute chunk of a table at a time: an
  expired point is shown for as long as the newest point of its chunk is.
  Tables and columns stay in the schema. `SHOW RETENTION POLICIES` prints the
  period (`1h0m0s`, `168h0m0s`, `30s`; `0s` for none). The double returned
  every row and always `0s`; it now keeps the period in whole seconds and
  applies all of this. A period of `"0"` (or under a second) is a retention of
  zero, not none: every point before now is hidden, as on Core. Creating a
  database that exists keeps its retention. Verified against Core;
  Enterprise's was not. See
  `docs/design/2026-10-03_local-database-retention.md`.
- **`Client.Local` InfluxQL found no rows for an `OR` naming a column the
  measurement lacks** (`host = 'a' OR zone = 'z'`); such a comparison is now
  false, as on the engine. Refusals no longer say "invalid statement" for
  statements the engine answers.
- **`Client.Local` SQL answered with error bodies the engine does not give**
  for qualified table names, `information_schema`, an empty `WHERE`, a
  trailing `ORDER BY`, a non-boolean `WHERE`, `LIKE` on `time` and
  `GROUP BY ()`; it now answers, or gives the engine's parser and planner
  errors.
- **The Hex package carried the wrong files.** `files:` sat outside
  `package()` in `mix.exs`, so Hex used its default list: 0.1.40 and earlier
  shipped `priv/plts/dialyzer.plt` and `.formatter.exs` and left out
  `usage-rules.md` and `usage-rules/`. The package now holds `lib/`, the
  README, LICENSE, CHANGELOG and the usage rules.
- **`Client.Local` InfluxQL refused `OR` with an unsigned field** (`u > 5 OR
  i < 0`, `h = 'c' OR u > 5`); the engine answers it. The comparisons that
  need the engine's unsigned rules are now a column of the point that the SQL
  reads, so `AND`, `OR` and parentheses combine them.
- **`Client.Local` InfluxQL regular expressions on string fields matched
  nothing.** `msg =~ /m/` and `msg !~ /m0/` now match string values; a
  backslash before a letter other than `d w s D S W p P x` is dropped, as the
  engine does (`\b` is `b`), and `\\/` no longer ends a regular expression.
- **0.1.40 shipped a stray script, `lib/influx_elixir/client/local/tmp_edit.exs`,
  in the package.** It is removed. It was never compiled or loaded.
- **`Client.Local` queries were 30-100% slower in 0.1.40 than in 0.1.39**
  at 100k points (`SELECT *`, numeric `WHERE`, every InfluxQL query). Each
  query scanned every point for column names an `ORDER BY` position might
  need, converted every result cell, and made a second pass for column
  types; InfluxQL lost its `SELECT *` fast path. They are back within 10%
  of 0.1.39.
- **`Client.Local` SQL runs what the engine's optimizer leaves.**
  - What the simplifier removes is never evaluated: `x AND false`,
    `x OR true`, absorption (`A AND (A OR B)`), `x = x` and `x IS NULL` of a
    constant, and comparisons with a `NULL` literal.
  - A `CAST` of an integer column to an integer type takes part in the
    empty-range check (`CAST(j AS INT) > 5 AND j < 3` is the engine's
    interval error), as does `col = lit AND 1/0 = 1`.
  - A decimal compared with a float past `1e20` is the optimizer's
    `Decimal128` error; an integer literal past `UInt64` compares as a
    double.
  - `AND`/`OR` whose right operand fails for a row the left one leaves out:
    the engine's outcome depends on how the table is stored (a fresh write
    runs the operand over the whole batch unless the left side keeps under a
    fifth of it; a persisted table runs the cheaper columns' conjuncts
    first), so the double answers only what is the same in both (a tag
    conjunct that leaves the failing rows out, in either order; a guard that
    keeps no row; a row that reaches the failure) and refuses the rest by
    name. A refusal of the double or a NaN in an operand a row does not
    reach is no failure: `total > 0 AND used / total > 0.5` answers.
  - Unsigned arithmetic, and an integer column's with a float constant, is
    not in the interval analysis (`u + 1 > 5 AND u < 3` is `[]`);
    `i / 0 = 1 AND i > 0` is the division's interval error and
    `i / 0 = 1 AND i < 5` closes the connection.
  - A literal on the left of `IS NULL`, `BETWEEN`, `IN`, `LIKE` is that
    constant; `(n + 1) > 5` and `(n) IS NULL` parse; `(SELECT ...)` is the
    query; statement parser errors print the engine's token (`X'1f'` for
    `0x1f`, `B'1'`, `1e5`, `@@x`) and a bare `UPDATE` or `GRANT` is
    `Expected: ..., found: EOF`.
- **Smaller `Client.Local` SQL fixes:** `ORDER BY a + 1` reads the output
  name `a`; `trunc(x, n)` wraps `n` to Int32 and `round(x, n)` past Int32
  closes the connection, as on the engine; `FOO bar` is the parser's
  `Expected: an SQL statement`; `COMMIT`, `SET`, `PREPARE` and `EXECUTE`
  are `Statement not supported`; `SELECT *, i` is refused by name.
- **InfluxQL in `Client.Local` follows the engine's planner.**
  - An unsigned field makes arithmetic unsigned, so it wraps (`-u < 0` is
    never true, `j > u` casts `j`); `SUM` wraps at its type's range, and a
    float `SUM` past the double range is `null` instead of raising.
  - `not` is a name; a column aliased `time` becomes `time_1`;
    `SELECT time FROM t` is empty; `TIME` is the time in any case.
  - `time = 'a'`, `GROUP BY time`, `WHERE time` and constant select items
    get the engine's planner errors.
  - Parentheses in `WHERE`, unclosed literals, `=~` without a regular
    expression and reserved words after `+`/`-` get the engine's positioned
    parse errors, after a `;` and in `SHOW TAG VALUES` too.
  - Two tags compared (`k = x`) are false for every row.

## [0.1.40] - 2026-10-02

### Fixed
- **`Client.Local` crashed on float overflow.** `f * 1e308 * 1e308`, a
  `sum` past the double range and the like raised `ArithmeticError`; they
  now answer `null` as the engine does, and an infinity compares as a
  number in `WHERE` and `ORDER BY`. A float divided by zero is no longer
  refused. An Int64 `sum` past the range wraps, as on the engine.
- **Unsigned (`UInt64`) fields in `Client.Local` SQL were treated as
  Int64.** `u / 2` gave `2` where the engine gives the decimal `2.5000`;
  `-u` answered where the engine refuses the negation; `u + n` wrapped at
  the wrong width. Unsigned columns now follow the engine's decimal and
  wrap rules.
- **More `Client.Local` SQL answers now match the engine:** `trunc`;
  `(v)` named `v`; an unaliased `1e400` named `Float64(inf)`; `ORDER BY`
  positions on `SELECT *` and their range errors; schema errors before a
  `time` type error; a `time` bound at the last nanosecond. A qualified
  reference to a column both sides of a `CROSS JOIN` have is refused by
  name instead of the engine's "ambiguous" error the engine does not give.
- **InfluxQL in `Client.Local` accepted reserved words.**
  `WHERE tag = 'a'`, `SELECT name`, `GROUP BY key` and the rest of the
  engine's keywords are its positioned parse errors; a failing statement
  after `;` gives that statement's own error; `LIMIT`/`OFFSET` past Int64
  are the engine's range errors; a boolean field compared with a number,
  and a negative number compared with an unsigned field, answer as the
  engine does.
- **A `Client.Local` lock taken again by its holder hung forever.** It now
  raises.
- **`CAST(x AS INTEGER)` in `Client.Local` was a 64-bit integer.** On the
  engine `INTEGER`/`INT` is Int32, `SMALLINT` Int16 and `TINYINT` Int8, so
  arithmetic on them wraps at that width and a constant that does not fit
  is the optimizer's 500. Local now does the same, unwraps a cast compared
  with an integer literal in `WHERE` as the engine's optimizer does, and
  folds a failing constant cast or a negated minimum into the engine's
  500 instead of closing the connection. `FLOAT`/`REAL` (Float32),
  unsigned and `DECIMAL` casts are refused by name.
- **`Client.Local` refused aggregates and expressions without `AS`.**
  `SELECT count(*) FROM t` now answers `[%{"count(*)" => n}]`, and every
  unaliased item is named as the engine names it (`avg(t.v)`,
  `sum(t.v * Int64(2))`, `Int64(1)`).
- **Empty ranges in `Client.Local` SQL returned `[]` where the engine
  fails.** A `time` range the top-level `AND` leaves empty is the engine's
  500 "provided filters on time column did not produce a valid set of
  boundaries"; an empty range on a numeric field is the engine's
  DataFusion internal error, in its three wordings. InfluxQL still answers
  `[]`, as the engine does.
- **More `Client.Local` SQL answers now match InfluxDB 3 Core:**
  - "Valid fields are" lists columns qualified by the table, with the
    select list first for `ORDER BY` and `GROUP BY`;
  - quoted names in the select list are columns;
  - integer literals past UInt64 are Float64, `1e400` is null, and
    `-(9223372036854775808)` is the engine's negation error;
  - `abs` of the Int64 minimum closes the connection, as on the engine;
  - an Int64 divided by a UInt64 parameter is a four-place decimal;
  - UTC aliases (`Zulu`, `UCT`, `Etc/GMT±N`), `EST`/`MST`/`HST` and the
    `:60` leap second are read in timestamps;
  - `NULL = time` matches nothing, and `"r""vt"` prints as `r"vt`.
- **InfluxQL in `Client.Local`:** `GROUP BY r, h` orders series by tag
  key, as the engine does; a doubled sign, an integer overflow, a lone
  `.` and a second statement after `;` give the engine's parse errors at
  its positions.
- **`Client.Local` locks backed off for seconds under contention.**
  Token creation and the database limit used `:global.trans`; 16
  concurrent creates took 4.4 s. They now use a lock key in the store
  that a waiter clears when its holder has died.

- **`Client.Local` slowed to a crawl under concurrent writes.** Eight
  writers of 2,500 lines to one series took 4.5 s, 32 took 20 s, and 50
  timed out at 60 s. A payload's points now go into the store as one
  batched insert, its series keys are claimed by one all-or-nothing
  `insert_new`, and the table has `write_concurrency`. The same writers
  now take 0.05 s, 0.2 s and 0.4 s. Duplicate merging and last-write-wins
  are unchanged.
- **Parsing a large payload no longer spawns an unbounded process.** The
  parse for 2,000 lines or more sized a process for the whole payload, which
  added about 1 GB for 200k lines (8.7 GB for eight at once), and it kept
  running after its caller died. Lines are now parsed 10k at a time, each
  chunk in a process that ends with the chunk: about 170 MB retained and
  380-470 MB at peak for 200k lines, and
  the speed is unchanged.
- **InfluxDB 2 reads of a field with mixed types stopped at the wrong
  group in `Client.Local`.** The engine reads the earliest group's type up
  to the first later group of another type and drops that group and every
  group after it, per measurement and field, across all tag sets. Local
  also returned later groups of the first type. Verified on 2.7.
- **`delete_bucket/2` on `Client.Local` left the bucket's points and
  per-group schema behind.** A bucket created again returned the old
  points, and a write of a new field type was refused with a 422.
- **`Client.Local` accepted a point older than a v2 bucket's retention.**
  2.7 drops it before any shard sees it and answers 422 `partial write:
  dropped N points outside retention policy of duration 2h0m0s - oldest
  point <series key> at <time> dropped because it violates a Retention
  Policy Lower Bound at <now - retention>, newest point ... dropped=N for
  database: <bucket id> for retention policy: autogen`. A failing shard
  group's message replaces it; the other points are written. A v3
  database's `retention:` is still not applied.
- **`Client.Local` SQL matches InfluxDB 3 in more corners.** Verified
  against Core.
  - A huge integer or Decimal param (beyond a double) is the engine's 400
    `number out of range`, not a crash. `params: nil` is accepted, and an
    unusable key or shape is `{:error, {:invalid_param, ...}}`.
  - Int64 arithmetic wraps as the engine's does (`MAX + 1` is `MIN`), and
    `MIN / -1` closes the connection.
  - `E'…'` strings take the engine's backslash escapes.
  - A double-quoted name is always a column. A name that needs its quotes
    is printed as the engine prints it in "No field named".
  - A `time` string Arrow cannot read is the optimizer's 500
    (`Error parsing timestamp from '…': …`), not a 400 about integers.
  - `time = NULL` and a nil `time` param match no rows.
  - `round` keeps the sign of a zero result (`round(-0.3)` is `-0.0`).
- **`Client.Local` InfluxQL.**
  - A series without the `GROUP BY` tag comes last, as on the engine.
  - A number with an exponent, a trailing dot or a hex prefix is the
    engine's parse error.
  - The parse error's position is right when a clause follows `WHERE`.
- **Contract tests no longer assume what the engines leave open.**
  - Row order without `ORDER BY` is not assumed.
  - When several InfluxDB 2 shard groups fail in one write, the engine
    reports one of them, and which one varies between identical writes.
    The contract accepts any of them, and the double reports the
    earliest.
- **HTTP timeout tests could flake under load.** Each wait is now well
  under the timeout a wrong precedence would apply, and well over the one
  under test.
- **`Client.Local` read SQL text its tokenizer would refuse, and ignored
  what the engine ignores.** Verified against Core 3.10.
  - An unterminated `'...'`, `"..."`, `/* ... */` or `$$...$$` is the
    engine's `SQL error: TokenizerError(...)` 400 naming the line and
    column, not an answer.
  - `-- ...` and `/* ... */` (which nest) are comments: a quote inside one
    no longer re-pairs the quotes and drops a `WHERE`.
  - A trailing `;` is accepted, empty statements are nothing, and two
    statements are the engine's 405.
  - `$$...$$` and `$tag$...$tag$` are string literals; `$a$b` is the
    tokenizer's error, as on the engine.
  - A literal that starts with a combining mark was compared as nothing.
  - Identifiers in any script (`"fé"`, `é AS é2`, `count("é")`) are
    columns; only ASCII letters fold to lower case.
- **Parameters are bound, not substituted into the text.** A placeholder
  is a value wherever a value may stand (comparands, `IN` and `BETWEEN`
  items, `LIKE` and regex patterns, expression operands, `LIMIT`,
  `OFFSET`), typed as the engine types the request's JSON: a non-negative
  integer is a `UInt64` (`"time" > $a` with `0` is the engine's type
  error, and an error body no longer carries a private-use character).
  A key spelled `"$a"` no longer binds `$a`, as on the engine.
- **`Client.Local` answers a boolean compared with another type as the
  engine does** (`v = $p` with `true` against an integer column,
  `v IN (1, true)`, `v BETWEEN 1 AND true`), and reports the planner's
  first error in the engine's order: the select list's calls, operators
  and aggregates, then `WHERE`, then `ORDER BY`, a negation last.
- **A parameter that is a JSON object or array** is the engine's 400 from
  `Client.Local`, with the column where its parser stops; a `Decimal` that
  is NaN or an infinity (which has no JSON number) and a value with no JSON
  form are `{:error, {:invalid_param, name, reason}}` from both clients
  instead of invalid JSON or a raise.
- **`Client.Local` line protocol now splits lines the way both engines
  do.** Verified against Core and 2.7.
  - A `"` in a measurement, tag key or tag value is an ordinary byte. It
    used to join the line to the next, losing that line or rejecting the
    write; it now opens a string only as a field value. Lines are split
    with the engines' own `scanLine` rules.
  - A quoted measurement keeps its quotes (`"m"` is the table `"m"`).
  - Each engine's escape rules apply to measurements, tag keys and
    values, and field keys. InfluxDB 2 never collapses `\\`.
  - On InfluxDB 3, an error's `line_number` counts only the lines that
    are not blank or comments, as on the engine.
  - On InfluxDB 2:
    - field types are per shard group;
    - a partial write is reported by one failing group: the engine's
      choice among several varies between identical writes (usually the
      earliest), and the double always reports the earliest;
    - a measurement the engine accepts but never returns is accepted
      and never returned.
  - Refused by name rather than answered differently:
    - an infinite float (`1e999`), which InfluxDB 3 stores as infinity;
    - a repeated tag key, which InfluxDB 3 accepts and then fails every
      query on.
- **Flux in `Client.Local` orders rows by nanosecond.** `first()` and
  `last()` were swapped for points less than a microsecond apart.
  `sort()` and `group()` are refused by name.
- **InfluxDB 2 writes in `Client.Local` were quadratic in shard groups.**
  40k points in 40k hourly groups took 8.6 s; they now take about 0.2 s.

### Changed
- **`Client.Local`'s SQL executor is split into focused modules**
  (`SQLNumber`, `SQLCast`, `SQLEval`, `SQLAggregate`, `SQLCondition`,
  `SQLSort`, `SQLRow`, `SQLTyping`, `SQLPlan`, `SQLSchema`, `SQLGrouping`,
  `SQLJoin`, `SQLRange`, `SQLFold`, with shared `SQLLimits` and
  `SQLPredicates`); `SQLExecutor` keeps the pipeline.
- **Tests compare whole results.** About 150 partial map patterns, which
  ignore extra keys, became exact comparisons; numeric `==` became `===`
  outside the contract modules too; the batch writer's backpressure test
  is driven by a listener the test controls instead of the clock.
- **`Client.Local` store API trimmed.** `Store.measurement?/3`,
  `Store.store_point/3` and `InfluxQL.where_sql/2` are removed and
  `Store.put_database/2` is private; `SQLExecutor.run/2` is
  `run_influxql/2`.
- **Tests compare rows strictly.** `%{"v" => 1} == %{"v" => 1.0}` is true
  in Elixir, so contract assertions now use `===`; unique names carry the
  wall clock so runs on a persistent server never collide; real-server
  cleanup runs in `after`; concurrency tests start their tasks on a
  barrier.
- **`Client.Local`'s SQL parser is split into focused modules:**
  `SQLParser` (entry), `SQLLexer`, `SQLMask`, `SQLLiteral`, `SQLTime`,
  `SQLExpr`, `SQLSelect`, `SQLWhere`, `SQLClauses`, `SQLLimit` and
  `SQLBind`. `sql_parser.ex` drops from 3,027 lines to 694. InfluxQL and
  the line protocol share its quote masking and float rendering.
- **Contract coverage.**
  - Every contract quote keeps its source location, so a failure points
    at the contract line.
  - Tests where Local deliberately differs are tagged
    `:local_divergence`.
  - The SQL contracts also run on the `:v3_enterprise` profile.
  - Test databases and buckets on real servers have unique names and are
    cleaned up.
- **For tests: a parameter key written as `"$name"` no longer binds.**
  InfluxDB 3 reads a parameter's key without the `$`, and a `"$name"`
  key binds nothing there, so a query that passed against `Client.Local`
  failed in production. Write `params: %{name: value}` or
  `%{"name" => value}`.
- **`Client.Local` parses line protocol 3 to 4 times faster.** For
  100k-line payloads:
  - bare lines: 332 → about 130 ms;
  - three tags and four fields: 1752 → about 540 ms.

  A large payload is parsed 10k lines at a time, each chunk in a
  short-lived process, so the caller's heap is left alone.
- **Tests.**
  - Fidelity tests that repeated the contract suite are gone, so each
    fact is pinned once and runs against Local and the real engines.
  - Tests on internal functions are driven through the public API
    instead.
  - The optional-dependency check walks each file's syntax tree.
  - `test/support` compiles without warnings.

## [0.1.39] - 2026-10-01

### Fixed
- **The library failed to compile in a project without `decimal`.** It
  is an optional dependency, but the SQL parser matched `%Decimal{}`,
  which needs the struct at compile time
  (`Decimal.__struct__/1 is undefined`). It now matches
  `%{__struct__: Decimal}`, and a test keeps optional structs out of
  `lib/`.
- **A `Decimal` query parameter was compared as text over HTTP.** Jason
  encodes a Decimal as a JSON string, so `amount >= $p` with
  `Decimal.new("1000.00")` kept 500.0 (`"500.0" >= "1000.00"`), while
  `Client.Local` compared numbers. `Client.HTTP` now sends Decimal
  parameters as JSON numbers, and both clients compare numbers.
- **`Client.Local` gave wrong answers to SQL that InfluxDB 3 answers
  differently.** Each case was verified against Core 3.10.
  - **Quoting and parameters.**
    - `''` inside a literal (`'O''Brien'`) and in `LIKE` patterns was
      not read as a quote.
    - A string parameter containing a quote was injected into the
      query text (`"zzz' OR v > 0 OR name = 'q"` returned every row).
    - Literals containing a comma, an operator or a keyword
      (`IN ('Smith, John')`, `s = 'a>b'`, `'note limit 5'`) were refused
      or cut short.
    - `LIKE`/`ILIKE` matched bytes, not characters.
  - **Nulls and three-valued logic.**
    - `NOT IN (1, NULL)` and `BETWEEN … AND NULL` returned rows.
    - `first_value` dropped a `false` value.
    - Ordered aggregates sorted a null ordering value first.
  - **Grouping and ordering.**
    - `GROUP BY time` returned one row.
    - `DATE_BIN` put negative timestamps in the bucket after.
    - A `DATE_BIN` in the select list that did not match the `GROUP BY`
      was answered with the wrong buckets.
  - **Comparisons.**
    - A float compared with a string literal was rendered as `5.0e3`
      instead of `5000.0`, which gave wrong rows.
    - `WHERE 1 = 1` and `WHERE true` were a schema error or refused.
  - **Plan-time type errors.**
    - Aggregates over strings, booleans, tags or `time` crashed or
      answered (`median(s)` was `"y"`).
    - Arithmetic over a string answered nulls.
    - Each is now the engine's planning error, with the same wording,
      even when no row matches.
  - **Errors in the engine's words** (the double now uses them):
    - bare-integer `time` comparisons;
    - `AVG(time)` and the other `time` aggregates;
    - `DISTINCT … ORDER BY`;
    - negative or non-numeric `LIMIT`/`OFFSET`;
    - `FIRST()`/`LAST()`;
    - `LIKE` over a number;
    - CROSS JOIN ambiguity;
    - ungrouped projections;
    - unknown `format:` values (with the column position);
    - boolean casts;
    - a CTE column named `time`;
    - integer division by zero, which closes the connection.
  - **Crashes, now answered or refused by name:**
    - `DATE_BIN` with a zero interval;
    - `round` with a huge scale;
    - a CTE `time` column holding strings.
  - **Refused by name.** A float divided by zero is infinity on the
    engine, which compares as a number (`WHERE v / 0.0 > 1` keeps every
    row). Elixir cannot hold it, so the double refuses by name instead
    of returning no rows.
  - **Transport error shape.** A `CAST` that cannot be performed now
    returns `%Mint.TransportError{reason: :closed}`, as over HTTP, not
    a bare `:closed`.
- **`Client.Local` line protocol, InfluxQL and Flux now match the
  engines**, verified against Core and 2.7.
  - **Line protocol.**
    - Text after the timestamp (`m v=1 100 200`) is refused, as are
      `v=.5` and `v=5.`, with the engine's messages.
    - InfluxDB 2's parse errors are now its own words (`invalid field
      format`, `missing field value`, `invalid number`, …), and every
      bad line is reported.
  - **InfluxQL.**
    - A literal containing `into` or `fill(` is no longer refused.
    - `time > 0s` and bare-integer nanosecond times are answered.
    - An aggregate's `time` is the `WHERE` lower bound.
    - `LIMIT` and `OFFSET` count per field.
  - **Flux.**
    - A `range` far in the future wraps as the engine's does instead of
      crashing.
    - `start >= stop` is the engine's 400.
  - **Buckets.** `list_buckets` maps carry `type`, `orgID` and shard
    group durations.
- **`Client.Local` concurrency.** A token deleted while it was being
  created could reappear, and concurrent first writes could exceed
  `:v3_core`'s 5-database limit. Both now happen under a lock.

### Changed
- **`Client.Local` InfluxQL `SELECT` is about twice as fast** at 100k
  points. Redundant passes and sorts are gone, `SHOW MEASUREMENTS` reads
  the column index, and a Flux filter on `_measurement` reads only those
  measurements.
- **Tests.** About 55 `local_test.exs` tests that duplicated the contract
  suite or could not fail are gone. Others now assert exact results:
  - error bodies taken from the real servers;
  - `ORDER BY` checked on data written out of order;
  - `DISTINCT` checked with real duplicates.

  New contract modules for the SQL parser, the SQL executor, and
  InfluxQL/Flux/line protocol run against Local and the real engines.

## [0.1.38] - 2026-10-01

### Added
- **`Client.Local` evaluates `abs`, `round`, `floor` and `ceil` in SQL**
  (issue #25), wherever an expression stands: `WHERE`, the select list,
  `ORDER BY`, and an aggregate's argument. `WHERE abs(amount) >=
  $threshold` was refused by name, and before 0.1.37 it was read as a
  column named `abs(amount)`, which returned no rows. The double matches
  InfluxDB 3, verified against Core:
  - `round` rounds half away from zero and takes an optional scale.
  - `round`, `floor` and `ceil` return floats; `abs` keeps the argument's
    type.
  - A null argument gives null.
  - A wrong argument type or count is the planner's error, even when no
    row reaches the call. Its wording depends on the clause the call is
    in.
  - `floor` or `ceil` with a scale is the engine's 405.
- A `WHERE` operand may be an expression in `IS [NOT] NULL` and
  `[NOT] IN (...)` too.

### Changed
- **Breaking: tokens are created and deleted by name, on the endpoints
  InfluxDB 3 serves.** `create_token(conn, description, opts)` and
  `delete_token(conn, id)` called `/api/v3/configure/token` and
  `/api/v3/configure/token/{id}`, which neither Core nor Enterprise
  serves. They never worked against a server.
  - `create_token(conn, name, opts)` makes an admin token, on Core and
    Enterprise.
  - With `permissions: ["db:db1:read,write", ...]` (the CLI's
    `--permission` form) it makes an Enterprise resource token.
  - `expiry_secs:` sets an expiry.
  - The result carries `id`, `name`, `token`, `hash`, `created_at` and
    `expiry`.
  - `delete_token(conn, name)` deletes by name.
  - `Client.Local` answers as the server does, on `:v3_core` too:
    - a taken name is a 409;
    - an unknown name is a 404;
    - deleting `_admin` is a 405;
    - a bad `expiry_secs` is the 400 with its column.

  The admin token path is verified against Core. The resource token's
  request is the one the Enterprise CLI sends; its response is not
  verified, because Enterprise needs a license.

### Fixed
- **`Client.Local` read a literal on the left of a comparison as a column
  name.** `WHERE 1 < f` was the engine's "No field named 1" schema error,
  for a query the engine answers. The comparison is now turned around.

## [0.1.37] - 2026-10-01

### Added
- **`Client.Local` answers more of InfluxQL, as InfluxDB 3 does.** These
  constructs were refused by name and are now answered, verified against
  Core:
  - regular expressions (`tag =~ /re/`, `!~`);
  - relative time (`time > now() - 30m`);
  - double-quoted identifiers;
  - `SHOW TAG VALUES [FROM m] WITH KEY = | != | =~ | !~ | IN (...)
    [WHERE ...]`, with the engine's row per missing key and its default
    24-hour window.

  Arithmetic in the select list, several measurements in `FROM`,
  sub-second durations, and `LIMIT`/`OFFSET` on `SHOW TAG VALUES` are
  still refused by name.
- **`Client.Local` SQL has the regular-expression operators** `~`, `!~`,
  `~*` and `!~*`, with DataFusion's semantics (verified): unanchored, a
  null is unknown, a non-string column is the engine's planning error,
  and an invalid pattern is its 500.

### Fixed
- **`Client.Local` answered some InfluxQL `WHERE` clauses wrongly.** It
  ran InfluxQL's `WHERE` with SQL's null rules, but InfluxQL reads a tag
  a point lacks as the empty string. Verified against Core:
  - `host != 'h1'` dropped points without `host`; the engine keeps them.
  - `host = ''` found nothing; the engine finds those points.
  - `host > 'h0'` compared strings; ordering a tag is always false in
    InfluxQL.
  - `NOT`, which InfluxQL does not have, was answered; the engine
    refuses it as a parse error.
- **Untimed lines of one write became separate points in `Client.Local`.**
  Both engines give every line of a write that has no timestamp the same
  time, the request's, so lines of one series are one point, with fields
  merged and the last write winning. The double stamped each line
  separately and kept them as separate rows. Tests that wrote several
  untimed points of one series and counted rows now write timestamps.
- **`BatchWriter` stopped flushing on its timer after any other flush.**
  A flush at `batch_size`, an explicit `flush/2`, or a `write_sync/3`
  cancelled the interval timer, and nothing restarted it. Points written
  afterwards sat in the buffer until the next full batch or shutdown.
  Every flush now restarts the interval.
- **Killing one connection's supervisor took every connection down.**
  The restart found the killed supervisor's Finch pool and writer still
  registered, failed with `:already_started`, and the repeated failures
  stopped `InfluxElixir.Supervisor`. The restart now waits for those
  names to be released.
- **`query_sql(..., format: :csv)` lost rows of a one-column result.**
  InfluxDB 3 writes a null or empty one-column row as `""`. The parser
  took that for a table separator, dropped the row and read the next one
  as a header. InfluxDB 3's CSV is now parsed as the single table it is.
  `ResponseParser.parse/2` takes `:flux_csv` for InfluxDB 2's annotated
  CSV, which `query_flux` uses.
- **`gzip: true` on a write sent an uncompressed body under a gzip
  header.** The server refused it with `error decoding gzip stream`.
  `Writer` now compresses whenever `gzip: true` is given, and never when
  `gzip: false` is.
- **`execute_sql` over HTTP dropped `params:`.** A `$name` placeholder
  was the server's 400 `No value found for placeholder`.
  `Client.Local` bound it, so tests passed.
- **`database: nil` over HTTP overrode the connection's default
  database** and failed with `:no_database_specified`. `Client.Local` and
  the telemetry metadata already treated it as no database given.
- **HTTP admin calls returned a bare `Jason.DecodeError`** for a body
  that is not JSON. They now return `{:json_parse_error, reason}`, as
  queries do. `list_databases` returns `{:unexpected_response, body}` for
  JSON that is not a list, instead of raising.
- **`Client.Local` read a write body by its bytes, not by `gzip:`.**
  InfluxDB decompresses exactly when it is told to. Verified against
  InfluxDB 3 Core and 2.7:
  - A gzip body without `gzip: true` was stored by the double and refused
    by the server.
  - A plain body with `gzip: true` was stored by the double and refused
    by the server.
  - InfluxDB 3 refuses a body that is not UTF-8. The double stored it.

  The double now does all three as the engines do, with the engines' own
  error bodies. InfluxDB 3's database retention error now carries the
  server's `at line 1 column N` suffix.
- The `Admin.*` moduledocs claimed a telemetry span that admin calls do
  not emit. `Config` called `:token` required, but it is optional.

### Changed
- **Line protocol encoding is about 6x faster.** 10,000 tagged points
  now take 30 ms instead of 191 ms. The encoder no longer runs four
  string replacements on every name: it scans each name once and escapes
  only when needed, and it builds lines as iodata. The output is
  unchanged.

## [0.1.36] - 2026-09-30

### Fixed
- **`Client.Local` accepted line-protocol whitespace that InfluxDB
  refuses, and refused some it accepts.** Each case was verified against
  InfluxDB 3 Core and 2.7:
  - A line holding only a no-break space, `\v`, `\f` or `\r` was skipped
    as blank. Both servers refuse it; only spaces and tabs make a line
    blank.
  - CRLF line endings. InfluxDB 3 answers
    ``Could not parse entire line. Found trailing content: `\r` ``, and
    echoes the line without its `\r`.
    The double now gives that exact answer; it used to answer `Unable to
    parse timestamp value`.
  - InfluxDB 2 refuses a `\r` after a number, but stores a string field
    that a `\r` follows, closing quote included (`s="x"\r` is `x"`). The
    `:v2` profile used to refuse it.
  - A tab or `\r` after an invalid field value fails that field
    (`No fields were provided`, or trailing content for a later field),
    as on InfluxDB 3.

### Changed
- **`Client.Local` writes are about 40% faster.** A 100k-line write went
  from about 2.25 s to about 1.3 s. Three changes:
  - Leading whitespace and blank lines are now checked byte by byte,
    where a regex and a full-line trim ran on every line.
  - Each column's type is confirmed once per write, instead of costing
    two ETS calls per column per point.
  - The table-exists lookup that only a `time` column needs no longer
    runs for every point.
- **`Client.Local` multi-key `ORDER BY` is 25–35% faster.** Each row's
  sort-key values are now read once, not on every comparison. At 100k
  points, `ORDER BY host, time DESC` went from 375 to about 270 ms and
  `SELECT DISTINCT ON (host) ... ORDER BY host, time DESC` from 572 to
  about 395 ms (medians of 7 runs). A single-key sort such as `ORDER BY
  time` still sorts in place, which is faster when the key is a field
  read. Ordering is unchanged, including full ties in write order, which
  a new test pins; the testing guide notes that the server's order for
  ties is arbitrary.

### Fixed
- **`Query.*` and `Admin.*` behaved differently from the facade.**
  `Query.SQL`, `Query.SQLStream`, `Query.InfluxQL`, `Query.Flux` and the
  `Admin.*` modules called the client directly. So:
  - a connection name raised `FunctionClauseError` (for example
    `Query.SQL.query(:my_conn, sql)` or `Admin.Databases.list(:my_conn)`),
    where `InfluxElixir.query_sql(:my_conn, sql)` worked;
  - queries made through them emitted no telemetry span.

  They now call the facade functions, so the two entry points behave
  identically.

### Changed
- **Contract tests assert exact results.** Fifteen contract tests
  checked only `rows != []` before inspecting `hd(rows)`, or summed values
  across buckets. One tag-escaping test accepted either of two answers.
  They now assert the exact rows the engine returns, verified on
  InfluxDB 3 Core and 2.7:
  - the four 2-minute `AVG` buckets (10.0, 25.0, 45.0, 60.0);
  - the single hourly `SUM`, `COUNT` and `MIN`/`MAX` row;
  - `"us,east"` for an escaped comma in a tag;
  - all five streamed values.

  Their fixtures now check their own writes, so a failed write can't
  surface later as a wrong answer. The telemetry error test pins the
  query error it expects.

## [0.1.35] - 2026-09-29

### Fixed
- **`Client.Local` accepted any `retention:` for a v3 database.**
  InfluxDB 3 takes a duration string and refuses anything else with 400
  `serde json error: ... expected a duration`. That includes
  `retention: 3600`, seconds as a v2 bucket takes them, so such a call
  passed in tests and failed in production. The double now applies the
  engine's grammar, verified on 53 values against Core: one or more
  `<number><unit>` parts, a fraction allowed, case-sensitive units, or a
  bare `"0"`. It still stores no retention, so nothing expires.
- **`health/1` on `Client.Local` answered `"version" => "local"` on
  every profile.** InfluxDB 3's `/health` is a plain `OK`, which
  `Client.HTTP` reports as `%{"status" => "pass"}`. The double now
  answers that shape on the v3 profiles, and InfluxDB 2's JSON shape on
  `:v2`. The contract asserts each exactly instead of
  `status in ["pass", "ok"]`.
- **`delete_bucket/2` could delete another org's bucket.** The lookup
  from a bucket name to its ID did not name the connection's org. When
  two orgs had a bucket of the same name, it took the first match: on
  InfluxDB 2.7 a `dev-influx` connection deleted the other org's bucket
  and left its own. The lookup and `list_buckets/1` are now scoped to
  the connection's `:org`. A 404 for the org itself is passed through as
  the server's answer, not reported as "bucket not found".
- **`list_buckets/1` returned at most 20 buckets.** InfluxDB 2 pages the
  list, and only the first page was read, so an org with more buckets
  silently lost the rest. Every page is now read, 100 at a time.
- **Names with `&`, `+`, `#` or `=` went to the wrong place.** Query
  values were built with `URI.encode/1`, which leaves those characters
  alone. A write to bucket `a&b` went to bucket `a` (into its data, if
  such a bucket existed), `c+d` went to `c d`, and `e#f` went to `e`.
  Query values are now form-encoded and path segments strictly encoded,
  for org, bucket and database names, precision, and bucket and token
  IDs. A v3 `db/rp` name such as `name/autogen` writes, queries and drops
  as before.

### Changed
- **The testing guide explains how to pin production's column types
  (#24).** Each `Client.Local` store starts with an empty schema, so a
  test's first write to a measurement decides its column types. A writer
  that sends the wrong type therefore defines the column in its own test
  but is refused in production. The guide now says so, with a `setup`
  recipe that seeds one point with production's types. The double already
  refuses a conflicting type as InfluxDB 3 does, re-verified on every
  profile and on v0.1.33.

## [0.1.34] - 2026-09-28

### Fixed
- **`BatchWriter` options were not validated.** Each of these was
  reproduced:
  - `batch_size: 0` started a writer that refused every write as
    `{:error, :buffer_full}`.
  - A misspelt key such as `flush_interval:` was silently ignored and its
    default used.
  - `batch_size: "10"` started, then crashed the writer on its first
    write.

  `start_link/1` now validates with NimbleOptions and returns
  `{:error, %NimbleOptions.ValidationError{}}` naming the option. Through
  a connection's `batch_writer:` config, that fails
  `add_connection/2` (or application start). The moduledoc's option list
  is generated from the same schema, so it cannot drift from what is
  accepted.
- **A connection that failed to start stayed registered.**
  `ConnectionSupervisor` registers the connection and initialises the
  client before starting its children. When a child failed,
  `add_connection/2` returned the error but the name still resolved to a
  connection that was not running, and `Client.Local`'s store stayed
  allocated. Both are now released, so a corrected retry under the same
  name starts. A name that is already running keeps its registration.

## [0.1.33] - 2026-09-28

### Added
- **`Client.Local` runs `SELECT DISTINCT ON (...)` (#23).** The double
  refused every `DISTINCT ON` query. InfluxDB 3 (DataFusion) supports it,
  and it is the idiomatic "latest row per key" query
  (`... ORDER BY k, time DESC`). A consumer that rescued the refusal got
  "no rows" from its tests instead of exercising the read path. The
  double now keeps the first row per distinct key after `ORDER BY`,
  before `LIMIT` and `OFFSET`, over plain or projected columns or `*`. It
  follows the engine's rules, verified against InfluxDB 3 Core:
  - `ORDER BY` must start with the `ON` columns, in order (400);
  - `ORDER BY` resolves against the table, not select aliases (500);
  - aggregates and `GROUP BY` are refused (405);
  - an empty `ON ()` is a 400;
  - a missing key column is the null key.

  An expression in `ON`, such as `DATE_BIN(...)`, is refused by name.
- **Writes can be all-or-nothing, and acknowledged before persistence.**
  InfluxDB 3's `accept_partial=false` and `no_sync=true` write parameters
  had no way through the client; `write/3` now takes `accept_partial:`
  and `no_sync:` (v3 only) and `Client.HTTP` sends them. `Client.Local`
  models both as verified: with `accept_partial: false` the first bad line
  in line order rejects the payload with the engine's single-line
  `"line protocol parsing error"` body and stores nothing, not even
  schema; `no_sync` is accepted; a flag that is not a boolean is the
  engine's 400.

### Changed
- **Breaking (tests): `Client.Local` follows SQL's identifier rules.**
  DataFusion folds every unquoted identifier to lower case: columns,
  tables, aliases and CTE names. Only a double-quoted identifier is
  exact, and `"..."` is never a string. The double compared names
  case-sensitively and read `"..."` as a string literal, so it disagreed
  with the server both ways:
  - `SELECT Host` on a tag `Host` passed against the double, but the
    server answers `No field named host`.
  - `SELECT K` failed against the double, but the server reads `k`.
  - `v AS V` answered `"V"` instead of `"v"`.
  - `WHERE k = "a"` matched the string `a` instead of comparing with a
    column.
  - `SELECT "Host"` and `AS "Mixed Case"` were refused.

  The new `Client.Local.SQLIdentifiers` applies the rules before parsing,
  verified against InfluxDB 3 Core. InfluxQL identifiers stay
  case-sensitive, as on the server. `Client.Local:` error messages now
  echo the query with its identifiers folded.
- **Breaking (tests): `Client.Local` has no implicit `"default"`
  database.** With neither `:database` nor `:databases` configured, the
  double wrote to and queried a `"default"` database, and listed it. The
  server has no such database. `Client.HTTP` returns
  `{:error, :no_database_specified}` for the same call, so code that
  forgot `database:` passed its tests and failed in production. The
  double now answers exactly as HTTP does:
  - `write/3`, `query_sql/3` and `execute_sql/3` return
    `{:error, :no_database_specified}`.
  - `query_sql_stream/3` raises `StreamError` of kind `:no_database`.
  - `query_influxql/3` returns the engine's 400 (`must specify a 'db'
    parameter...`); `SHOW DATABASES` still works.

  Without `:database`, the first of `:databases` is now the default, as
  it already was in `Client.HTTP`. The Local connection map no longer
  carries `:databases`, a snapshot taken at start that went stale on
  every create and delete. Use `list_databases/1`.
- **`Client.Local`'s ETS storage is its own module,
  `Client.Local.Store`.** The key layout, the atomic
  insert rules, the duplicate-merge fast path and the deletion bookkeeping
  were spread through `local.ex` as raw `:ets` patterns (40 call sites);
  they now live in one 300-line module with a small API, and `local.ex`
  (1,583 → 1,430 lines) holds no `:ets` call. Behaviour is unchanged.

### Fixed
- **A `Point`'s `DateTime` timestamp only worked at nanosecond
  precision.** The encoder always wrote nanoseconds, so a `BatchWriter`
  with `write_opts: [precision: :second]` (or `:millisecond`,
  `:microsecond`) had every point refused by InfluxDB 3 with
  `timestamp, 1790596800123456000, out of range for precision: Second`.
  `LineProtocol.encode/2` now takes `precision:` and writes a `DateTime`
  in that unit, truncated toward the past. `BatchWriter` encodes with its
  own `write_opts` precision. An integer timestamp is still taken as
  given, since it is already in the caller's unit.
- **`Client.Local` accepted timestamps no server stores, and then crashed
  on the query.** A timestamp is refused once scaled past a signed 64-bit
  count of nanoseconds, in each version's words (verified on Core and
  2.7):
  - InfluxDB 3 answers `timestamp, N, out of range for precision: Unit`,
    and `Unable to parse timestamp value` for anything past 64 bits.
  - InfluxDB 2 answers `time outside range -9223372036854775806 -
    9223372036854775806`, a range that excludes both int64 ends, and a
    `strconv.ParseInt` error past 64 bits.

  The double used to store the scaled value, and a later `SELECT` raised
  converting it to a `DateTime`. A test fixture that built timestamps
  past int64 by string concatenation relied on this and was fixed.
- **`LineProtocol.encode/1` produced lines no server accepts, or one both
  drop silently.** Each case was verified on InfluxDB 3 Core and 2.7:
  - **An integer outside 64 bits.** Both reject the line.
  - **A name ending in a backslash.** Both reject it, even though the
    encoder escaped the backslash.
  - **A measurement starting with `#`.** It is a comment line to both, so
    inside a batch it vanished while the other lines were stored.
    Escaping it as `\#` stores the backslash.

  These are now refused with the existing `{:invalid_field_value, ...}`,
  `{:invalid_measurement, ...}`, `{:invalid_tag_key, ...}`,
  `{:invalid_tag_value, ...}` and `{:invalid_field_key, ...}` errors.
  `BatchWriter.write/3` returns the error to the caller.
- **`Client.Local` accepted tabs in line protocol that InfluxDB 3
  refuses.** InfluxDB 3 ends a name or value at an unescaped tab, but it
  separates sections only with spaces. So a tab in a measurement, tag,
  field key or after a value refuses the line, with a message that depends
  on where the tab stands. The double now gives each of those answers, as
  verified on InfluxDB 3 Core. A leading tab is whitespace, as on the
  engine; the double had kept it as part of the measurement name. A tab
  inside a quoted string is fine. InfluxDB 2 stores tabs, and so does the
  `:v2` profile.
- **`query_sql_stream/3` could starve its connection pool.** A stream
  runs its request in a producer process that holds a pool connection.
  There were two ways to lose it:
  - If the consuming process was killed mid-stream (`:kill`, a brutal
    task shutdown), the producer waited forever for an acknowledgement,
    holding the connection. On a small pool, every later request was a
    `:pool_timeout`.
  - If the consumer stopped early (`Enum.take/2`), cleanup killed the
    producer. Finch's pool drops the connection of an owner that dies
    without serving the requests already waiting for it, so a request
    queued at that moment timed out.

  Both were reproduced on InfluxDB 3 Core with a one-connection pool. The
  producer now monitors its consumer, and it ends the request with
  `Finch.stream_while/5`'s `{:halt, _}` instead of dying, which checks
  the connection back in. Early-stop cleanup asks the producer to cancel,
  and kills it only if it has not stopped within a second (a server gone
  silent). Two integration tests fail against the previous client.
- **`Flight.Client.query/3` closes its gRPC channel when decoding
  raises.** The channel was closed on every return path but not on a
  raise; the call now uses `try/after`.
- **Enterprise `DELETE` in `Client.Local` ignored SQL's identifier
  rules.** It is now read like a `SELECT`: unquoted names fold to lower
  case, and quoted ones are exact. Before, `DELETE FROM "Cpu"` looked for
  a measurement literally named `"Cpu"`, quotes included, and its
  `WHERE` compared names case-sensitively.
- **A `Client.Local` table ended with its last point.** A table exists
  once its columns are in the catalog, as on the engine, so a `SELECT`
  after an Enterprise `DELETE` of every row answers `[]`. Before, it was
  a "table not found" error.
- **Tests that proved little were tightened.** Contract tests now check
  the engine's full error body for malformed line protocol and a
  created token's fields, where they used to check only for a
  non-empty body and a map. Two tests that duplicated stronger ones
  were removed. The runtime `add_connection/2` test now writes and
  queries through the name, and checks the name is gone after
  `remove_connection/1`.
- **`Client.Local` ignored InfluxDB 3's database rules.** Each of the
  following was verified against Core:
  - **Names.** A name must start with an ASCII letter or digit and
    contain only letters, digits, `_`, `-` and at most one `/` (the
    `<db>/<rp>` form). The double accepted any name. It now returns the
    engine's 400, with the engine's message, in the engine's order. This
    applies to `create_database/3`, to a write that creates a database,
    and to `start/1`, which raises.
  - **Database limit.** Core holds at most 5 databases; the `:v3_core`
    profile now returns the engine's 422 for a sixth.
  - **Missing database.** A query against a database that does not
    exist is the engine's 404,
    `{"error":"query error: database not found: <name>"}`. That covers
    SQL of any kind, even unparseable, and InfluxQL after parsing. The
    double used to answer a table error, or rows for `SELECT 1`.
  - **`_internal`.** `list_databases/1` and `SHOW DATABASES` include
    the engine's own `_internal`, and dropping it is the engine's 500.
- **InfluxQL with `format: :csv` in `Client.Local` aggregated strings.**
  The inner SQL query inherited `format:`, so InfluxQL saw CSV strings
  before rendering them again. The format now applies once, to the
  InfluxQL result.
- **Stale module examples.** Three module examples no longer worked:
  `Write.Writer` wrote with no database, `Admin.Tokens` used the
  `:v3_core` profile (tokens are Enterprise-only), and `Admin.Buckets`
  used `:v3_core` (buckets are v2). All three now run as written.
- **A stopping `BatchWriter` lost its buffer.** Its `terminate/2` flushed
  the buffer, but the writer did not trap exits. When a supervisor stopped
  it (application shutdown, `remove_connection/1`), the exit signal killed
  it before `terminate/2` could run, so every buffered line was lost. The
  tests used `GenServer.stop/1`, which runs `terminate/2` regardless, so
  they never caught it. The writer now traps exits. On shutdown it
  writes any batch still being retried, then the buffer, once each and in
  the order they were written. It answers any `write_sync/3` caller
  waiting on those writes. The new `:shutdown` option sets how long the
  supervisor waits (default `5_000`).
- **An invalid `Point` crashed the `BatchWriter`.** The point was encoded
  inside the writer with `encode!`, so a point with no fields killed the
  process along with every other caller's buffered lines. `write/3` and
  `write_sync/3` now encode in the caller and return `{:error, reason}`,
  as `LineProtocol.encode/1` does.
- **Backpressure lifted while a retry chain was still in flight.** An
  explicit `flush/2` or `write_sync/3` during a retry chain starts a
  second chain, but the writer tracked only one. The first chain to end
  cleared the marker, so writes flushed into new chains instead of being
  held to the `10 × batch_size` bound. Each chain now keeps its own batch
  and `write_sync/3` caller until it ends.
- **`Client.Local` ignored `format:`.** Over HTTP, `format: :csv` returns
  every value as a string (`"1.5"`, `"true"`), but the double returned
  typed values. A test of CSV handling could pass against the double and
  fail in production. The double also returned rows for `:parquet`
  instead of a binary, and rows for an unknown format where the engine
  answers 400. The new `Client.Local.Format` answers as `Client.HTTP`
  does, verified against InfluxDB 3 Core:
  - Floats render as the engine's CSV does: `1e15` is
    `"1000000000000000.0"`, `1e16` is `"1e16"`, `1.5e-5` is
    `"0.000015"` and `1e-6` is `"1e-6"`. Integers and booleans render
    as the engine's strings too.
  - A nested value gives the same connection error as the server's
    aborted body.
  - `:parquet` is refused by name.
  - `:xml` is the engine's 400.
  - `:pretty` and `:json_lines` are `{:unsupported_format, f}`.

  The same applies to `query_influxql/3`. `query_sql_stream/3` ignores
  `format:` on both clients.
- **An empty CSV cell was a `nil` key.** A null column is absent from a
  JSON row, but `ResponseParser` put an empty CSV cell into the row as
  `nil`. An empty cell is either a null or an empty string; CSV cannot
  tell them apart (verified on InfluxDB 3's CSV and on a v2 Flux
  `pivot`). Empty cells are now left out, so `refute Map.has_key?/2`
  holds for every format.
- **Flux (HTTP) returned a newline inside a string as `\r\n`.** InfluxDB
  2's CSV writer (Go's `csv.Writer` in CRLF mode) rewrites every `\n` in a
  quoted value as `\r\n` and drops a bare `\r` (verified), so a stored
  `s="l1\nl2"` read back as `"l1\r\nl2"` over `Client.HTTP` while
  `Client.Local` returned `"l1\nl2"`. `ResponseParser` undoes the rewrite;
  both clients now return the value as stored (unless it contained a `\r`
  of its own, which the server has already dropped).
- **`transport: :flight` silently dropped every column of a type the
  reader did not know.** Verified on InfluxDB 3: `selector_*` without a
  subscript (a Struct), `array_agg` (a List), `time - LAG(time)` (a
  Duration), `concat`/`upper` results (Utf8View), `CAST(... AS DATE)`,
  `DECIMAL` and `BYTEA`, and literal lists and structs all came back as
  empty rows over Flight while HTTP returned them. The reader now walks
  Arrow's field nodes, buffers and variadic buffer counts depth-first and
  decodes each of these to exactly what HTTP returns; types it still does
  not decode (Interval, Time, Map, Union, ...) are an error naming the
  type and column instead of a vanished column. Tested against 13
  recorded engine responses in `test/fixtures/flight` and live.
- **Timestamps inside structs and lists were strings over HTTP.**
  `ResponseParser` now coerces nested values, so
  `selector_last(v, time)` is `%{"time" => %DateTime{}, "value" => v}` on
  HTTP, Flight and `Client.Local`, which now also accepts a selector
  without `['value' | 'time']` and returns that struct, as the engine does.
- **`Client.Local` refused a line with repeated spaces between its
  sections** (`m    v=1i   1`) as "No fields were provided"; InfluxDB 3
  accepts it (verified), and so does the double now.
- **A schema error's `original_line` was the raw line.** InfluxDB 3
  reports the line as it parsed it — single spaces, `v=2.0` as `v=2`,
  `1e3` as `1000`, strings unquoted (verified); the double renders it the
  same way. Parse errors still show the raw line, as on the engine.
- **`Client.Local` read three clocks.** Untimed points and Flux `now()`
  used `System.system_time/1`, SQL `now()` used `System.os_time/1`; the
  two differ by microseconds, so a point a test stamped with one clock
  could fall after `now()` read from the other and drop out of
  `range(start: -1h)`. The double now has one clock (`Store.now_ns/0`,
  the later of the two), and Flux's exclusive `stop` defaults to a
  nanosecond after it, so a point written a moment ago is always in range,
  as on a real server.

## [0.1.32] - 2026-09-25

### Changed
- **`Client.Local` reads and writes are two to four times faster.** Every
  read merged duplicate points (same measurement, tags and time), about
  three quarters of a query's cost at 100k points, although most
  measurements never hold a duplicate. A write now records each series
  and time with an atomic `insert_new`; a second write of the same key
  marks the measurement, and reads merge only marked measurements. The
  line-protocol parser skips its escape-aware scans and unescaping when a
  token has no quote or backslash, and slices bytes instead of graphemes.
  Measured: a 50k-point write 1,962 → 697 ms, 200 small writes 40 → 16 ms,
  `COUNT` over 50k points 88 → 19 ms. Results are unchanged.

### Fixed
- **`Client.Local.execute_sql/3` accepted statements InfluxDB 3 refuses.**
  Every statement but `DELETE` returned `{:ok, %{"rows_affected" => 0}}`,
  and `DELETE` on `:v3_core` returned a bare `:delete_not_supported`.
  Verified against Core: `DELETE`, `INSERT`, `UPDATE` are 400 `Error
  during planning: DML not supported: Delete | Insert Into | Update`;
  `CREATE TABLE | VIEW | DATABASE` and `DROP TABLE | VIEW` are 400 `... DDL
  not supported: CreateMemoryTable | CreateView | CreateCatalog |
  DropTable | DropView`; anything else (`ALTER`, `TRUNCATE`) is 405 `This
  feature is not implemented: Unsupported SQL statement: <sql>`; a
  `SELECT` returns rows. The double now answers each of these as the
  engine does (its `:v3_enterprise` `DELETE` is unchanged), and
  `query_sql/3` gives a non-query the same answer, since the engine serves
  both from one endpoint. The contract test that should have caught this
  asserted `{:error, _}` and `is_map(result)`; it and the other contract
  tests accepting any error now assert the engine's status and body.
- **`Client.HTTP.execute_sql/3` returned `SELECT` rows as raw JSON** with
  string timestamps; they are now typed like `query_sql/3` rows. The
  facade, `Query.SQL.execute/3` and the usage rules advertised
  `execute_sql` for "DELETE, INSERT INTO ... SELECT", which Core refuses;
  they now say what it accepts. The `execute_sql` callback returns
  `{:ok, map() | [map()]}`.
- **`Client.Local` got NULL wrong in `WHERE`, `ORDER BY` and `DISTINCT`.**
  Verified against InfluxDB 3: `WHERE NOT (rack = '1')`, `rack NOT IN (...)`
  and `v NOT BETWEEN ...` returned rows where the column was null (the
  double's logic was two-valued); `ORDER BY` put a null first for strings,
  last for numbers and between `false` and `true` (term order) where the
  engine puts nulls last ascending and first descending, so a `GROUP BY`
  of a tag with missing values was mis-ordered too; `SELECT DISTINCT`
  dropped the all-null combination the engine returns as `%{}`. The
  evaluator now uses three-valued logic, sorting honours DataFusion's null
  placement and `NULLS FIRST` / `NULLS LAST`, and `DISTINCT` keeps the null
  row.
- **`LIKE 'al\%%'` matched nothing in `Client.Local`.** The backslash
  escape was read as a literal backslash; it now makes the next character
  literal, as on the engine.
- **`Client.Local` refused valid SQL:** a boolean column as a predicate
  (`WHERE b`, `NOT b`), the `%` operator and unary minus (`-n`). All three
  now work as on the engine (`%` takes the dividend's sign and works on
  floats); a non-boolean bare column is the engine's planning error.
  `HAVING` is still refused by name.
- **`Client.Local` misparsed escaped backslashes.** A string field value
  ending in an escaped backslash (`s="ends\\",v=1i`) swallowed the next
  field and failed the line; InfluxDB 3 stores `ends\`. A measurement, tag
  key, tag value or field key ending in a backslash (`m\\,t=a`) was stored
  under a garbled name or refused with the wrong message; InfluxDB 3
  refuses it with "Measurements, tag keys and values, and field keys may
  not end with a backslash". Both verified. Under the `:v2` profile a
  measurement keeps `\\,` as InfluxDB 2 does (verified), and tag and field
  names ending in a backslash are refused as it refuses them.
- **No release since 0.1.21 had a CHANGELOG heading (#22).** The publish
  job bumped the version and published without touching `CHANGELOG.md`,
  so 0.1.22 through 0.1.31 were all released with their entries under
  `[Unreleased]` and a consumer could not tell which version changed what.
  Every entry is now under the release that first shipped it, worked out
  from the `[Unreleased]` block at each release tag (all 71 entries
  placed, their text unchanged). The publish job now writes
  `## [x.y.z] - date` under `[Unreleased]` before publishing, fails the
  release if the heading is missing, and commits it with the bump; a test
  fails CI if the version in `mix.exs` has no heading or the headings are
  out of order.

## [0.1.31] - 2026-09-24

### Fixed
- **`query_sql_stream/3` over HTTP returned timestamps as strings.** Each
  streamed JSONL row was only `Jason.decode`d, so `time` (and every
  `DATE_BIN` alias or `MAX(time)`) was `"2023-11-14T22:13:20"` while
  `query_sql/3` and `Client.Local`'s stream returned a `DateTime`; code
  that switched to streaming for a large result broke. Streamed rows now
  get the same coercion; verified identical to `query_sql/3` on
  InfluxDB 3.
- **`Client.Local` refused `GROUP BY` and `ORDER BY` references DataFusion
  accepts.** `GROUP BY bucket` (a select alias — the usual form after
  `DATE_BIN(...) AS bucket`), `GROUP BY 1, 2`, `ORDER BY 2 DESC` were all
  "No field named" schema errors, and `GROUP BY DATE_BIN(...), host` —
  one row per bucket per host — was refused although the guide said it
  was supported. Positions and aliases are now resolved to the select
  items they name, `DATE_BIN` combines with grouping columns, and a
  position outside the select list is the engine's planning error; 14 of
  14 comparison queries match InfluxDB 3.
- **`Client.Local` skipped every Flux stage it did not understand.** The
  double matched a few regexes anywhere in the query and ignored the rest,
  so `|> mean()`, `last()`, `limit()`, `count()`, `aggregateWindow()`,
  `pivot()` and `group()` all returned the raw rows; `or` behaved like
  `and`; `!=`, `not`, `r._value > 2.0` and `range(stop:)` were ignored; a
  query without `range()` or on a missing bucket returned rows or `[]`.
  Verified against InfluxDB 2.7, the new `Client.Local.Flux` runs the
  pipeline in order — `range`, `filter` with a real expression grammar
  and three-valued logic, `first`/`last`/`min`/`max`, `mean`/`sum`/`count`,
  `limit`, `yield` — numbers tables in the engine's series order, adds
  `_start`/`_stop`, and answers 24 of 24 comparison queries identically.
  Any other stage is a 400 naming it; no `range()` is the engine's
  unbounded-read 400; a missing bucket is its 404; `mean()` over strings is
  its 400. Two tests that asserted the old behaviour (all rows without
  `range()`, `[]` for a missing bucket) now assert the engine's answers.
- **`Client.Local` answered InfluxQL `SELECT` as SQL.** Verified against
  InfluxDB 3 over 50 statements, 28 of which differed: rows lacked
  `"iox::measurement"`, a projection lost `time`, `MEAN`/`COUNT` were
  refused, aggregates were not named `mean`/`count`/`sum`, a lone selector
  did not return its point's time, `LIMIT` did not apply per `GROUP BY`
  series, an unknown column or measurement was an error instead of
  `{:ok, []}`, `SHOW FIELD KEYS` and bare `SHOW TAG KEYS` were
  unsupported, and `SHOW DATABASES` lacked `"deleted"`. The new
  `Client.Local.InfluxQL` module answers all 50 identically;
  `GROUP BY time(...)`, regular expressions, `fill()` and other
  constructs it does not model are refused by name.
- **`Client.Local` compared `time` at microsecond precision in SQL.**
  `ORDER BY time` sorted the projected `DateTime`, so points less than a
  microsecond apart came back in insertion order, and a literal such as
  `'…:20.0000002Z'` lost its last three digits. The engine uses the
  nanoseconds (verified); so does the double now, on every `ORDER BY time`
  form (`*`, a projection, an alias of `time`) and in every time literal.
- **`transport: :flight` returned null columns as `nil` keys.** Over
  HTTP, InfluxDB 3 leaves a null column out of the row, and the library
  documents that a null column is absent, not `nil`. The Flight reader
  put every schema column in every row, so the same query gave different
  maps per transport, and code matching on `Map.has_key?/2` or comparing
  rows broke when switching. Verified on 25,000 rows mixing tags, integer,
  unsigned, float, string and boolean fields and nulls across several
  record batches: the rows differed only in `nil` keys, and now they are
  identical. The reader's null tests asserted `row["v"] == nil`, which
  passes whether the key is absent or `nil`; they now assert the key is
  absent.

## [0.1.30] - 2026-09-23

### Changed
- `Flight.Client` builds its `DoGet` ticket through `build_ticket/2`
  instead of a second inline copy of the JSON. Admin tests assert what a
  call does (the bucket is listed with its rule, the database is gone)
  rather than `:ok` alone.
- `Connection.get/1` reads `:persistent_term` with a default instead of
  rescuing `ArgumentError`.
- `Writer` tests assert what a write does — every point of a gzipped
  payload is stored, `precision:` changes the stored time, `:client`
  selects the client — instead of `{:ok, :written}` alone.
- `ResponseParser` tests every string cell for InfluxDB 3's zone-less
  timestamp shape before deciding whether to decode it; a one-clause binary
  pattern now screens out strings that cannot match before the regex runs
  (about 14 ns instead of 340 ns per ordinary string cell). Results are
  unchanged.
- `BatchWriter` tests cover a chain that exhausts more than one retry
  (errors are counted per chain, not per attempt) and `max_retries: 0`
  against a transport error.

### Fixed
- **`Admin.Databases` and `Admin.Buckets` documented options that did not
  exist.** The docs named `:retention_period` and `:retention_seconds`;
  `Client.HTTP` reads `:retention`, so a consumer following the docs got
  the option silently ignored. The docs now name `:retention` and its
  verified format: a duration string such as `"30d"` for InfluxDB 3 (an
  integer is a 400), seconds for InfluxDB 2 (1–3599 is a 500 `retention
  policy duration must be at least 1h0m0s`; `0` is no expiry).
- **`Client.Local.delete_bucket/2` returned `:ok` for a missing bucket**,
  claiming to match "the idempotent delete semantics of the v2 API".
  InfluxDB 2 answers 404 (verified) and `Client.HTTP` reports it as
  `{:error, %{status: 404, body: "bucket not found: <name>"}}`; the double
  now does the same. `create_bucket/3` keeps `:retention`, refuses 1–3599
  seconds as the engine does, and `list_buckets/1` lists each bucket's
  `"retentionRules"` in the engine's shape. `delete_database/2`'s 404 body
  is the engine's `the requested resource was not found: <name>`, and a v2
  write to a missing bucket answers the engine's JSON 404 (`bucket "<name>"
  not found`) instead of a plain "database not found".
- **`Client.Local` kept duplicate points as separate rows.** InfluxDB 3
  and 2.7 both treat a measurement's points with the same tag set and
  timestamp as one point — fields merge, the later write wins per field,
  the last of two such lines in a payload wins (verified) — and the double
  returned one row per write, so a fixture that rewrote a point saw two
  rows and doubled its aggregates. Points are still stored as written, one
  ETS insert each, and are merged on every read; `DELETE` removes the
  merged point and counts it once.
- **`Client.Local` crashed on precision spellings the engine accepts.**
  `HTTP.write/3` passes `precision:` to InfluxDB 3 verbatim, which takes
  `ns | n | nanosecond | us | u | microsecond | ms | millisecond | s |
  second | auto` (verified), and maps the long names onto InfluxDB 2's
  `ns | us | ms | s`. The double accepted only the four long atoms and
  raised `FunctionClauseError` on `:ms`, `"ms"`, `"nanosecond"` or
  `:auto`, so a write that works in production crashed in tests. It now
  accepts what each profile's server accepts, implements `auto` at the
  engine's thresholds (|ts| below 5e9 seconds, 5e12 milliseconds, 5e15
  microseconds, else nanoseconds; verified), and answers an unknown
  precision with the server's 400 body (`serde error: unknown variant …`
  on v3, `invalid precision; valid precision units are ns, us, ms, and s`
  on v2).
- **`ConnectionSupervisor` started a Finch pool the connection never used.**
  With `:finch_name` pointing at an existing pool, a second idle pool was
  still started per connection, and the batch writer restarted with it
  under `rest_for_one`. No per-connection pool is started when
  `:finch_name` is set.
- `Connection.fetch!/1` raised `:persistent_term`'s bare `ArgumentError`
  for an unknown name; it now names the missing connection and says how
  to register one.
- The manual telemetry emitters `write_stop/2`, `write_exception/2`,
  `query_stop/2` and `query_exception/2` emitted `%{duration}` only, while
  the spans (and the documented events) carry `monotonic_time` too. They
  now emit the same measurements. `write_stop/2`'s docs mentioned a
  `compressed_bytes` metadata key that nothing emits (removed from the
  event docs on 2026-09-11); the leftover is gone.
- **`LineProtocol.encode/1` emitted lines no server accepts.** An empty tag
  value (`host=`), an empty tag key or field key, the reserved tag key
  `time`, and a newline in a measurement, tag key, tag value or field key
  all encoded without complaint and failed at the server — and a newline
  splits the line, so `tags: %{"host" => "a\nb"}` stored a bogus
  measurement `b` on InfluxDB 3 (verified). A non-string tag value or an
  unsupported field value (`nil`, an atom) crashed the encoder with a
  `FunctionClauseError`. Each is now a tagged error from `encode/1`
  (`{:invalid_tag_value, key, value}`, `{:reserved_tag_key, "time"}`,
  `{:invalid_field_value, key, value}`, …); see "Validation" in the
  moduledoc.
- **`Client.Local` worded a `time` field on a new table as a column-type
  conflict.** InfluxDB 3 says `'time' is a reserved column` for a tag or a
  field on a table that does not exist yet, and reports the column-type
  conflict with `iox::column_type::timestamp` only on an existing table.
  The double now does the same (the check moved from the parser into the
  store, which knows whether the table exists).

## [0.1.29] - 2026-09-22

### Fixed
- **`Client.Local`'s `:v2` profile applied InfluxDB 3's write rules.**
  Verified against InfluxDB 2.7, which differs on nearly every point: a
  field type conflict is HTTP 422 (`"unprocessable entity"`, message ending
  in `dropped=N`) with the other lines stored; a line that fails to parse
  rejects the whole payload with HTTP 400 (`"code":"invalid"`, `unable to
  parse '<line>': ...`) and nothing is stored; `time` as a field is dropped
  silently and as a tag is a 400; a tag and a field may share a name; an
  empty payload is accepted. The double now applies those rules under
  `:v2` and InfluxDB 3's under `:v3_core` / `:v3_enterprise`.

## [0.1.28] - 2026-09-22

### Fixed
- **`Client.Local` refused `LIMIT n OFFSET m`, which InfluxDB 3 runs (#21).**
  Verified against the engine: `OFFSET` skips rows before `LIMIT` takes
  them, in either order, on plain, projected, grouped and `DISTINCT` rows;
  `OFFSET 0` is a no-op, an offset past the end is an empty result, a
  negative offset is "OFFSET must be >=0" and a bare word is a schema
  error. All of that is now mirrored, so a paginated read can be tested
  against the double instead of re-implementing the offset in Elixir.

## [0.1.27] - 2026-09-18

### Fixed
- **`Client.Local` accepted writes InfluxDB 3 rejects, and rejected one it
  accepts.** Verified against the engine: a field written as an integer and
  later as a float (or tag then field, string then float, boolean then
  integer) is refused line by line with "invalid column type for column
  'v', expected iox::column_type::field::integer, got
  iox::column_type::field::float"; `time` as a tag or field, a key used as
  both tag and field on one line, an integer outside int64 and an empty
  payload are refused; a rejected line drops only itself — the other lines
  are stored and the response is the partial-write JSON with one entry per
  bad line. The double accepted all of those (and stored every line), and
  refused a newline inside a quoted string value, which the engine keeps.
  It now keeps a per-measurement column schema (`{:column, database,
  measurement, column}`, fixed atomically by the first writer), applies a
  payload line by line, returns the engine's body, and drops the schema
  with the data when the database is deleted. Unsigned integers (`7u`) are
  accepted.
- **`Client.Local.delete_database/2` kept the deleted database's points**,
  so a re-created database was not empty. The points and schema go with it.

## [0.1.26] - 2026-09-17

### Changed
- **SQL execution split out of `Client.Local`.** The 900-line executor —
  CTEs, joins, the `WHERE` evaluator, aggregates, casts, ordering, schema
  checks — is `Client.Local.SQLExecutor`, pure over the points
  it is handed through a fetch function; `Client.Local` keeps storage,
  profiles and the InfluxQL and Flux paths. Public behaviour is unchanged.
- `Client.Local` checks a query's column references against the first
  row before scanning every row's columns; the scan now runs only when a
  name is missing there, which is also when the error message needs the
  full list. Per-query fixed cost at 10k points drops from about 20 ms to
  under 5 ms; results are unchanged.
- **`Client.Local.SQLParser` cuts a SELECT into its parts in one place.**
  Eight regexes each found "the table after FROM" for their own dispatcher
  (star, column list, aggregate, DISTINCT, the clause check, the alias
  stripper, two helpers); `split_select/1` now does it once and the
  dispatchers work from its parts. No behaviour change; 71 lines fewer.

### Fixed
- **`Client.Local` read a bare word inside `IN (...)` as a string.**
  `host IN (a, b)` compared against `"a"` and `"b"`; on the engine the
  items are column references (`v IN (1, other)` works, `host IN (a, b)`
  is a schema error). Items are now parsed like every other comparand.
- **`Client.Local` refused a constant in a select list.** `0.0 AS volume`
  (the #17 candle query's placeholder volume) was "unsupported column
  expression" in an aggregate and a schema error in a projection; the
  engine returns the constant on every row. Supported with an alias in
  every query shape; an unaliased constant is refused with the reason.
- **`DELETE ... WHERE a OR b` crashed `Client.Local`** (`:v3_enterprise`)
  with a `FunctionClauseError`: the delete path still folded predicates
  with the helper from before `WHERE` became a boolean expression. It now
  evaluates the same expression tree `SELECT` does.
- **`CAST(col AS INTEGER)` in `WHERE` was rejected by 0.1.24 (#20) — and
  silently matched nothing in 0.1.23.** The report is right that 0.1.24
  refuses the orderbook depth query with `Client.Local: unsupported WHERE
  clause: CAST(level AS INTEGER)`. It was never a working query on the
  double: 0.1.23 read `CAST(level AS INTEGER)` as a column named that and
  returned no rows for it, so tests passing against 0.1.23 were passing on
  an empty result. `CAST` (and DataFusion's `col::TYPE` shorthand) now works
  wherever an expression is allowed — `WHERE`, `BETWEEN`, `LIKE`, projections,
  aggregates, arithmetic and `ORDER BY` — with the engine's semantics,
  verified against InfluxDB 3 Core: `INTEGER` / `INT` / `BIGINT`, `DOUBLE` /
  `FLOAT`, `VARCHAR` / `STRING` / `TEXT`; text converts only when the whole
  string is a number, a float truncates to an integer, a number renders to
  text. A cast that cannot be performed (`'abc'` to `INTEGER`, `time` to
  `INTEGER`) makes InfluxDB 3 Core drop the connection mid-response, which
  `Client.HTTP` reports as `{:error, {:connection_error, %Mint.TransportError{
  reason: :closed}}}`; the double reports `{:error, {:connection_error,
  :closed}}`.
- **`ORDER BY` ignored every term after the first in `Client.Local`.**
  `ORDER BY symbol DESC, level` sorted by `symbol` only. All terms apply,
  each with its own direction, and a term may be an expression
  (`ORDER BY CAST(level AS INTEGER) DESC`) on raw and projected rows.

## [0.1.25] - 2026-09-15

### Fixed
- **`Client.Local` ignored `GROUP BY` on a plain projection and `ORDER BY`
  on column-grouped aggregates, and sampled a row for an ungrouped
  column.** `SELECT host FROM p GROUP BY host` returned every row; `SELECT
  host, SUM(v) AS t FROM p GROUP BY host ORDER BY t DESC` came back in map
  order; `SELECT host, MAX(v) FROM p` (no `GROUP BY`) picked the first
  row's host. The engine returns one row per group, honours the ordering,
  and fails planning for the ungrouped column ("must appear in the GROUP BY
  clause or must be part of an aggregate function"); the double now does
  all three.
- **`Client.Local` answered queries that name a column no row has.**
  `SELECT nosuch`, `MAX(nosuch)`, `WHERE nosuch = 1`, `GROUP BY nosuch`,
  `ORDER BY nosuch` and `DISTINCT nosuch` are all the same 500 schema error
  on InfluxDB 3 ("No field named nosuch"); the double returned rows without
  the column, no rows, or unsorted rows depending on the clause. Every
  column reference in a query is now checked against the rows' columns
  (the check added for `WHERE` expressions in 0.1.24 generalised), and an
  output alias remains a valid `ORDER BY` target.

## [0.1.24] - 2026-09-15

### Fixed
- **An unbound `$placeholder` matched nothing in `Client.Local`**; the
  engine fails planning ("No value found for placeholder with name $host").
  The double now returns that error, so a missing binding cannot pass a
  test as an empty result.
- **`Client.Local` refused `median()` and `CROSS JOIN`, which InfluxDB 3
  runs (#19).** Verified against InfluxDB 3 Core: `median` returns the
  middle value, or for an even count the mean of the two middle values in
  the column's type (two integers average with integer division: the median
  of 1 and 4 is 2), null over no rows, and is rejected over `time`;
  `FROM w CROSS JOIN ref` pairs every row with every row of `ref`. Both are
  supported, so the median-screened candle query in the issue now runs on
  the double with the same rows as the server. A column present on both
  sides of the join is refused as ambiguous, as the engine refuses the
  unqualified reference.
- **`Client.Local` compared a bare word in `WHERE` as a string.**
  `price <= med * 3` compared `price` with the text `"med * 3"` and
  `host = prod` with `"prod"` — both silently wrong. Either side of a
  comparison may now be an arithmetic expression over columns, a bare word
  is a column reference, and a column no row has is the engine's schema
  error ("No field named prod"), which is what production returns for a
  forgotten pair of quotes.
- A `nil` param rendered as the word `nil` in `Client.Local`; it now renders
  as `NULL`, which never matches, as the JSON `null` Jason sends over HTTP
  never matches.

## [0.1.23] - 2026-09-15

### Fixed
- **`Client.Local` returned wrong rows for `OR`, `NOT`, parentheses and
  `<>` in `WHERE`, and for `LIMIT 0`.** The clause splitter only knew `AND`:
  `v > 3 OR v < 2` was read as one predicate against the string
  `"3 OR v < 2"`, `NOT host = 'a'` and `v <> 1.0` matched nothing, and
  `LIMIT 0` returned every row where the engine returns none. `WHERE` is now
  parsed as a boolean expression — `AND` binding tighter than `OR`, `NOT`,
  parentheses, string literals opaque — and `<>`, `[NOT] BETWEEN ... AND
  ...` (including `time`) and `[NOT] LIKE` / `ILIKE` are supported with the
  engine's semantics (`LIKE` case-sensitive, `_` one character, `LIKE` over a
  numeric column reproduces the engine's planning error). `LIMIT 0` returns
  no rows; a negative or non-numeric `LIMIT` is rejected as the engine
  rejects it. A malformed expression is rejected, never truncated.
- **`Client.Local` compared a string tag against a bare number by Erlang
  term order**, so `rack > 3` matched every tag. The engine keeps the column
  as text and renders the literal (`rack = 2` matches `"2"`; `rack > 3`
  does not match `"10"`); the double now does the same.
- **`Flight.Reader` walked empty FlatBuffer vectors at bogus indices.**
  `for i <- 0..(count - 1)` with `count == 0` is the descending range
  `[0, -1]` in Elixir, so a schema with no fields or a record batch with an
  empty buffers vector was read twice at invalid positions instead of not
  at all. The ranges now carry an explicit `//1` step, as the other
  comprehensions in the module already did.
- **`Client.Local` refused projected arithmetic and CTEs InfluxDB 3 runs
  (#18).** Verified against InfluxDB 3 Core: `SELECT (bid + ask) / 2 AS mid,
  time FROM q` and `WITH w AS (SELECT bid, time FROM q) SELECT
  DATE_BIN(INTERVAL '1 minute', w.time) AS time, MAX(w.bid) AS hi FROM w
  GROUP BY DATE_BIN(INTERVAL '1 minute', w.time)` both return rows on the
  server and were `Client.Local:` 400s. The double now supports an arithmetic
  expression as a projected column (with an alias; `ORDER BY` may name it),
  non-recursive `WITH` CTEs executed in order (a later CTE or the final
  `SELECT` reads an earlier one), table aliases (`FROM q AS w`, `FROM q w`)
  and `alias.column` qualifiers in every clause.
- **`Client.Local` silently ignored everything after the table name.**
  `SELECT * FROM w CROSS JOIN q` answered from `w` alone, `... UNION SELECT
  ...` took `UNION` as a table alias, and `WHERE x IN (SELECT ...)` compared
  against the string `"SELECT ..."`. Joins, set operations, subqueries,
  `HAVING`, `OFFSET` and window functions are now rejected by name
  (`Client.Local: unsupported SQL construct JOIN`). Keywords are matched
  by the shape only a clause can have (`OFFSET 1`, `OVER (`) and string
  literals are ignored, so a column named `offset` or `over` and a value
  such as `'select from join'` — both fine on the engine — still work.
- `Client.Local` returned `"time" => nil` for a row without a timestamp (a
  CTE that did not project `time`); the column is omitted, as everywhere
  else.

## [0.1.22] - 2026-09-14

### Changed
- `BatchWriter` tests no longer inspect GenServer state to check that
  configuration was stored; scheduling and jitter are asserted through the
  observable flush instead.
- **`Client.Local` split into three modules.** The 2,470-line module now owns
  storage, capability checks and query execution (1,450 lines); the SQL parser
  is `Client.Local.SQLParser` and the line-protocol parser is
  `Client.Local.LineProtocolParser`, both pure. Public behaviour
  is unchanged; the contract suites prove it.
- `Client.Local.query_influxql/3` matches each `SHOW` pattern once.
- Removed the unused internal `InfluxElixir.InfluxCase` case template from
  `test/support/` (never shipped; no test used it).
- `Client.Local`'s line-protocol splitters accumulate tokens in binaries
  (runtime-optimised append) instead of one list cell per byte plus a
  reverse and join, cutting allocations on every write to the double.

### Fixed
- **`Client.Local` accepted `time` comparands InfluxDB rejects, and silently
  matched nothing for ones it accepts.** Verified against InfluxDB 3 Core:
  a bare integer (`time > 1700000000`) or integer param fails planning on
  the server ("Cannot infer common argument type for comparison operation
  Timestamp(ns) > Int64") and an unparseable string fails execution, while
  the double returned `{:ok, []}` for both; `now() - INTERVAL '2 minutes'`
  runs on the server but was compared as the literal string, so it too
  returned `{:ok, []}`. The parser now accepts exactly the engine's forms —
  quoted ISO-8601 datetimes (zoned, zone-less, fractional), quoted dates,
  `now()` offset by `INTERVAL` terms, evaluated at query time — and rejects
  the rest with a `Client.Local:` 400 that names the engine's rule.
- **`DateTime` params rendered as `~U[...]` in `Client.Local`.** Jason sends
  them as ISO-8601 strings over HTTP; the double now renders `DateTime`,
  `NaiveDateTime` and `Date` params the same way.
- **`SELECT DISTINCT ... ORDER BY` was ignored by `Client.Local`**: rows came
  back ascending whatever the direction. `ORDER BY` on a selected column is
  honoured; on any other column it is rejected with DataFusion's own
  message.
- **`MAX(time)` / `MIN(time)` returned an empty row from `Client.Local`**
  (the timestamp is not a field, so the aggregate saw only nulls). They now
  return the `DateTime`, as the engine does; `AVG(time)`, `SUM(time)`, the
  statistics over `time` and arithmetic on `time` are rejected as DataFusion
  rejects them.
- **`Client.Local` refused `COUNT(DISTINCT col)` and `WHERE col IS [NOT]
  NULL`**, both ordinary SQL the engine runs. Both are supported.
- **HTTP JSON left aliased timestamp columns as strings** — see the entry
  above for #16/#17; this sweep's contract tests cover `MAX(time)` too.
- **`BatchWriter` documented a backpressure it could never apply.** The
  buffer emptied on every flush, so `{:error, :buffer_full}` was
  unreachable and the tests that "proved" it forged the GenServer state.
  Automatic flushes now wait for an in-flight retry chain instead of
  opening a new chain per batch against a failing server, the buffer is
  bounded at `10 * batch_size` while a chain is in flight, and the deferred
  buffer is flushed when the chain ends. A `write_sync/3` caller is answered
  by its own chain's result (the caller's reference travels with the chain;
  before, a later chain could answer it).
- `BatchWriter` tests no longer inject `:retry` messages or read GenServer
  state: retries are exercised through a closed port (unit) and through a
  Finch pool checkout timeout that resolves before the backoff fires
  (integration, against the real server).
- **`Client.Local` rejected valid InfluxDB 3 SQL (#16, #17).** Verified
  against InfluxDB 3 Core: `STDDEV` / `STDDEV_SAMP` / `STDDEV_POP` /
  `VAR` / `VAR_SAMP` / `VAR_POP`, arithmetic inside an aggregate
  (`SUM(value * value)`, `AVG(bid + ask)`, integer operands dividing as
  integers), `selector_first|last|min|max(field, time)['value' | 'time']`,
  `SELECT DISTINCT a, b`, and `ORDER BY` a projected alias (`ORDER BY bucket
  DESC`) all work on the server and were all `Client.Local:` 400s in the
  double. All are now supported with the values the engine returns; `VARIANCE`
  stays rejected because DataFusion has no such function.
- **`Client.Local` returned `nil` columns the real engine omits.** InfluxDB 3
  leaves a null column out of the JSON row entirely (an empty group carries
  only `COUNT: 0`; a sample statistic over one row has no key). The double now
  omits them too, so `refute Map.has_key?(row, "avg")` means the same thing
  on both.
- **HTTP JSON responses left timestamp columns other than `time` as strings.**
  A `DATE_BIN(...) AS bucket` alias or `selector_*(...)['time']` came back as
  `"2023-11-14T22:12:00"` over HTTP but as a `DateTime` over Flight and from
  `Client.Local`. `Query.ResponseParser` now decodes InfluxDB 3's zone-less
  timestamp rendering under any column name (zoned RFC3339 strings are still
  decoded only under `time` / `_time` / `_start` / `_stop`).
- `mix docs` warned that the README's `LICENSE` link had no target; the
  licence is now an ExDoc extra.

### Added
- `InfluxElixir.Client.Local.check_sql/1` — parse a query without running it
  and get the same `Client.Local:` error `query_sql/3` would, so a test can
  `flunk/1` with the reason instead of being silently excluded.
- Testing guide: "Checking a Query Before Running It" and "Running Against a
  Real InfluxDB" (the integration tier, `INFLUX_V3_CORE_HOST` / `_PORT`,
  Docker one-liners), and the new aggregate, selector and null-omission
  semantics with the values recorded from the engine.
- `CLAUDE.md` described a `/docs` layout (`architecture/`, `api/`,
  `development/`, per-directory READMEs, a design template) that did not exist.
  The READMEs and template now exist, `docs/design/README.md` indexes every
  design document and carries the real-engine Docker one-liners, and
  `CLAUDE.md` describes the actual layout.
- **The shipped usage rules made false claims.** They told consumers to
  start a Finch pool themselves (the supervisor starts one per connection),
  that booleans encode as `t`/`f` (they are `true`/`false`), to pass params as
  a keyword list (a map), and that write errors carry `:retryable` /
  `:non_retryable` atoms (no such atoms exist; errors are `%{status, body}` or
  `{:connection_error, reason}`). All three rule files rewritten against the
  current code.
- **`Client.HTTP` raised on keyword-list `params:`.** Jason cannot encode the
  tuples, so `params: [tag: "v"]` crashed the HTTP client while `Client.Local`
  accepted it — exactly the shape the old usage rules recommended. Both clients
  now accept a map or a keyword list; the contract suite proves it against the
  real engine.
- **`Client.Local` lost concurrent writes to the same database** (#15). Points
  were stored as one list per measurement and every write read the list,
  prepended and wrote it back, so parallel writers overwrote each other's
  inserts while all reported `{:ok, :written}` (159 of 480 survived in the
  report). The ETS layout is now one object per point, database, bucket and
  token, so every mutation is a single atomic insert or delete. The same
  change removes the quadratic copy on bulk writes: 20,000 lines took 63 s
  and now take well under a second. Points scan in insertion order.
- The testing guide's "Key Differences" still listed `first`/`last` as
  supported aggregates and omitted `DISTINCT`, `GROUP BY <columns>`,
  `COUNT(*)` and `$param` substitution; corrected to the current parser.
- **README usage example could not work.** It placed `{InfluxElixir, ...}` in
  a supervision tree (the facade has no `child_spec/1`; the library is an OTP
  application configured via `config :influx_elixir, :connections`), put a
  scheme in `host:` and used the nonexistent `default_database:` key, which
  HTTP config validation now rejects at startup. Rewritten with a working
  configuration, a write/query example, the v2 options and the shipped test
  helper.
- **`InfluxElixir.TestHelper` now ships in the package.** It was documented
  (CLAUDE.md, usage rules, the original design) as a helper for consuming
  applications' test suites, but lived under `test/support/`, which is only
  compiled in this repository's test environment — no consumer ever received
  it. It is now under `lib/`. The usage rules also named a nonexistent
  `setup_local/1`; the function is `setup_influx/1`, which passes its options
  straight to `Client.Local.start/1`. Covered by its own test module.
- `InfluxElixir.Admin.Health` documented an atom-keyed `%{status: "pass"}`
  result; both clients return string keys (`%{"status" => "pass"}`), as the
  2026-03-13 integration plan already required.

## [0.1.21] - 2026-09-11

### Added
- **Telemetry is actually emitted.** `InfluxElixir.Telemetry` documented
  `[:influx_elixir, :write | :query, ...]` events, but nothing in the library
  called it. `Write.Writer.write/3` (hence `InfluxElixir.write/3` and every
  `BatchWriter` flush) now emits the write span with `database`, `bytes` and
  `point_count`; `InfluxElixir.query_sql/3`, `execute_sql/3`, `query_influxql/3`
  and `query_flux/3` emit the query span with `database`, `transport` (the client
  module) and, for list results, `row_count`. `:stop` metadata carries
  `result: :ok | :error`.
- `BatchWriter` and `Write.Writer` accept a `:client` option to write with a
  specific client module instead of the configured one.
- `InfluxElixir.Config` knows `:timeout`, `:batch_writer` and `:finch_name`.

### Fixed
- **`Client.HTTP` never set Finch's `pool_timeout`** (#14), so every request
  waited at most Finch's default 5 s to check a connection out of the pool no
  matter how generous `:timeout` was, and against a slow multi-node endpoint
  failed with a transport `:timeout` at five seconds. A `:pool_timeout` option
  now resolves like `:timeout` (per-call opt → connection → 5_000) and is passed
  on every request, including the streaming query. Verified against InfluxDB 3
  Core with a size-1 pool held by a sleeping stream — which also showed that
  Finch **raises** on a checkout timeout rather than returning an error, so the
  exception used to escape `query_sql/3`. It is now
  `{:error, {:connection_error, :pool_timeout}}`, and the streaming query
  raises `InfluxElixir.StreamError` with `reason: :pool_timeout`.
- **Flight and HTTP now return the same `time` values.** `Flight.Reader`
  decoded Timestamp columns to raw integers while the HTTP path yields
  `DateTime`; the reader now reads the Arrow `TimeUnit` and converts.
  `Query.ResponseParser` also treated InfluxDB 3's zone-less JSON timestamps
  (`"2023-11-14T22:13:20.123456789"`) as opaque strings because
  `DateTime.from_iso8601/1` rejects them; they are now parsed as UTC. Verified
  against InfluxDB 3 Core: identical rows on both transports.
- **`transport: :flight` was documented but ignored** by the facade,
  `Query.SQL` and the usage rules; every query went over HTTP.
  `Client.HTTP.query_sql/3` now dispatches to `Flight.Client` when
  `transport: :flight` is given, using the connection's host/token, the resolved
  database, and `flight_port` (opt, connection, or 443). `params:` are rejected
  over Flight instead of being dropped. Verified against InfluxDB 3 Core's
  Flight endpoint.
- **`BatchWriter` retried 4xx responses.** The discard clause matched
  `{:error, {:http_error, status}}`, a shape no client produces, so a rejected
  batch (bad line protocol, unknown database) was retried with backoff until
  `max_retries` ran out. It now matches the clients' `%{status: 4xx}` and drops
  the batch on the first response. The retry path is covered by a real
  transport error against a closed port.
- **`ConnectionSupervisor` handed the batch writer the raw config instead of
  the initialised connection**, so a `batch_writer:` under `Client.Local`
  crashed on its first flush. Covered by a supervisor-level test.
- **`ConnectionSupervisor` validates HTTP connection config.** A typo such as
  `default_database:` (which the facade and application docs themselves used)
  was silently ignored; with `Client.HTTP` it now fails at startup with a
  `NimbleOptions.ValidationError`. `Client.Local` configs are not validated.

### Changed
- **`time` is a `DateTime` on every client and transport.** `Client.Local`
  returned `time` and `DATE_BIN` buckets as ISO 8601 strings, while the HTTP
  path (once its zone-less parsing was fixed, see below) and Flight return
  `DateTime`. All three now return `DateTime` with microsecond precision, so
  the contract suite asserts one instant across Local, HTTP and Flight. Code
  that compared Local's `time` to a string must use a `DateTime` (six-digit
  sigil or `DateTime.compare/2`).
- `InfluxElixir.write/3` goes through `Write.Writer`, so payloads over 1 KB
  are gzipped like `BatchWriter` flushes already were.
- `Flight.Reader` decodes fixed-width columns with binary comprehensions
  (one pass, no per-element slicing) instead of indexed `binary_part/3`.
- **`Client.Local.query_flux/3` returns the long row shape real Flux returns**:
  one row per field with `_field`/`_value`, `_measurement`, `_time` (a
  `DateTime`), the tags, `result` and a per-series `table` index, ordered by
  table then time. `filter(fn: (r) => r._field == "...")` is honoured. The old
  wide rows (`%{"_measurement", "<field>" => v, "time"}`) could not exercise
  consumer Flux handling; verified against InfluxDB 2.7.
- **`Client.HTTP.query_flux/3` requests `#datatype` annotations** so CSV cells
  come back typed (`double`, `long`, `unsignedLong`, `boolean`, RFC3339 →
  `DateTime`) instead of as strings.
- `Query.ResponseParser.coerce_types/1` also converts `_time`, `_start` and
  `_stop`. `parse/2` returns `{:error, {:unexpected_json, term}}` for a JSON
  scalar body instead of raising `CaseClauseError`.

### Added
- `api_version: :v2 | :v3` connection option (`InfluxElixir.Config`). Required
  for InfluxDB 2.x: a v2 server answers `200` to the v3 write path **without
  storing anything**, so writes silently vanished and malformed line protocol
  or an unknown bucket reported success. With `:v2` the client uses
  `POST /api/v2/write?org=&bucket=&precision=ns|us|ms|s`.

### Fixed
- **`Client.HTTP.create_bucket/3` works against real InfluxDB v2.** It sent
  `"orgID": ""`, which v2 rejects (`id must have a length of 16 bytes`). The org
  ID is now resolved from the connection's `:org` name (`org_id:` overrides).
  Creating a bucket that already exists is treated as success, matching
  `Client.Local`.
- **`Client.HTTP.delete_bucket/2` accepts a bucket name.** v2 deletes by ID;
  the name is resolved via `GET /api/v2/buckets?name=`, so the same call works
  against `Client.Local`. A 16-hex argument is used as an ID directly.
- **Flux CSV parsing uses NimbleCSV.** The hand-rolled splitter left `\r` on
  every last cell and header, turned the blank line between tables into a row
  and the next table's header into data, and broke quoted cells containing
  commas. All were observed against InfluxDB 2.7.
- **`LineProtocol` floats no longer lose precision.** `{:decimals, 17}`
  formatting wrote `1.0e-20` as `0.0`; the shortest round-trip form is used
  (`1.0e-20`, `2.5e-7`), which InfluxDB 3 Core accepts and reads back exactly.
- **`Telemetry.write_start/1` and `query_start/1` emit wall-clock
  `system_time`.** They emitted `System.monotonic_time/0` under that key, an
  arbitrary offset that is useless as a timestamp. A `monotonic_time`
  measurement is emitted alongside, matching `:telemetry.span/3`.
- **`Flight.Client.query/3` closes the gRPC channel when `DoGet` fails**; it
  was only disconnected on success.
- **`Client.Local.stop/1` no longer races the owner process's ETS cleanup.**
  Called from an `on_exit` after the test process had exited, the
  `:ets.info/1` guard could pass and `:ets.delete/1` then raise
  `ArgumentError`, failing the test intermittently.
- **`Flight.Reader` row assembly is linear in the batch's row count.** Cells
  were read with `Enum.at/2` on the column lists for every row, which made
  decoding a record batch quadratic; columns are now tuples read with `elem/2`.

### Changed
- `Client.HTTP` routes every request through one `request/7` helper that maps
  the status to `{:ok, response}` / `{:error, %{status, body}}` /
  `{:error, {:connection_error, reason}}`, replacing fourteen copies of the same
  three-clause `case`. No behavioural change.

## [0.1.20] - 2026-09-10

### Changed
- **`Client.Local` ordered aggregates now use the InfluxDB v3 SQL spelling**
  (#13). `first_value(field ORDER BY col [ASC|DESC])` and
  `last_value(field ORDER BY col [ASC|DESC])` are parsed and executed, including
  `GROUP BY <columns>` for "latest value per group" queries. The InfluxQL-style
  `FIRST(field, time)` / `LAST(field, time)` the double previously accepted are
  **rejected**: InfluxDB v3 fails planning on them (`Invalid function 'last'`),
  so accepting them let a query pass tests and 400 in production. The rejection
  names the v3 spelling. `first_value`/`last_value` without an inner `ORDER BY`
  are also rejected — DataFusion returns an arbitrary group member in that case,
  which the double cannot reproduce. Verified against a live InfluxDB 3 Core;
  the shared contract suite now passes against the real engine (it previously
  failed on the two `FIRST`/`LAST` tests).
- **`Client.Local` parser rejections are prefixed `Client.Local:`** so an
  `unsupported column expression` error reads as a limitation of the test double
  rather than of InfluxDB. Plain aggregates (`AVG`, `SUM`, `COUNT`, `MIN`,
  `MAX`) now reject a second argument, as the real engine does.
- **`Client.Local` reports a missing table the way the real engine does.**
  `query_sql/3` on an unknown measurement returned
  `{:error, {:table_not_found, name}}` while `Client.HTTP` returns
  `{:error, %{status: 400, body: "Error during planning: table ... not found"}}`,
  and the streaming path mapped it to a 404. Both now produce the 400 planning
  error, so consumer code that matches `%{status: 400}` can be exercised against
  the double. Code matching the old tuple must be updated.

### Fixed
- **`BatchWriter` now honours its `:database` option.** The value was stored in
  state and never forwarded to the write, so every flush landed in the
  connection's default database. It is now the write target unless
  `:write_opts` names a `:database` explicitly.
- **`Client.Local` (`:v2` profile) accepts writes to buckets created with
  `create_bucket/3`.** Writes only checked the `databases:` seeded at start, so a
  bucket created through the API returned `404 database not found`.
- **`Client.Local` no longer re-types quoted string literals** (#12). A bound
  string param or quoted literal such as `'08338636'` was parsed back through
  `Integer.parse`, dropping the leading zero and changing the type, so
  `WHERE repcode = $rc` / `IN ($rc)` over zero-padded identifiers never matched
  while real InfluxDB v3 matched correctly. Quoted literals are now strings;
  only bare literals are typed. Comparing a string literal against a numeric
  field compares the field's text rendering, which is what DataFusion does
  (`amount >= '1000.00'` is lexical and matches `500.0` on the real engine
  too), so that footgun now fails in tests the same way it fails in production.
- **Linear-time accumulation in `Client.Local` WHERE parsing and
  `Flight.Reader` batch decoding.** Both appended with `++` inside a reduce,
  which is quadratic in the number of clauses / record batches.
- **`Client.Local` param substitution is whole-placeholder and single-pass.**
  `$h` was previously replaced inside `$hmin`, and a substituted string value
  containing another placeholder's name could be re-substituted.

## [0.1.19] - 2026-07-08

### Fixed
- **`InfluxElixir.Client.Local.query_sql_stream/3` now mirrors the HTTP client's
  error semantics** (#11). `Client.Local` is the documented drop-in test double for
  `Client.HTTP`, but it still returned an empty stream on a query error or an
  unsupported operation while `Client.HTTP` raised — so consumer code that rescues
  `InfluxElixir.StreamError` (to avoid treating an outage as "no data") could not be
  exercised against the test double. It now raises `InfluxElixir.StreamError` on
  enumeration for both cases, matching `Client.HTTP`.

### Added
- Tests covering the Local `:http_status`/`:unsupported` stream-error paths and
  lazy (deferred) raising.

## [0.1.18] - 2026-07-08

### Fixed
- **`query_sql_stream/3` (HTTP transport) now truly streams and no longer swallows
  errors** (#10). Previously it used `Finch.request/3`, which buffered the entire
  response body and eagerly decoded every JSONL line before yielding — giving zero
  memory benefit over `query_sql/3` — and it halted to an empty list on non-2xx
  statuses, transport errors, and unresolved databases, so every failure class
  looked like "zero rows". It now consumes the response with `Finch.stream/5`,
  decoding JSONL line-by-line with back-pressure (constant memory), and raises an
  `InfluxElixir.StreamError` on a missing database, a non-success HTTP status, or a
  transport error when the stream is enumerated.

### Added
- `InfluxElixir.StreamError` exception, raised while consuming a streaming query
  that cannot produce rows. Carries a `:kind` (`:no_database | :http_status |
  :transport | :decode | :unsupported`) plus `:status`/`:body`/`:reason` context.
  `InfluxElixir.StreamError.stream/1` builds an `Enumerable.t()` that defers the
  raise to enumeration, shared by both client implementations.
- Tests covering the HTTP `:no_database`/`:transport` paths (real Finch pool, no
  mocking) and `StreamError` message construction.

## [0.1.17] - 2026-06-30

### Changed
- **Loosened `decimal` constraint to `~> 2.0 or ~> 3.0`** (#9). Unblocks downstream
  apps from upgrading past `decimal 2.4.1` (EEF-CVE-2026-32686) and from picking up
  `ecto ~> 3.14 → ash ~> 3.29` chains. Surface used (`Decimal.to_string/2`,
  `%Decimal{}` pattern) is stable across 2 → 3.
- **Loosened `grpc` constraint to `~> 0.11 or ~> 1.0`** (#9). Unblocks downstream
  apps from upgrading past `grpc 0.11.5` (5 CVEs including EEF-CVE-2026-48853).
- **Defaulted the Flight client to the Mint gRPC adapter** so the library doesn't
  pull in `:gun`, which became `optional` in `grpc 1.0`. Mint is already available
  via `finch`.
- `InfluxElixir.Supervisor` now skips adding `GRPC.Client.Supervisor` as a child
  when `grpc 1.0+` is present (1.0 auto-starts it via its own `Application`).

### Fixed
- `LocalClient` now supports `COUNT(*)` as a scalar and DATE_BIN-bucketed aggregate.
- `LocalClient` WHERE-clause parser now returns a 400 error for unrecognised
  clauses (e.g. `LIKE`) instead of silently matching all rows.

### Added
- Regression tests for `COUNT(*)`, explicit column-list `SELECT`, `IN` operator
  narrowing, write-timestamp preservation, and silent WHERE drop.

## Earlier releases

- Initial project setup with module stubs
- CI pipeline with quality checks and auto-publish to Hex.pm
