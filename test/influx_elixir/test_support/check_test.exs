defmodule InfluxElixir.TestSupport.CheckTest do
  # The ratchet and the float comparison decide what the contracts pass, so
  # their failure paths are pinned here.
  use ExUnit.Case, async: true

  alias InfluxElixir.TestSupport.Check

  defp outcome(:ok), do: :ok
  defp outcome(:refused), do: :refused
  defp outcome({:mismatch, _why} = mismatch), do: mismatch

  describe "check_ratchet/3" do
    test "passes when the pinned number of cases was refused" do
      assert :ok === Check.check_ratchet([:ok, :refused, :refused], &outcome/1, 2)
      assert :ok === Check.check_ratchet([:ok, :ok], &outcome/1, 0)
    end

    test "fails above the pin and lists the refused cases" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          Check.check_ratchet([:ok, :refused, :refused], &outcome/1, 1)
        end

      assert error.message =~ "2 case(s) refused, 1 pinned (of 3)"
    end

    test "fails below the pin, so that an improvement moves the pin" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          Check.check_ratchet([:ok, :refused], &outcome/1, 2)
        end

      assert error.message =~ "1 case(s) refused, 2 pinned (of 2)"
    end

    test "a mismatch fails whatever the count" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          Check.check_ratchet([{:mismatch, :wrong}, :refused], &outcome/1, 1)
        end

      assert error.message =~ "1 case(s) did not hold"
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
