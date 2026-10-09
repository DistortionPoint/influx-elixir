# Twentieth Review: Options That Are Not Usable, Flight Never Ends the Caller

**Date**: 2026-10-08
**Scope**: what commit 0c04b29 added. In the client: `Client.Local`'s entry
points and options, `Client.HTTP`'s JSON bodies, `Flight.Client` and
`Flight.Reader`. In `Client.Local`: the InfluxQL blank rule, its tokenizer and
the clause rules, and the SQL regex rewrite check.
**Issue**: scheduled quality sweep (no open issues). This reviews 0c04b29
([`2026-10-08_nineteenth-review`](2026-10-08_nineteenth-review.md)).

---

## Problem

The nineteenth review made values that are not text a named error. Its own
change, and the paths next to it, still raised:

- **A regression.** `Scope.resolve_database/2` began returning a refusal map
  for a `:database` that is not a string. Two InfluxQL callers matched only
  `:no_database_specified`, so `query_influxql(conn, q, database: 1)` raised
  `CaseClauseError`.
- **Options.** These raised instead of answering:
  - options that are not a keyword list (`nil`, a map);
  - a `:precision` that is no word (`%{}`);
  - a v2 bucket name, or a `:retention`, that is not UTF-8 (`Jason.encode!`);
  - `:permissions` that are not a list (in `Client.HTTP` too: the token request
    is shared);
  - `Local.check_sql/1` of a non-string.
- **Parity.** `Client.HTTP` sends iodata as a write body; `Client.Local`
  refused it.
- **JSON bodies.** `Jason.encode/1` raises, rather than returning an error,
  for an improper list and for a map key it has no form for.
- **Flight.** A bare IPv6 host (`::1`) passed the bracket check and crashed
  the caller through the linked connect task.
- **Flight bounds.** A null or struct field was bounded by its share of the
  cells, so a wide batch (80 null columns beside a column of 8192 rows) was
  refused.
- **SQL regex rewrite.** An unterminated class (`D[$[`) raised
  `FunctionClauseError`. `SQLRustRegex.check/1` refuses it first, so no
  query reached it.

## Decision

- Both InfluxQL callers pass the refusal through.
- `Client.Local`'s facade refuses options that are not a keyword list by name:
  `400 "Client.Local: the options are not a keyword list"`. A precision that
  is no word, a retention or a database name that is not UTF-8 are refusals
  named the same way. `:permissions` that are not a list are
  `{:error, {:invalid_permission, value}}`, as a bad permission already was.
- `Local.write/3` reads a list body as iodata; one that is not iodata stays
  the refusal it was.
- `Client.HTTP.json_body/1` rescues Jason's raises into
  `{:error, {:unencodable_body, message}}`.
- `Flight.Client` treats any host with a colon as
  `{:error, {:ipv6_unsupported, host}}`. `bounded_connect/2` turns a raise
  inside the connect into `{:error, {:connect_failed, message}}`.
- `Flight.Reader` lets a field without buffers cover the batch's rows, which
  the body bounds whenever any field carries data. A batch of such fields
  alone is still bounded by cells.
- `SQLRegexRewrite` reads an unterminated class as no literal: total without
  the check before it.
- `Local.start/1` raises a named `ArgumentError` for database names that are
  not strings: it raises for bad names already, and a test setup is where a
  raise belongs.
- `InfluxQLBlankRegex` stays out of the coverage count. It runs only while the
  InfluxQL patterns compile, and a construct it cannot rewrite now fails that
  compile.

### InfluxQL

The review also found that InfluxQL keywords standing directly against the next
character were refused, or answered with a body Core does not give. Each fix is
a case in `InfluxQLGlueCases` with the answer live Core gave in the same run.

- `WHERE` against `(`, `+` or `-`; `SELECT` against `*` or `(`; `FROM` after
  `*`, `)` or a quote, and against `/re/`, read as Core reads them.
  `SHOW … WHERE(…)` is `[]`.
- `LIMIT`, `OFFSET`, `SLIMIT`, `SOFFSET` and `GROUP BY` against a parenthesis or
  a sign give Core's `Nom` error from the keyword.
- `tz(…)` where an operand is wanted is Core's "only valid function calls"
  error. It had been read as the `tz` clause.
- A statement that starts with a quote or a slash is Core's `Nom` at its first
  character.
- In SHOW, the scan no longer raises "unterminated …" up front. It records
  where the literal starts, and only a clause that reads a name, a regex or an
  expression there gives the lexer error. Elsewhere the clause fails at the
  quote, as in Core. This also fixed a `MatchError` on
  `SHOW MEASUREMENTS WITH MEASUREMENT = /x`.
- The tokenizer skips a run of blanks once (it trimmed the rest of the run at
  every blank byte).
- `InfluxQLBlankRegex.blank_pattern/1` tracks bracket classes, and fails the
  compile on any construct it cannot rewrite faithfully. That surfaced
  `[\f\v]` in the blank check: in PCRE, `\v` is every vertical space,
  `\n` and `\r` included. It is now `[\x0b\x0c]`. The patterns that read
  quoted time content keep `\s`, with the reason in `influxql_time.ex`.

## Known differences left

- Flight over an IPv6 address: use the HTTP transport.
- Refused by name where Core answers: InfluxQL subqueries, a number glued to
  `FROM`, `WHERE` glued to a quote, `*`, `=` or `)` in a SELECT (Core gives a
  `Nom` error), and text left after the clauses that starts with a quote.
- `SHOW TAG KEYS FROM m WHERE(…) LIMIT 1` is an internal 500 from Core; Local
  refuses it by name.
- `query_influxql` takes no `params:`.

## Verification

- Unit: 2,151 tests, three runs, one at a time; coverage 92.93%; credo,
  dialyzer, docs and both compile environments clean.
- Integration on fresh `influxdb:3.10.1-core` (`--wal-snapshot-size 100000`)
  and 2.7, run twice: Core 680 tests, InfluxDB 2.7 90 tests; auth-enabled
  Core tokens 8 tests.
- The reviewer's crash inputs (16), each answered without a raise.
- 5,850 corrupted Flight frames (three seeds) decode under a 16 MB heap cap
  after the bound changed; 81 columns (80 null) of 8192 rows decode.
- 30,000 random patterns through the SQL regex rewrite check: no raise.
- A `FROM/^name$/` case was anchored on the fixture's own name: the agent's
  probe matched a prefix only its probe database had. Core gives the same rows
  for the anchored form.
- Agents edited only, one at a time; every test run was mine, sequential.
