defmodule InfluxElixir.MixProject do
  use Mix.Project

  @version "0.1.41"
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
          InfluxElixir.TestHelper,
          # The contracts and their helpers live in test/support
          ~r/^InfluxElixir\.(Contract|ClientContract|TestSupport|TestServer|TokenContract)/
        ]
      ],

      # Hex.pm
      name: "InfluxElixir",
      description: "Elixir client library for InfluxDB v3 with v2 compatibility",
      package: package(),
      source_url: @source_url,
      docs: docs(),

      # UsageRules
      usage_rules: usage_rules()
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
      {:grpc, "~> 0.11 or ~> 1.0"},
      {:protobuf, "~> 0.12"},

      # Optional — consumers passing %Decimal{} as SQL params get
      # numeric serialisation. Consumers without Decimal are unaffected.
      {:decimal, "~> 2.0 or ~> 3.0", optional: true},

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
      ],
      test: &run_tests/1
    ]
  end

  # The 65 integration modules cost about 23 s of CPU to compile and every one of
  # them is excluded by tag unless `--include integration` is given. A bare
  # `mix test` therefore runs only the test directories that are not
  # `test/integration`. The integration suites are compiled when a path under
  # `test/integration` is named, or when INTEGRATION=1 is set:
  #
  #     mix test test/integration/contract_v3_core --include integration --include v3_core
  #     INTEGRATION=1 mix test --include integration --include v3_core
  @non_unit_test_entries ~w(integration support fixtures test_helper.exs)

  defp run_tests(args) do
    Mix.Task.run("test", test_args(args, System.get_env("INTEGRATION")))
  end

  defp test_args(args, integration) do
    if integration in [nil, "", "0"] and not Enum.any?(args, &test_path?/1) do
      unit_test_paths() ++ args
    else
      args
    end
  end

  defp test_path?(arg) do
    [path | _line_filters] = String.split(arg, ":")
    String.starts_with?(path, "test") and File.exists?(path)
  end

  defp unit_test_paths do
    "test"
    |> File.ls!()
    |> Enum.reject(&(&1 in @non_unit_test_entries))
    |> Enum.filter(&(File.dir?(Path.join("test", &1)) or String.ends_with?(&1, "_test.exs")))
    |> Enum.sort()
    |> Enum.map(&Path.join("test", &1))
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
      maintainers: ["bcatherall"],
      # Only what a consumer needs: no priv/plts (dialyzer PLTs), no .formatter.exs.
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

  defp docs do
    [
      main: "InfluxElixir",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/guides/testing-with-local-client.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: ~r/docs\/guides\/.*/
      ],
      groups_for_modules: [
        "Public API": [InfluxElixir, InfluxElixir.Config, InfluxElixir.StreamError],
        Clients: [
          InfluxElixir.Client,
          InfluxElixir.Client.HTTP,
          InfluxElixir.Client.Local,
          InfluxElixir.Client.QueryParams
        ],
        Writing: [
          InfluxElixir.Write.Point,
          InfluxElixir.Write.LineProtocol,
          InfluxElixir.Write.Writer,
          InfluxElixir.Write.BatchWriter
        ],
        Querying: [
          InfluxElixir.Query.SQL,
          InfluxElixir.Query.SQLStream,
          InfluxElixir.Query.InfluxQL,
          InfluxElixir.Query.Flux,
          InfluxElixir.Query.ResponseParser
        ],
        Administration: [
          InfluxElixir.Admin.Databases,
          InfluxElixir.Admin.Buckets,
          InfluxElixir.Admin.Tokens,
          InfluxElixir.Admin.Health
        ],
        "Connections and Testing": [
          InfluxElixir.Connection,
          InfluxElixir.ConnectionSupervisor,
          InfluxElixir.Supervisor,
          InfluxElixir.Telemetry,
          InfluxElixir.TestHelper
        ],
        "Arrow Flight": [
          InfluxElixir.Flight.Client,
          InfluxElixir.Flight.Reader,
          InfluxElixir.Flight.FlatBuffer
        ]
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
