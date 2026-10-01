defmodule InfluxElixir.OptionalDependencyTest do
  use ExUnit.Case, async: true

  # An optional dependency (`optional: true` in mix.exs) may be absent from a
  # consumer's project. Writing `%Decimal{}` expands the struct at compile
  # time, so the library failed to compile there (verified with a scratch
  # consumer). Code must match `%{__struct__: Decimal}` and call the module
  # only behind that match.
  #
  # The main module of an optional dependency is its app name camelized
  # (`:decimal` is `Decimal`); a dependency whose module is named otherwise
  # is listed here.
  @main_modules %{}

  @lib_files Path.wildcard(Path.expand("../../lib/**/*.ex", __DIR__))

  defp optional_modules do
    for app <- optional_deps(), do: main_module(app)
  end

  defp optional_deps do
    for dep <- Mix.Project.config()[:deps],
        {app, _requirement, opts} <- [normalise(dep)],
        Keyword.get(opts, :optional, false),
        do: app
  end

  # `{:app, "~> 1.0"}`, `{:app, "~> 1.0", opts}` and `{:app, opts}` are all
  # dependency specs.
  defp normalise({app, requirement, opts}) when is_list(opts), do: {app, requirement, opts}
  defp normalise({app, opts}) when is_list(opts), do: {app, nil, opts}
  defp normalise({app, requirement}), do: {app, requirement, []}

  defp main_module(app) do
    Map.get_lazy(@main_modules, app, fn ->
      Module.concat([app |> Atom.to_string() |> Macro.camelize()])
    end)
  end

  # The struct expansions of `module` in `source`, as line numbers: `%Module{}`
  # directly or through an `alias Module, as: Other`.
  defp struct_expansions(source, module) do
    ast = Code.string_to_quoted!(source, columns: true)
    target = module |> Module.split() |> Enum.map(&String.to_atom/1)

    {_ast, {_names, found}} =
      Macro.prewalk(ast, {MapSet.new([target]), []}, fn
        {:alias, _call_meta, [{:__aliases__, _name_meta, segments}, opts]} = node, {names, found}
        when is_list(opts) ->
          names =
            case {normalise_segments(segments), Keyword.get(opts, :as)} do
              {^target, {:__aliases__, _as_meta, as}} -> MapSet.put(names, normalise_segments(as))
              _other -> names
            end

          {node, {names, found}}

        {:%, meta, [{:__aliases__, _name_meta, segments}, _fields]} = node, {names, found} ->
          if MapSet.member?(names, normalise_segments(segments)) do
            {node, {names, [meta[:line] | found]}}
          else
            {node, {names, found}}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp normalise_segments([:"Elixir" | rest]), do: rest
  defp normalise_segments(segments), do: segments

  describe "the library's optional dependencies" do
    test "the library has source files and optional dependencies to check" do
      refute @lib_files == []
      refute optional_modules() == []
    end

    test "each optional dependency resolves to its main module" do
      for module <- optional_modules() do
        assert Code.ensure_loaded?(module),
               "#{inspect(module)} is not a module; see @main_modules"
      end
    end

    test "no library file expands a struct of an optional dependency" do
      offenders =
        for module <- optional_modules(),
            path <- @lib_files,
            line <- path |> File.read!() |> struct_expansions(module),
            do: "#{Path.relative_to_cwd(path)}:#{line} expands %#{inspect(module)}{}"

      assert offenders == []
    end
  end

  describe "the struct detector" do
    test "finds a struct written directly or through an alias, and ignores a match on the map" do
      source = """
      defmodule Sample do
        alias Decimal, as: D

        def a(%Decimal{} = value), do: value
        def b(%D{coef: 1}), do: :one
        def c(%{__struct__: Decimal} = value), do: value
        def d(value), do: is_struct(value, Decimal)
        # %Decimal{} in a comment
        def e, do: "%Decimal{} in a string"
      end
      """

      assert struct_expansions(source, Decimal) == [4, 5]
    end
  end
end
