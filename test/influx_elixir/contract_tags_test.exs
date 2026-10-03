defmodule InfluxElixir.ContractTagsTest do
  @moduledoc """
  Keeps the `local_divergence` tag honest.

  The contracts run the same tests against `Client.Local` and against a real
  engine. A test that does something else for the double (it expects a refusal
  by name where the engine answers, say) must say so with
  `@tag local_divergence: "why"`, so that every place the double is known to differ
  can be listed with `mix test --only local_divergence`. This test reads the
  contract sources (every `.ex` and `.exs` under `test/support`) and fails when

    * a test branches on the client under test and has no such tag, or
    * a test has the tag and does not branch.

  A test branches when its body

    * names `InfluxElixir.Client.Local`, or the alias `Client.Local` or `Local`,
    * calls a `*local?` helper (`sxc_local?/0`, `sp_local?/0`),
    * tests a connection with `is_map(conn)` or `is_list(conn)` (a map is the
      double's connection, a keyword list the HTTP client's),
    * reads `Process.get` or `Application.get_env` (state that only one client
      has), or
    * calls a helper of its contract that itself branches.

  The scan is parsed once for the module. It also asserts how many tests it found,
  overall and in each contract, so that a parser that silently skips a file or
  half of one fails here instead of passing every check above on an empty list.
  """

  use ExUnit.Case, async: true

  @support Path.expand("../support", __DIR__)

  # The fewest tests the scan must find in each contract (a little under the count
  # when they were set; raise them with the contract, never lower them to pass).
  @floors %{
    "client_contract" => 183,
    "client_contract/line_protocol.ex" => 15,
    "contract/flux_contract.ex" => 27,
    "contract/influxql_flux_lp_contract.ex" => 88,
    "contract/sql_aggregates_contract.ex" => 26,
    "contract/sql_executor_contract.ex" => 130,
    "contract/sql_expressions_contract.ex" => 33,
    "contract/sql_parser_contract.ex" => 108,
    "contract/influxql_planner_contract.ex" => 29,
    "contract/retention_contract.ex" => 14,
    "contract/sql_scalar_contract.ex" => 6,
    "contract/write_rules_contract.ex" => 19,
    "token_contract.ex" => 9
  }

  @total_floor 727

  setup_all do
    files =
      [Path.join(@support, "**/*.ex"), Path.join(@support, "**/*.exs")]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.sort()

    {:ok, tests: Enum.flat_map(files, &tests/1)}
  end

  describe "the contract sources" do
    test "the scan finds the contracts' tests, tagged and untagged", %{tests: tests} do
      assert length(tests) >= @total_floor
      assert Enum.any?(tests, & &1.tagged?)
      assert Enum.any?(tests, & &1.branches?)
    end

    test "the scan finds at least the expected tests in each contract", %{tests: tests} do
      found = Enum.frequencies_by(tests, &Path.relative_to(&1.file, @support))

      # A floor names a file, or a prefix: `client_contract` is the file and the
      # directory of the modules it was split into.
      short =
        for {prefix, floor} <- @floors,
            count = count_under(found, prefix),
            count < floor,
            do: "#{prefix}: #{count} < #{floor}"

      assert short === []
    end

    test "every test that branches on the client carries a local_divergence tag",
         %{tests: tests} do
      untagged = for %{branches?: true, tagged?: false} = test <- tests, do: describe(test)

      assert untagged === []
    end

    test "every local_divergence tag sits on a test that branches on the client",
         %{tests: tests} do
      idle = for %{branches?: false, tagged?: true} = test <- tests, do: describe(test)

      assert idle === []
    end

    test "every local_divergence tag gives its reason", %{tests: tests} do
      blank =
        for %{reason: reason} = test <- tests, test.tagged?, blank?(reason), do: describe(test)

      assert blank === []
    end
  end

  defp count_under(found, prefix) do
    for({file, n} <- found, String.starts_with?(file, prefix), do: n) |> Enum.sum()
  end

  defp describe(%{file: file, line: line, name: name}),
    do: "#{Path.relative_to_cwd(file)}:#{line} #{name}"

  defp blank?(reason) when is_binary(reason), do: String.trim(reason) === ""
  defp blank?(nil), do: true
  defp blank?(_expression), do: false

  # The tests of one source file, in source order: where each is, whether its
  # body branches on the client, and the reason of the tag before it if any.
  defp tests(file) do
    ast = file |> File.read!() |> Code.string_to_quoted!(file: file)
    helpers = branching_helpers(ast)

    {_ast, events} =
      Macro.prewalk(ast, [], fn node, events -> {node, event(node, helpers, file) ++ events} end)

    events
    |> Enum.sort_by(& &1.line)
    |> Enum.reduce({nil, []}, &attach/2)
    |> elem(1)
    |> Enum.reverse()
  end

  # A tag is held until the next test, which it belongs to.
  defp attach(%{kind: :tag, reason: reason}, {_held, tests}), do: {{:tagged, reason}, tests}

  defp attach(%{kind: :test} = test, {held, tests}) do
    test =
      case held do
        {:tagged, reason} -> %{test | tagged?: true, reason: reason}
        nil -> test
      end

    {nil, [test | tests]}
  end

  defp event({:@, meta, [{:tag, _tag_meta, [tag]}]}, _helpers, _file) do
    case divergence(tag) do
      {:ok, reason} -> [%{kind: :tag, line: meta[:line], reason: reason}]
      :error -> []
    end
  end

  defp event({:test, meta, [name | rest]}, helpers, file) do
    [
      %{
        kind: :test,
        file: file,
        line: meta[:line],
        name: Macro.to_string(name),
        branches?: branches?(body(rest), helpers),
        tagged?: false,
        reason: nil
      }
    ]
  end

  defp event(_node, _helpers, _file), do: []

  defp divergence(tag) when is_list(tag) do
    case Keyword.fetch(tag, :local_divergence) do
      {:ok, reason} -> {:ok, reason}
      :error -> :error
    end
  end

  defp divergence(_tag), do: :error

  # `test name do ... end` and `test name, ctx do ... end`.
  defp body(rest) do
    rest |> List.last() |> Keyword.get(:do)
  end

  # The names of the contract's own helpers whose bodies branch, with the
  # helpers that call them, until no more are found.
  defp branching_helpers(ast) do
    {_ast, defs} =
      Macro.prewalk(ast, [], fn
        {kind, _def_meta, [{name, _head_meta, args}, [do: body]]} = node, defs
        when kind in [:def, :defp] and is_atom(name) and is_list(args) ->
          {node, [{name, body} | defs]}

        {kind, _def_meta, [{name, _head_meta, nil}, [do: body]]} = node, defs
        when kind in [:def, :defp] and is_atom(name) ->
          {node, [{name, body} | defs]}

        node, defs ->
          {node, defs}
      end)

    close(defs, MapSet.new())
  end

  defp close(defs, found) do
    next =
      for {name, body} <- defs, branches?(body, found), into: found do
        name
      end

    if MapSet.equal?(next, found), do: found, else: close(defs, next)
  end

  defp branches?(ast, helpers) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? ->
        {node, found? or branch_node?(node, helpers)}
      end)

    found?
  end

  # The alias of the double, in any spelling.
  defp branch_node?({:__aliases__, _meta, [:InfluxElixir, :Client, :Local]}, _helpers), do: true
  defp branch_node?({:__aliases__, _meta, [:Client, :Local]}, _helpers), do: true
  defp branch_node?({:__aliases__, _meta, [:Local]}, _helpers), do: true

  # A map is the double's connection and a keyword list the HTTP client's.
  defp branch_node?({guard, _meta, [arg]}, _helpers) when guard in [:is_map, :is_list],
    do: conn_ref?(arg)

  # State only one client has.
  defp branch_node?({{:., _dot, [{:__aliases__, _meta, [:Process]}, :get]}, _call, _args}, _h),
    do: true

  defp branch_node?(
         {{:., _dot, [{:__aliases__, _meta, [:Application]}, :get_env]}, _call, _args},
         _helpers
       ),
       do: true

  defp branch_node?({name, _call_meta, args}, helpers) when is_atom(name) and is_list(args),
    do: local_call?(name) or MapSet.member?(helpers, name)

  defp branch_node?(_node, _helpers), do: false

  # `conn`, `ctx.conn` or any variable whose name ends in `conn`.
  defp conn_ref?({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: String.ends_with?(Atom.to_string(name), "conn")

  defp conn_ref?({{:., _dot, [_ctx, :conn]}, _meta, []}), do: true
  defp conn_ref?(_arg), do: false

  defp local_call?(name), do: String.ends_with?(Atom.to_string(name), "local?")
end
