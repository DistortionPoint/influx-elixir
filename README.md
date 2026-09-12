# InfluxElixir

Elixir client library for InfluxDB v3 with v2 compatibility.

## Installation

Add `influx_elixir` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:influx_elixir, "~> 0.1"}
  ]
end
```

## Configuration

The library is an OTP application: it starts one supervisor per connection
listed in config, each with its own Finch pool and (optionally) a batch
writer. Hosts are bare hostnames — the scheme and port are separate options.

```elixir
# config/runtime.exs
config :influx_elixir, :connections,
  default: [
    host: "localhost",
    port: 8181,
    scheme: :http,
    token: System.fetch_env!("INFLUX_TOKEN"),
    database: "my_database"
  ]
```

For InfluxDB 2.x add `api_version: :v2` and `org: "my-org"` (the v2 write
endpoint is bucket/org scoped). Connections can also be added at runtime
with `InfluxElixir.add_connection/2`. See `InfluxElixir.Config` for every
option, including `batch_writer:`, `timeout:`, `pool_timeout:` and
`flight_port:`.

## Usage

Every operation goes through the `InfluxElixir` facade and accepts either a
connection name or a connection term:

```elixir
point = InfluxElixir.point("cpu", %{"value" => 0.64}, tags: %{"host" => "web01"})
{:ok, line} = InfluxElixir.Write.LineProtocol.encode(point)
{:ok, :written} = InfluxElixir.write(:default, line)

{:ok, rows} =
  InfluxElixir.query_sql(:default, "SELECT * FROM cpu WHERE host = $host",
    params: %{host: "web01"}
  )

# rows: [%{"host" => "web01", "value" => 0.64, "time" => ~U[...]}]
```

Large result sets stream with `InfluxElixir.query_sql_stream/3`; Arrow Flight
is available with `transport: :flight`. Write and query operations emit
`[:influx_elixir, :write | :query, ...]` telemetry events.

## Testing

This library ships with `InfluxElixir.Client.Local`, an in-memory InfluxDB
client that enables fast, isolated tests with `async: true` and no external
dependencies. Configure it in `config/test.exs`:

```elixir
config :influx_elixir, :client, InfluxElixir.Client.Local
```

LocalClient enforces an InfluxDB **version profile** matching your production
backend, so your tests fail if you use operations your real InfluxDB doesn't
support:

```elixir
setup do
  InfluxElixir.TestHelper.setup_influx(databases: ["myapp_test"], profile: :v3_core)
end
```

See the [Testing with LocalClient](testing-with-local-client.html)
guide for full setup instructions, shared case templates, and contract testing.

## Documentation

Full documentation available at [HexDocs](https://hexdocs.pm/influx_elixir).

## License

MIT — see [LICENSE](LICENSE).
