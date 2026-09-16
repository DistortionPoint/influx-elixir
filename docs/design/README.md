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

## Verifying against a real engine

Claims about server behaviour are checked against a real InfluxDB before
they are written down. No compose file is kept in the repo; these one-liners
match the defaults in `test/support/integration_helper.ex`:

```bash
# InfluxDB 3 Core on 8181 (HTTP and Flight, no auth)
docker run -d --rm --name influx3_verify -p 8181:8181 influxdb:3-core \
  influxdb3 serve --node-id node0 --object-store memory --without-auth
mix test test/integration/contract_v3_core_test.exs --include v3_core --include integration

# InfluxDB 2.7 on 8086 (org dev-influx, bucket metrics)
docker run -d --rm --name influx2_verify -p 8086:8086 \
  -e DOCKER_INFLUXDB_INIT_MODE=setup -e DOCKER_INFLUXDB_INIT_USERNAME=dev \
  -e DOCKER_INFLUXDB_INIT_PASSWORD=devpassword123 -e DOCKER_INFLUXDB_INIT_ORG=dev-influx \
  -e DOCKER_INFLUXDB_INIT_BUCKET=metrics \
  -e DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=dev-influx-token-123456789 influxdb:2.7
mix test test/integration/contract_v2_test.exs --include v2 --include integration

docker stop influx3_verify influx2_verify
```
