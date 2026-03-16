# InfluxElixir

Elixir client library for InfluxDB v3 with v2 compatibility.

## Installation

Add `influx_elixir` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:influx_elixir, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
# In your application supervision tree
children = [
  {InfluxElixir,
    connections: [
      default: [
        host: "http://localhost:8086",
        token: "your-token",
        default_database: "my_database"
      ]
    ]}
]
```

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
{:ok, conn} = InfluxElixir.Client.Local.start(
  databases: ["myapp_test"],
  profile: :v3_core
)
```

See the [Testing with LocalClient](testing-with-local-client.html)
guide for full setup instructions, shared case templates, and contract testing.

## Documentation

Full documentation available at [HexDocs](https://hexdocs.pm/influx_elixir).

## License

MIT — see [LICENSE](LICENSE).
