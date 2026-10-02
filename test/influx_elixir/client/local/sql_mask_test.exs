defmodule InfluxElixir.Client.Local.SQLMaskTest do
  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.SQLMask

  describe "mask/2 — as SQL reads quoted text" do
    test "blanks the inside of a string or a quoted identifier, byte for byte" do
      assert SQLMask.mask("a = 'xyz' AND \"b c\" = 1") == "a = 'xxx' AND \"xxx\" = 1"
      assert SQLMask.mask("a = 'é'") == "a = 'xx'"
      assert SQLMask.mask("a = ''") == "a = ''"
    end

    test "reads a doubled quote as part of the literal" do
      assert SQLMask.mask("a = 'O''Brien' AND b = 1") == "a = 'xxxxxxxx' AND b = 1"
      assert SQLMask.mask(~S|"a""b" = 1|) == ~S|"xxxx" = 1|
    end

    test "does not read a backslash or a regular expression" do
      assert SQLMask.mask(~S|a = 'x\' AND b =~ /c\/d/|) == ~S|a = 'xx' AND b =~ /c\/d/|
    end

    test "raises on an unterminated literal, which the lexer refuses first" do
      assert_raise ArgumentError, ~r/unterminated ' literal/, fn -> SQLMask.mask("a = 'b") end
    end
  end

  # What `InfluxElixir.Client.Local.InfluxQL` needs: a backslash escapes the
  # next byte, a quote is never doubled, `/.../` after `=~` or `!~` is a
  # regular expression, the filler is `_`, and an unterminated literal is
  # masked to the end.
  @influxql [blank: ?_, doubled: false, backslash: true, regex: true, lenient: true]

  describe "mask/2 — as InfluxQL reads quoted text" do
    test "a backslash escapes the next byte, and a doubled quote is two literals" do
      assert SQLMask.mask(~S|a = 'x\'y' AND b = 'p''q'|, @influxql) ==
               ~S|a = '____' AND b = '_''_'|
    end

    test "a regular expression after =~ or !~ is masked, a slash elsewhere is not" do
      assert SQLMask.mask(~S|a =~ /b\/c/ AND d / 2 > 1 AND e !~ /f/|, @influxql) ==
               ~S|a =~ /____/ AND d / 2 > 1 AND e !~ /_/|

      assert SQLMask.mask(~S|a =~ /b/ AND c = 'd' AND e / f|, @influxql) ==
               ~S|a =~ /_/ AND c = '_' AND e / f|
    end

    test "a slash after =~ needs the operator to be the last thing before it" do
      assert SQLMask.mask("a =~ b / c", @influxql) == "a =~ b / c"
      assert SQLMask.mask("a =~   /c/", @influxql) == "a =~   /_/"
    end

    test "an unterminated literal is masked to the end" do
      assert SQLMask.mask("a = 'bc", @influxql) == "a = '__"
      assert SQLMask.mask("a = \"b\\", @influxql) == "a = \"__"
    end
  end

  describe "run/2, cut/2, split_commas/1 and balanced/1" do
    test "run cuts the captures from the text, so a literal cannot end a clause" do
      assert SQLMask.run(~r/WHERE (.+?) LIMIT/, "WHERE a = 'LIMIT' LIMIT") ==
               ["WHERE a = 'LIMIT' LIMIT", "a = 'LIMIT'"]

      assert SQLMask.run(~r/zzz/, "a") == nil
    end

    test "cut gives an unmatched group as the empty string" do
      assert SQLMask.cut("abcdef", {1, 3}) == "bcd"
      assert SQLMask.cut("abcdef", {-1, 0}) == ""
    end

    test "split_commas splits outside parentheses and literals" do
      assert SQLMask.split_commas("a, f(b, c), 'x,y', \"p,q\", d") ==
               ["a", " f(b, c)", " 'x,y'", " \"p,q\"", " d"]
    end

    test "balanced splits at the parenthesis that closes the open one" do
      assert SQLMask.balanced("a, (b), ')' ) tail") == {:ok, "a, (b), ')' ", " tail"}
      assert SQLMask.balanced("a, (b") == :error
    end
  end
end
