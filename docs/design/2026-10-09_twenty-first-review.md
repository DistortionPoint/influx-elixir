# Twenty-First Review: The Client Never Raises on What a Caller Passes

**Date**: 2026-10-09
**Scope**: what commit 735fc6e added. In the client: `Client.Local`'s facade
guards, `Client.HTTP`, `Flight.Client` and the `InfluxElixir` facade with
`Write.Writer`. In `Client.Local`: InfluxQL keywords against the next
character, the duplicated glue rules, and quadratic condition scans.
**Issue**: scheduled quality sweep (no open issues). This reviews 735fc6e
([`2026-10-08_twentieth-review`](2026-10-08_twentieth-review.md)).

---

## Problem

The twentieth review made `Client.Local`'s entry points total. The review of
it found the same class of raise one layer out, and a few left inside:

- `Local.query_sql_stream/3` checked `is_list(opts)`, not a keyword list: an
  improper list raised, and `[1]` ran the query.
- `Flight.Client.bounded_connect/2` caught raises only. The task was linked,
  so an exit or a throw ended the caller, and a `{:exit, _}` from
  `Task.yield/2` was a `CaseClauseError`.
- `Flight.Client.query/3` raised on a statement or database that is not UTF-8
  (`Jason.encode!`), on a token that is not a string, and on a host that is
  not a string. It called `"localhost:8181"` an IPv6 address.
- `Client.HTTP` raised on options that are not a keyword list, on a URL value
  that is not text (`write(conn, lp, database: %{})`, `delete_database(conn,
  {1})`), and on a write body that is not iodata.
- The facade and `Write.Writer` read the options and the body (`byte_size/1`)
  before the client ran, so they raised on what the client would have named,
  and on iodata, which every client accepts.
- `Local.start/1` raised `FunctionClauseError` for an improper list or a
  non-list, and refused `databases: nil`, which a config without the key gives.
- A precision that is not UTF-8 came back as raw bytes in Local's 400. Core
  writes U+FFFD (verified).

## Decision

- **Each client names its own errors.** The facade and `Writer` never decide
  for it: what they cannot read goes through as given. `Client.Local` refuses
  by name with a 400. `Client.HTTP` returns `{:invalid_options, opts}`,
  `{:invalid_value, key, value}` or `{:invalid_body, body}`, before anything
  is sent. A JSON body keeps its `{:unencodable_body, message}`.
- **iodata is a write body everywhere.** The specs say `iodata()`; `Writer`
  flattens it once, so telemetry counts bytes and lines as before.
- **`bounded_connect/2` monitors and never links.** Any raise, throw or exit in
  the connect is `{:connect_failed, banner}`, also for a caller that traps
  exits. A result that arrives as the bound kills the process is dropped.
- **`Flight.Client.query/3` checks first.** The host, the token and the JSON
  ticket are checked before any connection. IPv6 is a leading `[` or two
  colons or more; one colon is `{:invalid_host, host}`, since the port
  belongs in `:port`. A missing key still raises `KeyError`: that is a
  programming error, and the docs now say so.
- **`add_connection/2`** returns `{:error, {:invalid_options, opts}}`.

### InfluxQL

The review found keywords glued to the next character that Local answered
where Core refuses: `GROUP BY"host"` gave rows. It also found error bodies at
the wrong place, and a regex column against `FROM` that Local refused.

- **Probed per keyword.** `LIMIT`, `OFFSET`, `SLIMIT`, `SOFFSET`, `WHERE`,
  `GROUP BY`, `ORDER BY`, `AS`, `ON`, `fill` and `tz` were probed against
  about 30 characters, control characters included. Core's rule for each is
  encoded and pinned in `InfluxQLGlueCases.keyword_glue/0` (about 120 cases).
  - An operator or parenthesis after `GROUP BY` is `Nom` at `GROUP`; any
    other non-word character is "expected BY".
  - `ORDER BY` mirrors that.
  - `LIMIT` and its kin are `Nom` at the keyword.
  - `AS` gives "invalid field alias" after an operator, and `Nom` at 0
    otherwise.
  - `ON` is `Nom` at `ON`.
- **Regex columns.** `/v/FROM m`, `/v/,/w/FROM`, `/v/AS x` and `/v/*FROM` read
  as Core reads them; the comment scanner no longer takes `/v/*` for `/*`.
  A cast with an unknown type (`v::fieldFROM`) is Core's type error at the
  end of `::`. A valid cast stays refused by name. `1AS x`, a planning error
  in Core, is refused by name.
- **One definition of the glue sets.** The glue characters and the `FROM`
  keyword pattern live in `InfluxQLText`. Before, they were written in five
  places, and that drift was the cause of both findings above.
- **Linear scans.** `SQLWhere.scan_where` ran a regex over the remaining text
  at every character. `SQLSimplify.conjuncts` used `++` on a left-nested
  tree. `InfluxQLWhere.parse_atom` rescanned each group once per nesting
  level. Each is now a single pass.
- **Raises found while probing.** `fill'(null)` and `ORDER'` raised
  `CaseClauseError`; both are answered now.

## Known differences left

- `GROUP BY time<c>1m)` with a word-like character `<c>`, `v > (w > 1)`, and
  older fuzz mismatches the agent's differential run listed. These are the
  next review's work.
- A SELECT list of thousands of items is still quadratic (4,000 items take
  1.5 s).
- Flight over an IPv6 address: use the HTTP transport.
- `query_influxql` takes no `params:`.

## Verification

- Unit: 2,179 tests, three runs, one at a time; coverage 92.92%; credo,
  dialyzer, docs and both compile environments clean.
- Integration on fresh `influxdb:3.10.1-core` (`--wal-snapshot-size 100000`)
  and 2.7, run twice: Core 683 tests, InfluxDB 2.7 90 tests; auth-enabled
  Core tokens 8 tests.
- The reviewer's crash inputs, and the facade, `Writer` and `add_connection`
  inputs found while fixing them: each answered without a raise.
- InfluxQL: about 4,900 statements compared against Core before and after.
  None that matched Core changed, and about 500 moved to a match.
- Agents edited only, one at a time; every test run was mine, sequential.
