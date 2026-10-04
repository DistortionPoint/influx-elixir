defmodule InfluxElixir.Client.Local.TokenTimeTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.Admin

  # The engine prints a token's times with no fraction at all when the milliseconds are zero,
  # and to the millisecond otherwise.

  describe "token_time/1" do
    test "a whole second carries no fraction" do
      assert Admin.token_time(~U[2026-01-01 00:00:00Z]) === "2026-01-01T00:00:00Z"
    end

    test "a whole second held at millisecond precision carries no fraction" do
      assert Admin.token_time(~U[2026-01-01 00:00:00.000Z]) === "2026-01-01T00:00:00Z"
    end

    test "milliseconds are printed to the millisecond" do
      assert Admin.token_time(~U[2026-01-01 00:00:00.120Z]) === "2026-01-01T00:00:00.120Z"
    end
  end
end
