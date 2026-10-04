Code.require_file("../../mix/test_args.ex", __DIR__)

defmodule InfluxElixir.MixTestArgsTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.MixTestArgs
  alias InfluxElixir.TestSupport.Check

  @unit ["test/influx_elixir"]

  # What exists on disk, for the cases: a test file, a directory and a name
  # (`lib`, `test`, `0`) that is also an option's value.
  @existing ~w(test test/influx_elixir test/influx_elixir/x_test.exs lib 0 tmp/x_test.exs)
  defp exists?(path), do: path in @existing

  describe "args/4 without INTEGRATION" do
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
          # A path, in any form, chooses.
          {~w(test/influx_elixir/x_test.exs), :as_given},
          {~w(test/influx_elixir/x_test.exs:12), :as_given},
          {~w(test/influx_elixir/x_test.exs:12:20), :as_given},
          {~w(./test/influx_elixir/x_test.exs), :as_given},
          {~w(test), :as_given},
          {~w(tmp/x_test.exs), :as_given},
          {~w(nosuch_test.exs), :as_given},
          # A path after a switch `mix test` does not take a value for.
          {~w(--no-compile test/influx_elixir/x_test.exs), :as_given},
          {~w(--force test/influx_elixir/x_test.exs), :as_given},
          {~w(--profile-require time test/influx_elixir/x_test.exs), :as_given},
          {~w(test/influx_elixir/x_test.exs --no-deps-check), :as_given},
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
          wanted = if expected == :unit, do: @unit ++ args, else: args
          got = MixTestArgs.args(args, nil, @unit, &exists?/1)
          if got === wanted, do: :ok, else: {:mismatch, %{expected: wanted, actual: got}}
        end
      )
    end
  end

  describe "args/4 with INTEGRATION" do
    test "set, the arguments are kept as given; empty or 0, they are not set" do
      assert MixTestArgs.args(~w(--cover), "1", @unit, &exists?/1) === ~w(--cover)
      assert MixTestArgs.args(~w(--cover), "", @unit, &exists?/1) === @unit ++ ~w(--cover)
      assert MixTestArgs.args(~w(--cover), "0", @unit, &exists?/1) === @unit ++ ~w(--cover)
    end
  end
end
