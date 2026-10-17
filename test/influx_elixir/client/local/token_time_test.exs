defmodule InfluxElixir.Client.Local.TokenTimeTest do
  @moduledoc """
  How a token's times are printed. `Admin.token_time/1` is tested directly because it is a
  pure function of the time it is given: through `create_token` the time is the real clock's,
  which cannot be made to stand at a whole second or a given millisecond.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.Admin

  # The engine prints a token's times with no fraction at all when the milliseconds are zero,
  # to the millisecond otherwise, and a year past 9999 with its sign (all verified on Core).

  @ms_2026 DateTime.to_unix(~U[2026-01-01 00:00:00Z], :millisecond)

  describe "token_time/1" do
    test "a whole second carries no fraction" do
      assert Admin.token_time(@ms_2026) === "2026-01-01T00:00:00Z"
    end

    test "milliseconds are printed to the millisecond" do
      assert Admin.token_time(@ms_2026 + 120) === "2026-01-01T00:00:00.120Z"
      assert Admin.token_time(@ms_2026 + 7) === "2026-01-01T00:00:00.007Z"
    end

    test "a year before 1000 is four digits" do
      assert Admin.token_time(DateTime.to_unix(~U[0999-12-31 23:59:59Z], :millisecond)) ===
               "0999-12-31T23:59:59Z"
    end

    test "a year past 9999 is signed, up to the calendar's last instant" do
      # 1792259146943 is 2026-10-17T17:45:46.943Z; Core printed the token created then with
      # `expiry_secs` 253402300799 as expiring at this time.
      assert Admin.token_time(1_792_259_146_943 + 253_402_300_799_000) ===
               "+10056-10-16T17:45:45.943Z"

      assert Admin.token_time(8_210_266_876_799_999) === "+262142-12-31T23:59:59.999Z"
    end
  end
end
