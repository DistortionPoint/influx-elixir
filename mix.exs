defmodule InfluxElixir.MixProject do
  use Mix.Project

  @version "0.1.4"
  @source_url "https://github.com/DistortionPoint/influx-elixir"

  def project do
    [
      app: :influx_elixir,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      preferred_cli_env: preferred_cli_env(),

      # Test coverage — exclude modules that require external services
      test_coverage: [
        threshold: 90,
        ignore_modules: [
          # Requires a live InfluxDB instance (integration-only)
          InfluxElixir.Client.HTTP,
          # Auto-generated gRPC stub (no logic to test)
          InfluxElixir.Flight.Proto.FlightService.Stub,
          # Requires a live gRPC server (integration-only)
          InfluxElixir.Flight.Client,
          # Test support modules (not library code)
          InfluxElixir.InfluxCase,
          InfluxElixir.IntegrationHelper,
          InfluxElixir.TestHelper
        ]
      ],

      # Hex.pm
      name: "InfluxElixir",
      description: "Elixir client library for InfluxDB v3 with v2 compatibility",
      package: package(),
      source_url: @source_url,
      docs: docs(),

      # UsageRules
      usage_rules: usage_rules(),

      # Include usage-rules files in hex package
      files: [
        "lib",
        "mix.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        "usage-rules.md",
        "usage-rules/**/*"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {InfluxElixir.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # Runtime — HTTP
      {:finch, "~> 0.18"},
      {:jason, "~> 1.4"},
      {:nimble_csv, "~> 1.2"},
      {:telemetry, "~> 1.0"},
      {:nimble_options, "~> 1.0"},

      # Runtime — Arrow Flight
      {:grpc, "~> 0.11"},
      {:protobuf, "~> 0.12"},

      # Dev/Test
      {:usage_rules, "~> 1.2", only: :dev},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "sobelow --config"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end

  defp preferred_cli_env do
    [
      quality: :test
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["bcatherall"]
    ]
  end

  defp docs do
    [
      main: "InfluxElixir",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/guides/testing-with-local-client.md"
      ],
      groups_for_extras: [
        Guides: ~r/docs\/guides\/.*/
      ],
      source_ref: "v#{@version}"
    ]
  end

  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [:usage_rules]
    ]
  end
end
