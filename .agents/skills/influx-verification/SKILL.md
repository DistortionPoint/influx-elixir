---
name: influx-verification
description: Verify InfluxElixir and Client.Local behavior against real InfluxDB 3 Core (3.10.1-core) and InfluxDB v2 (2.7) endpoints via curl and contract test suites. Use when probing engine edge cases, fixing Client.Local discrepancies, or running integration/contract tests.
---

# Real InfluxDB Verification & Contract Testing Skill

Every claim about what InfluxDB accepts, returns, or rejects must be verified against a real InfluxDB instance before encoding it into `InfluxElixir.Client.Local` or the contract suites under `test/support/`.

> [!CAUTION]
> **NEVER run `docker` or `docker-compose` commands (`docker ps`, `docker run`, `docker exec`, `docker stop`, etc.).**
> The user manages all Docker containers externally. Always check service availability using `curl` against the HTTP health endpoints. If a service is down or needs reconfiguring, ask the user.

## 1. Checking Running InfluxDB Services (No Docker Commands)

Check endpoint health using `curl`:

```bash
# InfluxDB v3 Core (port 8181)
curl -sf -o /dev/null -w "%{http_code}\n" http://localhost:8181/health

# InfluxDB v3 Enterprise Trading / Analytics (ports 8182 / 8183)
curl -sf -o /dev/null -w "%{http_code}\n" http://localhost:8182/health
curl -sf -o /dev/null -w "%{http_code}\n" http://localhost:8183/health

# InfluxDB v2 (port 8086)
curl -sf -o /dev/null -w "%{http_code}\n" http://localhost:8086/health
```

Standard local dev service credentials:
- **InfluxDB v2 (`http://localhost:8086`)**: token `dev-influx-token-123456789`, org `dev-influx`, bucket `metrics`
- **InfluxDB v3 Core (`http://localhost:8181`)**: no-auth or bearer token depending on instance config
- **InfluxDB v3 Enterprise (`http://localhost:8182`, `http://localhost:8183`)**

---

## 2. Probing Real Engine Behavior With `curl`

### v3 Core Probes (`:8181`)

```bash
# Write v3 line protocol
curl -i -s -X POST "http://localhost:8181/api/v3/write_lp?db=probe&precision=nanosecond" \
  --data-binary 'cpu,host=a val=1.0 1700000000000000000'

# Write v2 line protocol endpoint on v3
curl -i -s -X POST "http://localhost:8181/api/v2/write?bucket=probe&precision=ns" \
  --data-binary 'cpu,host=a val=1.0 1700000000000000000'

# Query SQL (JSON)
curl -i -s -X POST "http://localhost:8181/api/v3/query_sql" \
  -H "Content-Type: application/json" \
  -d '{"db":"probe","q":"SELECT * FROM cpu","format":"json"}'

# Query InfluxQL on v3 (JSON)
curl -i -s -X POST "http://localhost:8181/api/v3/query_influxql" \
  -H "Content-Type: application/json" \
  -d '{"db":"probe","q":"SELECT val FROM cpu"}'
```

### v2 Probes (`:8086`)

```bash
# Write v2 line protocol
curl -i -s -X POST "http://localhost:8086/api/v2/write?org=dev-influx&bucket=metrics&precision=ns" \
  -H "Authorization: Token dev-influx-token-123456789" \
  --data-binary 'cpu,host=a val=1.0 1700000000000000000'

# Query Flux (annotated CSV response)
curl -i -s -X POST "http://localhost:8086/api/v2/query?org=dev-influx" \
  -H "Authorization: Token dev-influx-token-123456789" \
  -H "Accept: application/csv" \
  -H "Content-Type: application/vnd.flux" \
  --data-binary 'from(bucket: "metrics") |> range(start: 0)'

# Query v1 compatibility InfluxQL on v2
curl -i -s -G "http://localhost:8086/query" \
  -H "Authorization: Token dev-influx-token-123456789" \
  --data-urlencode "db=metrics" \
  --data-urlencode "q=SELECT val FROM cpu"
```

---

## 3. Running Contract Test Suites

Always run one test run at a time, from the main agent only:

```bash
# Run contract suites against Client.Local only (no external services needed)
mix test test/integration/contract_v3_core
mix test test/integration/contract_v2
mix test test/integration/contract_v3_enterprise

# Run contract suites against BOTH Client.Local AND live InfluxDB instances
INFLUXDB_V3_CORE_URL=http://localhost:8181 \
  mix test test/integration/contract_v3_core --include v3_core

INFLUXDB_V2_URL=http://localhost:8086 \
INFLUXDB_V2_TOKEN=dev-influx-token-123456789 \
INFLUXDB_V2_ORG=dev-influx \
  mix test test/integration/contract_v2 --include v2

# Verify contract meta-invariants (local_divergence tags & case table uniqueness)
mix test \
  test/influx_elixir/contract_tags_test.exs \
  test/influx_elixir/contract_case_tables_test.exs
```

---

## 4. Tagging Divergences & Engine Bugs

- **`@tag local_divergence: "reason"`**:
  - Required by `InfluxElixir.ContractTagsTest` on every test in `test/support/` whose body (or called helper) branches on `Client.Local` vs HTTP (`Local`, `is_map(conn)`, `is_list(conn)`, `*local?()`).
  - Forbidden on tests that do NOT branch on the client.
- **`@tag engine_bug: "reason"`**:
  - Used when pinning a verified quirk or bug of the real InfluxDB engine itself.
