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
| `:v3_core` | write, SQL queries, InfluxQL, database CRUD, admin tokens |
| `:v3_enterprise` | everything in v3_core + resource tokens (`create_token/3` with `:permissions`) |
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
`Client.Local` pre-creates each entry, and both use the first entry as
the default when `:database` is not set, so any combination of the two
keys resolves to the same database on either client.

With neither key there is no default database — as on the server,
which has none. An operation that needs one returns
`{:error, :no_database_specified}` (InfluxQL answers the engine's 400,
`SHOW DATABASES` still works). Earlier versions of the double wrote to
an implicit `"default"` database instead, so code that forgot
`database:` passed its tests and failed in production.

The double also applies the server's database rules (verified against
InfluxDB 3 Core):

- A name must start with an ASCII letter or digit and contain only
  letters, digits, `_`, `-` and at most one `/` (InfluxDB 1's
  `<db>/<rp>` form); anything else is the engine's 400, from
  `create_database/3`, from a write that would create the database and
  from `start/1` (which raises).
- The `:v3_core` profile holds at most 5 databases, as Core does: a
  sixth is the engine's 422.
- A query against a database that does not exist is the engine's 404
  `{"error":"query error: database not found: <name>"}`.
- `list_databases/1` and `SHOW DATABASES` include the engine's own
  `_internal`, which cannot be dropped (500).

### Retention

`create_database(conn, "metrics", retention: "1h")` is kept and applied as
InfluxDB 3 does (verified against Core):

```elixir
:ok = Local.create_database(conn, "metrics", retention: "1h")

# A write is never refused for a point's age: this is accepted (204).
{:ok, :written} = Local.write(conn, "m v=1i #{two_hours_ago_ns}\nm v=2i #{a_minute_ago_ns}",
  database: "metrics")

# A query sees the chunks that still hold a point at or after now - 1h.
{:ok, [%{"v" => 2}]} = Local.query_sql(conn, "SELECT v FROM m", database: "metrics")
{:ok, [%{"duration" => "1h0m0s"}]} =
  Local.query_influxql(conn, "SHOW RETENTION POLICIES", database: "metrics")
```

- Expiry hides, it does not refuse: SQL, InfluxQL and `SHOW TAG VALUES` all
  skip expired data, and `accept_partial: false` does not make the write
  fail. The tables and columns an expired point created stay in the
  schema.
- The engine expires a 10-minute chunk of a table (a multiple of 600 s
  since the epoch), not a point. An expired point stays visible while a
  newer point of its chunk is, so a test that wants a point gone writes it
  at least ten minutes beyond the retention.
- The period is read in whole seconds (`1500ms` is `1s`, anything shorter
  is `0`). `"0"` is a retention of zero, not none: every point before now is
  hidden. Omit `retention:` for data that never expires; `SHOW RETENTION
  POLICIES` then says `0s`.
- Creating a database that exists keeps the retention it has.

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
    {:ok, conn: conn, database: "contract_db"}
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
fields and numeric literals, evaluated per row before aggregation. Without
`AS alias` a column is named as the engine names it (verified): `count(*)`,
`avg(trades.price)`, `sum(trades.price * Int64(2))`, `Int64(1)` for a bare
constant.

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

`SELECT DISTINCT ON (a[, b])` keeps the first row per distinct key after
`ORDER BY` — the idiomatic "latest row per key":

```elixir
{:ok, latest} =
  Local.query_sql(
    conn,
    "SELECT DISTINCT ON (symbol) symbol, price, time FROM prices ORDER BY symbol, time DESC",
    database: "test_db"
  )
```

It follows the engine's rules (verified against InfluxDB 3): `ORDER BY`
must begin with the `ON` columns, in order (400 otherwise); `ORDER BY`
names table columns, not select aliases (500); `LIMIT` and `OFFSET` apply
to the de-duplicated rows; a row missing a key column belongs to the null
key; aggregates and `GROUP BY` are the engine's 405. Without `ORDER BY`
the engine picks an arbitrary row per key in an arbitrary order, so don't
assert on it. The double takes plain columns in `ON` and refuses an
expression such as `DATE_BIN(...)` by name.

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

Two things are worth knowing when a test must also hold against the engine:

- Without `ORDER BY` the double returns rows in time order. The engine's
  order is not defined: it sorts what it reads by the tags (in the order
  they were first written) and then by time, but which block of rows comes
  first depends on how the data was written and held (separate writes, a
  tag filter), so ask for the order you assert on.
- The engine runs `a AND b` and `a OR b` over a batch of rows, and a `b`
  that fails for a row `a` leaves out (`j <> 0 AND 100 / j > 1`) fails the
  query or not by how it batches them. The double refuses such a query by
  name rather than guess (a filter in a CTE does not help: the engine merges
  it with the outer one). Keep such a query to an integration test.

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

## NULLs

The double follows DataFusion's NULL rules, verified against InfluxDB 3:

- `ORDER BY col` puts nulls last, `ORDER BY col DESC` puts them first, and
  `NULLS FIRST` / `NULLS LAST` override either.
- Rows that tie on every `ORDER BY` key come back in the order they were
  written. The engine's order for such ties is arbitrary, so don't assert
  it against a real server; add a key that breaks the tie, such as `time`.
- A comparison with a null is unknown, and `NOT` of unknown is unknown, so
  `WHERE NOT (rack = '1')` does not return rows that have no `rack`; neither
  do `rack NOT IN (...)` or `v NOT BETWEEN ...`.
- `SELECT DISTINCT rack` includes the all-null combination as `%{}`, and a
  `GROUP BY rack` has a group for rows without a `rack`.

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

Grouping columns combine with `DATE_BIN` — a row per bucket per value —
and a `GROUP BY` or `ORDER BY` item may be a select alias or a 1-based
position, as in DataFusion (verified against InfluxDB 3):

```elixir
sql = """
SELECT DATE_BIN(INTERVAL '1 minute', time) AS bucket, host, COUNT(v) AS c
FROM cpu
GROUP BY bucket, host
ORDER BY 1, 2
"""
```

A position outside the select list is the engine's planning error
("Cannot find column with position 3 in SELECT clause. Valid columns: 1 to
2").

## Flux Queries (`:v2` profile)

`query_flux/3` returns the same **long** rows a real InfluxDB 2.x returns: one
row per field, with `_field` / `_value`, `_measurement`, `_time`, `_start` and `_stop` (`DateTime`s),
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

The whole pipeline runs or is refused; a stage is never skipped (verified
against InfluxDB 2.7). Supported stages: `range` (required, as on the
engine; Unix seconds, RFC3339, `-1h`-style durations, `now()`; rows carry
`_start` and `_stop`), `filter` (`r.key` / `r["key"]` with
`== != < <= > >=`, `and`, `or`, `not`, parentheses; a key the row lacks
never matches), `first`, `last`, `min`, `max` (the selected row per table),
`mean`, `sum`, `count` (one row per table, without `_time`), `limit(n:,
offset:)` per table, and `yield(name:)`. Tables are numbered per series in
measurement, tag, field order. Any other stage, such as `aggregateWindow`,
`pivot`, `group` or `sort`, is a 400 naming it (`Client.Local: unsupported
Flux function: pivot()`); so are arguments to `first`, `last`, `min`,
`max`, `mean`, `sum` and `count`, a second `range`, a `filter` predicate
or `range` time the double does not read, and a `yield` that is not
`yield(name: "x")`. A missing bucket is the engine's 404. Against a real server, set `api_version: :v2` on the
connection so writes go to `/api/v2/write`.

## Params

`params:` is a map or a keyword list; a `$name` placeholder takes the key
`name` (`%{min: 1000}` binds `$min`; a key spelled `"$min"` binds nothing, as
on InfluxDB). Both clients read the parameters through
`InfluxElixir.Client.QueryParams`, and `Client.Local` binds what the engine
reads from the request's JSON:

  * a value is data, never SQL text: a string holding a quote, `--` or `$x`
    is compared as that string
  * a non-negative integer is a `UInt64`, so `time = $t` with `0` is the
    engine's type error (`Timestamp(ns) = UInt64`); bind an ISO-8601 string
    or a `DateTime` for a `time`
  * `LIMIT $n` and `OFFSET $n` take an integer or `nil`; a boolean compared
    with a number or a string is the engine's type error
  * an object or an array is the engine's 400 (`JSON objects are not
    supported as query parameters ... at line 1 column N`), and a `Decimal`
    that is NaN or an infinity, or a value with no JSON form (a tuple, a
    pid), is `{:error, {:invalid_param, name, reason}}` from both clients
  * a placeholder with no value is the planner's 400, `No value found for
    placeholder with name $name`

## Decimal Params

`Decimal` values are sent as JSON numbers — no quoting, so
`WHERE amount >= $min` performs a numeric comparison even when `$min` is a
`%Decimal{}`:

```elixir
params = %{min: Decimal.new("1000.00")}
{:ok, rows} = Local.query_sql(conn, sql, database: "test_db", params: params)
```

Do **not** pass pre-stringified numbers (`"1000.00"`) as params. A string
param becomes a string literal, and InfluxDB v3 compares a numeric column
against a string literal by casting the column to text — so
`amount >= '1000.00'` is a lexical comparison in which `500.0` matches.
`Client.Local` reproduces that so the mistake fails in tests rather than
in production.

## Identifiers and Case

SQL identifiers follow DataFusion's rules on the double as on the server
(verified against InfluxDB 3):

- An unquoted identifier is folded to lower case — columns, tables,
  aliases and CTE names. `SELECT Host FROM cpu` is the schema error
  `No field named host` when the tag is `Host`; `FROM Cpu` reads table
  `cpu`; `AVG(v) AS AvgV` answers the key `"avgv"`.
- A double-quoted identifier is exact: `SELECT "Host" FROM "Cpu"`,
  `AS "Mixed Case"`.
- `"..."` is always an identifier. `WHERE k = "a"` compares `k` with a
  column named `a`; string literals take single quotes.

Earlier versions of the double compared names case-sensitively and read
`"..."` as a string, so queries the server refuses passed against it.
InfluxQL identifiers are case-sensitive and are not folded.

## WHERE Literal Typing

Quoted literals are always strings, exactly as in InfluxDB v3. A
zero-padded identifier keeps its leading zero and matches a string tag:

```elixir
sql = "SELECT * FROM accounts WHERE repcode IN ($rc)"
{:ok, rows} = Local.query_sql(conn, sql, database: "test_db", params: %{rc: "08338636"})
```

Bare literals are typed (`42` integer, `1.5` float, `true` boolean) and
compare numerically against numeric fields (`v = 1` matches `1.0`). Against a
string tag the engine keeps the column as text and renders the literal, so
the comparison is lexical: `WHERE rack = 2` matches the tag `"2"`,
`WHERE rack > 3` does not match `"10"`, and `WHERE repcode = 08338636`
returns no rows because the literal renders as `"8338636"`. The double
reproduces all three.

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

## Projected Expressions, CTEs and Table Aliases

A projected column may be an arithmetic expression, with an alias; a null
operand makes the column null, which is omitted from the row. `ORDER BY` may
name the alias:

```elixir
{:ok, rows} =
  Local.query_sql(conn, ~s|SELECT (bid + ask) / 2 AS mid, time FROM "quotes" ORDER BY mid DESC|,
    database: "test_db"
  )
```

Non-recursive CTEs run in order; each body is a query in the supported
subset over a measurement or an earlier CTE, and the final `SELECT` reads
from any of them. Table aliases and `alias.column` qualifiers are accepted in
every clause. The candle shape — derive a mid price, then bin it — is:

```elixir
sql = """
WITH w AS (
  SELECT (bid + ask) / 2 AS mid, time
  FROM "quotes"
  WHERE symbol = $symbol AND bid IS NOT NULL AND ask IS NOT NULL
)
SELECT
  DATE_BIN(INTERVAL '1 minute', w.time) AS time,
  selector_first(w.mid, w.time)['value'] AS open,
  MAX(w.mid) AS high,
  MIN(w.mid) AS low,
  selector_last(w.mid, w.time)['value'] AS close
FROM w
GROUP BY DATE_BIN(INTERVAL '1 minute', w.time)
ORDER BY time ASC
"""

{:ok, candles} = Local.query_sql(conn, sql, database: "test_db", params: %{symbol: "BTC-USD"})
```

`FROM a CROSS JOIN b` pairs every row of `a` with every row of `b`. Its
everyday use is broadcasting a one-row CTE across the rows it screens — here
a median-based outlier guard, with `median()` and arithmetic on both sides of
the comparison:

```elixir
sql = """
WITH w AS (
  SELECT price, volume, time FROM "prices"
  WHERE time >= $start AND time < $end AND symbol = $symbol
),
ref AS (SELECT median(price) AS med FROM w)
SELECT
  DATE_BIN(INTERVAL '1 minute', w.time) AS time,
  selector_first(w.price, w.time)['value'] AS open,
  max(w.price) AS high,
  min(w.price) AS low,
  selector_last(w.price, w.time)['value'] AS close,
  sum(w.volume) AS volume
FROM w CROSS JOIN ref
WHERE ref.med <= 0 OR (w.price <= ref.med * 3 AND w.price >= ref.med / 3)
GROUP BY DATE_BIN(INTERVAL '1 minute', w.time)
ORDER BY time ASC
"""
```

A column present on both sides of the join is refused as ambiguous
(qualifiers are dropped, so the two could not be told apart; the engine
refuses the unqualified reference as well). Other joins (`INNER JOIN`, ...),
set operations, subqueries in `WHERE`, `HAVING` and window
functions are outside the subset and are rejected **by name**
(`Client.Local: unsupported SQL construct JOIN`) rather than ignored, so a
query the double cannot run never returns rows computed from its first
table alone. Cover those in the integration tier.

A bare word is a column reference, as in SQL. A column that no row has —
named anywhere, in `SELECT`, an aggregate, `WHERE`, `GROUP BY`, `ORDER BY` or
`DISTINCT` — is the engine's schema error (`No field named prod`, HTTP 500)
rather than an empty or unsorted result; the usual cause is a typo or a
forgotten pair of quotes. The error lists the known columns as the engine
does: qualified by the table (`trades.price`), and for `ORDER BY` and
`GROUP BY` with the select list's own fields first.

A `time` range that is empty in the top-level `AND` (`time > X AND time < X`,
`BETWEEN` with reversed bounds) is the engine's HTTP 500 "provided filters
on time column did not produce a valid set of boundaries", not an empty
result.

The same holds for a numeric field: when the top-level `AND` bounds a bare
`Int64`, `UInt64` or `Float64` column to no value (`v > 1 AND v < 1`,
`v BETWEEN 2 AND 1`, `u < 0` on an unsigned field), the engine fails with
DataFusion's HTTP 500 "Only intervals with the same data type are
comparable", and so does `Client.Local`. Any `OR`, a string or tag column,
or an arithmetic expression keeps the query answering. Shapes whose error
text the engine does not choose consistently are refused by name. InfluxQL
answers `[]` for these, as the engine does.

## WHERE Clauses

Predicates are `=`, `!=` / `<>`, `<`, `<=`, `>`, `>=`, `IN (...)`,
`NOT IN (...)`, `IS [NOT] NULL`, `[NOT] BETWEEN low AND high` and
`[NOT] LIKE` / `ILIKE`, the regular-expression operators `~`, `!~`, `~*`
and `!~*` (unanchored; `*` ignores case), combined with `AND`, `OR`, `NOT`
and parentheses. Either side of a predicate may be an expression: arithmetic,
`CAST`, and the scalar functions `abs`, `round(x[, n])`, `floor` and `ceil`
(`abs(amount) >= $threshold`, `1 < abs(f)`, `round(price, 2) IN (...)`).
Those functions work in the select list, `ORDER BY` and aggregates too, as on
the engine (verified): `abs` keeps its argument's type, the others return
floats, `round` rounds half away from zero, and a null argument gives null. A
wrong argument type or count is the engine's planning error, even when no row
matches, worded as the engine words it for the clause the call is in.
`AND` binds tighter than `OR`, as in SQL:

```elixir
sql = """
SELECT * FROM holdings
WHERE (ticker IN ('AAPL', 'MSFT') OR sector = 'tech')
  AND shares BETWEEN 5 AND 500
  AND NOT account LIKE 'test_%'
"""

{:ok, rows} = Local.query_sql(conn, sql, database: "test_db")
```

`IN ()` (empty list) matches no rows; `NOT IN ()` matches all rows. `LIKE`
is case-sensitive and `ILIKE` is not; `%` matches any run and `_` one
character. `LIKE` over a numeric column is rejected with the engine's own
planning error. A malformed expression (an unbalanced parenthesis, a
trailing `AND`) is rejected rather than truncated. `LIMIT 0` returns no
rows; `LIMIT n OFFSET m` (or `OFFSET m LIMIT n`) pages through the ordered
rows as on the server; a negative or non-numeric `LIMIT` or `OFFSET` is
rejected.

## CAST and Ordering

A tag is always a string, so `level <= 20` compares text (`"100"` sorts
before `"20"`). Cast it, as you would on the server, wherever an expression
is allowed — `WHERE`, `BETWEEN`, `LIKE`, projections, aggregates and
`ORDER BY`; `col::INTEGER` is the same as `CAST(col AS INTEGER)`. Note
that, as on the engine, `INTEGER` is a 32-bit integer: use `BIGINT` for
values past 2,147,483,647, or arithmetic that may leave that range:

```elixir
sql = """
SELECT *
FROM "orderbooks"
WHERE time >= $start_time
  AND symbol = $symbol
  AND CAST(level AS INTEGER) <= $depth
ORDER BY time DESC, CAST(level AS INTEGER) ASC
LIMIT $row_limit
"""

{:ok, rows} =
  Local.query_sql(conn, sql,
    database: "test_db",
    params: %{start_time: ~U[2026-01-01 00:00:00Z], symbol: "BTC-USD", depth: 20, row_limit: 100}
  )
```

Targets are `BIGINT` (`INT8`, 64-bit), `INTEGER` (`INT`, `INT4`, 32-bit),
`SMALLINT` (`INT2`, 16-bit), `TINYINT` (8-bit), `DOUBLE` and `VARCHAR`
(`STRING`, `TEXT`); `FLOAT`/`REAL` (32-bit on the engine), unsigned and
`DECIMAL` targets are refused by name. Text converts only when the whole
string is a number, a float truncates to an integer, and a number renders
to text. A cast of a constant that cannot be performed (`CAST(300 AS
TINYINT)`, a `$param` that does not fit) is the engine's HTTP 500
"Optimizer rule 'simplify_expressions' failed". A cast of a column value
that cannot be performed — `'abc'` to `INTEGER`, `time` to `INTEGER` —
makes InfluxDB 3 Core drop the connection mid-response rather than send an
error;
`Client.HTTP` reports `{:error, {:connection_error, %Mint.TransportError{
reason: :closed}}}` and the double reports `{:error, {:connection_error,
:closed}}`, so a test that handles the production failure handles the
double's.

`ORDER BY` takes several terms, each with its own direction.

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

## Expressions, information_schema and What Stays Refused

Beyond the arithmetic projection above, `query_sql/3` answers these as
InfluxDB 3 Core does (each verified against Core 3.10.1, error bodies
included):

```elixir
Local.query_sql(conn, """
SELECT host,
       CASE WHEN avg(cpu) > 80 THEN 'hot' ELSE 'ok' END AS state,
       sum(cpu) / count(cpu) AS mean_cpu
FROM metrics
WHERE lower(region) = 'eu' AND cpu IS DISTINCT FROM 0
GROUP BY host
HAVING count(*) > 10
""", database: "test_db")
```

- `CASE`, `COALESCE`, `NULLIF`, `GREATEST`, `LEAST`
- `lower`, `upper`, `length`, `substr`, `starts_with`, `sqrt`, `ln`, `log`, `pow`
- `IS [NOT] DISTINCT FROM`, `IS [NOT] TRUE|FALSE`
- `SELECT 1` with no `FROM`, and an alias without `AS` (`SELECT n a`)
- expressions of aggregates, `GROUP BY` expressions, `HAVING <comparison>`
- `information_schema.tables|columns|schemata`, `SHOW TABLES`,
  `SHOW COLUMNS FROM t`, and the names `iox.t` and `public.iox.t`

A malformed statement gets the engine's parser error (`SQL error:
ParserError("Expected: an expression, found: EOF")`), and the planner's errors
for a `WHERE` that is not a boolean, `LIKE` over `time`, `GROUP BY ()` and a
function called with the wrong type are the engine's too.

### What stays refused

These answer `{:error, %{status: 400, body: "Client.Local: ..."}}`. Test them
against a real InfluxDB (see "Running Against a Real InfluxDB"):

- `date_trunc`, `extract`, `date_part`, `INTERVAL` arithmetic, and the string
  form `date_bin('1 minute', time)` (the `INTERVAL` form is modelled)
- `date_bin_gapfill` with `locf` / `interpolate`
- `approx_percentile_cont`, `approx_median`, `bool_and`, `bool_or`,
  `array_agg`, `FILTER (WHERE ...)`
- window functions (`OVER`), `JOIN` (other than `CROSS JOIN`), `UNION`,
  `INTERSECT`, `EXCEPT`, subqueries, `FROM (VALUES ...)`
- `ROLLUP`, `CUBE`, `GROUPING SETS`, table functions, `system.*` tables,
  other `information_schema` views and `SHOW` variants
- `concat`, `trim`, `replace` and the other string functions not listed above
- `HAVING` without a comparison or without a `GROUP BY`; `COALESCE` mixing
  text and numbers; a comparison of `time` inside a select item

`var_*` and `stddev*` add the values one by one, in the order the engine scans a
whole table (by the tags in the order of their names, then by time), and the
last digits match the engine's there. Under a `WHERE`, a `GROUP BY`, an
expression argument or more than one batch of rows the engine adds in another
order, so the last digits of `var_*`, `stddev*` and of the `sum` and `avg` of
floats can differ from its. Compare them with a tolerance (the contract uses a
relative `1.0e-12`); `sum` and `avg` of whole numbers are exact.

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

## InfluxQL

`query_influxql/3` answers in InfluxDB 3's InfluxQL shape, which is not the
SQL shape (every row below was taken from `influxdb:3.10.1-core`):

```elixir
Local.query_influxql(conn, "SELECT v FROM o", database: "db")
#=> {:ok, [%{"iox::measurement" => "o", "time" => ~U[...], "v" => 1}, ...]}

Local.query_influxql(conn, "SELECT SUM(v), COUNT(*) FROM o", database: "db")
#=> {:ok, [%{"iox::measurement" => "o", "time" => ~U[1970-01-01 00:00:00.000000Z],
#            "sum" => 6, "count_v" => 3, "count_w" => 1}]}
```

Rows come in time order and drop when they carry no selected field. A lone
selector (`MAX`, `MIN`, `FIRST`, `LAST`, `PERCENTILE`) returns its point's time
and the columns beside it. `LIMIT` and `OFFSET` apply per `GROUP BY` series
(and per measurement of a `FROM` list). An unknown column or measurement is
`{:ok, []}`, and in a `WHERE` a column the measurement lacks is null, so false
(`host = 'a' OR zone = 'z'` finds host `a`).

InfluxQL's `WHERE` is not SQL's, and the double follows the engine
(verified):

- A tag a point lacks is the empty string: `host != 'h1'` keeps points
  without `host`, and `host = ''` finds them. A missing field stays null.
- `host =~ /h1/` and `host !~ /h1/` match anywhere in the value
  (`/^h1$/` to anchor, `(?i)` to ignore case). A regex on a field, or `<`,
  `>`, `<=` or `>=` on a tag, is false. Look-around and atomic groups are the
  engine's 500 (`Invalid regex ... look-around ... is not supported`).
- `time > now() - 30m` works with `s`, `m`, `h`, `d` and `w` durations.
- `"host"` and `"usage"` are exact identifiers; InfluxQL folds no case.
- InfluxQL has no `NOT`: it is the engine's parse error. `/* ... */` and
  `-- ...` are comments.
- A field, a constant or a tag that is no comparison inside `AND` / `OR`
  (`WHERE s AND v > 1`, `WHERE b OR n OR v > 1`) is typed the way the planner
  types it, leaves first: a pair with such an operand keeps no point (`b OR s OR b`
  is `b`), but the planner refuses the pair when one operand is unsigned or both
  are numbers (`Int64 AND Int64`) with its `Cannot infer common argument type`
  error, among the errors of the comparisons in the order it builds them.
- Clauses come in the engine's order (`WHERE`, `GROUP BY`, `fill()`, `ORDER BY`,
  `LIMIT`, `OFFSET`, `SLIMIT`, `SOFFSET`, `tz()`): the first one out of its place
  is the parse error at its start, and of two bad operands the leftmost is the
  error (a number past the unsigned range stands before a later `SLIMIT x`, a `fill()` option
  that does not read before a later bad `LIMIT`). A `fill(` where an operand is wanted
  (`WHERE fill(1)`, `WHERE n > 1 AND fill(1)`) is the engine's `invalid expression, the only
  valid function calls ...` at the call; behind a whole condition it is the clause, and what
  follows it must be `ORDER BY` or later (`fill(1) GROUP BY host` is left over from the
  `GROUP`). A sign may stand apart from the digits of a `fill()` number (`fill(- 1)`).
- A comparison of constants (`1 = 1`, `'a' = 'b'`, `'us' =~ /a/`) or of a column the
  measurement lacks with a string, a regular expression, a boolean or a tag keeps no point
  beside a bare operand and raises no error; a missing column compared with a number does the
  same beside numbers, and beside a string or a tag it is refused by name (Core's `Cannot
  infer common argument type`). A string constant under `=~` / `!~` keeps no point.

### SHOW

`SHOW DATABASES`, `SHOW RETENTION POLICIES` (`autogen`, with the database's
`retention:` as `1h0m0s`, or `0s` for none),
`SHOW MEASUREMENTS`, `SHOW TAG KEYS`, `SHOW FIELD KEYS` and `SHOW TAG VALUES`
are answered from the schema, with `ON db`, `FROM` (names and `/re/`),
`WITH MEASUREMENT`, `WITH KEY`, `WHERE`, `LIMIT` and `OFFSET`. Only the last
24 hours count for a `WHERE` that does not bound `time`. The engine's parse
errors are given at their positions. A column the measurement lacks is null in
a comparison, as in a `SELECT` (`nosuch = 'x' OR region = 'eu'` keeps the
points of region `eu`), and a `WHERE` that is no boolean (`WHERE 1`, a string,
a tag or a field) is the engine's `type_coercion` error. Refused by name:
`LIMIT`/`OFFSET` on `SHOW TAG VALUES` over several keys, a time comparison
inside `OR`, and the engine's internal error for a `TAG KEYS` with `WHERE` and
`LIMIT`.

### SELECT

`GROUP BY` takes tags, fields, `*` (every tag), `/re/` (the tags whose key
matches) and `time(every[, offset])` (the first one counts), with `fill(null |
none | previous | linear | n)`; the engine's parse errors for a malformed
clause are given at their positions. The buckets run from the first point (or
the range's start) to `now()`: `fill(none)` and `LIMIT` read only the buckets
they keep, and a series of more than 2,000,000 rows (set
`config :influx_elixir, :local_influxql_max_rows, n`) is refused rather than
held in memory (a fortnight at one second is 1.2 million rows).

Functions: `mean sum count min max first last median spread stddev mode
percentile distinct`, `top` and `bottom` (with tags), `integral`, the math
functions `abs round floor ceil sqrt ln log pow` (a result that is not finite
is a null that is in the row), and the transforms `derivative`,
`non_negative_derivative`, `difference`, `non_negative_difference`,
`cumulative_sum`, `moving_average` and `elapsed` of a field or of an aggregate
in a `GROUP BY time` (the transforms that compare with the bucket before scan
one bucket before the range, as the engine does). `F(*)`, `F(/re/)`, `*::field`,
`*::tag` and `/re/` in the select list, `FROM` with several names or `/re/`,
`tz('UTC')`, `SLIMIT`/`SOFFSET` (the engine's 405) and arithmetic in the select
list (`usage + 1`, `sum(n) / count(n)`, `n::float`) are answered. `count`,
`mode` and `elapsed` take every field (strings and booleans too) in `F(*)` and
`F(/re/)`; `F(*::tag)` is the engine's "unable to use tag as wildcard" error,
and a regular expression stands alone in the parentheses (`percentile(/re/, 99)`
is the engine's parse error). A duration or window the planner refuses
(`derivative(f, 0s)`, `moving_average(f, 1)`) is its planning error, with the
duration worded as it words it (`-1s` is `-1000ms`). A float result that
overflows is a null that is in the row (an integer wraps at 64 bits), and a
`percentile()` of an integer field that has no value, beside another column or
in a `GROUP BY time`, breaks the connection as the engine does
(`{:error, {:connection_error, %Mint.TransportError{reason: :closed}}}`).

The engine finds a statement's errors in an order, and the double keeps it: the
errors of rewriting the statement first (a constant that is the whole field,
`mixing aggregate and non-aggregate columns`, a transform of a field in a
`GROUP BY time`, an operand a function cannot take), whatever the `WHERE` holds;
then a select list that reads no field (tags, `time`, a column the measurement
lacks, an expression of numbers alone) is answered empty without the `WHERE` or
the `LIMIT` being planned; then the comparisons of the `WHERE` it cannot type
and its `AND`/`OR` it cannot type; then the select list's own planning errors
(`mean(s)`, `u / n`); then a `WHERE` that is no boolean. A constant alone in
parentheses (`n * (3)`, `-(3)`, `pow(n, (2))`) is the planner's `field must
contain at least one variable`. An aggregate of a tag is the planner's coercion
error beside a field (`mean(host), mean(usage)`) and empty alone; `fill(n)` of a
plain select fills the number columns that a row lacks with `n` cut to the column's
type (a string or boolean column stays null), and of a selector over a string or
boolean column is the engine's `no conversion` error.

Refused by name, because the double cannot answer them as the engine does:

- `INTO`, subqueries, `tz()` of a zone other than UTC (needs a time zone
  database), a statement after `;` that is not a parse error.
- Float results that depend on the order the engine adds in (`stddev`, the
  `mean` and `sum` of many floats) are answered, and can differ from the
  engine's in the last digits: compare them with a tolerance.
- `fill(linear)` on a text or boolean column or with a `count` over an empty
  bucket, `fill(previous)` with a `count` when the first bucket is empty (the
  engine breaks the connection), `mode()` of values equally often there,
  `integral()` in a `GROUP BY time`, `elapsed()` of an aggregate, a transform
  over points of several series that share a time, in descending order after
  data in the bucket before the range, beside `cumulative_sum`, a `GROUP BY` a field the select list also
  reads, a `GROUP BY` a tag called `time`, an integer or `now()` for `time()`,
  a bucket under a microsecond.
- `top`/`bottom` and `percentile` in arithmetic (the engine ignores the
  arithmetic), a math function over a selector other than the engine's 500,
  `distinct(f)` of a field (the engine lists the values in the order of its
  hash).
- Columns beside a selector in a `GROUP BY time`, `*` beside other items,
  select items that end up with the same name, a remainder by zero, a negative
  fraction cast to an integer, arithmetic on a selector beside columns, several
  aggregates of a type they do not take (the engine names one of them in an
  order of its own), an aggregate of a tag beside fields it is not a dimension
  of when it answers, and clauses out of order with a malformed one among them.
- A quoted time in a form the double does not tell from the engine's, a time
  comparison inside `OR`, a regular expression with `\u` or a back reference.

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
    # Core and 2.7 answer a query with every write they acknowledged, so a
    # test does not wait between a write and a read.
    {:ok, database: db}
  end
end
```

Exclude the tag by default in `test/test_helper.exs`
(`ExUnit.start(exclude: [:integration])`) and include it when a server is up:

```bash
# InfluxDB 3 Core on 8181, no auth, data in memory. A write is answered
# when the write-ahead log flushes (every second by default), so a short
# interval keeps a write-heavy suite fast. A large snapshot size keeps the
# server from snapshotting mid-run: Core 3.10.1 panics when it snapshots a
# point near the largest timestamp, and its writes then hang.
docker run -d --rm --name influx3 -p 8181:8181 influxdb:3.10.1-core \
  influxdb3 serve --node-id node0 --object-store memory --without-auth \
  --wal-flush-interval 10ms --wal-snapshot-size 100000

mix test --include integration
docker stop influx3
```

This library's own contract suite is that second tier:
`test/integration/contract_v3_core/` runs the same assertions as
`test/influx_elixir/client/contract_local/v3_core/` against the
server, and reads `INFLUX_V3_CORE_HOST` / `INFLUX_V3_CORE_PORT` (defaults
`localhost` / `8181`); the v2 suite reads `INFLUX_V2_HOST`, `INFLUX_V2_PORT`,
`INFLUX_V2_TOKEN`, `INFLUX_V2_ORG` and `INFLUX_V2_BUCKET`. Every statement
in this guide about what the real engine returns was recorded that way. This
library's `mix test` does not compile `test/integration` unless a path under it
is named, an integration tag is selected or `INTEGRATION=1` is set, so the
unit suite stays fast. One server's suite is selected by its tag alone,
`mix test --only v3_core` (or `--only v2`); `--include integration` selects
every server's suites, so use it only together with a path.

## Write Rules

A write's body is read as the server reads it. `gzip: true` says the body
is gzip-compressed (it is the HTTP client's `Content-Encoding: gzip`,
which `InfluxElixir.write/3` sets whenever it compresses): the double
decompresses then and only then, and a body that does not decompress is
the engine's `error decoding gzip stream: ...` (InfluxDB 2: its 500). On
the v3 profiles a body that is not UTF-8 is the engine's 400
`body content is not valid utf8: ...`; the v2 profile stores the bytes as
they are.

A write is applied line by line, as on InfluxDB 3. A line with a syntax error,
or a column whose kind conflicts with the measurement's schema, is dropped and
reported while the other lines are stored; the call then returns the engine's
partial-write response:

```elixir
{:ok, :written} = Local.write(conn, "cpu value=1i", database: "test_db")

{:error, %{status: 400, body: body}} =
  Local.write(conn, "cpu value=2.0\ncpu value=3i", database: "test_db")

%{
  "error" => "partial write of line protocol occurred",
  "data" => [
    %{
      "line_number" => 1,
      "original_line" => "cpu value=2.0",
      "error_message" =>
        "invalid column type for column 'value', expected iox::column_type::field::integer, got iox::column_type::field::float"
    }
  ]
} = Jason.decode!(body)
# `cpu value=3i` was stored.
```

A column's kind — tag, or integer / unsigned / float / string / boolean field —
is fixed by the first write that names it, per database and measurement, and
a fixture that writes `value=1i` and later `value=2.0` fails in the double the
way it fails in production. Deleting the database drops the schema with the
data. `time` is a reserved column (`'time' is a reserved column` on a new
table, a column-type conflict with the timestamp column on an existing one),
a key cannot be both a tag and a field on
one line, an integer must fit in 64 bits (`7u` is unsigned), a newline inside
a quoted string value is part of the value, a name ending in a backslash is
rejected ("Measurements, tag keys and values, and field keys may not end with
a backslash"), a tab outside a quoted string value is rejected with the
engine's message for where it stands (InfluxDB 3 only; a leading tab is
whitespace), a CRLF line ending is refused on InfluxDB 3 (the `\r` is
trailing content after the last value) and accepted by InfluxDB 2 only after
a string field (which then keeps its closing quote), a line of anything but
spaces and tabs is not blank, a line starting with `#` is a comment, a
timestamp that does not
fit in 64 bits of nanoseconds once scaled by the precision is rejected in each
version's words, and an empty payload is rejected.
### Pinning production's column types

Every `Local.start/1` begins with an empty schema, so in a test the *first*
write to a measurement decides each column's type. Production's columns were
typed long ago by other writers. A writer that sends the wrong type is
therefore refused in production (`invalid column type ...`), but in its own
test it simply defines the column, and the test passes.

To catch that drift, write one point with production's types before the code
under test runs. Stamp it at a time your queries never reach, for example the
epoch:

```elixir
setup %{conn: conn} do
  # duration_ms is a float in production.
  {:ok, :written} =
    Local.write(conn, "job_runs,job=seed duration_ms=0.0 0", database: "test_db")

  :ok
end

test "records whole-millisecond durations as the column's type", %{conn: conn} do
  # Refused, as on the server, if the writer sends duration_ms=1153i.
  assert :ok = MyApp.JobLog.record(conn, "import", 1153)
end
```

The seed row is stored like any other. A query that is not bounded by time,
such as a plain `COUNT(*)`, sees it.

Points with the same measurement, tag set and timestamp are one point on both
versions (verified): their fields merge and the later write wins per field,
so a fixture that rewrites `v=2i` at an existing instant reads back one row.

Under the `:v2` profile the rules are InfluxDB 2's (verified against 2.7): a
field type conflict is HTTP 422 with `"code": "unprocessable entity"` and a
message ending in `dropped=N`, the other lines stored; a line that fails to
parse rejects the whole payload with HTTP 400 (`"code": "invalid"`) and
nothing is stored; `time` as a field is dropped silently, as a tag it is a
400; a tag and a field may share a name; an empty payload is accepted.

## Key Differences from Real InfluxDB

- **No WAL flush delay**: Writes are immediately queryable
- **In-memory only**: Data is lost when `stop/1` is called
- **Simplified SQL parser**: Supports `SELECT *`, multi-column projection (with
  optional `AS alias`), `SELECT DISTINCT col[, col ...]`,
  `SELECT DISTINCT ON (col[, col ...])`, `WHERE` with binary
  ops + `IN` / `NOT IN` (quoted literals are strings, bare literals are typed),
  `ORDER BY <column>`, `LIMIT`, `$param` substitution, `DATE_BIN` + aggregate
  functions (`AVG`, `SUM`, `COUNT`, `COUNT(*)`, `MIN`, `MAX`,
  `STDDEV[_SAMP|_POP]`, `VAR[_SAMP|_POP]` over field arithmetic,
  `selector_first|last|min|max`, `first_value` / `last_value` with an inner
  `ORDER BY`) with optional `GROUP BY DATE_BIN` or `GROUP BY <columns>`.
  Anything else is rejected with a `Client.Local:` prefixed 400 — see
  `check_sql/1` above and "What stays refused" in the SQL section above.
- **`format: :parquet`**: refused with a `Client.Local:` 400 — the double
  holds no Parquet writer. `format: :csv` is modelled: values come back as
  the engine's CSV strings (`"1.5"`, `"1e16"`, `"true"`), empty cells
  absent, and a nested value fails as the server's aborted response does.
- **Division by zero**: an integer divided by zero closes the connection,
  as on the engine. A float divided by zero is IEEE infinity or NaN there
  (shown as JSON `null`, but compared as a number: `WHERE v / 0.0 > 1` keeps
  every row); Elixir has no such float, so the double refuses it by name.
- **No authentication**: All operations succeed regardless of token
- **ETS-based**: Each `start/1` creates an isolated ETS table
