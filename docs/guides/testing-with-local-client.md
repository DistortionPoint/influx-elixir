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

## Key Differences from Real InfluxDB

- **No WAL flush delay**: Writes are immediately queryable (set `query_delay: 0`)
- **In-memory only**: Data is lost when `stop/1` is called
- **Simplified SQL parser**: Supports `SELECT *`, `WHERE`, `ORDER BY time`, `LIMIT`
- **No authentication**: All operations succeed regardless of token
- **ETS-based**: Each `start/1` creates an isolated ETS table
