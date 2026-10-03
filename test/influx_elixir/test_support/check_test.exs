defmodule InfluxElixir.TestSupport.CheckTest do
  # The ratchet and the float comparison decide what the contracts pass, so
  # their failure paths are pinned here.
  use ExUnit.Case, async: true

  alias InfluxElixir.TestSupport.Check

  # Cases are their own answers: `:ok`, `:refused` or `{:mismatch, why}`.
  describe "check_cases/2" do
    test "passes when every case holds" do
      assert :ok === Check.check_cases([:ok, :ok], & &1)
      assert :ok === Check.check_cases([], & &1)
    end

    test "fails once with every mismatch" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          Check.check_cases([{:mismatch, :one}, :ok, {:mismatch, :two}], & &1)
        end

      assert error.message =~ "2 case(s) did not hold"
      assert error.message =~ ":one"
      assert error.message =~ ":two"
    end

    test "fails on a return that is not :ok or a mismatch, naming the case" do
      for unknown <- [nil, true, :refused, {:ok, 1}] do
        error =
          assert_raise ExUnit.AssertionError, fn ->
            Check.check_cases([:ok, unknown], & &1)
          end

        assert error.message =~ "1 case(s) did not hold"
        assert error.message =~ "unknown_return"
        assert error.message =~ inspect(unknown)
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

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Check.check_ratchet(cases, &elem(&1, 1), [:b], &elem(&1, 0))
        end

      assert error.message =~ "1 case(s) refused that are not pinned"
      assert error.message =~ ":c"
      refute error.message =~ "answered now"
    end

    test "fails for a pinned case that is answered now, so that an improvement moves the pin" do
      cases = [{:a, :ok}, {:b, :refused}]

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Check.check_ratchet(cases, &elem(&1, 1), [:a, :b], &elem(&1, 0))
        end

      assert error.message =~ "1 case(s) pinned as refused that are answered now"
      assert error.message =~ ":a"
      refute error.message =~ "not pinned"
    end

    test "fails for a pinned case that is no longer in the table" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          Check.check_ratchet([:ok], & &1, [:gone])
        end

      assert error.message =~ "answered now or gone from the table"
      assert error.message =~ ":gone"
    end

    test "fails for a swap that leaves the count as it was, naming both cases" do
      # b was pinned as refused and is answered now; c is refused and was not pinned.
      cases = [{:b, :ok}, {:c, :refused}]

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Check.check_ratchet(cases, &elem(&1, 1), [:b], &elem(&1, 0))
        end

      assert error.message =~ "1 case(s) refused that are not pinned"
      assert error.message =~ "1 case(s) pinned as refused that are answered now"
      assert error.message =~ ":b"
      assert error.message =~ ":c"
    end

    test "a mismatch fails whatever the pin" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          Check.check_ratchet([{:mismatch, :wrong}, :refused], & &1, [:refused])
        end

      assert error.message =~ "1 case(s) did not hold"
    end

    test "fails on a return that is not :ok, :refused or a mismatch, naming the case" do
      for unknown <- [nil, false, :skipped, {:error, 1}] do
        error =
          assert_raise ExUnit.AssertionError, fn ->
            Check.check_ratchet([:refused, unknown], & &1, [:refused])
          end

        assert error.message =~ "unknown_return"
        assert error.message =~ inspect(unknown)
      end
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
