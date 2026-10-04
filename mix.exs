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
          # Auto-generated gRPC stub (no logic to test)
          InfluxElixir.Flight.Proto.FlightService.Stub,
          # Test support modules (not library code)
          InfluxElixir.InfluxCase,
          InfluxElixir.IntegrationHelper,
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

  # The 71 integration modules cost about 23 s of CPU to compile and every one of
  # them is excluded by tag unless `--include integration` is given. A bare
  # `mix test` therefore runs only the test directories that are not
  # `test/integration`. The integration suites are compiled when a path is
  # named, an integration tag is selected, or INTEGRATION=1 is set. One
  # server's suite is selected by its tag alone (`--include integration`
  # would also select every other server's):
  #
  #     mix test --only v3_core
  #     mix test test/integration/contract_v3_core --include integration --include v3_core
  @non_unit_test_entries ~w(integration support fixtures test_helper.exs)

  defp run_tests(args) do
    Mix.Task.run("test", test_args(args, System.get_env("INTEGRATION")))
  end

  # The unit paths are prepended only when nothing else says which tests to
  # run: no path, no `--failed` or `--stale` (Mix's own manifests choose
  # those), and no `--include`/`--only` of an integration tag. The arguments
  # are read as `mix test` reads them, so `--only=v2` and a value after a
  # switch are not taken for paths.
  @integration_tags ~w(integration v2 v3_core v3_core_auth v3_enterprise)
  @test_switches [
    include: :keep,
    exclude: :keep,
    only: :keep,
    failed: :boolean,
    stale: :boolean,
    cover: :boolean,
    trace: :boolean,
    raise: :boolean,
    color: :boolean,
    warnings_as_errors: :boolean,
    seed: :integer,
    slowest: :integer,
    max_cases: :integer,
    max_failures: :integer,
    timeout: :integer,
    formatter: :keep,
    partitions: :integer
  ]

  defp test_args(args, integration) do
    if integration in [nil, "", "0"] and not explicit_selection?(args) do
      unit_test_paths() ++ args
    else
      args
    end
  end

  # A path is recognised by what it is, not by where OptionParser leaves it:
  # a switch this list does not know (`--no-compile`, `--force`) would take
  # the path after it as its value.
  defp explicit_selection?(args) do
    {opts, _paths, _unknown} = OptionParser.parse(args, switches: @test_switches)
    tags = Keyword.get_values(opts, :include) ++ Keyword.get_values(opts, :only)

    Enum.any?(args, &path_argument?/1) or opts[:failed] == true or opts[:stale] == true or
      Enum.any?(tags, &(hd(String.split(&1, ":")) in @integration_tags))
  end

  defp path_argument?("-" <> _switch), do: false

  defp path_argument?(arg) do
    path = arg |> String.split(":") |> hd()
    String.ends_with?(path, ".exs") or (path != "" and File.exists?(path))
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
