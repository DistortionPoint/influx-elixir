defmodule InfluxElixir.Client.Local.SQLLimitsTest do
  @moduledoc """
  The ends of the engine's integer and float types, and the wrap-around of its
  integer arithmetic: the numbers the SQL modules of `Client.Local` share, pinned
  against the types' definitions (Arrow's `Int64`, `UInt64` and `Float64`).
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.SQLLimits

  require SQLLimits

  describe "the limits" do
    test "are the ends of Int64, UInt64 and Float64" do
      assert SQLLimits.int64_min() === -Integer.pow(2, 63)
      assert SQLLimits.int64_max() === Integer.pow(2, 63) - 1
      assert SQLLimits.uint64_max() === Integer.pow(2, 64) - 1
      largest = 1.7_976_931_348_623_157e308
      assert SQLLimits.float_max() === largest
    end

    test "stand in a pattern" do
      assert match?(SQLLimits.int64_min(), -9_223_372_036_854_775_808)
      refute match?(SQLLimits.int64_max(), 9_223_372_036_854_775_806)
    end
  end

  describe "is_int64/1 and is_uint64/1" do
    test "hold exactly for the integers each type holds" do
      cases = [
        {SQLLimits.int64_min() - 1, false, false},
        {SQLLimits.int64_min(), true, false},
        {-1, true, false},
        {0, true, true},
        {SQLLimits.int64_max(), true, true},
        {SQLLimits.int64_max() + 1, false, true},
        {SQLLimits.uint64_max(), false, true},
        {SQLLimits.uint64_max() + 1, false, false}
      ]

      InfluxElixir.TestSupport.Check.check_cases(cases, fn {value, int64, uint64} ->
        actual = {int64?(value), uint64?(value)}

        if actual === {int64, uint64},
          do: :ok,
          else: {:mismatch, %{expected: {int64, uint64}, actual: actual}}
      end)
    end

    test "do not hold for a number that is not an integer" do
      refute int64?(1.0)
      refute uint64?(1.0)
      refute int64?("1")
      refute uint64?(nil)
    end
  end

  describe "wrap_int64/1" do
    test "keeps what fits and wraps the rest as two's complement does" do
      cases = [
        {0, 0},
        {SQLLimits.int64_max(), SQLLimits.int64_max()},
        {SQLLimits.int64_min(), SQLLimits.int64_min()},
        {SQLLimits.int64_max() + 1, SQLLimits.int64_min()},
        {SQLLimits.int64_min() - 1, SQLLimits.int64_max()},
        {SQLLimits.int64_max() * 2, -2},
        {Integer.pow(2, 64), 0}
      ]

      InfluxElixir.TestSupport.Check.check_cases(cases, fn {value, expected} ->
        actual = SQLLimits.wrap_int64(value)
        if actual === expected, do: :ok, else: {:mismatch, %{expected: expected, actual: actual}}
      end)
    end
  end

  describe "wrap_uint64/1" do
    test "keeps what fits and wraps the rest modulo 2^64" do
      cases = [
        {0, 0},
        {SQLLimits.uint64_max(), SQLLimits.uint64_max()},
        {SQLLimits.uint64_max() + 1, 0},
        {-1, SQLLimits.uint64_max()},
        {Integer.pow(2, 64) + 5, 5}
      ]

      InfluxElixir.TestSupport.Check.check_cases(cases, fn {value, expected} ->
        actual = SQLLimits.wrap_uint64(value)
        if actual === expected, do: :ok, else: {:mismatch, %{expected: expected, actual: actual}}
      end)
    end
  end

  defp int64?(value) when SQLLimits.is_int64(value), do: true
  defp int64?(_value), do: false

  defp uint64?(value) when SQLLimits.is_uint64(value), do: true
  defp uint64?(_value), do: false
end
