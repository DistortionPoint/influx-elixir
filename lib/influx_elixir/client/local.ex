defmodule InfluxElixir.Client.Local do
  @moduledoc """
  In-memory InfluxDB client for fast, isolated testing.

  Stores data in ETS tables, enabling safe `async: true` tests with full
  isolation between test instances. Each call to `start/1` creates an
  independent ETS table.

  Parses real line protocol on write, stores points as maps, and responds
  with realistic InfluxDB response formats on query. Parsing is split out:
  `InfluxElixir.Client.Local.LineProtocolParser` handles writes and
  `InfluxElixir.Client.Local.SQLParser` handles the SQL subset;
  `InfluxElixir.Client.Local.Store` owns the ETS table; this module
  owns profiles, the write rules and the InfluxQL and Flux paths; SQL execution is
  `InfluxElixir.Client.Local.SQLExecutor`.

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

  Each instance is one ETS table owned by `InfluxElixir.Client.Local.Store`,
  which alone knows the key layout. Every mutation is a single insert or
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
      value", and a field named twice is refused. See
      `InfluxElixir.Client.Local.LineProtocolParser` for the grammar.
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
  them. See `InfluxElixir.Client.Local.SQLIdentifiers` and
  `InfluxElixir.Client.Local.SQLLexer`. (InfluxQL identifiers are
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
      joins, set operations, `HAVING` and window functions are
      rejected by name rather than silently ignored.
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
    * What the engine's simplifier removes before a row is read is not run
      (`InfluxElixir.Client.Local.SQLSimplify`): `x AND false`, `x OR true`,
      the absorption `A AND (A OR B)`, a comparison with a NULL literal, and
      `x = x` or `x IS NULL` of a constant. An `AND` or an `OR` whose right
      operand fails for a row the left one leaves out (`j <> 0 AND 100 / j >
      1`) is refused by name: the engine runs it over a batch of rows, and
      whether it meets that row depends on how it batches them. An integer
      literal past `UInt64` is a double, as on the engine, and a decimal
      expression compared with a float past `1e20` is its cast error (see
      `InfluxElixir.Client.Local.SQLDecimal`).
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
  format is the engine's 400: see `InfluxElixir.Client.Local.Format`.

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
  see `InfluxElixir.Client.QueryParams` and `InfluxElixir.Client.Local.Format`.

  ## Write Bodies

  `gzip: true` (the HTTP client's `Content-Encoding: gzip`, which
  `InfluxElixir.write/3` sets whenever it compresses) decompresses the
  payload, and on InfluxDB 3 a payload that is not UTF-8 is refused; see
  `InfluxElixir.Client.Local.Body` for the engines' errors. A gzip payload
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

  alias InfluxElixir.Admin.TokenRequest
  alias InfluxElixir.Client.QueryParams

  alias InfluxElixir.Client.Local.{
    Body,
    DatabaseRules,
    Flux,
    Format,
    InfluxQL,
    LineProtocolParser,
    SQLExecutor,
    SQLIdentifiers,
    SQLLexer,
    SQLParser,
    SQLStatement,
    Store
  }

  @type point_map :: LineProtocolParser.point()

  @type profile :: :v3_core | :v3_enterprise | :v2

  @type conn :: %{
          required(:table) => Store.t(),
          required(:database) => binary() | nil,
          required(:profile) => profile(),
          optional(:org) => binary()
        }

  # Operations supported by each profile.
  # An operation not in the list returns {:error, :unsupported_operation}.
  @profile_capabilities %{
    v3_core: [
      :health,
      :write,
      :query_sql,
      :query_sql_stream,
      :execute_sql,
      :query_influxql,
      :create_database,
      :list_databases,
      :delete_database,
      :create_token,
      :delete_token
    ],
    v3_enterprise: [
      :health,
      :write,
      :query_sql,
      :query_sql_stream,
      :execute_sql,
      :query_influxql,
      :create_database,
      :list_databases,
      :delete_database,
      :create_token,
      :delete_token
    ],
    v2: [
      :health,
      :write,
      :query_flux,
      :create_bucket,
      :list_buckets,
      :delete_bucket
    ]
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
  engine's message otherwise (see `InfluxElixir.Client.Local.DatabaseRules`).
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

    unless Map.has_key?(@profile_capabilities, profile) do
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

    # A public ETS store (see `InfluxElixir.Client.Local.Store`): every
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

  Queries outside the subset (CTEs, joins, window functions, `median`, ...)
  belong in an integration test against a real InfluxDB; see the testing
  guide.
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
    operation in Map.fetch!(@profile_capabilities, profile)
  end

  @spec require_capability(conn(), atom()) ::
          :ok | {:error, :unsupported_operation}
  defp require_capability(conn, operation) do
    if supports?(conn, operation), do: :ok, else: {:error, :unsupported_operation}
  end

  # Mirrors HTTP's resolve_database/2: opts[:database], then the
  # connection-level default; neither is the HTTP client's error.
  @spec resolve_database(keyword(), conn()) ::
          {:ok, binary()} | {:error, :no_database_specified}
  defp resolve_database(opts, conn) do
    case Keyword.get(opts, :database) || Map.get(conn, :database) do
      nil -> {:error, :no_database_specified}
      database -> {:ok, database}
    end
  end

  # A query names a database the engine has (verified: SQL of any kind and
  # InfluxQL other than SHOW DATABASES answer 404 otherwise). `_internal`
  # exists on the engine, but its system tables are not modelled.
  @spec database_exists(Store.t(), binary()) :: :ok | {:error, map()}
  defp database_exists(table, database) do
    cond do
      Store.database?(table, database) ->
        :ok

      database == DatabaseRules.internal() ->
        {:error,
         %{
           status: 400,
           body: "Client.Local: the _internal database's system tables are not modelled"
         }}

      true ->
        {:error,
         %{
           status: 404,
           body: Jason.encode!(%{"error" => "query error: database not found: #{database}"})
         }}
    end
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
  def write(%{table: table, profile: profile} = conn, payload, opts \\ []) do
    with :ok <- require_capability(conn, :write),
         {:ok, database} <- resolve_database(opts, conn),
         # The engine's order (verified): the request's parameters, then
         # the body, then the database.
         {:ok, precision} <- normalize_precision(Keyword.get(opts, :precision), profile),
         {:ok, accept_partial} <- write_flag(opts, :accept_partial, true, profile),
         {:ok, _no_sync} <- write_flag(opts, :no_sync, false, profile),
         {:ok, text} <- Body.read(payload, Keyword.get(opts, :gzip, false) == true, profile),
         :ok <- ensure_database(table, database, profile) do
      case text
           |> LineProtocolParser.parse_lines(precision, dialect(profile))
           |> stamp_untimed() do
        {:ok, lines} when profile != :v2 and not accept_partial ->
          store_lines_atomically(table, database, lines)

        {:ok, lines} ->
          store_lines(table, database, lines, profile)

        # InfluxDB 2 answers 204 to an empty payload; InfluxDB 3 refuses it.
        {:error, _empty} when profile == :v2 ->
          {:ok, :written}

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Both engines give every line of one write that has no timestamp the
  # same one, the request's time (verified): untimed lines of one series in
  # one payload are one point, their fields merged and the last write
  # winning.
  @spec stamp_untimed({:ok, [LineProtocolParser.line_result()]} | {:error, term()}) ::
          {:ok, [LineProtocolParser.line_result()]} | {:error, term()}
  defp stamp_untimed({:ok, lines}) do
    now = Store.now_ns()

    {:ok,
     Enum.map(lines, fn
       {:ok, %{timestamp: nil} = point, number, line} ->
         {:ok, %{point | timestamp: now}, number, line}

       other ->
         other
     end)}
  end

  defp stamp_untimed(error), do: error

  # What `HTTP.write/3` plus the engine accept for `:precision`, verified:
  # InfluxDB 3 takes the spellings below verbatim (case-sensitive) and
  # answers 400 to anything else; InfluxDB 2 takes only `ns|us|ms|s`, which
  # `HTTP.write/3` maps the long names onto, and answers 400 to the rest.
  @v3_precisions %{
    "auto" => :auto,
    "s" => :second,
    "second" => :second,
    "ms" => :millisecond,
    "millisecond" => :millisecond,
    "u" => :microsecond,
    "us" => :microsecond,
    "microsecond" => :microsecond,
    "n" => :nanosecond,
    "ns" => :nanosecond,
    "nanosecond" => :nanosecond
  }

  @v2_precisions Map.take(
                   @v3_precisions,
                   ~w(ns nanosecond us microsecond ms millisecond s second)
                 )

  @spec normalize_precision(atom() | binary() | nil, profile()) ::
          {:ok, LineProtocolParser.precision()} | {:error, map()}
  defp normalize_precision(nil, _profile), do: {:ok, :nanosecond}

  defp normalize_precision(precision, :v2) do
    case Map.fetch(@v2_precisions, to_string(precision)) do
      {:ok, unit} ->
        {:ok, unit}

      :error ->
        {:error,
         %{
           status: 400,
           body:
             Jason.encode!(%{
               "code" => "invalid",
               "message" => "invalid precision; valid precision units are ns, us, ms, and s"
             })
         }}
    end
  end

  defp normalize_precision(precision, _v3) do
    case Map.fetch(@v3_precisions, to_string(precision)) do
      {:ok, unit} ->
        {:ok, unit}

      :error ->
        {:error,
         %{
           status: 400,
           body:
             "serde error: unknown variant `#{precision}`, expected one of `auto`, `s`, " <>
               "`second`, `millisecond`, `ms`, `microsecond`, `u`, `us`, `n`, `nanosecond`, `ns`"
         }}
    end
  end

  @spec dialect(profile()) :: LineProtocolParser.dialect()
  defp dialect(:v2), do: :v2
  defp dialect(_v3), do: :v3

  # InfluxDB 3: every accepted line is stored and every rejected one
  # reported ("partial write of line protocol occurred", HTTP 400, one entry
  # per bad line) — a syntax error or a column whose kind conflicts with the
  # measurement's schema drops that line only.
  #
  # InfluxDB 2: a line that fails to parse rejects the whole payload (HTTP
  # 400 `{"code":"invalid","message":"unable to parse '<line>': ..."}`,
  # nothing stored); a field type conflict drops the conflicting lines and
  # answers 422 with the first conflict and `dropped=N`.
  #
  # Both bodies are the engine's JSON so consumer code that reads them can
  # be exercised.
  @spec store_lines(Store.t(), binary(), [LineProtocolParser.line_result()], profile()) ::
          InfluxElixir.Client.write_result()
  defp store_lines(table, database, lines, :v2) do
    case for({:error, line_error} <- lines, do: line_error) do
      [] -> store_v2_points(table, database, lines)
      errors -> {:error, v2_parse_error(errors)}
    end
  end

  defp store_lines(table, database, lines, _v3) do
    {errors, accepted} = check_v3_lines(table, database, lines)
    Store.store_points(table, database, accepted)
    if errors == [], do: {:ok, :written}, else: {:error, partial_write_error(errors)}
  end

  # Every line that fails to parse is reported, joined by newlines.
  @spec v2_parse_error([map()]) :: map()
  defp v2_parse_error(errors) do
    message =
      Enum.map_join(errors, "\n", fn %{error_message: reason, line: line} ->
        "unable to parse '#{line}': #{reason}"
      end)

    %{status: 400, body: Jason.encode!(%{"code" => "invalid", "message" => message})}
  end

  # The lines InfluxDB 3 accepts, in order, and the errors of those it
  # rejects (newest first): a line is checked against the schema as the lines
  # before it have left it.
  @spec check_v3_lines(Store.t(), binary(), [LineProtocolParser.line_result()]) ::
          {[map()], [point_map()]}
  defp check_v3_lines(table, database, lines) do
    {errors, accepted, _known} =
      Enum.reduce(lines, {[], [], %{}}, fn
        {:error, line_error}, {errors, accepted, known} ->
          {[line_error | errors], accepted, known}

        {:ok, point, number, line}, {errors, accepted, known} ->
          case check_schema(table, database, point, :v3, known) do
            {:ok, known} ->
              {errors, [strip_uint_markers(point) | accepted], known}

            {:error, message} ->
              {[LineProtocolParser.schema_error(message, number, line) | errors], accepted, known}
          end
      end)

    {errors, Enum.reverse(accepted)}
  end

  @spec partial_write_error([map()]) :: map()
  defp partial_write_error(errors) do
    %{
      status: 400,
      body:
        Jason.encode!(%{
          "error" => "partial write of line protocol occurred",
          "data" => errors |> Enum.reverse() |> Enum.map(&Map.delete(&1, :line))
        })
    }
  end

  # InfluxDB 2 maps a payload's points onto shards first and drops the ones
  # older than the bucket's retention (verified): `now - retention` is the
  # lower bound, and a point before it never reaches a shard — it registers
  # no field and is dropped whatever else is wrong with it.
  #
  # The rest are written in groups, one per shard group (verified): a point
  # it drops is counted, and the message it answers with is the first drop
  # of one group that dropped any, counting only that group's drops. The
  # engine's choice among several failing groups varies between identical
  # writes (verified; usually the earliest); the double takes the earliest,
  # whatever order the payload gave the groups in. A point is dropped
  # for a field type that conflicts with the stored one and for having no
  # field but `time`. The retention drops are reported only when no group
  # dropped anything (verified): the group's message replaces them.
  @spec store_v2_points(Store.t(), binary(), [LineProtocolParser.line_result()]) ::
          InfluxElixir.Client.write_result()
  defp store_v2_points(table, database, lines) do
    retention = bucket_retention(table, database)
    shard_ns = shard_group_seconds(retention) * 1_000_000_000
    lower_bound = Store.now_ns() - retention * 1_000_000_000

    {failures, expired, accepted, _known} =
      Enum.reduce(lines, {[], [], [], %{}}, fn
        {:ok, %{unreadable: true}, _number, _line}, state ->
          state

        {:ok, %{timestamp: timestamp} = point, _number, _line},
        {failures, expired, accepted, known}
        when retention > 0 and timestamp < lower_bound ->
          {failures, [point | expired], accepted, known}

        {:ok, point, _number, _line}, {failures, expired, accepted, known} ->
          group = Integer.floor_div(point.timestamp, shard_ns)

          case store_v2_point(table, database, point, v2_scope(point, group), known) do
            {:ok, known} ->
              {failures, expired, [strip_uint_markers(point) | accepted], known}

            {:dropped, reason, known} ->
              {[{group, reason} | failures], expired, accepted, known}
          end
      end)

    Store.store_points(table, database, Enum.reverse(accepted))

    case {failures, expired} do
      {[], []} ->
        {:ok, :written}

      {[], expired} ->
        v2_retention_result(expired, database, retention, lower_bound)

      {failures, _expired} ->
        v2_write_result(Enum.reverse(failures))
    end
  end

  # InfluxDB 2 types a field per shard group (verified): the same field may
  # be an integer in one week and a float in another. The schema of a group
  # is kept under the measurement and the group, joined by a NUL.
  @spec v2_scope(point_map(), integer()) :: binary()
  defp v2_scope(point, group), do: point.measurement <> <<0>> <> Integer.to_string(group)

  @spec store_v2_point(Store.t(), binary(), point_map(), binary(), map()) ::
          {:ok, map()} | {:dropped, term(), map()}
  defp store_v2_point(_table, _database, %{fields: fields} = point, _scope, known)
       when map_size(fields) == 0,
       do: {:dropped, {:invalid_name, point.measurement}, known}

  defp store_v2_point(table, database, point, scope, known) do
    case check_schema(table, database, point, {:v2, scope}, known) do
      {:ok, known} ->
        {:ok, known}

      {:error, conflict} ->
        {:dropped, conflict, known}
    end
  end

  # The 422 for points older than the retention: the count, the oldest and
  # the newest of them (the first one met on a tie) by series key and time,
  # and the lower bound, all as the engine words them (verified).
  @spec v2_retention_result([point_map()], binary(), pos_integer(), integer()) ::
          InfluxElixir.Client.write_result()
  defp v2_retention_result(expired, database, retention, lower_bound) do
    expired = Enum.reverse(expired)

    oldest =
      Enum.reduce(expired, fn point, kept ->
        if point.timestamp < kept.timestamp, do: point, else: kept
      end)

    newest =
      Enum.reduce(expired, fn point, kept ->
        if point.timestamp > kept.timestamp, do: point, else: kept
      end)

    bound = rfc3339_nano(lower_bound)

    drop = fn which, point ->
      "#{which} point #{series_key(point)} at #{rfc3339_nano(point.timestamp)} dropped because " <>
        "it violates a Retention Policy Lower Bound at #{bound}"
    end

    message =
      "failure writing points to database: partial write: dropped #{length(expired)} points " <>
        "outside retention policy of duration #{go_duration(retention)} - " <>
        "#{drop.("oldest", oldest)}, #{drop.("newest", newest)} dropped=#{length(expired)} " <>
        "for database: #{hex_id(database)} for retention policy: autogen"

    {:error,
     %{
       status: 422,
       body: Jason.encode!(%{"code" => "unprocessable entity", "message" => message})
     }}
  end

  # Go's `time.Duration` string for a whole number of seconds of an hour or
  # more: `2h0m0s`.
  @spec go_duration(pos_integer()) :: binary()
  defp go_duration(seconds) do
    "#{div(seconds, 3600)}h#{div(rem(seconds, 3600), 60)}m#{rem(seconds, 60)}s"
  end

  # Go's RFC 3339 with nanoseconds: the fraction only as far as it is not
  # zero.
  @spec rfc3339_nano(integer()) :: binary()
  defp rfc3339_nano(ns) do
    stamp =
      ns
      |> Integer.floor_div(1_000_000_000)
      |> DateTime.from_unix!()
      |> DateTime.to_iso8601()
      |> String.trim_trailing("Z")

    case Integer.mod(ns, 1_000_000_000) do
      0 ->
        stamp <> "Z"

      fraction ->
        digits = fraction |> Integer.to_string() |> String.pad_leading(9, "0")
        stamp <> "." <> String.trim_trailing(digits, "0") <> "Z"
    end
  end

  # A point's series key as the engine prints it: the measurement and the
  # tags sorted by key, with the line protocol's escapes.
  @spec series_key(point_map()) :: binary()
  defp series_key(point) do
    tags =
      point.tags
      |> Enum.sort()
      |> Enum.map_join(fn {key, value} -> "," <> escape_key(key) <> "=" <> escape_key(value) end)

    String.replace(point.measurement, [",", " "], &("\\" <> &1)) <> tags
  end

  @spec escape_key(binary()) :: binary()
  defp escape_key(text), do: String.replace(text, [",", "=", " "], &("\\" <> &1))

  @spec v2_write_result([{integer(), term()}]) :: InfluxElixir.Client.write_result()
  defp v2_write_result(failures) do
    {earliest, _reason} = Enum.min_by(failures, &elem(&1, 0))
    [first | _rest] = reasons = for {^earliest, reason} <- failures, do: reason

    message =
      "failure writing points to database: partial write: " <>
        v2_drop_reason(first) <> " dropped=#{length(reasons)}"

    {:error,
     %{
       status: 422,
       body: Jason.encode!(%{"code" => "unprocessable entity", "message" => message})
     }}
  end

  @spec v2_drop_reason(term()) :: binary()
  defp v2_drop_reason({:invalid_name, measurement}) do
    ~s|invalid field name: input field "time" on measurement "#{measurement}" is invalid|
  end

  defp v2_drop_reason({field, measurement, existing, got}) do
    ~s|field type conflict: input field "#{field}" on measurement "#{measurement}" is | <>
      "type #{got}, already exists as type #{existing}"
  end

  # How long a bucket's shard groups are: a week when its retention is
  # none or at least 180 days, a day from two days, an hour below.
  @spec shard_group_seconds(non_neg_integer()) :: pos_integer()
  defp shard_group_seconds(retention) when retention == 0 or retention >= 15_552_000, do: 604_800
  defp shard_group_seconds(retention) when retention >= 172_800, do: 86_400
  defp shard_group_seconds(_retention), do: 3_600

  @spec bucket_retention(Store.t(), binary()) :: non_neg_integer()
  defp bucket_retention(table, bucket) do
    case Store.bucket(table, bucket) do
      %{retention: seconds} -> seconds
      _unregistered -> 0
    end
  end

  # `accept_partial: false` and `no_sync:` are InfluxDB 3 write parameters
  # (`HTTP.write/3` sends them as `&accept_partial=false`, `&no_sync=true`);
  # the engine refuses anything but `true` / `false` (verified). `no_sync`
  # changes durability only, which the double does not have, so it is
  # accepted and changes nothing. InfluxDB 2's endpoint has neither.
  @spec write_flag(keyword(), atom(), boolean(), profile()) :: {:ok, boolean()} | {:error, map()}
  defp write_flag(_opts, _key, default, :v2), do: {:ok, default}

  defp write_flag(opts, key, default, _v3) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) ->
        {:ok, value}

      _other ->
        {:error, %{status: 400, body: "serde error: provided string was not `true` or `false`"}}
    end
  end

  # `accept_partial: false` (verified against InfluxDB 3): the first bad
  # line in line order — a parse error or a schema conflict, including one
  # against an earlier line of the same payload — rejects the whole payload
  # and nothing is stored, not even the schema; the body is
  # `{"error": "line protocol parsing error", "data": {one line error}}`.
  # Every line is checked against the stored schema plus the payload's
  # pending columns before anything is written.
  @spec store_lines_atomically(Store.t(), binary(), [LineProtocolParser.line_result()]) ::
          InfluxElixir.Client.write_result()
  defp store_lines_atomically(table, database, lines) do
    case first_line_error(table, database, lines) do
      nil ->
        store_lines(table, database, lines, :v3_core)

      line_error ->
        {:error,
         %{
           status: 400,
           body:
             Jason.encode!(%{
               "error" => "line protocol parsing error",
               "data" => Map.delete(line_error, :line)
             })
         }}
    end
  end

  @spec first_line_error(Store.t(), binary(), [LineProtocolParser.line_result()]) ::
          LineProtocolParser.line_error() | nil
  defp first_line_error(table, database, lines) do
    Enum.reduce_while(lines, {:ok, %{}}, fn
      {:error, line_error}, _pending ->
        {:halt, {:error, line_error}}

      {:ok, point, number, line}, {:ok, pending} ->
        case dry_check(table, database, point, pending) do
          {:ok, pending} ->
            {:cont, {:ok, pending}}

          {:error, message} ->
            {:halt, {:error, LineProtocolParser.schema_error(message, number, line)}}
        end
    end)
    |> case do
      {:error, line_error} -> line_error
      {:ok, _pending} -> nil
    end
  end

  # The v3 schema checks without registering anything; `pending` holds the
  # kinds the payload's earlier lines would register.
  @spec dry_check(Store.t(), binary(), point_map(), map()) :: {:ok, map()} | {:error, binary()}
  defp dry_check(table, database, point, pending) do
    m = point.measurement

    exists? = fn ->
      Store.table?(table, database, m) or Enum.any?(Map.keys(pending), &match?({^m, _column}, &1))
    end

    with :ok <- reserved_time(point, exists?) do
      point
      |> point_columns(:v3)
      |> Enum.reduce_while({:ok, pending}, fn {column, type}, {:ok, pending} ->
        existing = Map.get(pending, {m, column}) || Store.column_kind(table, database, m, column)

        if existing in [nil, type],
          do: {:cont, {:ok, Map.put(pending, {m, column}, type)}},
          else: {:halt, {:error, conflict(:v3, column, point, existing, type)}}
      end)
    end
  end

  # InfluxDB 3 reserves `time` for the timestamp column. The wording
  # depends on whether the table exists (verified): a new table refuses
  # the line outright, an existing one reports a column-type conflict.
  #
  # `known` holds the kinds this write has already confirmed or registered,
  # `{measurement, column} => kind`: a kind never changes once set, so the
  # store is asked only about a column the write has not met yet.
  @spec check_schema(Store.t(), binary(), point_map(), :v3 | {:v2, binary()}, map()) ::
          {:ok, map()} | {:error, binary() | {binary(), binary(), binary(), binary()}}
  defp check_schema(table, database, point, :v3, known) do
    case reserved_time(point, fn -> Store.table?(table, database, point.measurement) end) do
      :ok -> check_column_types(table, database, point, :v3, point.measurement, known)
      {:error, _message} = error -> error
    end
  end

  defp check_schema(table, database, point, {:v2, scope}, known),
    do: check_column_types(table, database, point, :v2, scope, known)

  # `table_exists?` is asked only for a point that names `time`.
  @spec reserved_time(point_map(), (-> boolean())) :: :ok | {:error, binary()}
  defp reserved_time(%{tags: tags, fields: fields}, table_exists?) do
    cond do
      Map.has_key?(tags, "time") ->
        reserved_time_error(table_exists?.(), "iox::column_type::tag")

      Map.has_key?(fields, "time") ->
        reserved_time_error(
          table_exists?.(),
          LineProtocolParser.column_type(:field, Map.fetch!(fields, "time"))
        )

      true ->
        :ok
    end
  end

  @spec reserved_time_error(boolean(), binary()) :: {:error, binary()}
  defp reserved_time_error(table_exists?, got) do
    if table_exists? do
      {:error,
       "invalid column type for column 'time', expected iox::column_type::timestamp, got " <>
         got}
    else
      {:error, "'time' is a reserved column"}
    end
  end

  # The measurement's schema, one ETS object per column so the first writer
  # of a column fixes its kind atomically (`insert_new`) and a concurrent
  # writer never loses a column. InfluxDB 3 types tags and fields in one
  # namespace and reports a conflict with its column-type wording; InfluxDB
  # 2 types fields only and reports `{field, measurement, existing, got}`.
  @spec check_column_types(
          Store.t(),
          binary(),
          point_map(),
          LineProtocolParser.dialect(),
          binary(),
          map()
        ) :: {:ok, map()} | {:error, binary() | {binary(), binary(), binary(), binary()}}
  defp check_column_types(table, database, point, dialect, m, known) do
    point
    |> point_columns(dialect)
    |> Enum.reduce_while({:ok, known}, fn {column, type}, {:ok, known} ->
      case Map.fetch(known, {m, column}) do
        {:ok, ^type} ->
          {:cont, {:ok, known}}

        {:ok, existing} ->
          {:halt, {:error, conflict(dialect, column, point, existing, type)}}

        :error ->
          case Store.register_column(table, database, m, column, type) do
            :ok ->
              {:cont, {:ok, Map.put(known, {m, column}, type)}}

            {:conflict, existing} ->
              {:halt, {:error, conflict(dialect, column, point, existing, type)}}
          end
      end
    end)
  end

  # The columns a point types, as `{column, kind}`: InfluxDB 3 types tags
  # and fields in one namespace, InfluxDB 2 types fields only.
  @spec point_columns(point_map(), LineProtocolParser.dialect()) :: [{binary(), binary()}]
  defp point_columns(point, dialect) do
    tags =
      if dialect == :v3,
        do:
          Enum.map(point.tags, fn {k, _v} -> {k, LineProtocolParser.column_type(:tag, nil)} end),
        else: []

    tags ++
      Enum.map(point.fields, fn {k, v} -> {k, LineProtocolParser.column_type(:field, v)} end)
  end

  @spec conflict(LineProtocolParser.dialect(), binary(), point_map(), binary(), binary()) ::
          binary() | {binary(), binary(), binary(), binary()}
  defp conflict(:v3, column, _point, existing, type),
    do: "invalid column type for column '#{column}', expected #{existing}, got #{type}"

  defp conflict(:v2, column, point, existing, type) do
    {column, point.measurement, LineProtocolParser.v2_field_type(existing),
     LineProtocolParser.v2_field_type(type)}
  end

  # An unsigned integer is stored as the integer; the marker exists for the
  # schema check alone.
  @spec strip_uint_markers(point_map()) :: point_map()
  defp strip_uint_markers(point) do
    fields =
      Map.new(point.fields, fn
        {k, {:uint, n}} -> {k, n}
        {k, v} -> {k, v}
      end)

    %{point | fields: fields}
  end

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
  def query_sql(conn, sql, opts \\ []) do
    with :ok <- require_capability(conn, :query_sql),
         {:ok, database} <- resolve_database(opts, conn),
         {:ok, params} <- QueryParams.normalize(Keyword.get(opts, :params, %{})) do
      answer_sql(conn, database, sql, params, opts)
    end
  end

  # The engine answers query_sql and execute_sql from the same endpoint:
  # a statement that is not a query gets execute_sql's answer. A text its
  # tokenizer cannot read is answered after the request's format and
  # parameters, as its parser reads the text last.
  @spec answer_sql(conn(), binary(), binary(), QueryParams.t(), keyword()) ::
          InfluxElixir.Client.query_result()
  defp answer_sql(%{table: table} = conn, database, sql, params, opts) do
    case SQLLexer.scrub(sql) do
      {:ok, statement} ->
        if statement_kind(statement) == :query,
          do:
            Format.answer(
              query_format(opts),
              fn -> query_database(table, database, statement, params) end,
              database,
              params
            ),
          else: execute_sql(conn, sql, opts)

      {:error, _reason} = error ->
        Format.answer(
          query_format(opts),
          fn -> with :ok <- database_exists(table, database), do: error end,
          database,
          params
        )
    end
  end

  @spec query_database(Store.t(), binary(), binary(), QueryParams.t()) ::
          InfluxElixir.Client.query_result()
  defp query_database(table, database, sql, params) do
    with :ok <- database_exists(table, database), do: run_query(table, database, sql, params)
  end

  @spec run_query(Store.t(), binary(), binary(), QueryParams.t()) ::
          InfluxElixir.Client.query_result()
  defp run_query(table, database, sql, params) do
    with {:ok, query} <- SQLParser.parse_select(sql) do
      case SQLExecutor.run(
             query,
             &point_source(table, database, &1),
             QueryParams.engine_values(params),
             &Store.column_kind(table, database, &1, &2)
           ) do
        {:error, _reason} = err -> err
        rows -> {:ok, rows}
      end
    end
  end

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
  def query_sql_stream(conn, sql, opts \\ []) do
    case require_capability(conn, :query_sql_stream) do
      :ok ->
        case query_sql(conn, sql, Keyword.delete(opts, :format)) do
          {:ok, rows} -> Stream.map(rows, & &1)
          {:error, reason} -> InfluxElixir.StreamError.stream(stream_error_opts(reason))
        end

      {:error, :unsupported_operation} ->
        InfluxElixir.StreamError.stream(kind: :unsupported, reason: :unsupported_operation)
    end
  end

  # Maps a `query_sql/3` error reason to `InfluxElixir.StreamError` options,
  # mirroring how `Client.HTTP` classifies the same failures. Query errors that
  # a real InfluxDB surfaces as an HTTP status (bad SQL, missing table) map to
  # `:http_status`; a missing database maps to `:no_database`.
  @spec stream_error_opts(term()) :: keyword()
  defp stream_error_opts(%{status: status, body: body}),
    do: [kind: :http_status, status: status, body: body]

  defp stream_error_opts(:no_database_specified), do: [kind: :no_database]

  defp stream_error_opts(reason), do: [kind: :transport, reason: reason]

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
  def execute_sql(%{table: table, profile: profile} = conn, sql, opts \\ []) do
    with :ok <- require_capability(conn, :execute_sql),
         {:ok, database} <- resolve_database(opts, conn),
         {:ok, params} <- QueryParams.normalize(Keyword.get(opts, :params, %{})),
         :ok <- Format.check_params(params, nil, database),
         :ok <- database_exists(table, database),
         {:ok, trimmed} <- SQLLexer.scrub(sql) do
      case statement_kind(trimmed) do
        :query ->
          query_sql(conn, sql, opts)

        # The statement follows SQL's identifier rules, as a SELECT does:
        # `DELETE FROM "Cpu" WHERE "Host" = 'a'`.
        :delete when profile == :v3_enterprise ->
          case Regex.run(
                 ~r/^(?i)DELETE\s+FROM\s+("[^"]+"|(?:[^\s\\]|\\.)+)(.*)$/s,
                 SQLIdentifiers.normalize(trimmed)
               ) do
            [_full, measurement_raw, rest] ->
              execute_delete(table, database, measurement_raw, rest)

            nil ->
              {:error, %{status: 400, body: "Error during planning: DML not supported: Delete"}}
          end

        :delete ->
          {:error, %{status: 400, body: "Error during planning: DML not supported: Delete"}}

        {:planning, message} ->
          {:error, %{status: 400, body: "Error during planning: " <> message}}

        :unsupported ->
          {:error,
           SQLStatement.parser_error(sql) ||
             %{
               status: 405,
               body: "This feature is not implemented: Unsupported SQL statement: " <> trimmed
             }}
      end
    end
  end

  # Regexes nested in a list cannot be module attributes on OTP 28, so the
  # table is a function.
  @spec statement_kinds() :: [{Regex.t(), atom() | {:planning, binary()}}]
  defp statement_kinds do
    [
      # Statements the engine answers with rows. The ones the double does
      # not model (EXPLAIN, SHOW TABLES, DESCRIBE) reach its parser and are
      # refused by name there, not reported as unimplemented.
      {~r/^(?i)(?:SELECT|WITH|EXPLAIN|SHOW|DESCRIBE)\b|^\(/, :query},
      {~r/^(?i)DELETE\b/, :delete},
      {~r/^(?i)INSERT\b/, {:planning, "DML not supported: Insert Into"}},
      {~r/^(?i)UPDATE\b/, {:planning, "DML not supported: Update"}},
      {~r/^(?i)CREATE\s+(?:OR\s+REPLACE\s+)?VIEW\b/,
       {:planning, "DDL not supported: CreateView"}},
      {~r/^(?i)CREATE\s+(?:DATABASE|SCHEMA)\b/, {:planning, "DDL not supported: CreateCatalog"}},
      {~r/^(?i)CREATE\s+TABLE\b/, {:planning, "DDL not supported: CreateMemoryTable"}},
      {~r/^(?i)DROP\s+VIEW\b/, {:planning, "DDL not supported: DropView"}},
      {~r/^(?i)DROP\s+TABLE\b/, {:planning, "DDL not supported: DropTable"}},
      {~r/^(?i)(?:COMMIT|ROLLBACK)\s*;?\s*$/,
       {:planning, "Statement not supported: TransactionEnd"}},
      {~r/^(?i)START\s+TRANSACTION\s*;?\s*$/,
       {:planning, "Statement not supported: TransactionStart"}},
      {~r/^(?i)SET\s+[\w.]+\s*(?:=|TO\b)\s*\S/,
       {:planning, "Statement not supported: SetVariable"}},
      {~r/^(?i)PREPARE\s+\w+\s+AS\s+\S/, {:planning, "Statement not supported: Prepare"}},
      {~r/^(?i)DEALLOCATE\s+\w+\s*;?\s*$/, {:planning, "Statement not supported: Deallocate"}},
      {~r/^(?i)EXEC(?:UTE)?\s+\w+\s*(?:\([^)]*\))?\s*;?\s*$/,
       {:planning, "Statement not supported: Execute"}}
    ]
  end

  @spec statement_kind(binary()) :: :query | :delete | {:planning, binary()} | :unsupported
  defp statement_kind(sql) do
    Enum.find_value(statement_kinds(), :unsupported, fn {pattern, kind} ->
      if Regex.match?(pattern, sql), do: kind
    end)
  end

  @spec execute_delete(Store.t(), binary(), binary(), binary()) ::
          {:ok, map()} | {:error, term()}
  defp execute_delete(table, database, measurement_raw, rest) do
    measurement =
      case measurement_raw do
        "\"" <> _quoted -> String.trim(measurement_raw, "\"")
        bare -> LineProtocolParser.unescape_measurement(bare)
      end

    with {:ok, where} <- SQLParser.parse_where(rest) do
      count =
        Store.delete_points(table, database, measurement, &SQLExecutor.matches_all?(&1, where))

      {:ok, %{"rows_affected" => count}}
    end
  end

  # ---------------------------------------------------------------------------
  # InfluxQL and Flux queries
  # ---------------------------------------------------------------------------

  @doc """
  Executes an InfluxQL query.

  Answers what InfluxDB 3 answers, verified against the engine:

    * `SHOW DATABASES` — `%{"iox::database" => name, "deleted" => false}`
    * `SHOW MEASUREMENTS` — `%{"iox::measurement" => "measurements", "name" => m}`
    * `SHOW TAG KEYS [FROM m]` — `%{"iox::measurement" => m, "tagKey" => k}`
    * `SHOW FIELD KEYS [FROM m]` — `%{"iox::measurement" => m, "fieldKey" => k,
      "fieldType" => "integer" | "unsigned" | "float" | "string" | "boolean"}`
    * `SHOW TAG VALUES [FROM m] WITH KEY ... [WHERE ...]` —
      `%{"iox::measurement" => m, "key" => k, "value" => v}` by measurement,
      key and value, a row without `"value"` when a point lacks the key,
      over the last 24 hours unless the `WHERE` bounds `time`
    * `SELECT ...` — InfluxQL, not SQL: see `InfluxElixir.Client.Local.InfluxQL`
      for the row shape (`iox::measurement` and `time` on every row, time
      order, `mean`/`count`/... aggregates stamped with the `WHERE`'s lower
      bound on `time`, an unknown column or measurement is `{:ok, []}`,
      `LIMIT` and `OFFSET` per selected field), for InfluxQL's `WHERE` (a
      missing tag is `''`, regexes, durations, integers and durations as
      nanoseconds next to `time`) and for what is refused by name
  """
  @impl true
  @spec query_influxql(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  def query_influxql(%{table: table} = conn, influxql, opts \\ []) do
    with :ok <- require_capability(conn, :query_influxql) do
      Format.answer(
        query_format(opts),
        fn -> do_query_influxql(table, conn, influxql, opts) end,
        Keyword.get(opts, :database) || Map.get(conn, :database)
      )
    end
  end

  # `format:` as `Client.HTTP` sends it; see `Client.Local.Format`.
  @spec query_format(keyword()) :: term()
  defp query_format(opts), do: Keyword.get(opts, :format, :json)

  @show_databases ~r/^(?i)SHOW\s+DATABASES\s*;?$/
  @show_measurements ~r/^(?i)SHOW\s+MEASUREMENTS\s*;?$/
  @show_keys ~r/^(?i)SHOW\s+(TAG|FIELD)\s+KEYS(?:\s+FROM\s+("(?:[^"\\]|\\.)+"|\S+?))?\s*;?$/

  @spec do_query_influxql(Store.t(), map(), binary(), keyword()) ::
          InfluxElixir.Client.query_result()
  defp do_query_influxql(table, conn, raw, opts) do
    # The engine's positions count the text as sent, blanks included.
    influxql = String.trim(raw)

    if String.match?(influxql, @show_databases) do
      {:ok, Enum.map(database_names(table), &%{"iox::database" => &1, "deleted" => false})}
    else
      # The engine parses the statement before it looks for the database.
      with {:ok, statement} <- influxql_statement(influxql, raw),
           {:ok, database} <- influxql_database(opts, conn),
           :ok <- database_exists(table, database) do
        case statement do
          :show_measurements -> {:ok, show_measurements(table, database)}
          {:show_keys, match} -> {:ok, show_keys(table, database, match)}
          {:show_tag_values, spec} -> show_tag_values(table, database, spec)
          {:select, query} -> influxql_select(table, database, query)
        end
      end
    end
  end

  @spec influxql_statement(binary(), binary()) ::
          {:ok,
           :show_measurements
           | {:show_keys, [binary()]}
           | {:show_tag_values, map()}
           | {:select, map()}}
          | {:error, term()}
  defp influxql_statement(influxql, raw) do
    cond do
      String.match?(influxql, @show_measurements) ->
        {:ok, :show_measurements}

      match = Regex.run(@show_keys, influxql) ->
        {:ok, {:show_keys, match}}

      show = InfluxQL.parse_show_tag_values(influxql) ->
        case show do
          {:ok, spec} ->
            {:ok, {:show_tag_values, spec}}

          {:error, {:engine, body}} ->
            {:error, %{status: 400, body: body}}

          {:error, message} ->
            {:error, %{status: 400, body: "Client.Local: #{message}: #{influxql}"}}
        end

      true ->
        with {:ok, query} <- influxql_parse(raw, influxql), do: {:ok, {:select, query}}
    end
  end

  # `SHOW TAG VALUES`, as InfluxDB 3 answers it (verified): a row per
  # distinct value of each listed key, by measurement, key and value, plus
  # a row without `value` when a point in range lacks the key; a
  # measurement without the key has no rows. Without a WHERE on `time`,
  # only the last 24 hours count.
  @show_tag_values_window "time >= now() - INTERVAL '86400 seconds'"

  @spec show_tag_values(Store.t(), binary(), map()) :: {:ok, [map()]} | {:error, map()}
  defp show_tag_values(table, database, spec) do
    measurements =
      if spec.measurement, do: [spec.measurement], else: Store.measurements(table, database)

    measurements
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn m, {:ok, acc} ->
      case tag_value_rows(table, database, m, spec) do
        {:ok, rows} -> {:cont, {:ok, [rows | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, groups |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  @spec tag_value_rows(Store.t(), binary(), binary(), map()) :: {:ok, [map()]} | {:error, map()}
  defp tag_value_rows(table, database, measurement, spec) do
    tags = Store.tag_columns(table, database, measurement)
    keys = tags |> Enum.filter(&InfluxQL.key_listed?(&1, spec.keys)) |> Enum.sort()

    with [_first | _rest] <- keys,
         {:ok, where} <- tag_values_where(spec.where, tags) do
      sql = ~s|SELECT * FROM "#{measurement}" WHERE | <> where

      case run_influxql_sql(table, database, sql, tags) do
        {:ok, rows} -> {:ok, Enum.flat_map(keys, &key_value_rows(measurement, &1, rows))}
        {:error, _no_table_or_column} -> {:ok, []}
      end
    else
      [] -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  # The statement's WHERE, parenthesised so an `OR` in it binds before the
  # default window, which applies unless the WHERE bounds `time` itself.
  @spec tag_values_where(binary() | nil, MapSet.t(binary())) ::
          {:ok, binary()} | {:error, map()}
  defp tag_values_where(nil, _tags), do: {:ok, @show_tag_values_window}

  defp tag_values_where(where, tags) do
    case influxql_where(where, tags, %{}) do
      {:ok, %{where: " WHERE " <> sql}} ->
        if InfluxQL.mentions_time?(where),
          do: {:ok, sql},
          else: {:ok, "(#{sql}) AND " <> @show_tag_values_window}

      {:error, %{body: body} = error} ->
        {:error, %{error | body: InfluxQL.unframe_split(body)}}
    end
  end

  @spec key_value_rows(binary(), binary(), [map()]) :: [map()]
  defp key_value_rows(measurement, key, rows) do
    values = for %{^key => value} <- rows, do: value
    base = %{"iox::measurement" => measurement, "key" => key}
    missing = if Enum.any?(rows, &(not Map.has_key?(&1, key))), do: [base], else: []

    (values |> Enum.uniq() |> Enum.sort() |> Enum.map(&Map.put(base, "value", &1))) ++ missing
  end

  # HTTP sends an InfluxQL query without `db` when there is none, and the
  # engine answers this 400 (verified).
  @spec influxql_database(keyword(), conn()) :: {:ok, binary()} | {:error, map()}
  defp influxql_database(opts, conn) do
    case resolve_database(opts, conn) do
      {:ok, _database} = ok ->
        ok

      {:error, :no_database_specified} ->
        {:error,
         %{
           status: 400,
           body: "must specify a 'db' parameter, or provide the database in the InfluxQL query"
         }}
    end
  end

  # The engine lists its own `_internal` database with the others (sorted).
  @spec database_names(Store.t()) :: [binary()]
  defp database_names(table) do
    table |> Store.databases() |> MapSet.put(DatabaseRules.internal()) |> Enum.sort()
  end

  @spec show_measurements(Store.t(), binary()) :: [map()]
  defp show_measurements(table, database) do
    table
    |> Store.measurements(database)
    |> Enum.map(&%{"iox::measurement" => "measurements", "name" => &1})
  end

  # Tag and field keys come from the column schema, in (measurement, key)
  # order.
  @spec show_keys(Store.t(), binary(), [binary()]) :: [map()]
  defp show_keys(table, database, [_full, kind | from]) do
    only =
      case from do
        [m] -> m |> String.trim("\"") |> LineProtocolParser.unescape_measurement()
        [] -> nil
      end

    for {m, column, type} <- Store.columns(table, database),
        only in [nil, m],
        row = key_row(String.upcase(kind), m, column, type),
        row != nil do
      row
    end
  end

  @spec key_row(binary(), term(), binary(), binary()) :: map() | nil
  defp key_row("TAG", m, column, "iox::column_type::tag"),
    do: %{"iox::measurement" => m, "tagKey" => column}

  defp key_row("FIELD", m, column, "iox::column_type::field::" <> _type = kind),
    do: %{
      "iox::measurement" => m,
      "fieldKey" => column,
      "fieldType" => LineProtocolParser.v2_field_type(kind)
    }

  defp key_row(_kind, _m, _column, _type), do: nil

  # The statement's WHERE is evaluated by the SQL engine (the grammar the two
  # share: comparisons, AND/OR/NOT, time literals, now()); InfluxQL then
  # shapes the rows. A measurement or column the engine does not know is an
  # empty InfluxQL result, not an error (verified).
  #
  # The inner query gets typed rows: the caller's `format:` applies once, to
  # the InfluxQL result.
  @spec influxql_select(Store.t(), binary(), InfluxQL.query()) ::
          InfluxElixir.Client.query_result()
  defp influxql_select(table, database, query) do
    tags = Store.tag_columns(table, database, query.measurement)
    types = field_types(table, database, query.measurement)

    with {:ok, plan} <- influxql_where(query.where, tags, types),
         :ok <- influxql_items(query),
         :ok <- influxql_window(table, database, query),
         :ok <- influxql_deferred(plan) do
      # ORDER BY time sorts on the stored nanoseconds; rows carry microsecond
      # DateTimes, so sorting those alone would tie sub-microsecond points.
      # InfluxQL shapes the rows in that order and sorts nothing again.
      sql = ~s|SELECT * FROM "#{query.measurement}"| <> plan.where <> " ORDER BY time"

      table
      |> run_influxql_sql(database, sql, plan.tags)
      |> influxql_checked(plan.checks)
      |> influxql_result(query, tags,
        lower: lower_bound(plan.lowers),
        fields: window_fields(table, database, query),
        types: types
      )
    end
  end

  # What the SQL engine does not read as the engine does is checked over the
  # rows it kept.
  @spec influxql_checked({:ok, [map()]} | {:error, term()}, [term()]) ::
          {:ok, [map()]} | {:error, term()}
  defp influxql_checked(result, []), do: result

  defp influxql_checked({:ok, rows}, checks),
    do: {:ok, Enum.filter(rows, &InfluxQL.keep?(checks, &1))}

  defp influxql_checked(error, _checks), do: error

  # The engine's planning error for a select item that is a constant, raised
  # after the `WHERE` is planned and before `LIMIT` is.
  @spec influxql_items(InfluxQL.query()) :: :ok | {:error, map()}
  defp influxql_items(query) do
    case InfluxQL.check_items(query.items) do
      :ok -> :ok
      {:error, {:engine, body}} -> {:error, %{status: 400, body: body}}
    end
  end

  # The type of each field of a measurement, as the WHERE reads it.
  @spec field_types(Store.t(), binary(), binary()) :: %{binary() => atom()}
  defp field_types(table, database, measurement) do
    for {^measurement, column, "iox::column_type::field::" <> type} <-
          Store.columns(table, database),
        into: %{},
        do: {column, field_type(type)}
  end

  @spec field_type(binary()) :: :integer | :unsigned | :float | :string | :boolean
  defp field_type("integer"), do: :integer
  defp field_type("uinteger"), do: :unsigned
  defp field_type("float"), do: :float
  defp field_type("string"), do: :string
  defp field_type("boolean"), do: :boolean

  # A LIMIT or OFFSET beyond the signed 64-bit range is a planning error,
  # raised only for a measurement that exists (verified).
  @spec influxql_window(Store.t(), binary(), InfluxQL.query()) :: :ok | {:error, map()}
  defp influxql_window(table, database, query) do
    with true <- query.measurement in Store.measurements(table, database),
         {:error, {:engine, body}} <- InfluxQL.check_window(query) do
      {:error, %{status: 400, body: body}}
    else
      _in_range_or_absent -> :ok
    end
  end

  # An error the engine raises after it has planned the LIMIT.
  @spec influxql_deferred(map()) :: :ok | {:error, map()}
  defp influxql_deferred(%{deferred: nil}), do: :ok
  defp influxql_deferred(%{deferred: body}), do: {:error, %{status: 400, body: body}}

  # The field names a LIMIT or OFFSET counts per field, from the schema;
  # a query without either does not read them.
  @spec window_fields(Store.t(), binary(), InfluxQL.query()) :: [binary()] | nil
  defp window_fields(_table, _database, %{limit: nil, offset: 0}), do: nil

  defp window_fields(table, database, query) do
    for {measurement, column, "iox::column_type::field::" <> _type} <-
          Store.columns(table, database),
        measurement == query.measurement,
        do: column
  end

  # The WHERE as SQL (with its leading ` WHERE `, or nothing), the lower
  # bounds it puts on `time`, and the tag columns it names: only those
  # need the missing-tag fill.
  @spec influxql_where(binary() | nil, MapSet.t(binary()), %{binary() => atom()}) ::
          {:ok,
           %{
             where: binary(),
             lowers: [InfluxQL.bound()],
             checks: [term()],
             tags: MapSet.t(binary()),
             deferred: binary() | nil
           }}
          | {:error, map()}
  defp influxql_where(nil, _tags, _types),
    do: {:ok, %{where: "", lowers: [], checks: [], tags: MapSet.new(), deferred: nil}}

  defp influxql_where(where, tags, types) do
    case InfluxQL.where_plan(where, tags, types) do
      {:ok, plan} ->
        {:ok,
         %{
           where: " WHERE " <> plan.sql,
           lowers: plan.lowers,
           checks: plan.checks,
           tags: MapSet.intersection(tags, plan.idents),
           deferred: plan.deferred
         }}

      {:error, {:engine, body}} ->
        {:error, %{status: 400, body: body}}

      {:error, {:engine, status, body}} ->
        {:error, %{status: status, body: body}}

      {:error, message} ->
        {:error, %{status: 400, body: "Client.Local: #{message}"}}
    end
  end

  # InfluxQL reads a tag a point lacks as the empty string (verified), so
  # the WHERE runs over points with every missing tag it names filled with
  # "". A stored tag value is never empty (line protocol forbids it), so the
  # filled ones are dropped from the rows again afterwards. A tag the WHERE
  # does not name is not filled, and a query without a WHERE makes no extra
  # pass. InfluxQL identifiers are case-sensitive: the SQL written from
  # them is read as it is, not folded as a user's SQL would be.
  @spec run_influxql_sql(Store.t(), binary(), binary(), MapSet.t(binary())) ::
          {:ok, [map()]} | {:error, term()}
  defp run_influxql_sql(table, database, sql, fill_tags) do
    blank_tags = Map.new(fill_tags, &{&1, ""})

    fetch = fn measurement ->
      with {:ok, points} <- point_source(table, database, measurement) do
        if blank_tags == %{},
          do: {:ok, points},
          else: {:ok, Enum.map(points, &%{&1 | tags: Map.merge(blank_tags, &1.tags)})}
      end
    end

    with {:ok, query} <- SQLParser.parse_select(sql, identifiers: :exact),
         rows when is_list(rows) <- SQLExecutor.run_influxql(query, fetch) do
      {:ok,
       if(blank_tags == %{}, do: rows, else: Enum.map(rows, &drop_blank_tags(&1, fill_tags)))}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec drop_blank_tags(map(), MapSet.t(binary())) :: map()
  defp drop_blank_tags(row, tags) do
    Enum.reduce(tags, row, fn tag, row ->
      if Map.get(row, tag) == "", do: Map.delete(row, tag), else: row
    end)
  end

  @spec influxql_result(
          {:ok, [map()]} | {:error, term()},
          InfluxQL.query(),
          MapSet.t(binary()),
          keyword()
        ) :: InfluxElixir.Client.query_result()
  defp influxql_result(result, query, tags, opts) do
    case result do
      {:ok, rows} ->
        {:ok, InfluxQL.run(query, rows, tags, opts)}

      {:error, %{body: "Error during planning: table " <> _rest}} ->
        {:ok, []}

      {:error, %{body: "Schema error: No field named" <> _rest}} ->
        {:ok, []}

      error ->
        error
    end
  end

  # The greatest of the lower bounds a WHERE puts on `time`, `now()` taken
  # now, or `nil` for none.
  @spec lower_bound([InfluxQL.bound()]) :: integer() | nil
  defp lower_bound(lowers) do
    lowers
    |> Enum.map(fn
      {:now, offset} -> Store.now_ns() + offset
      ns -> ns
    end)
    |> Enum.max(fn -> nil end)
  end

  @spec influxql_parse(binary(), binary()) :: {:ok, InfluxQL.query()} | {:error, map()}
  defp influxql_parse(raw, influxql) do
    case InfluxQL.parse(raw) do
      {:ok, query} -> {:ok, query}
      {:error, {:engine, body}} -> {:error, %{status: 400, body: body}}
      {:error, message} -> {:error, %{status: 400, body: "Client.Local: #{message}: #{influxql}"}}
    end
  end

  @doc """
  Executes a Flux query as InfluxDB 2 does; see `InfluxElixir.Client.Local.Flux`
  for the stages supported. Every stage is applied or the query is refused
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
  def query_flux(%{table: table} = conn, flux, _opts \\ []) do
    with :ok <- require_capability(conn, :query_flux),
         {:ok, query} <- flux_parse(flux),
         :ok <- flux_bucket_exists(table, query.bucket) do
      points = Store.points_in_db(table, query.bucket, Flux.measurements(query))

      case Flux.run(query, flux_typed(table, query, points)) do
        {:ok, rows} -> {:ok, rows}
        {:error, message} -> {:error, flux_error(400, "invalid", message)}
      end
    end
  end

  # A field written with different types in different shard groups reads
  # as the type of the earliest group the range touches, up to the first
  # later group of another type: that group and every group after it are
  # not returned, whatever their type (verified). The cut is per measurement
  # and field, across all tag sets. A bucket's shard groups are as long as
  # its retention makes them.
  @spec flux_typed(Store.t(), Flux.query(), [point_map()]) :: [point_map()]
  defp flux_typed(table, %{bucket: bucket} = query, points) do
    {start_ns, stop_ns} = Flux.range(query)
    shard_ns = shard_group_seconds(bucket_retention(table, bucket)) * 1_000_000_000

    touched =
      for point <- points,
          group = Integer.floor_div(point.timestamp, shard_ns),
          group * shard_ns < stop_ns and (group + 1) * shard_ns > start_ns,
          do: {point, group}

    case flux_cutoffs(table, bucket, touched) do
      cutoffs when map_size(cutoffs) == 0 ->
        Enum.map(touched, &elem(&1, 0))

      cutoffs ->
        for {point, group} <- touched,
            fields = flux_typed_fields(point, group, cutoffs),
            map_size(fields) > 0,
            do: %{point | fields: fields}
    end
  end

  # `{measurement, field} => group`: the first group that is not read. The
  # store is asked for the kind of a field once per measurement, group and
  # field, not once per point.
  @spec flux_cutoffs(Store.t(), binary(), [{point_map(), integer()}]) :: %{
          {binary(), binary()} => integer()
        }
  defp flux_cutoffs(table, bucket, touched) do
    kinds =
      Enum.reduce(touched, %{}, fn {point, group}, kinds ->
        Enum.reduce(point.fields, kinds, fn {field, _value}, kinds ->
          key = {point.measurement, field, group}

          if is_map_key(kinds, key) do
            kinds
          else
            kind = Store.column_kind(table, bucket, v2_scope(point, group), field)
            Map.put(kinds, key, kind)
          end
        end)
      end)

    kinds
    |> Enum.group_by(&series_of_kind/1, &group_and_kind/1)
    |> Enum.reduce(%{}, fn {series, group_kinds}, cutoffs ->
      [{_group, first} | later] = Enum.sort(group_kinds)

      case Enum.find(later, fn {_group, kind} -> kind != first end) do
        {group, _kind} -> Map.put(cutoffs, series, group)
        nil -> cutoffs
      end
    end)
  end

  @spec series_of_kind({{binary(), binary(), integer()}, term()}) :: {binary(), binary()}
  defp series_of_kind({{measurement, field, _group}, _kind}), do: {measurement, field}
  @spec group_and_kind({{binary(), binary(), integer()}, term()}) :: {integer(), term()}
  defp group_and_kind({{_measurement, _field, group}, kind}), do: {group, kind}

  @spec flux_typed_fields(point_map(), integer(), map()) :: map()
  defp flux_typed_fields(point, group, cutoffs) do
    Map.filter(point.fields, fn {field, _value} ->
      case Map.fetch(cutoffs, {point.measurement, field}) do
        {:ok, cutoff} -> group < cutoff
        :error -> true
      end
    end)
  end

  @spec flux_parse(binary()) :: {:ok, Flux.query()} | {:error, map()}
  defp flux_parse(flux) do
    # The clock untimed points are stamped with, plus a nanosecond: `stop`
    # is exclusive and the clock can read the same value for a write and
    # the query right after it, which on a real server never happen at
    # the same instant.
    case Flux.parse(flux, Store.now_ns() + 1) do
      {:ok, query} -> {:ok, query}
      {:error, message} -> {:error, flux_error(400, "invalid", message)}
    end
  end

  @spec flux_bucket_exists(Store.t(), binary()) :: :ok | {:error, map()}
  defp flux_bucket_exists(table, bucket) do
    if Store.bucket?(table, bucket) or Store.database?(table, bucket),
      do: :ok,
      else:
        {:error,
         flux_error(
           404,
           "not found",
           "failed to initialize execute state: could not find bucket \"#{bucket}\""
         )}
  end

  @spec flux_error(pos_integer(), binary(), binary()) :: map()
  defp flux_error(status, code, message),
    do: %{status: status, body: Jason.encode!(%{"code" => code, "message" => message})}

  # ---------------------------------------------------------------------------
  # Database admin
  # ---------------------------------------------------------------------------

  @doc """
  Creates a named database in this local instance.

  Creating an existing database is `:ok` (the engine's 409, which
  `Client.HTTP` treats as success). A name the engine refuses is its 400,
  and a sixth database on the `:v3_core` profile its 422 — see
  `InfluxElixir.Client.Local.DatabaseRules`. `retention:` must be a
  duration the engine reads (`"30d"`, `"1h 30m"`, `"1.5h"`, `"0"`), or it
  is the engine's 400; the double keeps no retention for a database, so nothing
  expires. (A v2 bucket's `retention:` is applied: see `create_bucket/3`.)
  """
  @impl true
  @spec create_database(
          InfluxElixir.Client.connection(),
          binary(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_database(%{table: table} = conn, name, opts \\ []) do
    with :ok <- require_capability(conn, :create_database),
         :ok <- check_retention(Keyword.get(opts, :retention), name),
         :ok <-
           Store.create_database(table, name, &DatabaseRules.check_new(name, &1, conn.profile)) do
      :ok
    end
  end

  # `retention:` is sent as the engine's `retention_period`, a duration
  # string it reads before anything else in the request (verified against
  # InfluxDB 3 Core): one or more `<number><unit>` parts, optionally
  # spaced, a fraction allowed (`1.5h`), units case-sensitive (`M` months,
  # `m` minutes), or a bare `0`. Anything else is its 400, ending in the
  # `at line 1 column N` its JSON parser appends: the byte just before the
  # closing brace of the body `Client.HTTP` sends (verified). The double
  # stores no retention for a database: nothing expires.
  @duration_units ~w(nanos nsec ns usec us µs millis msec ms seconds second secs sec s
                     minutes minute mins min m hours hour hrs hr h days day d weeks week w
                     months month M years year y)
  @duration ~r/^\s*(?:0|(?:\d+(?:\.\d+)?\s*(?:#{Enum.join(@duration_units, "|")})\s*)+)\s*$/u

  @spec check_retention(term(), binary()) :: :ok | {:error, map()}
  defp check_retention(nil, _name), do: :ok

  defp check_retention(retention, name) when is_boolean(retention),
    do: retention_error("invalid type: boolean `#{retention}`", retention, name)

  defp check_retention(retention, name) when is_binary(retention) or is_atom(retention) do
    text = to_string(retention)

    if Regex.match?(@duration, text),
      do: :ok,
      else: retention_error(~s|invalid value: string "#{text}"|, retention, name)
  end

  defp check_retention(retention, name) when is_integer(retention),
    do: retention_error("invalid type: integer `#{retention}`", retention, name)

  defp check_retention(retention, name) when is_float(retention),
    do: retention_error("invalid type: floating point `#{retention}`", retention, name)

  defp check_retention(retention, name),
    do: retention_error("invalid type: `#{inspect(retention)}`", retention, name)

  @spec retention_error(binary(), term(), binary()) :: {:error, map()}
  defp retention_error(what, retention, name) do
    position =
      case Jason.encode(%{"db" => name, "retention_period" => retention}) do
        {:ok, body} -> " at line 1 column #{byte_size(body) - 1}"
        {:error, _unencodable} -> ""
      end

    {:error, %{status: 400, body: "serde json error: #{what}, expected a duration" <> position}}
  end

  @doc """
  Returns the databases as maps with a single `"name"` key, sorted, with
  the engine's own `_internal` among them as InfluxDB 3 lists it.
  """
  @impl true
  @spec list_databases(InfluxElixir.Client.connection()) ::
          {:ok, [map()]} | {:error, term()}
  def list_databases(%{table: table} = conn) do
    with :ok <- require_capability(conn, :list_databases) do
      {:ok, Enum.map(database_names(table), &%{"name" => &1})}
    end
  end

  @doc """
  Deletes a database from this local instance.

  Returns `{:error, %{status: 404, body: "the requested resource was not
  found: name"}}` — the engine's answer (verified) — if the database does
  not exist.
  """
  @impl true
  @spec delete_database(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_database(%{table: table} = conn, name) do
    with :ok <- require_capability(conn, :delete_database),
         :ok <- deletable(name) do
      # Dropping a database drops its tables: points and schema go with it,
      # so a re-created database starts empty.
      case Store.drop_database(table, name) do
        :ok -> :ok
        :error -> {:error, %{status: 404, body: "the requested resource was not found: #{name}"}}
      end
    end
  end

  # The engine's answer for its own database (verified).
  @spec deletable(binary()) :: :ok | {:error, map()}
  defp deletable("_internal"), do: {:error, %{status: 500, body: "cannot delete internal db"}}
  defp deletable(_name), do: :ok

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
  def create_bucket(%{table: table} = conn, name, opts \\ []) do
    with :ok <- require_capability(conn, :create_bucket) do
      case Keyword.get(opts, :retention, 0) do
        seconds when seconds in 1..3599 ->
          {:error,
           %{
             status: 500,
             body:
               Jason.encode!(%{
                 "code" => "internal error",
                 "message" => "retention policy duration must be at least 1h0m0s"
               })
           }}

        seconds ->
          created_at =
            case Store.bucket(table, name) do
              %{created_at: at} -> at
              _new -> nanosecond_timestamp()
            end

          Store.put_bucket(table, name, %{retention: seconds, created_at: created_at})
          :ok
      end
    end
  end

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
  def list_buckets(%{table: table} = conn) do
    with :ok <- require_capability(conn, :list_buckets) do
      org_id = hex_id(Map.get(conn, :org, "local"))

      bkts =
        table
        |> Store.buckets()
        |> Enum.map(fn {name, %{retention: seconds} = meta} ->
          bucket_map(name, seconds, org_id, Map.get(meta, :created_at, nanosecond_timestamp()))
        end)

      {:ok, bkts}
    end
  end

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
  def delete_bucket(%{table: table} = conn, name) do
    with :ok <- require_capability(conn, :delete_bucket) do
      case Store.delete_bucket(table, name) do
        :ok -> :ok
        :error -> {:error, %{status: 404, body: "bucket not found: #{name}"}}
      end
    end
  end

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
  def create_token(%{table: table, profile: profile} = conn, name, opts \\ []) do
    with :ok <- require_capability(conn, :create_token),
         {:ok, {kind, _path, body}} <- TokenRequest.build(name, opts),
         :ok <- token_endpoint(kind, profile),
         {:ok, expiry_secs} <- check_expiry(Keyword.get(opts, :expiry_secs), body) do
      case Store.create_token(table, name, &new_token(&1, name, expiry_secs)) do
        {:ok, token} ->
          {:ok, token}

        :exists ->
          {:error, %{status: 409, body: "token name already exists, #{name}"}}
      end
    end
  end

  @spec token_endpoint(TokenRequest.kind(), profile()) :: :ok | {:error, map()}
  defp token_endpoint(:resource, profile) when profile != :v3_enterprise,
    do: {:error, %{status: 404, body: "Not found"}}

  defp token_endpoint(_kind, _profile), do: :ok

  # `expiry_secs` is a u64 to the engine; anything else is its JSON error,
  # at the end of the value — the last key of the body (verified).
  @spec check_expiry(term(), binary()) :: {:ok, non_neg_integer() | nil} | {:error, map()}
  defp check_expiry(nil, _body), do: {:ok, nil}
  defp check_expiry(secs, _body) when is_integer(secs) and secs >= 0, do: {:ok, secs}

  defp check_expiry(secs, body) do
    what =
      cond do
        is_integer(secs) -> "invalid value: integer `#{secs}`"
        is_float(secs) -> "invalid type: floating point `#{secs}`"
        is_boolean(secs) -> "invalid type: boolean `#{secs}`"
        is_binary(secs) -> ~s|invalid type: string "#{secs}"|
        true -> "invalid type: `#{inspect(secs)}`"
      end

    {:error,
     %{
       status: 400,
       body: "serde json error: #{what}, expected u64 at line 1 column #{byte_size(body) - 1}"
     }}
  end

  @spec new_token(pos_integer(), binary(), non_neg_integer() | nil) :: map()
  defp new_token(id, name, expiry_secs) do
    created = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    secret = "apiv3_" <> Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false)

    %{
      "id" => id,
      "name" => name,
      "token" => secret,
      "hash" => :sha512 |> :crypto.hash(secret) |> Base.encode16(case: :lower),
      "created_at" => DateTime.to_iso8601(created),
      "expiry" => expiry_secs && DateTime.to_iso8601(DateTime.add(created, expiry_secs))
    }
  end

  @doc """
  Deletes the token named `name` as InfluxDB 3 does: `:ok`, the engine's
  404 for a name no token has, its 405 for the operator token `_admin`.
  """
  @impl true
  @spec delete_token(InfluxElixir.Client.connection(), binary()) ::
          :ok | {:error, term()}
  def delete_token(%{table: table} = conn, name) do
    with :ok <- require_capability(conn, :delete_token) do
      cond do
        name == "_admin" ->
          {:error, %{status: 405, body: "cannot delete operator token"}}

        Store.delete_token(table, name) == :ok ->
          :ok

        true ->
          {:error, %{status: 404, body: "the requested resource was not found: #{name}"}}
      end
    end
  end

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
  def health(conn) do
    with :ok <- require_capability(conn, :health) do
      {:ok, health_body(conn.profile)}
    end
  end

  @spec health_body(profile()) :: map()
  defp health_body(:v2) do
    %{
      "name" => "influxdb",
      "message" => "ready for queries and writes",
      "status" => "pass",
      "checks" => [],
      "version" => "local",
      "commit" => "local"
    }
  end

  defp health_body(_v3), do: %{"status" => "pass"}

  # ---------------------------------------------------------------------------
  # Private — storage policy
  # ---------------------------------------------------------------------------

  # v3 Core/Enterprise auto-create databases on write; v2 requires pre-existing
  @spec ensure_database(Store.t(), binary(), profile()) :: :ok | {:error, term()}
  defp ensure_database(table, database, profile) when profile in [:v3_core, :v3_enterprise] do
    Store.create_database(table, database, &DatabaseRules.check_new(database, &1, profile))
  end

  # v2 writes target buckets, so anything registered via `create_bucket/3` is a
  # valid target. Names seeded through `databases:` at start are accepted too,
  # so a v2 connection can be prepared either way.
  defp ensure_database(table, bucket, :v2) do
    cond do
      Store.bucket?(table, bucket) ->
        :ok

      Store.database?(table, bucket) ->
        :ok

      true ->
        # The engine's answer for a bucket that does not exist (verified).
        {:error,
         %{
           status: 404,
           body:
             Jason.encode!(%{
               "code" => "not found",
               "message" => "bucket \"#{bucket}\" not found"
             })
         }}
    end
  end

  # The SQL executor's view of the store: a table's points, or `:error` for
  # one the catalog does not have (the engine's "table not found"). A table
  # exists once a write registered its columns, not while it holds points:
  # an Enterprise DELETE of every row leaves an empty table, which answers
  # no rows as a DataFusion table does.
  @spec point_source(Store.t(), binary(), binary()) :: {:ok, [point_map()]} | :error
  defp point_source(table, database, measurement) do
    if Store.table?(table, database, measurement),
      do: {:ok, Store.points(table, database, measurement)},
      else: :error
  end

  # ---------------------------------------------------------------------------
  # Private — utilities
  # ---------------------------------------------------------------------------

  @spec bucket_map(binary(), non_neg_integer(), binary(), binary()) :: map()
  defp bucket_map(name, retention, org_id, created_at) do
    id = hex_id(name)
    base = "/api/v2/buckets/#{id}"

    %{
      "id" => id,
      "orgID" => org_id,
      "type" => "user",
      "name" => name,
      "retentionRules" => [
        %{
          "type" => "expire",
          "everySeconds" => retention,
          "shardGroupDurationSeconds" => shard_group_seconds(retention)
        }
      ],
      "createdAt" => created_at,
      "updatedAt" => created_at,
      "links" => %{
        "labels" => base <> "/labels",
        "members" => base <> "/members",
        "org" => "/api/v2/orgs/#{org_id}",
        "owners" => base <> "/owners",
        "self" => base,
        "write" => "/api/v2/write?org=#{org_id}&bucket=#{id}"
      },
      "labels" => []
    }
  end

  # InfluxDB 2's ids are 16 hex digits; these are derived from the name, so
  # they stay the same across calls and connections.
  @spec hex_id(binary()) :: binary()
  defp hex_id(name) do
    :crypto.hash(:sha256, name) |> binary_part(0, 8) |> Base.encode16(case: :lower)
  end

  # The engine's timestamps: RFC 3339 with nine fractional digits.
  @spec nanosecond_timestamp() :: binary()
  defp nanosecond_timestamp do
    ns = System.os_time(:nanosecond)
    seconds = Integer.floor_div(ns, 1_000_000_000)
    stamp = seconds |> DateTime.from_unix!() |> DateTime.to_iso8601() |> String.trim_trailing("Z")

    stamp <>
      "." <> String.pad_leading(Integer.to_string(Integer.mod(ns, 1_000_000_000)), 9, "0") <> "Z"
  end
end
