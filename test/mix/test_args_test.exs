Code.require_file("../../mix/test_args.ex", __DIR__)

defmodule InfluxElixir.MixTestArgsTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.MixTestArgs
  alias InfluxElixir.TestSupport.Check

  @unit ["test/influx_elixir"]

  # Paths of this repository, which the tests run from: a test file, a
  # directory and names (`lib`, `mix.exs`) that are also an option's value.
  @test_file "test/mix/test_args_test.exs"
  # A name that cannot exist, to show that a bare word is not a path.
  @no_such_path "ft6_no_such_path"

  # The switches `mix test` documents that take no value. A switch Mix documents that is in
  # neither this list nor `valued_switches/0` fails the cross-check below, so a new Mix
  # release cannot add a valued switch unnoticed.
  @boolean_switches ~w(--all-warnings --color --no-color --cover --failed
                       --force --listen-on-stdin --no-archives-check --no-compile
                       --no-deps-check --no-elixir-version-check --no-start
                       --preload-modules --raise --stale --trace --warnings-as-errors)

  # The switches in the "Command line options" list of `mix test`'s own documentation.
  # Mix's `@switches` is a private module attribute, so the documentation is the one
  # public record of what the task declares.
  defp documented_switches do
    {:docs_v1, _anno, _language, _format, %{"en" => doc}, _meta, _docs} =
      Code.fetch_docs(Mix.Tasks.Test)

    ~r/^\s+\* `(--[a-z-]+)/m
    |> Regex.scan(doc, capture: :all_but_first)
    |> List.flatten()
    |> Enum.sort()
  end

  describe "valued_switches/0" do
    test "is checked against the switches Mix's test task documents, not against itself" do
      documented = documented_switches()
      valued = MixTestArgs.valued_switches()

      assert valued -- documented === [], "not a switch of mix test"

      assert Enum.sort(documented -- valued) === Enum.sort(@boolean_switches),
             "a documented switch is neither valued nor known to take no value"
    end
  end

  describe "args/3 without INTEGRATION" do
    test "prepends the unit paths only when nothing chooses the tests" do
      Check.check_cases(
        [
          # Nothing chooses: the unit tier.
          {[], :unit},
          {~w(--cover), :unit},
          {~w(--seed 0), :unit},
          {~w(--trace --slowest 5), :unit},
          {~w(--max-cases 2), :unit},
          {~w(--exclude lib), :unit},
          {~w(--exclude=lib), :unit},
          {~w(--only test), :unit},
          {~w(--formatter ExUnit.CLIFormatter), :unit},
          {~w(--only zzz), :unit},
          {~w(--exclude integration), :unit},
          {~w(--profile-require time), :unit},
          {[@no_such_path], :unit},
          {["--only", "mix.exs"], :unit},
          # A path, in any form, chooses.
          {[@test_file], :as_given},
          {[@test_file <> ":12"], :as_given},
          {[@test_file <> ":12:20"], :as_given},
          {["./" <> @test_file], :as_given},
          {~w(test), :as_given},
          {~w(lib), :as_given},
          {~w(mix.exs), :as_given},
          {~w(tmp/x_test.exs), :as_given},
          {~w(nosuch_test.exs), :as_given},
          # A path after a switch `mix test` does not take a value for.
          {["--no-compile", @test_file], :as_given},
          {["--force", @test_file], :as_given},
          {["--profile-require", "time", @test_file], :as_given},
          {[@test_file, "--no-deps-check"], :as_given},
          # Mix's manifests choose.
          {~w(--failed), :as_given},
          {~w(--stale), :as_given},
          # An integration tag chooses.
          {~w(--only v3_core), :as_given},
          {~w(--only=v2), :as_given},
          {~w(--include integration), :as_given},
          {~w(--include=v3_enterprise:true), :as_given},
          {~w(--only v3_core_auth), :as_given}
        ],
        fn {args, expected} ->
          wanted = if expected === :unit, do: @unit ++ args, else: args
          got = MixTestArgs.args(args, nil, @unit)
          if got === wanted, do: :ok, else: {:mismatch, %{expected: wanted, actual: got}}
        end
      )
    end

    test "a valued switch never makes its value a path, whatever the value names" do
      for switch <- MixTestArgs.valued_switches(),
          args <- [[switch, "lib"], [switch <> "=lib"]] do
        assert MixTestArgs.args(args, nil, @unit) === @unit ++ args,
               "#{inspect(args)} chose the tests"
      end
    end

    test "a valued switch that is last has no value to swallow" do
      for switch <- MixTestArgs.valued_switches() do
        assert MixTestArgs.args([switch], nil, @unit) === @unit ++ [switch]
      end
    end
  end

  describe "args/3 with INTEGRATION" do
    test "set to anything but empty, 0 or false, the arguments are kept as given" do
      for value <- ["1", "true", "yes", "FALSE", " "] do
        assert MixTestArgs.args(~w(--cover), value, @unit) === ~w(--cover)
      end
    end

    test "empty, 0 or false, it is not set" do
      for value <- ["", "0", "false"] do
        assert MixTestArgs.args(~w(--cover), value, @unit) === @unit ++ ~w(--cover)
      end
    end
  end

  describe "unit_test_paths/1" do
    test "is every directory and test file of the test directory but the non-unit entries" do
      paths = MixTestArgs.unit_test_paths("test")

      assert paths === Enum.sort(paths)
      assert "test/influx_elixir" in paths
      assert "test/mix" in paths

      for entry <- ~w(integration support fixtures test_helper.exs) do
        refute "test/#{entry}" in paths
      end

      for path <- paths do
        assert File.dir?(path) or String.ends_with?(path, "_test.exs")
      end
    end

    test "a bare run of the project's tests selects exactly them" do
      unit = MixTestArgs.unit_test_paths("test")
      assert MixTestArgs.args([], nil, unit) === unit
      assert MixTestArgs.args(["--cover"], nil, unit) === unit ++ ["--cover"]
    end

    test "a missing directory is an error, not an empty tier" do
      assert_raise File.Error, fn -> MixTestArgs.unit_test_paths(@no_such_path) end
    end
  end
end
