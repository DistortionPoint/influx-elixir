defmodule InfluxElixir.Client.Local.SQLParserFidelityTest do
  @moduledoc """
  What a SQL answer cannot show, and no engine can be asked. What a query
  means, and every body the engine answers with, is pinned in
  `InfluxElixir.Contract.SQLParser` and `InfluxElixir.Contract.SQLExecutor`
  against both clients; these are the two edges only the double has:

    * a text that is not UTF-8 cannot be sent to the engine (JSON has no
      form for it), so the double's refusal has no engine answer to match
    * `SQLParser.bind/2` is handed the engine's values, which have passed
      `Format.check_params/3`; its refusal of a non-scalar is a defence that
      no query reaches
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local
  alias InfluxElixir.Client.Local.SQLParser

  test "SQLParser.bind/2 refuses a parameter that is not a scalar, naming it" do
    assert {:ok, query} = SQLParser.parse_select("SELECT * FROM m WHERE v > $a AND s = $b")

    assert SQLParser.bind(query, %{"a" => 1, "b" => %{"x" => 1}}) ===
             {:error,
              %{status: 400, body: "Client.Local: the parameter $b is a JSON object or array"}}
  end

  test "a query text that is not UTF-8 is refused by name" do
    {:ok, conn} = Local.start(databases: ["utf8_db"], profile: :v3_core)

    assert Local.query_sql(conn, <<"select ", 0xFF>>, database: "utf8_db") ===
             {:error, %{status: 400, body: "Client.Local: the SQL text is not valid UTF-8"}}
  end
end
