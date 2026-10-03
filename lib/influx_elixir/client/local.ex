defmodule InfluxElixir.Client.Local do
  @moduledoc """
  In-memory InfluxDB client for fast, isolated testing.

  Stores data in ETS tables, enabling safe `async: true` tests with full
  isolation between test instances. Each call to `start/1` creates an
  independent ETS table.

  Parses real line protocol on write, stores points as maps, and responds
  with realistic InfluxDB response formats on query. The module is a facade:
  the line protocol parser, the SQL, InfluxQL and Flux engines and the ETS
  store behind it are internal; this module is the public API and carries the
  documented behaviour below.

  ## Profiles

  LocalClient enforces an InfluxDB **version profile** that determines
  which operations are available. This prevents tests from accidentally
  using operations that the real InfluxDB backend doesn't support.

  | Profile | Write | SQL | InfluxQL | Flux | DB CRUD | Bucket CRUD | Tokens |
  |---|---|---|---|---|---|---|---|
  | `:v3_core` | yes | yes | yes | no | yes | no | no |
  | `:v3_enterprise` | yes | yes | yes | no | yes | no | yes |
  | `:v2` | yes | no | no | yes | no | yes | no |

  Operations outside the configured profile return
  `{:error, :unsupported_operation}`.

  ## Usage

      # Match your production InfluxDB version
      setup do
        {:ok, conn} = InfluxElixir.Client.Local.start(
          databases: ["test_db"],
          profile: :v3_core
        )
        on_exit(fn -> InfluxElixir.Client.Local.stop(conn) end)
        {:ok, conn: conn}
      end

  ## Checking Profile Support

  Use `supports?/2` to check if an operation is available:

      if Local.supports?(conn, :query_sql) do
        Local.query_sql(conn, "SELECT * FROM cpu", database: "test_db")
      end

  ## Storage

  Each instance is one ETS table whose key layout is private to the
  double. Every mutation is a single insert or
  delete of its own key, so concurrent writers — `async: true` tests sharing
  one database, `BatchWriter` flushes racing direct writes — never
  read-modify-write a shared value and no write is ever lost.

  ## Write Rules

  What a write accepts is what InfluxDB 3 accepts, verified against the
  engine:

    * A payload is applied line by line. A line with a syntax error, or a
      column whose kind conflicts with the measurement's schema, is dropped
      and reported; the other lines are stored. The result is then
      `{:error, %{status: 400, body: json}}` with the engine's body —
      `"partial write of line protocol occurred"` and one `data` entry per
      bad line (`error_message`, `line_number`, `original_line`).
    * A column's kind is fixed by the first write that names it, per
      database and measurement: a tag stays a tag, an integer field stays
      an integer (`v=1i` then `v=2.0` is "invalid column type for column
      'v', expected iox::column_type::field::integer, got
      iox::column_type::field::float"). Deleting the database drops the
      schema with the data.
    * `time` is a reserved column ("'time' is a reserved column" on a new table;
      on an existing one the engine words it as a column-type conflict with
      `iox::column_type::timestamp`); a key cannot be both a tag and a field on
      one line; an integer must fit in 64 bits (`7u` is unsigned); a newline
      inside a quoted string value is part of the value; a measurement, tag
      key, tag value or field key ending in a backslash is refused ("... may
      not end with a backslash"); an empty payload is
      "incoming write was empty".
    * Points with the same measurement, tag set and timestamp are one point,
      on both versions (verified): their fields merge and the later write
      wins per field — `v=1i,w=1i` then `v=2i` at the same instant reads
      back as `v=2, w=1`, and the last of two such lines in one payload
      wins. A different tag value is a different point. `DELETE` removes
      the merged point.
    * `accept_partial: false` makes a write all-or-nothing: the first bad
      line in line order — a parse error or a schema conflict, also against
      an earlier line of the same payload — rejects it, nothing is stored
      (not even schema), and the body is `{"error": "line protocol parsing
      error", "data": {...}}` with that one line. `no_sync:` is accepted
      and changes nothing (the double has no write-ahead log; on the
      engine a `no_sync` write may not be visible to a query right away).
      Either one that is not a boolean is the engine's 400.
    * A schema error's `original_line` is the line as the engine renders
      it, not as it was sent: single spaces, floats shortest and without an
      exponent (`2.0` → `2`), strings unquoted. Runs of spaces between a
      line's sections are one separator.
    * `line_number` counts the lines that are not blank and not comments,
      and `original_line` of a syntax error is the physical line of the
      payload with that number, so a comment before a bad line shifts the
      echo, as it does on the engine. A quote opens a string only after a
      field's `=`; one in a measurement, tag or field key is a plain byte,
      and a measurement in quotes keeps them in its name.
    * Two lines InfluxDB 3 Core accepts are refused by name, because what it
      then stores cannot be held: a tag key given twice (every query of the
      table then fails with a 500) and a float too large for 64 bits such as
      `1e999` (stored as infinity).
    * InfluxDB 3 reads a line the way its parser does, and says so in its
      words: `series SP+ fields [SP+ timestamp] SP*`, where whatever is left
      over is "Could not parse entire line. Found trailing content: `...`"
      and a first field that does not parse is "No fields were provided".
      `v=5.` leaves `.`, `v=1e` leaves `e`, `v=.5` and `v=+5` are no
      fields at all, `v=1 100 200` leaves `200`; a tag set that cannot be
      read is "Tag set malformed", "Expected tag key" or "Expected tag
      value", and a field named twice is refused.
    * Under the `:v2` profile the rules are InfluxDB 2's, verified against
      2.7, which parses with Go's `ParsePoints` and words its errors after
      the scanner that failed: a field type conflict is HTTP 422
      (`{"code":"unprocessable entity","message":"... field type conflict:
      input field \"v\" on measurement \"m\" is type float, already exists as
      type integer dropped=N"}`) with the other lines stored; a point whose
      only field is `time` is dropped, "invalid field name" (the other
      fields of a point that has some are stored, `time` is not); a payload
      is written a shard group at a time (a week of time, or a day or an
      hour for a bucket with a short retention), and the message is one
      failing group's first drop, counting that group's drops. When several
      groups fail, which one the engine reports varies between identical
      writes (verified; usually the earliest); the double always reports the
      earliest. A
      point older than the bucket's retention (`now - retention`) is dropped
      before any group sees it, and a write that has such points and no
      failing group is HTTP 422 `... partial write: dropped N points outside
      retention policy of duration 2h0m0s - oldest point <series key> at
      <time> dropped because it violates a Retention Policy Lower Bound at
      <bound>, newest point ... dropped=N for database: <bucket id> for
      retention policy: autogen`; a failing group's message replaces it. A line that
      fails to parse rejects the whole payload with HTTP 400
      (`{"code":"invalid","message":"unable to parse '<line>': <reason>"}`,
      one such sentence per failed line, joined by newlines, the reason one
      of `invalid field format`, `missing field value`, `invalid number`,
      `invalid float`, `invalid boolean`, `bad timestamp`, `point is
      invalid`, `missing fields`, `missing tag value`, ... the way the
      scanners say them) and nothing is stored; `time` as a tag is a 400; a
      tag and a field may share a name; an empty payload is accepted. A
      measurement with a backslash before `=` or `"`, or two or more before
      a `,` or a space, is accepted and never returned by a query, on the
      engine and in the double.

  ## SQL Query Support

  `query_sql/3` understands a subset of SQL.

  Identifiers follow DataFusion: an unquoted name is folded to lower case
  (`SELECT Host FROM Cpu` reads column `host` of table `cpu`, and `v AS V`
  answers `"v"`), a double-quoted one is exact (`"Host"`), and `"..."` is
  never a string — `WHERE k = "a"` compares with column `a`, and a name that
  needs its quotes (`"a b"`, `"ho""st"`) is a column too, printed quoted in
  the engine's "No field named" error. `'...'` is a string, a doubled quote
  one quote; `E'...'` or `e'...'` a string with backslash escapes
  (`E'it\\'s'`, `E'a\\nb'`, `E'\\x41'`), read as the engine's tokenizer reads
  them. (InfluxQL identifiers are
  case-sensitive and are not folded.) The subset:

    * `SELECT * FROM measurement`
    * Rows come back in time order when no `ORDER BY` says otherwise. The
      engine's own order then is not defined: it sorts what it reads by the
      tags in the order they were first written and then by time, but the
      blocks it holds that data in decide which comes first, and the same
      rows written in separate requests, or filtered by a tag, come back in
      another order (verified). Order is something to ask for with `ORDER BY`
      in a test that is to hold against the engine.
    * `SELECT col1, col2 [, ...] FROM measurement` with optional `AS alias`
      (projects fields and tags; `time` is selectable). `time` and
      `DATE_BIN` buckets are `DateTime` values with microsecond precision,
      the same as the HTTP and Flight transports return; compare them with
      `DateTime.compare/2` or a six-digit sigil (`~U[... .000000Z]`).
      A projected column may be an arithmetic expression
      (`(bid + ask) / 2 AS mid`; `+ - * / %` and unary minus, `%` taking the
      dividend's sign); a null operand makes the column null
      (omitted). `ORDER BY` may name a projected alias.
    * A select item with no alias is named as the engine names it: a column
      by its name, anything else by the engine's rendering over the table
      (or its alias) as the qualifier: `sum(m.v * Int64(2))`, `count(*)`,
      `count(DISTINCT m.h)`, `m.v + Int64(1) * Int64(2)`, `Int64(1)`,
      `Utf8("x")`, `$p`, `first_value(m.v) ORDER BY [m.time ASC NULLS
      LAST]`, `selector_first(m.v,m.time)[value]`, `date_bin(...)`; a `CAST`
      is not part of a name. A name that depends on which side of a `CROSS
      JOIN` holds a column, and two items with the same name (which the
      engine refuses), are refused by name. `ORDER BY` finds such an item by
      its position, its name in quotes, or the aggregate it repeats.
    * `WITH name AS (<select>)[, name AS (<select>)] <select>` — non-recursive
      CTEs. Each body is a query in this subset, run in order over the store
      or an earlier CTE; the final `SELECT` may read from any of them
      (`FROM w`). A CTE's output columns are its fields (`time` stays
      `time`).
    * `FROM a CROSS JOIN b` — every row of `a` paired with every row of `b`
      (the usual use is broadcasting a one-row CTE such as a median across
      the rows it screens). A column present on both sides is refused as
      ambiguous, because qualifiers are dropped and the two could not be
      told apart; the engine refuses the unqualified reference too. A shared
      column written with a qualifier (`a.v`) is refused by name, since the
      engine resolves it to a side. Other
      joins, set operations (`UNION`, `INTERSECT`, `EXCEPT`), subqueries and
      window functions are rejected by name rather than silently ignored.
    * Expressions, answered as the engine does (verified against InfluxDB 3
      Core, bodies of its errors included): `CASE`, `COALESCE`, `NULLIF`,
      `GREATEST`, `LEAST`; `lower`, `upper`, `length`, `substr`,
      `starts_with`; `sqrt`, `ln`, `log`, `pow`; `IS [NOT] DISTINCT FROM`,
      `IS [NOT] TRUE|FALSE`; a `SELECT` with no `FROM` (`SELECT 1 + 1 two`);
      an alias with no `AS` (`SELECT n a`); an expression of aggregates
      (`sum(n) / count(n)`), a `GROUP BY` expression, and `HAVING` with a
      comparison. These work in `WHERE` too.
    * `information_schema.tables`, `.columns` and `.schemata`, `SHOW TABLES`
      and `SHOW COLUMNS FROM t`, and the qualified names `iox.t` and
      `public.iox.t`. Another schema or catalog is the engine's "table not
      found".
    * A statement the engine's parser rejects (an empty `WHERE`, a trailing
      `ORDER BY`, a missing operand, an unclosed parenthesis) answers with
      the parser's own message and position, and a `WHERE` that is not a
      boolean, `LIKE` over a time, and `GROUP BY ()` with the planner's.
    * Refused by name, because the double does not model them: `date_trunc`,
      `extract` / `date_part`, `INTERVAL` arithmetic and the string form of
      `date_bin`, `date_bin_gapfill` with `locf` / `interpolate`,
      `approx_percentile_cont` and `approx_median`, window functions, `JOIN`
      other than `CROSS JOIN`, `UNION` / `INTERSECT` / `EXCEPT`, subqueries,
      `FROM (VALUES ...)`, `ROLLUP` / `CUBE` / `GROUPING SETS`, table
      functions, the `system.*` tables and the other `information_schema`
      views, `SHOW` other than `TABLES` and `COLUMNS`, `concat`, `trim`,
      `replace`, `bool_and`, `array_agg`, `FILTER (WHERE ...)`, a `HAVING`
      that is no comparison or has no `GROUP BY`, `COALESCE` of text with a
      number, and a comparison of `time` inside a select item. The last
      digit of `var_*` and `stddev*` can differ from the engine's, whose
      result depends on how it splits the rows into batches.
    * Table qualifiers and aliases: `FROM q AS w` / `FROM q w`, and
      `w.time` in any clause (or `q.time` with no alias: the engine knows an
      aliased table by the alias alone). One table per query, so the prefix
      is dropped; an unknown column is named as it was written (`w.nosuch`),
      and a quoted qualifier that differs in case (`"Q".bid`) is another
      relation, with the engine's hint about case.
    * `WHERE` with `=`, `!=` / `<>`, `<`, `<=`, `>`, `>=`, combined with
      `AND`, `OR`, `NOT` and parentheses (`AND` binds tighter than `OR`, as
      in SQL). A quoted literal is always a **string**, exactly as in
      InfluxDB v3: `'08338636'` keeps its leading zero and matches a string
      tag, and comparing it against a numeric field compares the field's
      text rendering (so `amount >= '1000.00'` is a lexical comparison —
      DataFusion casts the numeric side to Utf8). The other way round, a
      string column against a bare number compares the number's text
      rendering, also lexically (`rack = 2` matches the tag `"2"`; `rack > 3`
      does not match `"10"`). Bare literals (`42`, `1.5`, `true`) are typed
      and compare numerically against numeric fields. Either side may be an
      arithmetic expression over columns (`price <= med * 3`,
      `2 * price > volume`); a bare word is a column reference, as in SQL.
      A column that no row has — named anywhere: `SELECT`, an aggregate,
      `WHERE`, `GROUP BY`, `ORDER BY`, `DISTINCT` — is the engine's schema
      error ("No field named prod", HTTP 500), which is what a typo or a
      forgotten pair of quotes produces in production. The first one the
      engine meets is the one it names (`WHERE`, the select list, `ORDER BY`,
      `GROUP BY`, `DISTINCT ON`), and the fields it lists are the table's,
      each qualified and sorted by its bytes (`m.host, m."Zed", m.time`),
      preceded for `ORDER BY` and `GROUP BY` by the select list's own
      fields; a CTE lists its columns in the order it selects them. A
      double-quoted name in the select list is a column too (`"a b"`,
      `count("a b")`). With no rows a table's schema is unknown and nothing
      is checked; a CTE's columns are known. `col = NULL` (a `nil`
      param) is never true. Logic is SQL's three-valued logic: a comparison
      with a null operand is unknown, `NOT` keeps it unknown, and only a true
      predicate keeps the row, so `NOT (rack = '1')` does not return rows
      without a `rack`. A boolean column is itself a predicate (`WHERE b`,
      `NOT b`); any other bare column is the engine's planning error
      ("Cannot create filter with non-boolean predicate 't.n' returning
      Int64").
    * What the engine's simplifier removes before a row is read is not run:
      `x AND false`, `x OR true`,
      the absorption `A AND (A OR B)`, a comparison with a NULL literal, and
      `x = x` or `x IS NULL` of a constant. An `AND` or an `OR` whose right
      operand fails for a row the left one leaves out (`j <> 0 AND 100 / j >
      1`) is refused by name: the engine runs it over a batch of rows, and
      whether it meets that row depends on how it batches them. An integer
      literal past `UInt64` is a double, as on the engine, and a decimal
      expression compared with a float past `1e20` is its cast error.
    * `WHERE col IN (v1, v2, ...)` and `WHERE col NOT IN (v1, v2, ...)` — each
      item a literal, a column or an expression, as in SQL (a bare word is
      a column reference, never a string)
    * A constant in any select list (`0.0 AS volume`, `'x' AS label`, `NULL`);
      a number is typed as the engine types it: an integer is `Int64`, one
      above `Int64`'s range `UInt64`, one above that a double (`-` directly
      before a number is part of it, but `-(9223372036854775808)` negates a
      `UInt64`, which the engine refuses, as it does `-$p` for a
      non-negative integer parameter); a number past the double range is a
      JSON `null` that is there (`%{"a" => nil}`), named `Float64(inf)` when
      it has no alias. A column the store holds as `UInt64` (`5u`) has that
      type in an expression, as a literal or a parameter does: it divides by
      an `Int64` as a decimal truncated to four places (`u / 2` is `2.5`),
      by a `UInt64` as an integer, adds to an `Int64` as a decimal, wraps at
      2^64 with another `UInt64`, and cannot be negated (the engine's
      planning error); a decimal past 38 digits, and the mean of decimals, are
      refused by name. The magnitude of the `Int64` minimum, and its
      negation when it is folded as a constant, close the connection
      mid-response.
    * `WHERE col IS NULL` and `WHERE col IS NOT NULL`
    * `WHERE col [NOT] BETWEEN low AND high` (inclusive; `time` too)
    * `WHERE col [NOT] LIKE 'pattern'` and `ILIKE` (`%` any run, `_` one
      character, a backslash makes the next character literal — `'al\\%%'`; `LIKE` is
      case-sensitive, `ILIKE` is not). `LIKE` over a
      numeric column is the engine's planning error, reproduced.
    * `WHERE time <op> <comparand>` — exactly what InfluxDB 3 accepts against
      a Timestamp: a quoted datetime or date as Arrow reads it
      (`'2026-03-31T12:00:00Z'`; a space or `t` for the `T`, a fraction of
      any length, a zone as `Z`, `+01:00`, `+0100`, `+01`, or a name of the
      time zone database that the double can read: `UTC`, `GMT`, `Zulu`,
      `UCT`, `Universal`, `Greenwich`, `GMT0`, `GMT+0`, `GMT-0` and the same
      under `Etc/`, `Etc/GMT+1` to `Etc/GMT+12` (the sign is inverted) and
      `Etc/GMT-1` to `Etc/GMT-14`, `EST`, `MST` and `HST`; a second of `:60`
      is the start of the next minute; `'2026-03-31'` is midnight UTC),
      `now()` offset by `+`/`-`
      `INTERVAL 'N unit'` terms (`now() - INTERVAL '5 minutes'`), `NULL` or a
      `$param`. A bare integer (`time > 1700000000`) is rejected as
      DataFusion rejects it ("Cannot infer common argument type for
      comparison operation Timestamp(ns) > Int64"), rather than silently
      matching nothing. A string Arrow cannot read — an integer-as-string
      too — is the optimizer's 500 in Arrow's words ("Error parsing
      timestamp from 'abc': timestamp must contain at least 10
      characters"), raised after the planner's own errors, and an instant
      outside the nanosecond range is its overflow error. A null compares as
      unknown, and so is `NULL = time`. A zone name of the database whose
      offset changes with the date (`Europe/Paris`) is refused by name.
      A `WHERE` whose top-level conjuncts on `time` leave no instant
      (`time > X AND time < X`, `BETWEEN` with reversed bounds, adjacent
      exclusive bounds, `now()` against itself) is the planner's 500
      "provided filters on time column did not produce a valid set of
      boundaries", in the engine's order: after the schema and type errors
      and the optimizer's (an unreadable time string, a negative `LIMIT`),
      and not for an `OR`, `LIMIT 0`, `time IS NULL`, a constant false, or two
      different instants that `time` equals.
    * `SELECT DISTINCT col[, col ...] FROM measurement` (sorted combinations;
      `ORDER BY` must name a selected column, as in DataFusion). An all-null
      combination is a row too (`%{}`).
    * `SELECT DISTINCT ON (col[, col ...]) ...` over plain or projected
      columns (or `*`): the first row per distinct key after `ORDER BY`,
      then `LIMIT` / `OFFSET` — `ORDER BY k, time DESC` is the latest row
      per `k`. As on the engine, an `ORDER BY` must start with the `ON`
      columns (400), resolves against the table rather than select aliases
      (500), and aggregates or `GROUP BY` are refused (405). Without
      `ORDER BY` the engine's choice and order are unspecified. An
      expression in `ON` (`DATE_BIN(...)`) is refused by name.
    * `ORDER BY a [ASC|DESC][, b [ASC|DESC] ...]` — each term `time`, a
      column, an output alias, or (on raw and projected rows) an expression
      such as `CAST(level AS INTEGER) DESC`; every term applies, each with
      its own direction. Nulls sort last ascending and first descending,
      unless a term says `NULLS FIRST` / `NULLS LAST`.
    * `CAST(expr AS BIGINT | INT8 | INTEGER | INT | INT4 | SMALLINT | INT2 |
      TINYINT | DOUBLE | VARCHAR | STRING)`
      and DataFusion's `col::TYPE` shorthand, wherever an expression is
      allowed: `WHERE` (`CAST(level AS INTEGER) <= 20` compares a numeric tag
      numerically), `BETWEEN`, `LIKE`, projections, aggregates, arithmetic
      and `ORDER BY`. Text converts only when the whole string is a number,
      a float truncates to an integer, a number renders to text, null stays
      null. A cast that cannot be performed (`'abc'` to `INTEGER`, `time` to
      `INTEGER`) makes InfluxDB 3 Core drop the connection mid-response,
      which `Client.HTTP` reports as `{:error, {:connection_error,
      %Mint.TransportError{reason: :closed}}}`, and so does the double.
      As on the engine, `INTEGER`/`INT` is Int32, `SMALLINT` Int16 and
      `TINYINT` Int8: arithmetic of two such values wraps at the wider
      width, and a constant that does not fit is the optimizer's HTTP 500
      "Can't cast value". `BIGINT` is Int64. `FLOAT`/`REAL` (Float32),
      unsigned and `DECIMAL`, `BOOLEAN` and `TIMESTAMP` targets are refused
      by name.
    * `LIMIT n` and `OFFSET m`, in either order — `OFFSET` skips rows before
      `LIMIT` takes them, on plain, projected, grouped and `DISTINCT` rows
      alike; `LIMIT 0` returns no rows; a negative or non-numeric
      limit is rejected, as the engine rejects it
    * `$param` placeholders via `params: %{name: value}` (or `%{"name" => value}`)
      in opts; the key is the name without `$`, as the engine reads it (a
      `"$name"` key binds nothing on either client). A
      `DateTime`, `NaiveDateTime` or `Date` param renders as the ISO-8601
      string Jason sends over HTTP, so `time >= $start` works the same on
      both clients; an integer param against `time` is rejected on both.
    * `DATE_BIN(INTERVAL 'N unit', time)` time bucketing
    * Aggregate functions: `AVG`, `SUM`, `COUNT`, `MIN`, `MAX`, `MEDIAN`
      (the middle value; for an even count the mean of the two middle
      values in the column's type, so two integers average with integer
      division), `STDDEV` / `STDDEV_SAMP` (sample), `STDDEV_POP`, `VAR` /
      `VAR_SAMP` (sample), `VAR_POP`. The argument may be an arithmetic
      expression over fields
      and numeric literals (`SUM(value * value)`, `AVG(bid + ask)`); two
      integer operands divide as integers (`3 / 2 = 1`), as in DataFusion.
      `Int64` `+`, `-`, `*` and unary minus wrap in two's complement, as the
      engine's do (`9223372036854775807 + 1` is the minimum, `-` of the
      minimum is itself).
      `round` keeps the sign of a zero it leaves (`round(-0.3)` is `-0.0`);
      `trunc(x)` cuts toward zero and `trunc(x, n)` rounds to `n` places, as
      the engine's does. An integer divided by zero, or the minimum by -1,
      closes the connection mid-response, as on the engine (`{:error,
      {:connection_error, %Mint.TransportError{reason: :closed}}}`). A float
      that overflows, or is divided by zero, is IEEE infinity or NaN: `null`
      in a response, and an infinity compares as a number greater than every
      finite one (`SUM` and `AVG` of floats that overflow are `null`). A
      comparison or ordering of a NaN is refused by name, since the engine
      orders a NaN by a sign the CPU that computed it chooses. `SUM` of
      `Int64`s wraps. A sample
      statistic over one value is null. `COUNT(DISTINCT col)` counts
      distinct non-null values. `MIN(time)`, `MAX(time)` and `COUNT(time)`
      work (a `DateTime` result); every other aggregate over `time`, and
      any arithmetic on it, is rejected as DataFusion rejects it.
    * Selector functions: `selector_first|last|min|max(field, time)['value']`
      and `['time']`; without a subscript, the engine's struct
      `%{"time" => %DateTime{}, "value" => v}`
    * Ordered aggregates: `first_value(field ORDER BY col [ASC|DESC])` and
      `last_value(field ORDER BY col [ASC|DESC])` — the InfluxDB v3 SQL
      (DataFusion) spelling. The `ORDER BY` is required: without it the real
      engine returns an arbitrary row from the group, which the double cannot
      reproduce, so it rejects the query rather than certify a
      non-deterministic result. InfluxQL-style `FIRST(f, t)` / `LAST(f, t)`
      are rejected because InfluxDB v3 SQL has no such functions.
    * `GROUP BY DATE_BIN(INTERVAL 'N unit', time)` — optional. When omitted,
      aggregate queries return a single scalar row (`COUNT` over an empty
      result set is `0`; other aggregates return `nil`).
    * `GROUP BY <col>[, <col>...]` — bucket points by tag/field values,
      with or without an aggregate (`SELECT host FROM m GROUP BY host` is
      one row per host). Bare column names (with optional `AS alias`) are
      valid in the `SELECT` list only when grouped; a projected column that
      is neither grouped nor aggregated is the engine's planning error
      ("must appear in the GROUP BY clause or must be part of an aggregate
      function"). `ORDER BY` applies to grouped rows too. Grouping columns
      combine with `DATE_BIN` (a row per bucket per value).
    * A `GROUP BY` item may be a select alias (`GROUP BY bucket`) or a
      1-based position (`GROUP BY 1, 2`), and an `ORDER BY` item a position
      (`ORDER BY 2 DESC`), as DataFusion resolves them; a position outside
      the select list is the engine's planning error.
    * Interval units: `seconds`, `minutes`, `hours`, `days`

  A null column is omitted from the row rather than present as `nil`,
  exactly as InfluxDB 3's JSON and JSONL responses do (`COUNT` is `0`, never
  null).

  `format:` is answered as `Client.HTTP` answers it — `:csv` rows carry
  the engine's CSV strings, `:parquet` is refused by name, an unknown
  format is the engine's 400.

  Anything outside this subset is rejected with
  `{:error, %{status: 400, body: "Client.Local: ..."}}`. The `Client.Local:`
  prefix marks the rejection as a limitation of the test double rather than
  of InfluxDB — the real engine may well accept the query. `check_sql/1`
  answers the same question without executing, so a test can skip with a
  reason and the query can be covered in the integration tier instead.

  ## SQL Param Types

  `params:` is a map or a keyword list (or `nil`), sent as the JSON object of
  the request body: a value is data and is never spliced into the SQL text.
  A parameter is a `nil`, boolean, number, string, atom (its name), `Date`,
  `Time`, `NaiveDateTime`, `DateTime` (ISO-8601 strings) or a `Decimal` (a
  JSON number, when the optional `:decimal` dependency is loaded). A
  number is read as the engine's JSON parser reads it — an integer outside
  `Int64`/`UInt64` is a float, and one past the float range is the engine's
  `number out of range` 400 — and an object or an array is its 400 too;
  see `InfluxElixir.Client.QueryParams`.

  ## Flux Query Support (v2 profile)

  `query_flux/3` runs a pipeline `from(bucket: "b") |> range(...) |> ...`
  and applies every stage or refuses the query by name:

    * `from(bucket: "b")` — first; a bucket that does not exist is the
      engine's 404
    * `range(start:[, stop:])` — required, once; Unix seconds, RFC3339,
      a duration from now (`-1h`, `-30m`, `-7d`, `-2w`) or `now()`
    * `filter(fn: (r) => ...)` — `r.key` or `r["key"]` compared with
      `== != < <= > >=` against a string, number or boolean, combined with
      `and`, `or`, `not` and parentheses
    * `first()`, `last()`, `min()`, `max()` — the selected row per table
    * `mean()`, `sum()`, `count()` — one row per table, without `_time`
    * `limit(n:[, offset:])` — per table
    * `yield(name: "x")` — names the result

  Any other function (`aggregateWindow`, `pivot`, `group`, `sort`, ...),
  arguments to the selectors and aggregates, or a predicate or time the
  double does not model is `{:error, %{status: 400, body: json}}` whose
  message starts `Client.Local: unsupported Flux`.

  ## Write Bodies

  `gzip: true` (the HTTP client's `Content-Encoding: gzip`, which
  `InfluxElixir.write/3` sets whenever it compresses) decompresses the
  payload, and on InfluxDB 3 a payload that is not UTF-8 is refused (400
  `body content is not valid utf8: ...`; a bad gzip stream is 400
  `error decoding gzip stream: ...`, InfluxDB 2's 500). A gzip payload
  without `gzip: true` is line protocol to the engine, and so here.

  ## Timestamp Precision

  Pass `precision:` in opts to say what unit numeric timestamps are in.
  The spellings are the engine's, verified: InfluxDB 3 (`:v3_core`,
  `:v3_enterprise`) takes `ns | n | nanosecond | us | u | microsecond |
  ms | millisecond | s | second | auto` as an atom or a string, where
  `auto` guesses the unit from the magnitude (below 5e9 seconds, 5e12
  milliseconds, 5e15 microseconds, else nanoseconds); anything else is the
  engine's 400 `serde error: unknown variant`. InfluxDB 2 (`:v2`) takes
  `ns | us | ms | s` and the long names `HTTP.write/3` maps onto them, and
  answers 400 `invalid precision` to the rest. Default: nanoseconds.
  """

  @behaviour InfluxElixir.Client

  alias InfluxElixir.Client.Local.{
    Admin,
    DatabaseRules,
    FluxQuery,
    InfluxQLQuery,
    Scope,
    SQLParser,
    SQLQuery,
    Store,
    Writes
  }

  @typedoc "A parsed point: fields and tags as string-keyed maps, timestamp in ns."
  @type point_map :: %{
          required(:measurement) => binary(),
          required(:tags) => %{binary() => binary()},
          required(:fields) => %{binary() => term()},
          required(:timestamp) => integer() | nil,
          optional(:unreadable) => true
        }

  @type profile :: :v3_core | :v3_enterprise | :v2

  @type conn :: %{
          required(:table) => :ets.table(),
          required(:database) => binary() | nil,
          required(:profile) => profile(),
          optional(:org) => binary()
        }

  # ---------------------------------------------------------------------------
  # Connection lifecycle (behaviour callbacks)
  # ---------------------------------------------------------------------------

  @impl true
  @spec init_connection(keyword()) :: {:ok, conn()}
  def init_connection(config) do
    start(
      database: Keyword.get(config, :database),
      databases: Keyword.get(config, :databases, []),
      profile: Keyword.get(config, :profile, :v3_core),
      org: Keyword.get(config, :org)
    )
  end

  @impl true
  @spec shutdown_connection(conn()) :: :ok
  def shutdown_connection(conn), do: stop(conn)

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Starts a new LocalClient instance with isolated ETS storage.

  ## Options

    * `:database` - connection-level default database name. Used when the
      caller does not pass `database:` in opts. Pre-created automatically.
    * `:databases` - list of database names to pre-create (default: `[]`).
      Without `:database`, the first is the default, as in `Client.HTTP`.
      With neither there is no default: an operation that needs a database
      is `{:error, :no_database_specified}`, as over HTTP.
    * `:org` - the organisation the buckets belong to (`:v2`; default
      `"local"`). A bucket's `"orgID"` is derived from it, so it is stable
      for a connection and differs between organisations.

  On the v3 profiles each name must be one InfluxDB 3 accepts, and
  `:v3_core` holds at most 5; `start/1` raises `ArgumentError` with the
  engine's message otherwise.
    * `:profile` - InfluxDB version profile to emulate. Determines which
      operations are available. Operations outside the profile return
      `{:error, :unsupported_operation}`. Valid values:
      - `:v3_core` (default) — write, SQL, InfluxQL, database CRUD, admin tokens
      - `:v3_enterprise` — everything in v3_core plus resource tokens
        (`create_token/3` with `:permissions`)
      - `:v2` — write, Flux, bucket CRUD

  ## Examples

      iex> {:ok, conn} = InfluxElixir.Client.Local.start(databases: ["mydb"])
      iex> conn.profile
      :v3_core

      iex> {:ok, conn} = InfluxElixir.Client.Local.start(profile: :v2)
      iex> conn.profile
      :v2

      iex> {:ok, conn} = InfluxElixir.Client.Local.start(database: "metrics")
      iex> conn.database
      "metrics"
  """
  @spec start(keyword()) :: {:ok, conn()}
  def start(opts \\ []) do
    profile = Keyword.get(opts, :profile, :v3_core)

    unless Scope.profile?(profile) do
      raise ArgumentError,
            "invalid profile: #{inspect(profile)}. " <>
              "Must be one of: :v3_core, :v3_enterprise, :v2"
    end

    # As `Client.HTTP.init_connection/1`: without `:database` the first of
    # `:databases` is the default. With neither there is none, and an
    # operation that needs one is `{:error, :no_database_specified}` — no
    # "default" database the server does not have.
    listed = Keyword.get(opts, :databases, [])
    database = Keyword.get(opts, :database) || List.first(listed)
    databases = Enum.uniq(listed ++ List.wrap(database))

    if profile != :v2, do: DatabaseRules.check_start!(databases, profile)

    # A public ETS store: every
    # mutation is one insert or delete of its own key, so no process is
    # needed to make concurrent writers safe.
    org = Keyword.get(opts, :org) || "local"
    {:ok, %{table: Store.new(databases), database: database, profile: profile, org: org}}
  end

  @doc """
  Reports whether the SQL subset can express `sql`, without executing it.

  Returns `:ok` or the same `{:error, %{status: 400, body: "Client.Local: ..."}}`
  that `query_sql/3` would return. Use it to skip a test *with a reason*
  instead of tagging it excluded:

      case InfluxElixir.Client.Local.check_sql(sql) do
        :ok -> run_against_local(sql)
        {:error, %{body: why}} -> ExUnit.Callbacks.on_exit(fn -> :ok end); flunk(why)
      end

  Queries outside the subset (joins, window functions, `UNION`, subqueries,
  date and time functions, ...) belong in an integration test against a real
  InfluxDB; see the testing guide.
  """
  @spec check_sql(binary()) :: :ok | {:error, %{status: 400, body: binary()}}
  def check_sql(sql) do
    case SQLParser.parse_select(sql) do
      {:ok, _query} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns `true` if the given operation is supported by the connection's profile.
  """
  @spec supports?(conn(), atom()) :: boolean()
  def supports?(%{profile: profile}, operation) do
    Scope.supports?(%{profile: profile}, operation)
  end

  @doc """
  Stops a LocalClient instance and cleans up its ETS table.

  Safe to call multiple times; a no-op if the table is already deleted.
  """
  @spec stop(conn()) :: :ok
  def stop(%{table: table}), do: Store.drop(table)

  # ---------------------------------------------------------------------------
  # Write
  # ---------------------------------------------------------------------------

  @doc """
  Parses line protocol binary and stores the resulting points in ETS.

  The `database` is read from `opts[:database]`. If the database does not
  exist an `{:error, %{status: 404, body: ...}}` is returned. If line protocol
  cannot be parsed an `{:error, %{status: 400, body: ...}}` is returned.

  `gzip: true` says the payload is gzip-compressed (see "Write Bodies" in
  the moduledoc). Pass `precision:` to say what unit numeric timestamps are in (default
  nanoseconds); see "Timestamp Precision" in the moduledoc for the
  spellings each profile accepts and `auto`.
  """
  @impl true
  @spec write(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.write_result()
  def write(conn, payload, opts \\ []), do: Writes.write(conn, payload, opts)

  # ---------------------------------------------------------------------------
  # SQL Query
  # ---------------------------------------------------------------------------

  @doc """
  Executes a SQL query against the stored points and returns rows shaped as
  InfluxDB 3 returns them.

  The SQL subset, and what the double refuses by name, is described under
  "SQL" in the moduledoc; `check_sql/1` answers without running. `$name`
  placeholders take `params: %{"name" => value}` (or a keyword list).
  """
  @impl true
  @spec query_sql(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  def query_sql(conn, sql, opts \\ []), do: SQLQuery.query_sql(conn, sql, opts)

  @doc """
  Executes a SQL query and returns results as a lazy `Stream`.

  Delegates to `query_sql/3` then wraps the list in a stream.

  Mirrors the error semantics of the HTTP client's streaming query:
  because the return type is an `Enumerable.t()`, errors cannot be returned as a
  tuple. Instead a failure — an underlying query error or an operation the
  connection's profile does not support — is raised as an
  `InfluxElixir.StreamError` when the stream is enumerated, never swallowed as an
  empty result. This keeps `Client.Local` a faithful drop-in test double for
  `Client.HTTP`, so consumer code that rescues `InfluxElixir.StreamError` can be
  exercised against it.
  """
  @impl true
  @spec query_sql_stream(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: Enumerable.t()
  def query_sql_stream(conn, sql, opts \\ []), do: SQLQuery.query_sql_stream(conn, sql, opts)

  @doc """
  Executes a SQL statement as InfluxDB 3 does (verified against Core).

    * `SELECT` / `WITH ... SELECT` run as `query_sql/3` and return
      `{:ok, rows}`.
    * `DELETE FROM m [WHERE ...]` on `:v3_enterprise` removes the matching
      points and returns `{:ok, %{"rows_affected" => n}}`. Identifiers
      follow SQL's rules, as in a `SELECT` (`DELETE FROM "Cpu"`), and a
      table whose every point was deleted stays, answering no rows.
      (Not verified: no Enterprise server was available.)
    * Everything else is refused with the engine's answer: `DELETE`,
      `INSERT` and `UPDATE` are 400 `Error during planning: DML not
      supported: Delete | Insert Into | Update`; `CREATE TABLE | VIEW |
      DATABASE` and `DROP TABLE | VIEW` are 400 `Error during planning: DDL
      not supported: CreateMemoryTable | CreateView | CreateCatalog |
      DropTable | DropView`; any other statement (`ALTER`, `TRUNCATE`, ...)
      is 405 `This feature is not implemented: Unsupported SQL statement:
      <sql>`.
  """
  @impl true
  @spec execute_sql(InfluxElixir.Client.connection(), binary(), keyword()) ::
          {:ok, map() | [map()]} | {:error, term()}
  def execute_sql(conn, sql, opts \\ []), do: SQLQuery.execute_sql(conn, sql, opts)

  # ---------------------------------------------------------------------------
  # InfluxQL and Flux queries
  # ---------------------------------------------------------------------------

  @doc """
  Executes an InfluxQL query.

  Answers what InfluxDB 3 answers, verified against the engine:

    * `SHOW DATABASES` — `%{"iox::database" => name, "deleted" => false}`
    * `SHOW MEASUREMENTS`, `SHOW TAG KEYS`, `SHOW FIELD KEYS`, `SHOW TAG
      VALUES` and `SHOW RETENTION POLICIES`, with `ON`, `FROM` (names and
      `/re/`), `WITH MEASUREMENT`, `WITH KEY`, `WHERE`, `LIMIT` and `OFFSET`,
      answered from the schema in the engine's order, over the last 24 hours
      unless the `WHERE` bounds `time`; the engine's parse errors at their
      positions
    * `SELECT ...` — InfluxQL, not SQL. Rows have `iox::measurement` and
      `time` on every row, in time order; aggregates are stamped with the
      `WHERE`'s lower bound on `time`; an unknown column or measurement is
      `{:ok, []}`; `LIMIT` and `OFFSET` apply per series. The `WHERE` follows
      InfluxQL (a missing tag is `''`, a missing column null, regexes,
      durations, and integers or durations as nanoseconds next to `time`). The
      select list takes columns, `*`, `*::field`, `/re/`, arithmetic, the
      aggregates `MEAN SUM COUNT MIN MAX FIRST LAST MEDIAN SPREAD STDDEV MODE
      PERCENTILE INTEGRAL`, `TOP` and `BOTTOM`, `F(*)`, the math functions
      `ABS ROUND FLOOR CEIL SQRT LN LOG POW` and the transforms `DERIVATIVE
      NON_NEGATIVE_DERIVATIVE DIFFERENCE NON_NEGATIVE_DIFFERENCE CUMULATIVE_SUM
      MOVING_AVERAGE ELAPSED`; `FROM` lists names and `/re/`; `GROUP BY` takes
      tags, fields, `*`, `/re/` and `time(every[, offset])` with `fill(...)`;
      then `ORDER BY time`, `LIMIT`, `OFFSET`, `SLIMIT`/`SOFFSET` (the
      engine's 405) and `tz('UTC')`.

  Anything outside this subset (`INTO`, subqueries, a `tz()` of another zone,
  and the like) is refused by name with `{:error, %{status: 400, body:
  "Client.Local: unsupported InfluxQL (...)"}}`, never answered wrongly. The
  "Testing with LocalClient" guide's InfluxQL section lists the behaviour in
  full.
  """
  @impl true
  @spec query_influxql(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  def query_influxql(conn, influxql, opts \\ []),
    do: InfluxQLQuery.query_influxql(conn, influxql, opts)

  @doc """
  Executes a Flux query as InfluxDB 2 does. The pipeline starts with
  `from(bucket: "b")` and takes `range` (required), `filter`, `first`,
  `last`, `min`, `max`, `mean`, `sum`, `count`, `limit` and `yield`; the
  "Flux Queries" section of the "Testing with LocalClient" guide has the
  detail. Every stage is applied or the query is refused
  (`{:error, %{status: 400, body: json}}` naming it) — a stage is never
  skipped. Rows use the engine's long shape, one per field value:

      %{"result" => "_result", "table" => 0, "_start" => %DateTime{},
        "_stop" => %DateTime{}, "_time" => %DateTime{}, "_measurement" => "cpu",
        "_field" => "value", "_value" => 1.0, "host" => "web01"}

  A bucket that does not exist is the engine's 404, a `range` with no time
  in it its 400, and times that do not fit 64-bit nanoseconds wrap as they
  do there. A query that filters on `r._measurement` reads only the
  measurements it names.
  """
  @impl true
  @spec query_flux(InfluxElixir.Client.connection(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  def query_flux(conn, flux, opts \\ []), do: FluxQuery.query_flux(conn, flux, opts)

  # ---------------------------------------------------------------------------
  # Database admin
  # ---------------------------------------------------------------------------

  @doc """
  Creates a named database in this local instance.

  Creating an existing database is `:ok` (the engine's 409, which
  `Client.HTTP` treats as success). A name the engine refuses is its 400,
  and a sixth database on the `:v3_core` profile its 422. `retention:` must be a
  duration the engine reads (`"30d"`, `"1h 30m"`, `"1.5h"`, `"0"`), or it
  is the engine's 400. The database keeps it, in whole seconds, and applies it
  as InfluxDB 3 does (verified against Core):

    * a write is never refused for its age: a point older than the retention
      is accepted (204, with or without `accept_partial`) and stored
    * a read sees only the chunks that still hold a point at or after
      `now - retention`. A chunk is one table's points within one 10-minute
      window (a multiple of 600 s since the epoch), so an expired point is
      shown for as long as the newest point of its chunk is, and hidden with
      it. SQL, InfluxQL and `SHOW TAG VALUES` all read this way; the tables
      and columns an expired point created stay in the schema
      (`SHOW MEASUREMENTS`, `SHOW TAG KEYS`, `information_schema`)
    * the period is read in whole seconds (`1500ms` is `1s`, `100ms` is `0`),
      a month is 30.44 days and a year 365.25; a retention of `"0"` (or under
      a second) is zero, not none: every point before now is hidden. Omit
      `retention:` for data that never expires
    * `SHOW RETENTION POLICIES` prints it as `autogen` with the period in the
      engine's format (`1h0m0s`, `168h0m0s`, `30s`, `0s` for none)
    * creating a database that exists changes nothing, its retention
      included (the engine's 409, which `Client.HTTP` treats as success); the
      engine can change it (`PUT /api/v3/configure/database`) but this
      library has no call for it

  (A v2 bucket's `retention:` is applied differently: see `create_bucket/3`.)
  """
  @impl true
  @spec create_database(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_database(conn, name, opts \\ []), do: Admin.create_database(conn, name, opts)

  @doc """
  Returns the databases as maps with a single `"name"` key, sorted, with
  the engine's own `_internal` among them as InfluxDB 3 lists it.
  """
  @impl true
  @spec list_databases(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_databases(conn), do: Admin.list_databases(conn)

  @doc """
  Deletes a database from this local instance.

  Returns `{:error, %{status: 404, body: "the requested resource was not
  found: name"}}` — the engine's answer (verified) — if the database does
  not exist.
  """
  @impl true
  @spec delete_database(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_database(conn, name), do: Admin.delete_database(conn, name)

  # ---------------------------------------------------------------------------
  # Bucket admin (v2 compat)
  # ---------------------------------------------------------------------------

  @doc """
  Creates a named bucket in this local instance.

  `retention:` is the expiry in seconds (default `0`, none). InfluxDB 2
  refuses a period between 1 and 3599 seconds with a 500 `retention policy
  duration must be at least 1h0m0s` (verified), and so does this.
  A write of a point older than the retention is refused as the engine
  refuses it (see "Write" in the moduledoc), and the period sets how long the
  bucket's shard groups are. Creating an already-existing bucket is idempotent.
  """
  @impl true
  @spec create_bucket(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_bucket(conn, name, opts \\ []), do: Admin.create_bucket(conn, name, opts)

  @doc """
  Returns all buckets in this local instance as InfluxDB 2 lists them
  (verified against 2.7): `"id"`, `"orgID"` (stable for the connection's
  org), `"type"` (`"user"`; the engine's own `_tasks` and `_monitoring`
  buckets are not modelled), `"name"`, `"retentionRules"` (`[%{"type" =>
  "expire", "everySeconds" => n, "shardGroupDurationSeconds" => n}]`),
  `"createdAt"`, `"updatedAt"`, `"links"` and `"labels"`.
  """
  @impl true
  @spec list_buckets(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_buckets(conn), do: Admin.list_buckets(conn)

  @doc """
  Deletes a bucket from this local instance.

  Returns `{:error, %{status: 404, body: "bucket not found: name"}}` for a
  bucket that does not exist — InfluxDB 2 answers 404 (verified), which
  `InfluxElixir.Client.HTTP` reports with this body. The bucket's points and
  per-group schema go with it, so a bucket created again under the name
  starts empty and takes any field type.
  """
  @impl true
  @spec delete_bucket(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_bucket(conn, name), do: Admin.delete_bucket(conn, name)

  # ---------------------------------------------------------------------------
  # Token admin
  # ---------------------------------------------------------------------------

  @doc """
  Creates a named token as InfluxDB 3 does (verified against Core): an
  admin token, or with `:permissions` a resource token, on `:v3_enterprise`
  only (Core's 404 `Not found`). See `InfluxElixir.Admin.Tokens.create/3`
  for the options and the answers. Ids count up from 1 (the operator token
  `_admin` is 0) and are never reused; the secret is random.
  """
  @impl true
  @spec create_token(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def create_token(conn, name, opts \\ []), do: Admin.create_token(conn, name, opts)

  @doc """
  Deletes the token named `name` as InfluxDB 3 does: `:ok`, the engine's
  404 for a name no token has, its 405 for the operator token `_admin`.
  """
  @impl true
  @spec delete_token(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_token(conn, name), do: Admin.delete_token(conn, name)

  # ---------------------------------------------------------------------------
  # Health
  # ---------------------------------------------------------------------------

  @doc """
  Returns a passing health status in the shape `Client.HTTP` returns for
  the profile's server (verified): InfluxDB 3's `/health` answers a plain
  `OK`, which the HTTP client reports as `%{"status" => "pass"}`; InfluxDB
  2 answers JSON with `name`, `message`, `status`, `checks`, `version` and
  `commit` (here `"local"`).
  """
  @impl true
  @spec health(InfluxElixir.Client.connection()) ::
          {:ok, map()} | {:error, term()}
  def health(conn), do: Admin.health(conn)
end
