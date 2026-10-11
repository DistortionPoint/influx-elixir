defmodule InfluxElixir.TestSupport.CheckTest do
  # The ratchet and the float comparison decide what the contracts pass, so
  # their failure paths are pinned here, to the message each gives.
  use ExUnit.Case, async: true

  alias InfluxElixir.TestSupport.Check

  @regressed "case(s) refused that are not pinned as refused"
  @improved "case(s) pinned as refused that are answered now or gone from the table; " <>
              "remove them from the pin:"

  defp failure(fun), do: assert_raise(ExUnit.AssertionError, fun).message

  # Cases are their own answers: `:ok`, `:refused` or `{:mismatch, why}`.
  describe "check_cases/2" do
    test "passes when every case holds" do
      assert :ok === Check.check_cases([:ok, :ok], & &1)
      assert :ok === Check.check_cases([], & &1)
    end

    test "fails once with every mismatch" do
      assert failure(fn ->
               Check.check_cases([{:mismatch, :one}, :ok, {:mismatch, :two}], & &1)
             end) ===
               "2 case(s) did not hold:\n" <>
                 "  {:mismatch, :one}: :one\n" <>
                 "  {:mismatch, :two}: :two"
    end

    test "fails on a return that is not :ok or a mismatch, naming the case" do
      for unknown <- [nil, true, :refused, {:ok, 1}] do
        assert failure(fn -> Check.check_cases([:ok, unknown], & &1) end) ===
                 "1 case(s) did not hold:\n" <>
                   "  #{inspect(unknown)}: {:unknown_return, #{inspect(unknown)}}"
      end
    end
  end

  describe "check_ratchet/4" do
    test "passes when the pinned cases, and only those, were refused" do
      cases = [{:a, :ok}, {:b, :refused}, {:c, :refused}]
      answer = fn {_name, outcome} -> outcome end
      key = fn {name, _outcome} -> name end

      assert :ok === Check.check_ratchet(cases, answer, [:b, :c], key)
      assert :ok === Check.check_ratchet(cases, answer, MapSet.new([:c, :b]), key)
      assert :ok === Check.check_ratchet([:ok, :ok], & &1, [])
    end

    test "fails for a refused case that is not pinned, naming it" do
      cases = [{:a, :ok}, {:b, :refused}, {:c, :refused}]

      assert failure(fn -> Check.check_ratchet(cases, &elem(&1, 1), [:b], &elem(&1, 0)) end) ===
               "1 #{@regressed} (of 3), a regression:\n  :c"
    end

    test "fails for a pinned case that is answered now, so that an improvement moves the pin" do
      cases = [{:a, :ok}, {:b, :refused}]

      assert failure(fn ->
               Check.check_ratchet(cases, &elem(&1, 1), [:a, :b], &elem(&1, 0))
             end) === "1 #{@improved}\n  :a"
    end

    test "fails for a pinned case that is no longer in the table" do
      assert failure(fn -> Check.check_ratchet([:ok], & &1, [:gone]) end) ===
               "1 #{@improved}\n  :gone"
    end

    test "fails for a swap that leaves the count as it was, naming both cases" do
      # b was pinned as refused and is answered now; c is refused and was not pinned.
      cases = [{:b, :ok}, {:c, :refused}]

      assert failure(fn -> Check.check_ratchet(cases, &elem(&1, 1), [:b], &elem(&1, 0)) end) ===
               "1 #{@regressed} (of 2), a regression:\n  :c\n1 #{@improved}\n  :b"
    end

    test "a mismatch fails whatever the pin" do
      assert failure(fn ->
               Check.check_ratchet([{:mismatch, :wrong}, :refused], & &1, [:refused])
             end) === "1 case(s) did not hold:\n  {:mismatch, :wrong}: :wrong"
    end

    test "fails on a return that is not :ok, :refused or a mismatch, naming the case" do
      for unknown <- [nil, false, :skipped, {:error, 1}] do
        assert failure(fn -> Check.check_ratchet([:refused, unknown], & &1, [:refused]) end) ===
                 "1 case(s) did not hold:\n" <>
                   "  #{inspect(unknown)}: {:unknown_return, #{inspect(unknown)}}"
      end
    end
  end

  describe "each_case/2" do
    test "passes when every case's assertions hold" do
      assert Check.each_case([1, 2], &assert(&1 > 0)) === :ok
    end

    test "fails once with the message of every case that failed, failed matches among them" do
      message =
        failure(fn ->
          Check.each_case([1, 2, 3], fn
            1 -> :ok
            2 -> flunk("two")
            3 -> {:ok, _value} = Function.identity(:error)
          end)
        end)

      # Each case's line is its exception's message, as Elixir words it.
      flunked = Exception.message(%ExUnit.AssertionError{message: "two"})
      unmatched = Exception.message(%MatchError{term: :error})

      assert message ===
               "2 case(s) did not hold:\n" <>
                 "  2: #{inspect(flunked)}\n" <>
                 "  3: #{inspect(unmatched)}"
    end
  end

  describe "assert_rows_close/3" do
    test "passes on floats within the tolerance, at any nesting" do
      assert Check.assert_rows_close([{%{"r" => 0.1 + 0.2}}], [{%{"r" => 0.3}}]) === :ok
      assert Check.assert_rows_close([0.0], [-0.0]) === :ok
    end

    test "fails once with the path of every differing value" do
      actual = {:ok, [%{"r" => 0.31, "s" => "a"}, %{"r" => 1}]}
      expected = {:ok, [%{"r" => 0.3, "s" => "a"}, %{"r" => 1.0}]}

      assert failure(fn -> Check.assert_rows_close(actual, expected) end) ===
               "rows differ beyond a relative tolerance:\n" <>
                 "  at [1, 0, \"r\"]: 0.31 !== 0.3\n" <>
                 "  at [1, 1, \"r\"]: 1 !== 1.0\n" <>
                 "actual:   #{inspect(actual)}\n" <>
                 "expected: #{inspect(expected)}"
    end

    test "a map with other keys, or a list of another length, differs as a whole" do
      assert failure(fn -> Check.assert_rows_close([%{a: 1}, [1, 2]], [%{b: 1}, [1]]) end) ===
               "rows differ beyond a relative tolerance:\n" <>
                 "  at [0]: %{a: 1} !== %{b: 1}\n" <>
                 "  at [1]: [1, 2] !== [1]\n" <>
                 "actual:   [%{a: 1}, [1, 2]]\n" <>
                 "expected: [%{b: 1}, [1]]"
    end
  end

  describe "rows_close?/3" do
    test "reads floats to a relative tolerance and everything else strictly" do
      assert Check.rows_close?({:ok, [%{"r" => 0.1 + 0.2}]}, {:ok, [%{"r" => 0.3}]})
      refute Check.rows_close?({:ok, [%{"r" => 0.31}]}, {:ok, [%{"r" => 0.3}]})
      refute Check.rows_close?({:ok, [%{"r" => 1}]}, {:ok, [%{"r" => 1.0}]})
      refute Check.rows_close?({:ok, [1, 2]}, {:ok, [1]})
    end
  end
end
