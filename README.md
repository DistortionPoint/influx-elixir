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

## Documentation

Full documentation available at [HexDocs](https://hexdocs.pm/influx_elixir).

## License

MIT — see [LICENSE](LICENSE).
