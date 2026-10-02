defmodule InfluxElixir.Client.Local.SQLMaskTest do
  @moduledoc """
  What no query can reach. How `InfluxElixir.Client.Local.SQLMask` reads quoted
  text, in SQL and in InfluxQL, decides which clause each part of a statement
  belongs to, and so is pinned by the answers to those statements: the SQL
  contract (`InfluxElixir.Contract.SQLParser`, a literal that holds a comma,
  `limit 5` or `from t`; a doubled quote) and the InfluxQL contract (a
  backslash in a literal, a `/regex/`).

  An unterminated literal is the one thing left: `SQLLexer.scrub/1` refuses a
  SQL text that holds one before anything masks it, so a query never gets
  there, and `mask/2` raising is the guard that says so.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.SQLMask

  test "mask/2 raises on an unterminated literal, which the lexer refuses first" do
    assert_raise ArgumentError, ~r/unterminated ' literal/, fn -> SQLMask.mask("a = 'b") end
    assert_raise ArgumentError, ~r/unterminated " literal/, fn -> SQLMask.mask(~S|a = "b|) end
  end
end
