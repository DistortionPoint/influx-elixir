defmodule InfluxElixir.Client.Local.SQLParserFidelityTest do
  @moduledoc """
  What a SQL answer cannot show. What a query means, and every body the
  engine answers with, is pinned in `InfluxElixir.Contract.SQLParser` and
  `InfluxElixir.Contract.SQLExecutor` against both clients; these are the
  two edges only the double has:

    * a text that is not UTF-8 cannot be sent to the engine (JSON has no
      form for it), so the double's refusal has no engine answer to match
    * `SQLParser.bind/2` is handed the engine's values, which have passed
      `Format.check_params/3`; its refusal of a non-scalar is a defence that
      no query reaches
    * `SQLLexer.scrub/1` is the text the identifier folder and the parser
      read: how a comment, a dollar quote or an escape string was rewritten
      is invisible in the rows
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.{SQLLexer, SQLParser}

  describe "SQLParser.bind/2" do
    test "refuses a parameter that is not a scalar, naming it" do
      assert {:ok, query} = SQLParser.parse_select("SELECT * FROM m WHERE v > $a AND s = $b")

      assert SQLParser.bind(query, %{"a" => 1, "b" => %{"x" => 1}}) ==
               {:error,
                %{status: 400, body: "Client.Local: the parameter $b is a JSON object or array"}}
    end
  end

  describe "SQLLexer.scrub/1" do
    test "removes the comments, the semicolons and the dollar quotes, nothing else" do
      assert SQLLexer.scrub("select 'a -- b' /* c /* d */ */ , \"x;y\" from t -- e\n ; ;") ==
               {:ok, "select 'a -- b'   , \"x;y\" from t"}

      assert SQLLexer.scrub("select $$it's$$, $t$ $$ $t$, $1, $é") ==
               {:ok, "select 'it''s', ' $$ ', $1, $é"}
    end

    test "writes an escape string as a plain literal, a quote doubled" do
      assert SQLLexer.scrub(~S|select E'it\'s', e'a\nb', E'''', 'E''x', name, $e|) ==
               {:ok, "select 'it''s', 'a\nb', '''', 'E''x', name, $e"}

      assert SQLLexer.scrub("select xe'a', E'\\x41\\101\\u00e9'") ==
               {:ok, "select xe'a', 'AAé'"}
    end

    test "refuses a text that is not UTF-8" do
      assert SQLLexer.scrub(<<"select ", 0xFF>>) ==
               {:error, %{status: 400, body: "Client.Local: the SQL text is not valid UTF-8"}}
    end
  end
end
