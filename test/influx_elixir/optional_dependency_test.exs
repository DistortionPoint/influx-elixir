defmodule InfluxElixir.OptionalDependencyTest.Deps do
  @moduledoc false

  # The main module of each dependency marked `optional: true` in mix.exs.
  # `{:app, "~> 1.0"}`, `{:app, "~> 1.0", opts}` and `{:app, opts}` are all
  # dependency specs.
  @spec modules(%{atom() => module()}) :: [module()]
  def modules(main_modules) do
    for dep <- Mix.Project.config()[:deps],
        {app, opts} = spec(dep),
        Keyword.get(opts, :optional, false) do
      Map.get_lazy(main_modules, app, fn ->
        Module.concat([app |> Atom.to_string() |> Macro.camelize()])
      end)
    end
  end

  defp spec({app, _requirement, opts}) when is_list(opts), do: {app, opts}
  defp spec({app, opts}) when is_list(opts), do: {app, opts}
  defp spec({app, _requirement}), do: {app, []}
end

defmodule InfluxElixir.OptionalDependencyTest do
  use ExUnit.Case, async: true

  # An optional dependency (`optional: true` in mix.exs) may be absent from a
  # consumer's project. Writing `%Decimal{}` expands the struct at compile
  # time, and `import`, `require` and `use` of the module need it at compile
  # time too, so the library failed to compile there (verified with a scratch
  # consumer for the struct). Code must match `%{__struct__: Decimal}` and call
  # the module only behind that match.
  #
  # The main module of an optional dependency is its app name camelized
  # (`:decimal` is `Decimal`); a dependency whose module is named otherwise
  # is listed here.
  @main_modules %{}

  @lib_files Path.wildcard(Path.expand("../../lib/**/*.ex", __DIR__))

  # A library with no optional dependency has nothing to check.
  @optional_modules InfluxElixir.OptionalDependencyTest.Deps.modules(@main_modules)

  @compile_time_forms [:import, :require, :use]

  setup_all do
    # Every library file is parsed once, for every optional module.
    {:ok, asts: Map.new(@lib_files, &{&1, &1 |> File.read!() |> parse()})}
  end

  defp parse(source), do: Code.string_to_quoted!(source, columns: true)

  # What needs `module` at compile time in `ast`, as `{line, form}`: a struct
  # `%Module{}` directly or through an `alias Module, as: Other`, and an
  # `import`, `require` or `use` of it.
  defp compile_time_needs(ast, module) do
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
          if MapSet.member?(names, normalise_segments(segments)),
            do: {node, {names, [{meta[:line], :struct} | found]}},
            else: {node, {names, found}}

        {form, meta, [{:__aliases__, _name_meta, segments} | _opts]} = node, {names, found}
        when form in @compile_time_forms ->
          if MapSet.member?(names, normalise_segments(segments)),
            do: {node, {names, [{meta[:line], form} | found]}},
            else: {node, {names, found}}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp normalise_segments([:"Elixir" | rest]), do: rest
  defp normalise_segments(segments), do: segments

  describe "the library's optional dependencies" do
    if @optional_modules === [] do
      @describetag skip: "the library declares no optional dependency"
    end

    test "each optional dependency resolves to its main module" do
      for module <- @optional_modules do
        assert Code.ensure_loaded?(module),
               "#{inspect(module)} is not a module; see @main_modules"
      end
    end

    test "no library file needs an optional dependency at compile time", %{asts: asts} do
      offenders =
        for module <- @optional_modules,
            {path, ast} <- asts,
            {line, form} <- compile_time_needs(ast, module),
            do: "#{Path.relative_to_cwd(path)}:#{line} #{form}s #{inspect(module)}"

      assert offenders === []
    end
  end

  describe "the library's source" do
    test "has files to check", %{asts: asts} do
      assert map_size(asts) > 0
    end
  end

  describe "the compile-time detector" do
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

      assert source |> parse() |> compile_time_needs(Decimal) ===
               [{4, :struct}, {5, :struct}]
    end

    test "finds an import, a require and a use, with options or an alias" do
      source = """
      defmodule Sample do
        import Decimal
        import Decimal, only: [new: 1]
        require Decimal
        require Decimal, as: D
        use Decimal
        use Decimal, option: true
        alias Decimal, as: Dec
        import Dec
      end
      """

      assert source |> parse() |> compile_time_needs(Decimal) ===
               [
                 {2, :import},
                 {3, :import},
                 {4, :require},
                 {5, :require},
                 {6, :use},
                 {7, :use},
                 {9, :import}
               ]
    end

    test "ignores a plain alias, another module and a call on the module" do
      source = """
      defmodule Sample do
        alias Decimal
        alias Decimal, as: D
        import Enum
        require Logger
        use GenServer

        def a(%{__struct__: Decimal} = value), do: Decimal.to_string(value)
        def b(value), do: D.to_string(value)
      end
      """

      assert source |> parse() |> compile_time_needs(Decimal) === []
    end
  end
end
