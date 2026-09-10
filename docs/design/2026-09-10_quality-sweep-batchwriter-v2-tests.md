# Quality Sweep: BatchWriter `:database`, v2 Bucket Writes, Test Rules

**Date**: 2026-09-10
**Scope**: Bugs and test-rule violations found by the scheduled code/test analysis (no open GitHub issues beyond #12/#13, already fixed in `2026-09-10_localclient-v3-sql-fidelity.md`)

---

## Bugs found and fixed

### 1. `BatchWriter` ignored its `:database` option

`init/1` stored `:database` in state but every flush called
`Writer.write(connection, lines, state.write_opts)`, so the option never reached
the client and all flushes landed in the connection's default database. The
existing test even passed `database: "ignored"` to prove that `write_opts` won,
without noticing that the option did nothing on its own.

**Fix**: `resolve_write_opts/1` puts `:database` into `write_opts` with
`Keyword.put_new/3`, so an explicit `write_opts[:database]` still wins.
Regression test: "the :database option is the write target for every flush".

### 2. `Client.Local` `:v2` rejected writes to created buckets

`ensure_database/3` for `:v2` only consulted the `:databases` set seeded at
`start/1`. A bucket created with `create_bucket/3` lived in `:buckets`, so
`write/3` to it returned `404 database not found` — unlike real InfluxDB v2, where
a bucket is precisely a write target.

**Fix**: the `:v2` clause accepts a name present in either set. Contract test
"a bucket created via create_bucket accepts writes" runs against Local and real
v2.

### 3. Quadratic list building

`parse_where_clauses/1` (`acc ++ conds`) and `Flight.Reader.decode_batches/2`
(`acc ++ rows`) appended inside a reduce. Both now prepend and reverse/concat
once. `parse_single_where_clause/1` returns a single clause instead of a
one-element list.

## Test-rule violations fixed

| Rule | Violation | Fix |
|---|---|---|
| Testing function exports is BAD | `proto_test.exs` asserted `Code.ensure_loaded?` / `function_exported?` on the generated gRPC stub | Describe block removed |
| Inconsistent tests are BAD | `batch_writer_test.exs` used `:timer.sleep(200)` / `(500)` and asserted `>= 1` | Bounded `wait_until/2` polling on public API; retry test uses `base_retry_delay_ms: 1` |
| Tests must be isolated / async | `supervisor_test.exs` was not `async: true` and used fixed connection names `:isolation_a/b` | Unique names, `async: true`, `on_exit` cleanup |
| Just asserting `true` is useless | "supervisor uses :one_for_one strategy" only asserted `is_list(children)` | Asserts `init/1` returns `strategy: :one_for_one` with one child per connection |
| ONLY test actual functionality | 20 tests asserted only `is_list/is_map` on results | Each now asserts the actual rows, names, token fields, or `rows_affected` |

Tightening the type-only assertions is what exposed bugs 1 and 2: the Flux
delegation tests could not write to a created bucket, and the timer-flush test
could not find its row in the configured database.

## Second pass (same day)

### Bug: quadratic Flight row assembly

`Flight.Reader.zip_columns/3` built each row by calling `Enum.at(col, i)` on
every column list, so decoding a record batch of `n` rows cost `O(n²)` per
column. Columns are now converted to tuples once and cells read with `elem/2`;
a column shorter than `n` still yields `nil`, as before.

### Refactor: one request path in `Client.HTTP`

Fourteen public functions repeated the same three-clause `case` on
`do_request/6` (success status → result, other status → `%{status, body}`,
transport failure → `{:connection_error, reason}`). `request/7` takes the list
of success statuses and returns `{:ok, %Finch.Response{}}` or the normalised
error; every function is now a `with` over it. No behavioural change, verified
by the contract suite against a live InfluxDB 3 Core.

### More test-rule fixes

| Rule | Violation | Fix |
|---|---|---|
| Testing function exports is BAD | `http_test.exs` asserted the behaviour attribute and callback exports | Removed with its `setup_all` |
| Testing tests is BAD | `connection_test.exs` compared `finch_name/1` to the function it delegates to | Asserts the concrete atom |
| Just asserting `true` is useless | `is_binary`/`is_integer`/`is_map` assertions in Flight, FlatBuffer, BatchWriter, SQL, stream and supervisor tests | Assert decoded values, field contents, row values, or a working health call |

## Documentation corrected

- `CLAUDE.md` claimed there is no `application.ex`; there is one, and it starts
  `InfluxElixir.Supervisor` with configured connections.
- `BatchWriter` moduledoc now states the `:database` / `:write_opts` precedence.

## Verification

```bash
mix compile --warnings-as-errors
mix test
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration
mix credo --strict
mix dialyzer
mix format --check-formatted
```
