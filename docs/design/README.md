# Design Documents

One document per change that needed a decision, named
`YYYY-MM-DD_design-topic-name.md`, written from
[`templates/design-document-template.md`](templates/design-document-template.md).
A document records the problem with evidence, the design, the files touched
and the verification that closed it. When a later document supersedes an
earlier one, the earlier one gets a banner at the top pointing forward (see
`2026-03-17_localclient-first-last-aggregates.md`).

## Index

| Date | Document | Subject |
|---|---|---|
| 2026-03-12 | [`influxdb-elixir-client-library`](2026-03-12_influxdb-elixir-client-library.md) | Original library design and consuming-application requirements |
| 2026-03-13 | [`elixir-architecture-review`](2026-03-13_elixir-architecture-review.md) | Architecture review and remediation plan |
| 2026-03-13 | [`integration-test-plan`](2026-03-13_integration-test-plan.md) | Integration testing and `Client.Local` fidelity plan |
| 2026-03-16 | [`contract-testing-redesign`](2026-03-16_contract-testing-redesign.md) | Shared contract suite run against Local and real engines |
| 2026-03-17 | [`connection-registry-fix`](2026-03-17_connection-registry-fix.md) | Connection registry never populated |
| 2026-03-17 | [`facade-local-compatibility`](2026-03-17_facade-local-compatibility.md) | Facade connection resolution with `Client.Local` |
| 2026-03-17 | [`localclient-aggregate-sql`](2026-03-17_localclient-aggregate-sql.md) | `DATE_BIN` aggregates in `Client.Local` |
| 2026-03-17 | [`localclient-first-last-aggregates`](2026-03-17_localclient-first-last-aggregates.md) | *Superseded* — `first()`/`last()` (not valid v3 SQL) |
| 2026-09-10 | [`localclient-v3-sql-fidelity`](2026-09-10_localclient-v3-sql-fidelity.md) | `first_value`/`last_value`, string literal typing, `Client.Local:` errors (#12, #13) |
| 2026-09-10 | [`quality-sweep-batchwriter-v2-tests`](2026-09-10_quality-sweep-batchwriter-v2-tests.md) | BatchWriter `:database`, v2 bucket writes, test-rule fixes, Flight row assembly |
| 2026-09-10 | [`v2-http-fidelity`](2026-09-10_v2-http-fidelity.md) | `api_version: :v2`, annotated-CSV Flux, float precision, telemetry clock |
| 2026-09-11 | [`telemetry-batchwriter-supervisor-fixes`](2026-09-11_telemetry-batchwriter-supervisor-fixes.md) | Telemetry emission, 4xx retry classification, supervisor wiring, `transport: :flight`, `time` as `DateTime` |
| 2026-09-11 | [`http-pool-timeout`](2026-09-11_http-pool-timeout.md) | Finch `pool_timeout` and checkout-timeout error mapping (#14) |
| 2026-09-12 | [`local-parser-extraction`](2026-09-12_local-parser-extraction.md) | `SQLParser` and `LineProtocolParser` split out of `Client.Local` |
| 2026-09-12 | [`local-atomic-ets-layout`](2026-09-12_local-atomic-ets-layout.md) | Per-key ETS layout: no lost concurrent writes, linear bulk writes (#15) |
| 2026-09-14 | [`local-sql-stats-selectors-distinct`](2026-09-14_local-sql-stats-selectors-distinct.md) | `STDDEV`/`VAR` family, field arithmetic, selectors, multi-column `DISTINCT`, null omission, `check_sql/1`, HTTP timestamp typing (#16, #17) |
| 2026-09-14 | [`local-time-filters-count-distinct`](2026-09-14_local-time-filters-count-distinct.md) | `now()` and strict `time` comparands, `COUNT(DISTINCT)`, `IS NULL`, `MAX(time)`, `DISTINCT ORDER BY`, real `BatchWriter` backpressure |
| 2026-09-15 | [`local-ctes-projected-expressions`](2026-09-15_local-ctes-projected-expressions.md) | `WITH` CTEs, projected arithmetic, table qualifiers, joins/subqueries refused by name (#18) |
| 2026-09-15 | [`local-where-boolean-logic`](2026-09-15_local-where-boolean-logic.md) | `WHERE` as a boolean expression: `OR`/`NOT`/parentheses, `<>`, `BETWEEN`, `LIKE`, `LIMIT 0`, string-vs-number comparison |
| 2026-09-15 | [`local-median-cross-join`](2026-09-15_local-median-cross-join.md) | `median()`, `CROSS JOIN`, arithmetic on either side of a `WHERE` comparison, schema error for unknown columns (#19) |
| 2026-09-15 | [`local-schema-errors`](2026-09-15_local-schema-errors.md) | Unknown column in any clause is the engine's schema error; `GROUP BY` without an aggregate, ungrouped projections, grouped `ORDER BY` |
| 2026-09-16 | [`local-cast-order-by`](2026-09-16_local-cast-order-by.md) | `CAST` / `::TYPE` everywhere an expression is allowed, multi-term `ORDER BY`, run-time cast failure shape (#20) |
| 2026-09-16 | [`parser-single-select-split`](2026-09-16_parser-single-select-split.md) | One `split_select/1` replaces eight table-after-FROM regexes |
| 2026-09-17 | [`local-sql-executor-extraction`](2026-09-17_local-sql-executor-extraction.md) | SQL execution split into `SQLExecutor`; `DELETE` with `OR` crash fixed |
| 2026-09-17 | [`local-in-lists-and-constants`](2026-09-17_local-in-lists-and-constants.md) | `IN`-list items as comparands; constants in select lists |
| 2026-09-17 | [`local-write-schema-and-partial-writes`](2026-09-17_local-write-schema-and-partial-writes.md) | Column schema fixed by first write, partial writes, reserved `time`, int64 range, `delete_database` drops data |
| 2026-09-22 | [`local-offset`](2026-09-22_local-offset.md) | `LIMIT n OFFSET m` pagination (#21) |
| 2026-09-22 | [`local-v2-write-rules`](2026-09-22_local-v2-write-rules.md) | `:v2` profile write rules verified against InfluxDB 2.7: 422 conflicts, all-or-nothing parse errors, `time` field dropped |
| 2026-09-22 | [`encoder-validation-and-reserved-time`](2026-09-22_encoder-validation-and-reserved-time.md) | `LineProtocol.encode/1` refuses lines no server accepts (newline corruption verified); Local's `time` wording per table state; `ResponseParser` timestamp shape guard |
| 2026-09-23 | [`precision-spellings-and-connection-plumbing`](2026-09-23_precision-spellings-and-connection-plumbing.md) | Local accepts the engines' precision spellings and `auto` (thresholds verified); duplicate points merge on read as both engines do; bucket retention and 404s as the engines answer; admin `:retention` docs; no idle Finch pool with `:finch_name`; clearer `fetch!/1`; observable Writer and admin tests |
| 2026-09-23 | [`flight-null-columns`](2026-09-23_flight-null-columns.md) | Flight rows omit null columns as HTTP does; verified identical on 25,000 mixed-type rows |
| 2026-09-23 | [`local-influxql`](2026-09-23_local-influxql.md) | Local answers InfluxQL in the engine's shape (50/50 verified); SQL `ORDER BY time` and time literals keep nanoseconds |
| 2026-09-24 | [`local-flux-pipeline`](2026-09-24_local-flux-pipeline.md) | Local runs every Flux stage or refuses it (24/24 verified against InfluxDB 2.7); filter grammar, `_start`/`_stop`, series table order |
| 2026-09-24 | [`sql-references-and-stream-types`](2026-09-24_sql-references-and-stream-types.md) | HTTP stream rows coerced like `query_sql`; Local resolves `GROUP BY`/`ORDER BY` aliases and positions and groups `DATE_BIN` with columns |
| 2026-09-24 | [`changelog-release-headings`](2026-09-24_changelog-release-headings.md) | #22: headings for 0.1.22–0.1.31 backfilled from the tags; the publish job writes each release's heading; a test guards it |
| 2026-09-24 | [`local-write-read-performance`](2026-09-24_local-write-read-performance.md) | Local merges duplicates only where one was written; parser fast paths (writes 2.8×, `COUNT` 4.6× faster); escaped and trailing backslashes as the engines read them |
| 2026-09-25 | [`local-sql-nulls-and-operators`](2026-09-25_local-sql-nulls-and-operators.md) | Local: three-valued WHERE, DataFusion null ordering and `NULLS FIRST/LAST`, DISTINCT null row, LIKE escapes, `WHERE b`, `%`, unary minus |
| 2026-09-25 | [`execute-sql-and-weak-contracts`](2026-09-25_execute-sql-and-weak-contracts.md) | Local `execute_sql` answers DML/DDL as the engine refuses them (it returned `rows_affected: 0`); HTTP `execute_sql` rows typed; contract tests assert exact errors |
| 2026-09-25 | [`local-store-module`](2026-09-25_local-store-module.md) | ETS layout moved into `Client.Local.Store` (40 raw `:ets` call sites); one clock for untimed points and SQL/Flux `now()` |
| 2026-09-25 | [`atomic-writes-and-no-sync`](2026-09-25_atomic-writes-and-no-sync.md) | `write/3` takes `accept_partial:` / `no_sync:` (v3); Local models all-or-nothing writes; schema errors render the line as the engine does; repeated spaces accepted |
| 2026-09-26 | [`flight-arrow-types`](2026-09-26_flight-arrow-types.md) | Flight decodes structs, lists, durations, Utf8View, dates, decimals, binary as HTTP returns them (they were silently dropped); nested timestamps coerced on HTTP; Local's bare selector struct |
| 2026-09-26 | [`flux-csv-newlines`](2026-09-26_flux-csv-newlines.md) | InfluxDB 2's CSV turns `\n` in a value into `\r\n`; ResponseParser restores it so HTTP and Local agree |
| 2026-09-26 | [`query-formats`](2026-09-26_query-formats.md) | Local answers `format:` as HTTP does: engine CSV strings (float rendering rule), nested-value connection error, Parquet refused, unknown format 400; empty CSV cells absent |
| 2026-09-26 | [`batch-writer-shutdown`](2026-09-26_batch-writer-shutdown.md) | BatchWriter traps exits so a supervisor shutdown flushes; points encoded in the caller; one entry per retry chain |
| 2026-09-27 | [`local-database-rules`](2026-09-27_local-database-rules.md) | Local drops the implicit "default" database (HTTP's `:no_database_specified`), defaults to the first of `:databases`, applies Core's name rules, 5-database limit, missing-database 404 and `_internal` |
| 2026-09-27 | [`local-distinct-on`](2026-09-27_local-distinct-on.md) | #23: Local runs `SELECT DISTINCT ON (cols)` with the engine's semantics and refusals |
| 2026-09-30 | [`local-influxql-where-and-tag-values`](2026-09-30_local-influxql-where-and-tag-values.md) | InfluxQL WHERE with InfluxQL semantics (missing tag = `''`, regex, durations, tag ordering false, no NOT); `SHOW TAG VALUES`; SQL `~` operators; untimed lines of one write share a time |
| 2026-10-01 | [`review-of-the-fidelity-sweep`](2026-10-01_review-of-the-fidelity-sweep.md) | Review of the agent-written sweep: SQL tokenizer/comments/semicolons, params bound on the parse tree (`"$name"` keys no longer bind), line splitting as `scanLine`, v2 shard-group typing, Flux ns order, parse 3–4x faster, duplicate tests removed |
| 2026-10-01 | [`local-fidelity-sweep-and-optional-decimal`](2026-10-01_local-fidelity-sweep-and-optional-decimal.md) | Library compiled only with `decimal`; Decimal params compared as text over HTTP; ~40 Local SQL/InfluxQL/Flux/line-protocol answers made the engines'; store races; tests deduplicated and made exact |
| 2026-10-01 | [`scalar-functions-and-named-tokens`](2026-10-01_scalar-functions-and-named-tokens.md) | Issue #25: `abs`/`round`/`floor`/`ceil` wherever an expression stands, with the planner's errors; expression operands for `IS NULL`/`IN`, a literal on the left; token API rebuilt on the endpoints the servers serve |
| 2026-10-02 | [`local-sql-split-and-second-review`](2026-10-02_local-sql-split-and-second-review.md) | SQL parser split into focused modules; huge params, Int64 wrap, E-strings, quoted names, Arrow time errors, NULL time, `round(-0.0)`; InfluxQL number grammar and series order; contract no longer assumes row order or which v2 shard group reports a drop |
| 2026-10-02 | [`influxql-planner-and-module-split`](2026-10-02_influxql-planner-and-module-split.md) | Local InfluxQL as the planner reads it (unsigned arithmetic, `not`, names and the time column, quoted times, constants, parentheses, reserved words after operators); `influxql.ex` and `line_protocol_parser.ex` split by seam |
| 2026-10-02 | [`fourth-review`](2026-10-02_fourth-review.md) | Local: float overflow answers null, UInt64 columns typed, `INTEGER` casts are Int32, failing constants fold to the optimizer's 500, executor split; InfluxQL reserved words and second statements; re-entrant lock raises; whole-result `===` assertions, clock-free backpressure test |
| 2026-10-02 | [`third-review`](2026-10-02_third-review.md) | Local: unaliased aggregates named as DataFusion names them, empty time and numeric ranges fail as on Core, qualified field lists, number literals, UTC aliases; InfluxQL parse errors and `GROUP BY` order; store locks without `:global`; strict `===` in contract tests |
| 2026-10-02 | [`local-write-concurrency-retention-and-mixed-types`](2026-10-02_local-write-concurrency-retention-and-mixed-types.md) | Local: batched store writes (50 concurrent writers in 0.4 s, was a timeout), bounded chunked parse, v2 retention 422, mixed field types cut at the first differing group, `delete_bucket` clears data |
| 2026-10-04 | [`sql-one-typing-table`](2026-10-04_sql-one-typing-table.md) | `Client.Local` SQL: one table of types (planner and coerced), an exact memo, the engine's order of errors by phase, `HAVING` aliases and placeholders, `ORDER BY` names, `IS DISTINCT FROM`, a recursive `UPDATE` parser, `GRANT ROLE`, linear parsing; system-table cases only for Core |
| 2026-10-04 | [`influxql-projection-plan`](2026-10-04_influxql-projection-plan.md) | InfluxQL columns planned once (names, `LIMIT` windows, duplicate-name error in select-list order); unsigned arithmetic beside text is the coercion error; absent columns beside tags are `false`; `top()` beside arithmetic and the 500 of a function before a selector; descending ties; refusal reasons pinned |
| 2026-10-05 | [`fourteenth-review`](2026-10-05_fourteenth-review.md) | Review of 31ddadb (SQL): pruning by the engine's folding rules, one cast grammar for `::` and CAST, one table resolver, linear DML typing, named arguments, every refusal pinned to a specific reason, no tests of internals |
| 2026-10-05 | [`fourteenth-review-influxql`](2026-10-05_fourteenth-review-influxql.md) | Review of 31ddadb (InfluxQL): the planner's order of errors, the typed operands of `AND`/`OR` in pairs, chains and groups, constants alone in parentheses, clauses read in order, aggregates of tags, `fill(n)` of a plain select; lock, cost, case-table and argument tests proven; equality made strict |
| 2026-10-06 | [`fifteenth-review`](2026-10-06_fifteenth-review.md) | Review of 6e5b8fd (SQL, DML, tests): refuse what is not verified (NULL folds, regex constructs), floats answered within the documented tolerance, linear tokenizing, lock/atom/cost tests proven by mutation, no tests of internals |
| 2026-10-06 | [`fifteenth-review-influxql`](2026-10-06_fifteenth-review-influxql.md) | Review of 6e5b8fd (InfluxQL): `fill()` behind and inside a condition, `GROUP BY` beside a `WHERE`, bare operands beside comparisons of constants or of a missing column, the sign of a `fill()` number, errors that carry their position |
| 2026-10-05 | [`thirteenth-review`](2026-10-05_thirteenth-review.md) | Review of f565fdb: INSERT/UPDATE/DELETE read their operands, one error-stage table, typing without whole-node lookups, every SQL refusal pinned to its reason; selector ties and unsigned comparisons in InfluxQL; cost and lock tests proven |
| 2026-10-05 | [`twelfth-review`](2026-10-05_twelfth-review.md) | Review of b04c320: one SQL typing table, an UPDATE parser, one InfluxQL projection plan, InfluxQL refusal reasons pinned; raises and silent wrong answers fixed; duplicate identity by statement |
| 2026-10-04 | [`eleventh-review`](2026-10-04_eleventh-review.md) | Rare statements answered only in verified shapes, refused otherwise; `||` precedence, DISTINCT…HAVING, InfluxQL missing-field counts and mixed-kind comparisons; linear expression typing; the `mix test` alias as a tested module |
| 2026-10-04 | [`tenth-review`](2026-10-04_tenth-review.md) | Regressions of f0902fa: aggregate SQL cost, InfluxQL time aggregates and `WHERE` arithmetic, selector raises, statement display; nanosecond times answered as the client reads them; `mix test` path detection; load-proof wait bounds |
| 2026-10-04 | [`ninth-review`](2026-10-04_ninth-review.md) | Cause of the Core `timestamp wraparound` panic (forced snapshot of a near-largest timestamp; `--wal-snapshot-size 100000`), regressions in the 0.1.41 fixes, `mix test` alias via OptionParser, refusal ratchet pins sets |
| 2026-10-04 | [`influxql-time-aggregates-and-where-calls`](2026-10-04_influxql-time-aggregates-and-where-calls.md) | InfluxQL: aggregates of `time` beside fields, time/boolean/string arithmetic, `WHERE` strings, division by zero and `abs()`, regex flags outside the `WHERE`, `*` beside columns, nanosecond stamps answered to the microsecond a client reads |
| 2026-10-03 | [`eighth-review`](2026-10-03_eighth-review.md) | Defects in 0.1.41: InfluxQL transform crashes and empty wildcard answers, SQL engine-shaped errors, retention read cost, `mix test` path handling, refusal ratchet, Core image pinned |
| 2026-10-03 | [`seventh-review`](2026-10-03_seventh-review.md) | Review of 69cf692: InfluxQL GROUP BY wrong answers and fill(none) hang fixed, dashboard refusal rates cut (InfluxQL 37%→2.4%, SQL 57%→23%), retention modelled, each fact pinned once, mix test skips integration compiles |
| 2026-10-03 | [`local-database-retention`](2026-10-03_local-database-retention.md) | Local applies a v3 database's `retention:` as Core does: writes accepted, reads hide 10-minute chunks older than `now - retention`, schema stays, `0` is a zero period, `SHOW RETENTION POLICIES` prints it (`1h0m0s`) |
| 2026-10-02 | [`sixth-review`](2026-10-02_sixth-review.md) | Review of 2b7b801: false refusals removed (guarded division, unsigned OR), InfluxQL GROUP BY time and fill, package file list fixed, Local internals by area and hidden from docs, engine facts moved into contracts, contract-tag lint |
| 2026-10-02 | [`fifth-review`](2026-10-02_fifth-review.md) | Review of e71cf7b: query performance restored, scratch script removed from lib, contract modules split per part (suite 27-41 s → 8-10 s), shared test helpers, whole-row assertions, clock-free batch-writer retry tests |
| 2026-10-02 | [`local-sql-simplifier-and-intervals`](2026-10-02_local-sql-simplifier-and-intervals.md) | Local SQL: the simplifier's rules, casts, unsigned and float arithmetic and divisions by zero in the interval analysis, decimal-versus-float casts, integer literals past `UInt64`, the order the engine runs `AND`/`OR` operands in (fresh write against persisted table: guards answered, tag guards, what is refused), literal and parenthesised operands, `ORDER BY` aliases, `round`/`trunc` scales, the tokens of statement parser errors; 100k-point regression fixed |
| 2026-09-30 | [`writer-timer-csv-gzip-restart`](2026-09-30_writer-timer-csv-gzip-restart.md) | BatchWriter timer re-armed; one-column v3 CSV rows kept; `gzip:` owned by `Writer`, Local reads bodies as the engines do; killed connection restarts alone; HTTP `execute_sql` params and `database: nil`; encoder 6x; token API mismatch recorded |
| 2026-09-30 | [`local-write-speed-and-line-endings`](2026-09-30_local-write-speed-and-line-endings.md) | Local writes ~40% faster (byte trims, per-write column-kind cache, lazy `time` check); CRLF, `\r` and whitespace-only lines as both engines answer them |
| 2026-09-29 | [`query-admin-modules-delegate`](2026-09-29_query-admin-modules-delegate.md) | `Query.*` and `Admin.*` call the facade: connection names resolve and queries emit telemetry, as through `InfluxElixir` |
| 2026-09-29 | [`local-retention-and-health`](2026-09-29_local-retention-and-health.md) | Local refuses a `retention:` the engine refuses (duration grammar, 53 values verified); `health/1` in each server's shape |
| 2026-09-29 | [`http-names-and-buckets`](2026-09-29_http-names-and-buckets.md) | Names percent-encoded properly (`a&b` was written to `a`); bucket listing paged and lookups org-scoped (`delete_bucket` removed another org's bucket) |
| 2026-09-28 | [`issue-24-column-types`](2026-09-28_issue-24-column-types.md) | #24 not reproducible: Local refuses type conflicts on every profile; the gap is that each store's schema starts empty — guide recipe to pin production's types |
| 2026-09-28 | [`batch-writer-options`](2026-09-28_batch-writer-options.md) | BatchWriter options validated by a NimbleOptions schema (the moduledoc renders it); a connection that fails to start is unregistered and its client state released |
| 2026-09-28 | [`line-protocol-edges`](2026-09-28_line-protocol-edges.md) | Encoder refuses int64 overflow, `#` measurements and trailing backslashes, and writes a `DateTime` in the write's precision; Local answers InfluxDB 3's tab errors and both versions' timestamp ranges |
| 2026-09-27 | [`stream-connection-release`](2026-09-27_stream-connection-release.md) | `query_sql_stream/3` halts its request instead of killing the producer, so the pool connection is checked in when the consumer stops early or dies |
| 2026-09-27 | [`local-sql-identifiers`](2026-09-27_local-sql-identifiers.md) | Local folds unquoted SQL identifiers to lower case and reads `"..."` as an exact identifier, never a string, as DataFusion does |

## Verifying against a real engine

Claims about server behaviour are checked against a real InfluxDB before
they are written down. No compose file is kept in the repo; these one-liners
match the defaults in `test/support/integration_helper.ex`.

The Core image is pinned (`influxdb:3.10.1-core`, `influxdb3 --version` prints
`3.10.1`), not the floating `3-core` tag: about fifty cases pin the words of
DataFusion's internal errors, which change between engine versions, and the
double's contract is to reproduce those words exactly. Moving to a newer Core
means running the contract against it, correcting the cases that changed, and
only then changing the tag here and in the guide.

A bare `mix test` runs the unit suite only: the 71 integration modules cost about
23 s of CPU to compile and every one is excluded by tag, so `mix.exs` does not
hand `test/integration` to the test task unless a path is named (as below) or
`INTEGRATION=1` is set (`INTEGRATION=1 mix test --include integration --include
v3_core` compiles and runs them all). CI's `mix test --cover` therefore runs
exactly the tests it always ran.

```bash
# InfluxDB 3 Core on 8181 (HTTP and Flight, no auth). A write is answered
# once the WAL flushes, every second by default; 10ms takes the suite from
# minutes to seconds and changes no answer. Core forces a snapshot after
# three times --wal-snapshot-size WAL files, and a snapshot of a point near
# the largest timestamp panics ("timestamp wraparound"; writes then hang
# until restart), which the contracts write; a large snapshot size keeps a
# test run far from that.
docker run -d --rm --name influx3_verify -p 8181:8181 influxdb:3.10.1-core \
  influxdb3 serve --node-id node0 --object-store memory --without-auth \
  --wal-flush-interval 10ms --wal-snapshot-size 100000
mix test test/integration/contract_v3_core --include v3_core --include integration

# InfluxDB 2.7 on 8086 (org dev-influx, bucket metrics)
docker run -d --rm --name influx2_verify -p 8086:8086 \
  -e DOCKER_INFLUXDB_INIT_MODE=setup -e DOCKER_INFLUXDB_INIT_USERNAME=dev \
  -e DOCKER_INFLUXDB_INIT_PASSWORD=devpassword123 -e DOCKER_INFLUXDB_INIT_ORG=dev-influx \
  -e DOCKER_INFLUXDB_INIT_BUCKET=metrics \
  -e DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=dev-influx-token-123456789 influxdb:2.7
mix test test/integration/contract_v2 --include v2 --include integration

# InfluxDB 3 Core on 8183 *with* auth, for the token endpoints (the test
# creates the operator token, once per fresh server; or set
# INFLUX_V3_AUTH_TOKEN)
docker run -d --rm --name influx3_auth -p 8183:8181 influxdb:3.10.1-core \
  influxdb3 serve --node-id node0 --object-store memory --wal-flush-interval 10ms --wal-snapshot-size 100000
mix test test/integration/tokens_v3_core_auth_test.exs --include v3_core_auth --include integration

docker stop influx3_verify influx2_verify influx3_auth
```

## Contract tags

The contract modules in `test/support` run each test against `Client.Local` and,
in `test/integration`, against a real engine. Two tags say where the double and
the engine part ways.

- `@tag local_divergence: "why"` marks a test whose body branches on the client
  under test, because `Client.Local` refuses by name what the engine answers. The
  branch must be there for the tag and the tag for the branch:
  `test/influx_elixir/contract_tags_test.exs` reads the contract sources and fails
  on either one without the other, or on a tag with no reason.
  `mix test test/influx_elixir/client/contract_local --only local_divergence`
  lists them (add `--trace` to see the names).
- `@tag engine_bug: "what"` marks a test that pins an engine defect (a closed
  connection, a DataFusion internal error, a wrong answer) exactly as the engine
  gives it today. When the double only refuses such a case, the test has both
  assertions, the double's exact refusal text and the engine's answer, and its name
  ends with `(Local refuses it by name)`.

### Re-checking the pins after an engine upgrade

After upgrading an engine, run only the engine-bug pins against it. A test that
carries the `engine_bug` tag is run by `--only engine_bug` even though its module
is excluded as `:integration`, so no `--include` is needed (adding
`--include integration` would run the whole directory instead, since an included
tag brings in every test it matches):

```bash
# Core: every pin the engine still shows (a failure means the defect is fixed or
# changed: update the pin and the double together)
mix test test/integration/contract_v3_core --only engine_bug --trace
# Enterprise, when one is running on the configured port
mix test test/integration/contract_v3_enterprise --only engine_bug --trace
# The double's side of the same pins
mix test test/influx_elixir/client/contract_local --only engine_bug --trace
```
