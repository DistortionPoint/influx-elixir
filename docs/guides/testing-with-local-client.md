# Testing with LocalClient

`InfluxElixir.Client.Local` is an in-memory InfluxDB client that parses real
line protocol, stores data in ETS, and responds with the same shapes as the
HTTP client. It enables fast, isolated tests with `async: true` and no
external dependencies.

## Choosing a Profile

LocalClient enforces an InfluxDB **version profile** matching your production
backend. This ensures your tests fail if you use operations your real InfluxDB
doesn't support.

| Profile | Operations |
|---|---|
| `:v3_core` | write, SQL queries, InfluxQL, database CRUD |
| `:v3_enterprise` | everything in v3_core + token management |
| `:v2` | write, Flux queries, bucket CRUD |

## Setup

### 1. Add the dependency

```elixir
# mix.exs
defp deps do
  [
    {:influx_elixir, "~> 0.1"}
  ]
end
```

### 2. Configure LocalClient for tests

```elixir
# config/test.exs
config :influx_elixir, :client, InfluxElixir.Client.Local
```

### 3. Write your test setup

```elixir
defmodule MyApp.InfluxTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  setup do
    # Match your production InfluxDB version
    {:ok, conn} = Local.start(
      databases: ["myapp_test"],
      profile: :v3_core
    )
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn}
  end

  test "writes and queries data", %{conn: conn} do
    {:ok, :written} = Local.write(
      conn,
      "sensors,location=lab temp=22.5",
      database: "myapp_test"
    )

    {:ok, [row]} = Local.query_sql(
      conn,
      "SELECT * FROM sensors WHERE location = 'lab' LIMIT 1",
      database: "myapp_test"
    )

    assert row["temp"] == 22.5
    assert row["location"] == "lab"
  end
end
```

The library ships `InfluxElixir.TestHelper.setup_influx/1`, which does the
same start / `on_exit` dance in one line and accepts every
`Local.start/1` option:

```elixir
defmodule MyApp.InfluxTest do
  use ExUnit.Case, async: true
  import InfluxElixir.TestHelper

  setup do
    setup_influx(databases: ["myapp_test"], profile: :v3_core)
  end
end
```

### 4. Use the shared case template (optional)

If you have many test modules that need InfluxDB, create a shared setup:

```elixir
# test/support/my_influx_case.ex
defmodule MyApp.InfluxCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias InfluxElixir.Client.Local
    end
  end

  setup do
    {:ok, conn} = InfluxElixir.Client.Local.start(
      databases: ["test_db"],
      profile: :v3_core
    )
    on_exit(fn -> InfluxElixir.Client.Local.stop(conn) end)
    {:ok, conn: conn}
  end
end
```

Then use it in tests:

```elixir
defmodule MyApp.SensorTest do
  use MyApp.InfluxCase, async: true

  test "stores sensor readings", %{conn: conn} do
    {:ok, :written} = Local.write(conn, "sensors temp=22.5", database: "test_db")
    # ...
  end
end
```

## Connection-Level Default Database

Both `Client.HTTP` and `Client.Local` honour the `:database` config key
as a connection-level default. When the caller doesn't pass `database:`
in opts, this value is used:

```elixir
{:ok, conn} = Local.start(database: "myapp_test")

# No explicit `database:` opt — uses "myapp_test"
{:ok, :written} = Local.write(conn, "sensors temp=22.5")
{:ok, rows} = Local.query_sql(conn, "SELECT * FROM sensors")
```

`:databases` (list) is also accepted by both implementations:
`Client.Local` pre-creates each entry; `Client.HTTP` uses the first
entry as the default when `:database` is not set. This makes a config
like `database: "primary", databases: ["primary", "backup"]` a true
drop-in across implementations.

## Profile Enforcement

If you pick the wrong profile, operations fail the same way they would
against the real backend:

```elixir
# Your production InfluxDB is v3 Core — no Flux support
{:ok, conn} = Local.start(profile: :v3_core)

# This returns {:error, :unsupported_operation}
Local.query_flux(conn, "from(bucket: \"test\") |> range(start: -1h)")
```

This catches profile mismatches in tests, before they reach production.

## Checking Support at Runtime

Use `supports?/2` if you need to conditionally execute operations:

```elixir
if Local.supports?(conn, :query_flux) do
  Local.query_flux(conn, flux_query)
else
  # fall back or skip
end
```

## Running Contract Tests

The library includes a shared contract test template at
`InfluxElixir.ClientContract`. You can use it to verify that your own
adapters or wrappers conform to the InfluxDB client contract:

```elixir
defmodule MyApp.ContractTest do
  use ExUnit.Case, async: true
  use InfluxElixir.ClientContract,
    client: InfluxElixir.Client.Local,
    profile: :v3_core

  alias InfluxElixir.Client.Local

  setup do
    {:ok, conn} = Local.start(databases: ["contract_db"], profile: :v3_core)
    on_exit(fn -> Local.stop(conn) end)
    {:ok, conn: conn, database: "contract_db", query_delay: 0}
  end
end
```

The contract tests verify health, write, query, admin, and round-trip
operations. They run the same assertions against every backend — if both
LocalClient and real InfluxDB pass, LocalClient is proven faithful.

## Named Connections via the Facade

LocalClient works seamlessly with the facade's named connection system.
When `Client.Local` is the configured client, `ConnectionSupervisor`
calls `Local.init_connection/1` to create an ETS-backed connection and
registers it under the given name. All facade functions then work
transparently:

```elixir
# config/test.exs
config :influx_elixir, :client, InfluxElixir.Client.Local

config :influx_elixir, :connections,
  test_db: [
    databases: ["myapp_test"],
    profile: :v3_core
  ]
```

```elixir
defmodule MyApp.FacadeTest do
  use ExUnit.Case

  test "write and query via named connection" do
    {:ok, :written} = InfluxElixir.write(
      :test_db,
      "sensors temp=22.5",
      database: "myapp_test"
    )

    {:ok, [row]} = InfluxElixir.query_sql(
      :test_db,
      "SELECT * FROM sensors LIMIT 1",
      database: "myapp_test"
    )

    assert row["temp"] == 22.5
  end
end
```

This lets you test your application code that uses `InfluxElixir.write/3`
and `InfluxElixir.query_sql/3` without any code changes — just swap the
client in config.

## Aggregate Queries

LocalClient supports `DATE_BIN` time-bucketed aggregate queries — the same
pattern used in InfluxDB v3 SQL:

```elixir
test "hourly average temperature", %{conn: conn} do
  # Write some data points
  lines = """
  sensors,location=lab temp=20.0 1000000000000
  sensors,location=lab temp=22.0 2000000000000
  sensors,location=lab temp=24.0 5000000000000
  """
  {:ok, :written} = Local.write(conn, lines, database: "test_db")

  sql = """
  SELECT
    DATE_BIN(INTERVAL '1 hour', time) AS time,
    AVG(temp) AS avg_temp
  FROM "sensors"
  WHERE location = 'lab'
  GROUP BY DATE_BIN(INTERVAL '1 hour', time)
  ORDER BY time ASC
  """

  {:ok, rows} = Local.query_sql(conn, sql, database: "test_db")
  assert [%{"time" => _, "avg_temp" => _} | _] = rows
end
```

Supported aggregate functions: `AVG`, `SUM`, `COUNT`, `COUNT(*)`, `MIN`,
`MAX`, `STDDEV` / `STDDEV_SAMP` (sample), `STDDEV_POP`, `VAR` / `VAR_SAMP`
(sample) and `VAR_POP`. The argument may be an arithmetic expression over
fields and numeric literals, evaluated per row before aggregation:

```elixir
sql = """
SELECT
  STDDEV(price) AS volatility,
  SUM(price * volume) AS notional,
  AVG(bid + ask) AS mid
FROM "trades"
"""
```

Two integer operands divide as integers (`3 / 2 = 1`), as in DataFusion.
`VARIANCE` is not a DataFusion function and is rejected, as it is by the
real engine. `COUNT(DISTINCT col)` counts distinct non-null values.
`MIN(time)`, `MAX(time)` and `COUNT(time)` work and return a `DateTime`;
`AVG(time)`, `SUM(time)`, the statistics over `time` and any arithmetic on
`time` are rejected, exactly as DataFusion rejects them ("does not support
inputs of type Timestamp").

`SELECT DISTINCT a, b` returns each distinct combination, sorted, and honours
`ORDER BY` on a selected column (`ORDER BY` on any other column is rejected
with DataFusion's own message):

```elixir
{:ok, rows} =
  Local.query_sql(conn, ~s|SELECT DISTINCT provider, symbol FROM "prices" ORDER BY symbol DESC LIMIT 5|,
    database: "test_db"
  )
```

Selector functions return the value, or the timestamp, of the row a
selector picks — `selector_first` / `selector_last` by time,
`selector_min` / `selector_max` by the field. Either accessor works:

```elixir
sql = """
SELECT
  DATE_BIN(INTERVAL '1 minute', time) AS bucket,
  selector_first(price, time)['value'] AS open,
  selector_max(price, time)['value']   AS high,
  selector_min(price, time)['value']   AS low,
  selector_last(price, time)['value']  AS close,
  selector_max(price, time)['time']    AS high_at
FROM "trades"
GROUP BY DATE_BIN(INTERVAL '1 minute', time)
ORDER BY bucket DESC
"""
```

`ORDER BY` accepts `time` or any output column or alias (`bucket`,
`volatility`), ascending or descending.
Ordered aggregates use the InfluxDB v3 SQL (DataFusion) spelling:
`first_value(field ORDER BY col [ASC|DESC])` and
`last_value(field ORDER BY col [ASC|DESC])` — for OHLCV candles and
"latest value per group" queries:

```elixir
sql = """
SELECT symbol, last_value(price ORDER BY time) AS price
FROM prices
WHERE time >= $start
GROUP BY symbol, provider
"""
```

The `ORDER BY` inside the call is required. Without it the real engine
returns an *arbitrary* row from each group, which the double cannot
reproduce, so it rejects the query instead of certifying a
non-deterministic result. InfluxQL-style `FIRST(field, time)` /
`LAST(field, time)` are rejected too: InfluxDB v3 SQL has no such
functions (the real engine fails planning with `Invalid function 'last'`),
and a double that accepted them would pass tests for a query that 400s in
production.

Supported interval units: `seconds`, `minutes`, `hours`, `days`.

Anything outside the supported subset is rejected with
`{:error, %{status: 400, body: "Client.Local: ..."}}`. The `Client.Local:`
prefix tells you the double, not InfluxDB, refused the query.

`GROUP BY DATE_BIN` is optional. When omitted, aggregate queries return a
single scalar row over all matching points:

```elixir
sql = """
SELECT AVG(net_value) AS average_balance
FROM account_balances
WHERE account_id = 'abc'
"""

{:ok, [%{"average_balance" => avg}]} = Local.query_sql(conn, sql, database: "test_db")
```

`COUNT` over zero matching rows returns `0`. Every other aggregate is null
over zero rows — and so is a sample statistic (`STDDEV`, `VAR`) over one
row — and a null column is **absent from the row**, not present as `nil`,
exactly as InfluxDB 3's JSON responses omit null columns. Assert with
`refute Map.has_key?(row, "avg_usage")`, not `row["avg_usage"] == nil`
(the latter passes for both shapes and proves nothing).

## GROUP BY Tag/Field Columns

`GROUP BY` on bare tag/field columns is supported alongside `DATE_BIN`
time bucketing. The grouping columns can also appear in the `SELECT`
list (with optional `AS alias`):

```elixir
sql = """
SELECT ticker, AVG(value) AS average_balance, holding_type
FROM account_holdings
WHERE account_id = 'abc'
GROUP BY ticker, holding_type
"""

{:ok, rows} = Local.query_sql(conn, sql, database: "test_db")
# => one row per unique (ticker, holding_type) pair
```

## Flux Queries (`:v2` profile)

`query_flux/3` returns the same **long** rows a real InfluxDB 2.x returns: one
row per field, with `_field` / `_value`, `_measurement`, `_time` (a `DateTime`),
the tags, `result`, and a `table` index per series:

```elixir
{:ok, conn} = Local.start(profile: :v2)
:ok = Local.create_bucket(conn, "metrics")
{:ok, :written} = Local.write(conn, "cpu,host=web01 value=1.0,count=3i", database: "metrics")

{:ok, rows} =
  Local.query_flux(conn, """
  from(bucket: "metrics")
    |> range(start: -1h)
    |> filter(fn: (r) => r._measurement == "cpu")
    |> filter(fn: (r) => r._field == "value")
  """)

assert [%{"_field" => "value", "_value" => 1.0, "host" => "web01", "table" => 0}] = rows
```

Supported predicates: `from(bucket:)`, `range(start: -N[smhd])`,
`r._measurement == "..."`, `r._field == "..."`, and `r.<tag_or_field> == "..."`.
Against a real server, set `api_version: :v2` on the connection so writes go to
`/api/v2/write`.

## Decimal Params

`Decimal` values pass through `params:` as bare numeric literals — no
quoting, so `WHERE amount >= $min` performs a numeric comparison even
when `$min` is a `%Decimal{}`:

```elixir
params = %{"$min" => Decimal.new("1000.00")}
{:ok, rows} = Local.query_sql(conn, sql, database: "test_db", params: params)
```

Do **not** pass pre-stringified numbers (`"1000.00"`) as params. A string
param becomes a string literal, and InfluxDB v3 compares a numeric column
against a string literal by casting the column to text — so
`amount >= '1000.00'` is a lexical comparison in which `500.0` matches.
`Client.Local` reproduces that so the mistake fails in tests rather than
in production.

## WHERE Literal Typing

Quoted literals are always strings, exactly as in InfluxDB v3. A
zero-padded identifier keeps its leading zero and matches a string tag:

```elixir
sql = "SELECT * FROM accounts WHERE repcode IN ($rc)"
{:ok, rows} = Local.query_sql(conn, sql, database: "test_db", params: %{rc: "08338636"})
```

Bare literals are typed (`42` integer, `1.5` float, `true` boolean). A bare
numeric literal never matches a string tag (`WHERE repcode = 08338636`
returns no rows), again matching the real engine.

## Multi-Column Projection

Specific columns can be projected by name (with optional `AS alias`):

```elixir
sql = """
SELECT net_value, total_balance, time
FROM account_balances
WHERE account_id = 'abc'
ORDER BY time DESC
LIMIT 1
"""

{:ok, [row]} = Local.query_sql(conn, sql, database: "test_db")
# => row has keys "net_value", "total_balance", "time" only
```

Both fields and tags are selectable. Aliasing renames the output key:
`SELECT net_value AS nv FROM x` produces rows keyed by `"nv"`.

## IN / NOT IN Clauses

`WHERE col IN (...)` and `WHERE col NOT IN (...)` are supported on tags
and fields. Combine with binary operators via `AND`:

```elixir
sql = """
SELECT * FROM holdings
WHERE ticker IN ('AAPL', 'MSFT') AND shares > 5
"""

{:ok, rows} = Local.query_sql(conn, sql, database: "test_db")
```

`IN ()` (empty list) matches no rows; `NOT IN ()` matches all rows.

## Time Filters

`WHERE time` accepts exactly what InfluxDB 3 accepts against a Timestamp
column: a quoted ISO-8601 datetime (zoned, zone-less or fractional), a quoted
date (midnight UTC), and `now()` offset by `INTERVAL` terms, which the double
evaluates when the query runs:

```elixir
"WHERE time >= '2026-03-31'"
"WHERE time >= '2026-03-31T00:00:00Z'"
"WHERE time >= now() - INTERVAL '5 minutes'"
"WHERE time >= now() - INTERVAL '1 day' - INTERVAL '1 hour' AND time < now()"
```

A bare integer (`WHERE time >= 1774915200000000000`), an integer-as-string,
and any unparseable string are **rejected** with a `Client.Local:` 400, because
DataFusion rejects them too ("Cannot infer common argument type for comparison
operation Timestamp(ns) >= Int64"; "Error parsing timestamp"). Returning no
rows for those would let a query pass tests and fail in production.

The same holds for params: bind a `DateTime` (rendered as the ISO-8601 string
Jason sends over HTTP), never an integer:

```elixir
Local.query_sql(conn, ~s|SELECT * FROM "prices" WHERE time >= $start|,
  database: "test_db",
  params: %{start: DateTime.add(DateTime.utc_now(), -300, :second)}
)
```

`WHERE col IS NULL` and `WHERE col IS NOT NULL` test whether the row has the
field or tag.

## Checking a Query Before Running It

`InfluxElixir.Client.Local.check_sql/1` parses a query without executing it
and returns `:ok` or the same `{:error, %{status: 400, body: "Client.Local:
..."}}` that `query_sql/3` would. Use it to fail a test *with the reason*
when a query is outside the double's subset, instead of tagging the test
excluded and forgetting why:

```elixir
test "median latency", %{conn: conn} do
  sql = ~s|SELECT median(latency) AS p50 FROM "requests"|

  case Local.check_sql(sql) do
    :ok -> assert {:ok, [%{"p50" => _}]} = Local.query_sql(conn, sql, database: "test_db")
    {:error, %{body: why}} -> flunk("cover this in the integration tier: #{why}")
  end
end
```

Queries the double cannot express (CTEs, joins, window functions, `median`,
`percentile_cont`, ...) belong in the integration tier below.

## Running Against a Real InfluxDB

The double proves the *shape* of your code; only a real engine proves the
query. Keep a second, tagged test tier that runs the same test bodies against
InfluxDB via `InfluxElixir.Client.HTTP`, and skip it when no server is
reachable:

```elixir
defmodule MyApp.Integration.CandlesTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias InfluxElixir.Client.HTTP

  setup_all do
    conn = [
      host: System.get_env("INFLUX_V3_CORE_HOST", "localhost"),
      port: String.to_integer(System.get_env("INFLUX_V3_CORE_PORT", "8181")),
      token: System.get_env("INFLUX_V3_CORE_TOKEN", "")
    ]

    case HTTP.health(conn) do
      {:ok, _status} -> {:ok, conn: conn}
      {:error, _down} -> {:ok, skip: true, conn: conn}
    end
  end

  setup ctx do
    if ctx[:skip], do: flunk("InfluxDB 3 Core not reachable on #{ctx.conn[:host]}")
    db = "candles_#{System.unique_integer([:positive])}"
    :ok = HTTP.create_database(ctx.conn, db)
    on_exit(fn -> HTTP.delete_database(ctx.conn, db) end)
    # Real servers ingest asynchronously: wait before querying a fresh write.
    {:ok, database: db, query_delay: 500}
  end
end
```

Exclude the tag by default in `test/test_helper.exs`
(`ExUnit.start(exclude: [:integration])`) and include it when a server is up:

```bash
# InfluxDB 3 Core on 8181, no auth, data in memory
docker run -d --rm --name influx3 -p 8181:8181 influxdb:3-core \
  influxdb3 serve --node-id node0 --object-store memory --without-auth

mix test --include integration
docker stop influx3
```

This library's own contract suite is that second tier:
`test/integration/contract_v3_core_test.exs` runs the same assertions as
`test/influx_elixir/client/contract_local_v3_core_test.exs` against the
server, and reads `INFLUX_V3_CORE_HOST` / `INFLUX_V3_CORE_PORT` (defaults
`localhost` / `8181`); the v2 suite reads `INFLUX_V2_HOST`, `INFLUX_V2_PORT`,
`INFLUX_V2_TOKEN`, `INFLUX_V2_ORG` and `INFLUX_V2_BUCKET`. Every statement
in this guide about what the real engine returns was recorded that way.

## Key Differences from Real InfluxDB

- **No WAL flush delay**: Writes are immediately queryable (set `query_delay: 0`)
- **In-memory only**: Data is lost when `stop/1` is called
- **Simplified SQL parser**: Supports `SELECT *`, multi-column projection (with
  optional `AS alias`), `SELECT DISTINCT col[, col ...]`, `WHERE` with binary
  ops + `IN` / `NOT IN` (quoted literals are strings, bare literals are typed),
  `ORDER BY <column>`, `LIMIT`, `$param` substitution, `DATE_BIN` + aggregate
  functions (`AVG`, `SUM`, `COUNT`, `COUNT(*)`, `MIN`, `MAX`,
  `STDDEV[_SAMP|_POP]`, `VAR[_SAMP|_POP]` over field arithmetic,
  `selector_first|last|min|max`, `first_value` / `last_value` with an inner
  `ORDER BY`) with optional `GROUP BY DATE_BIN` or `GROUP BY <columns>`.
  Anything else is rejected with a `Client.Local:` prefixed 400 — see
  `InfluxElixir.Client.Local.SQLParser` and `check_sql/1` above.
- **Division by zero**: null in the double. InfluxDB returns IEEE infinity
  for a float divided by zero (serialised as JSON `null`, but counted by
  `COUNT`) and fails the query for an integer divided by zero.
- **No authentication**: All operations succeed regardless of token
- **ETS-based**: Each `start/1` creates an isolated ETS table
