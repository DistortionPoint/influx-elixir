defmodule InfluxElixir.MixTestArgs do
  @moduledoc false
  # The arguments `mix test` is given in this project (see the `test` alias
  # in mix.exs). The 71 integration modules are compiled only when something
  # asks for them; otherwise the unit test paths are prepended, so a bare
  # `mix test` neither compiles nor loads `test/integration`.
  #
  # Something asks for them, or for a chosen set of tests, when the arguments
  # name a path, give `--failed` or `--stale` (Mix's manifests choose those),
  # or include an integration tag; or when INTEGRATION is set.
  #
  # INTEGRATION is set when it holds any value but the empty string, `0` and
  # `false` (the spellings of "off" a shell user reaches for). The docs and the
  # changelog only ever write `INTEGRATION=1`, and CI does not set it, so every
  # other value reads as the request it looks like.

  @unset_integration [nil, "", "0", "false"]

  @integration_tags ~w(integration v2 v3_core v3_core_auth v3_enterprise)

  # What under the test directory is not a unit tier: the integration suites,
  # the support code, the fixtures and the helper.
  @non_unit_test_entries ~w(integration support fixtures test_helper.exs)

  # The switches of `mix test` that take a value: their value is never a path,
  # whatever it names (`--exclude lib`, `--only test`, `--seed 0`).
  @valued ~w(--include --exclude --only --seed --slowest --slowest-modules --max-cases
             --max-failures --max-requires --timeout --formatter --partitions
             --export-coverage --profile-require --exit-status --repeat-until-failure)

  @doc """
  The arguments to run `mix test` with: `args` with `unit_paths` first, unless
  the arguments or `integration` (the INTEGRATION environment variable) choose
  the tests.
  """
  @spec args([binary()], binary() | nil, [binary()]) :: [binary()]
  def args(args, integration, unit_paths) do
    if integration in @unset_integration and not explicit_selection?(args),
      do: unit_paths ++ args,
      else: args
  end

  @doc """
  The unit tier under `test_dir`: every directory and every `*_test.exs` file in
  it but the integration suites, the support code, the fixtures and the helper,
  sorted, as paths below `test_dir`.
  """
  @spec unit_test_paths(binary()) :: [binary()]
  def unit_test_paths(test_dir) do
    test_dir
    |> File.ls!()
    |> Enum.reject(&(&1 in @non_unit_test_entries))
    |> Enum.filter(&(File.dir?(Path.join(test_dir, &1)) or String.ends_with?(&1, "_test.exs")))
    |> Enum.sort()
    |> Enum.map(&Path.join(test_dir, &1))
  end

  @doc "The switches of `mix test` that take a value, whose value is never a path."
  @spec valued_switches() :: [binary()]
  def valued_switches, do: @valued

  @doc "Whether the arguments choose which tests run."
  @spec explicit_selection?([binary()]) :: boolean()
  def explicit_selection?(args) do
    {positionals, flags, tags} = split(args, [], [], [])

    Enum.any?(positionals, &path?/1) or
      Enum.any?(flags, &(&1 in ["--failed", "--stale"])) or
      Enum.any?(tags, &(hd(String.split(&1, ":")) in @integration_tags))
  end

  # Walks the arguments as `mix test` reads them: a known valued switch takes
  # the next argument (or its `=value`); every other switch stands alone, so a
  # value an unknown switch would swallow (`--no-compile test/x_test.exs`)
  # stays a candidate path.
  @spec split([binary()], [binary()], [binary()], [binary()]) ::
          {[binary()], [binary()], [binary()]}
  defp split([], positionals, flags, tags), do: {positionals, flags, tags}

  defp split(["--" <> _long = arg | rest], positionals, flags, tags) do
    case String.split(arg, "=", parts: 2) do
      [switch, value] -> split(rest, positionals, flags, tag(switch, value, tags))
      [switch] when switch in @valued -> valued(switch, rest, positionals, flags, tags)
      [switch] -> split(rest, positionals, [switch | flags], tags)
    end
  end

  defp split(["-" <> _short = flag | rest], positionals, flags, tags),
    do: split(rest, positionals, [flag | flags], tags)

  defp split([arg | rest], positionals, flags, tags),
    do: split(rest, [arg | positionals], flags, tags)

  defp valued(switch, [value | rest], positionals, flags, tags),
    do: split(rest, positionals, flags, tag(switch, value, tags))

  defp valued(_switch, [], positionals, flags, tags), do: {positionals, flags, tags}

  defp tag(switch, value, tags) when switch in ["--include", "--only"], do: [value | tags]
  defp tag(_switch, _value, tags), do: tags

  defp path?(arg) do
    path = arg |> String.split(":") |> hd()
    String.ends_with?(path, ".exs") or (path != "" and File.exists?(path))
  end
end
