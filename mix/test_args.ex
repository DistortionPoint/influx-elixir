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

  @integration_tags ~w(integration v2 v3_core v3_core_auth v3_enterprise)

  # The switches of `mix test` that take a value: their value is never a path,
  # whatever it names (`--exclude lib`, `--only test`, `--seed 0`).
  @valued ~w(--include --exclude --only --seed --slowest --slowest-modules --max-cases
             --max-failures --max-requires --timeout --formatter --partitions
             --export-coverage --profile-require --exit-status --repeat-until-failure)

  @doc """
  The arguments to run `mix test` with: `args` with `unit_paths` first, unless
  the arguments or `integration` (the INTEGRATION environment variable) choose
  the tests. `exists?` tells whether a path names a file or a directory.
  """
  @spec args([binary()], binary() | nil, [binary()], (binary() -> boolean())) :: [binary()]
  def args(args, integration, unit_paths, exists? \\ &File.exists?/1) do
    if integration in [nil, "", "0"] and not explicit_selection?(args, exists?),
      do: unit_paths ++ args,
      else: args
  end

  @doc "Whether the arguments choose which tests run."
  @spec explicit_selection?([binary()], (binary() -> boolean())) :: boolean()
  def explicit_selection?(args, exists? \\ &File.exists?/1) do
    {positionals, flags, tags} = split(args, [], [], [])

    Enum.any?(positionals, &path?(&1, exists?)) or
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

  defp path?(arg, exists?) do
    path = arg |> String.split(":") |> hd()
    String.ends_with?(path, ".exs") or (path != "" and exists?.(path))
  end
end
