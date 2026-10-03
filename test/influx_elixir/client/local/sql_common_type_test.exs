defmodule InfluxElixir.Client.Local.SQLCommonTypeTest do
  @moduledoc """
  The type the results of a `CASE` and the arguments of a `COALESCE`, `NULLIF`,
  `GREATEST` or `LEAST` share, and the engine's names for Arrow types. The
  answers of the engine to the expressions that need them are pinned by the SQL
  scalar contract (`InfluxElixir.Contract.SQLScalar`); these are the rules those
  answers were read into, one row each.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.SQLCommonType
  alias InfluxElixir.TestSupport.Check

  describe "common/2" do
    test "is the one type the arguments share, whatever the mode" do
      cases =
        for mode <- [:case, :coalesce],
            type <- ["Boolean", "Int64", "Float64", "Utf8"],
            do: {[type, type, nil], mode, type}

      check_common(cases)
    end

    test "reads a tag as the text it holds" do
      check_common([
        {["Dictionary(Int32, Utf8)", "Utf8"], :case, "Utf8"},
        {["Dictionary(Int32, Utf8)", "Dictionary(Int32, Utf8)"], :coalesce, "Utf8"},
        {["Dictionary(Int32, Utf8)", nil], :coalesce, "Utf8"}
      ])
    end

    test "is not known when no argument has a known type" do
      check_common([{[], :case, nil}, {[nil, nil], :coalesce, nil}])
    end

    test "widens an integer beside a float to the float" do
      check_common([
        {["Int64", "Float64"], :case, "Float64"},
        {["Float64", "Int64", "Int64"], :coalesce, "Float64"}
      ])
    end

    test "makes text of a number beside text in a CASE only" do
      check_common([
        {["Int64", "Utf8"], :case, "Utf8"},
        {["Utf8", "Float64"], :case, "Utf8"},
        {["Int64", "Utf8"], :coalesce, :mixed},
        {["Float64", "Utf8"], :coalesce, :mixed}
      ])
    end

    test "has no type for any other mix, or for a type it does not model" do
      check_common([
        {["Boolean", "Int64"], :case, :mixed},
        {["Boolean", "Utf8"], :coalesce, :mixed},
        {["Int64", "Float64", "Utf8"], :coalesce, :mixed},
        {["Timestamp(ns)"], :case, :mixed},
        {["UInt64", "UInt64"], :coalesce, :mixed},
        {[:mixed, "Int64"], :case, :mixed},
        {[:mixed], :coalesce, :mixed}
      ])
    end
  end

  describe "native/1" do
    test "names an Arrow type as the engine's messages do" do
      Check.check_cases(
        [
          {"Utf8", "String"},
          {"Dictionary(Int32, Utf8)", "String"},
          {"Timestamp(ns)", "Timestamp(Nanosecond, None)"},
          {"Int64", "Int64"},
          {"Boolean", "Boolean"}
        ],
        fn {type, expected} ->
          actual = SQLCommonType.native(type)

          if actual === expected,
            do: :ok,
            else: {:mismatch, %{expected: expected, actual: actual}}
        end
      )
    end
  end

  defp check_common(cases) do
    Check.check_cases(cases, fn {types, mode, expected} ->
      actual = SQLCommonType.common(types, mode)
      if actual === expected, do: :ok, else: {:mismatch, %{expected: expected, actual: actual}}
    end)
  end
end
