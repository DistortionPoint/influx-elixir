defmodule InfluxElixir.Client.Local.InfluxQLClausesTest do
  @moduledoc """
  The clauses after a statement's `FROM`, which the engine reads in one order and word
  position by position: whatever is written there is an answer or an error by name, and
  never an exception, in a VM that has seen no statement before it. The answers are pinned
  by the planner contract (`InfluxElixir.Contract.InfluxQLDefectCases`).
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local

  @clauses [
    "LIMIT",
    "OFFSET",
    "SLIMIT",
    "SOFFSET",
    "GROUP BY host",
    "ORDER BY time DESC",
    "fill(1)"
  ]
  @operands ["x", "1", "99999999999999999999", ""]

  setup do
    {:ok, conn} = Local.start(databases: ["clauses_db"])
    {:ok, :written} = Local.write(conn, "m,host=a v=1.5 1000000000", database: "clauses_db")
    {:ok, conn: conn}
  end

  defp statements do
    for first <- @clauses,
        second <- @clauses,
        first_operand <- @operands,
        second_operand <- @operands do
      "SELECT v FROM m #{first} #{first_operand} #{second} #{second_operand}"
    end
  end

  test "a statement with two clauses in any order, with any operand, is answered or refused",
       %{conn: conn} do
    for statement <- statements() do
      answer =
        try do
          Local.query_influxql(conn, statement, database: "clauses_db")
        rescue
          exception -> {:raised, Exception.message(exception)}
        catch
          kind, reason -> {kind, reason}
        end

      assert match?({:ok, rows} when is_list(rows), answer) or
               match?(
                 {:error, %{status: status, body: body}}
                 when status in [400, 405] and is_binary(body),
                 answer
               ),
             "#{statement} => #{inspect(answer)}"
    end
  end

  test "a bad SLIMIT or SOFFSET operand is the parse error of the SLIMIT clause", %{conn: conn} do
    assert {:error, %{status: 400, body: slimit}} =
             Local.query_influxql(conn, "SELECT v FROM m SLIMIT x", database: "clauses_db")

    assert slimit ===
             "error in InfluxQL statement: parsing error: " <>
               "invalid SLIMIT clause, expected unsigned integer at pos 23"

    # the engine words a bad SOFFSET operand as the SLIMIT clause's
    assert {:error, %{status: 400, body: soffset}} =
             Local.query_influxql(conn, "SELECT v FROM m SOFFSET x", database: "clauses_db")

    assert soffset ===
             "error in InfluxQL statement: parsing error: " <>
               "invalid SLIMIT clause, expected unsigned integer at pos 24"
  end

  test "clauses out of their order are left over from the first one out of its place",
       %{conn: conn} do
    assert {:error, %{status: 400, body: body}} =
             Local.query_influxql(
               conn,
               "SELECT v FROM m GROUP BY host fill(null) SLIMIT 1 LIMIT 2 OFFSET 1",
               database: "clauses_db"
             )

    assert body ===
             "error in InfluxQL statement: parsing error: invalid InfluxQL statement at pos 50. " <>
               ~s|Parsing Error: Nom("LIMIT 2 OFFSET 1", Tag)|
  end

  # A text no atom exists for: the VM has not met it, and no other test can write it.
  defp unique_text, do: "zz_" <> Integer.to_string(System.unique_integer([:positive]))

  defp answered?(answer),
    do:
      match?({:ok, rows} when is_list(rows), answer) or
        match?(
          {:error, %{status: status, body: body}}
          when status in [400, 404, 405, 500] and is_binary(body),
          answer
        )

  defp ask(fun, statement) do
    answer =
      try do
        fun.(statement)
      rescue
        exception -> {:raised, Exception.message(exception)}
      catch
        kind, reason -> {kind, reason}
      end

    assert answered?(answer), "#{statement} => #{inspect(answer)}"
  end

  describe "no atom is made from the text of a statement" do
    # The first statement in a fresh VM met an atom that did not exist yet, and raised. A
    # test cannot make a VM fresh, but it can use a text that no atom exists for and ask the
    # VM, after the statements, whether one was made for it: `String.to_existing_atom/1` of
    # the text raises when none was. The text stands where the statements read names and
    # operands: as a measurement, a field, a tag, a function, a time unit, and the operand of
    # each clause.
    test "in an InfluxQL statement", %{conn: conn} do
      text = unique_text()

      {:ok, :written} =
        Local.write(conn, "#{text},t=a #{text}=1.5 1000000000", database: "clauses_db")

      statements = [
        "SELECT #{text} FROM #{text}",
        "SELECT #{text}(v) FROM m",
        "SELECT mean(#{text}) FROM #{text} GROUP BY #{text}",
        "SELECT v FROM #{text}.#{text}",
        "SELECT v FROM m WHERE #{text} = '#{text}'",
        "SELECT v FROM m WHERE host = #{text}",
        "SELECT v FROM m WHERE time > #{text}",
        "SELECT v FROM m LIMIT #{text}",
        "SELECT v FROM m OFFSET #{text}",
        "SELECT v FROM m LIMIT #{text} OFFSET #{text}",
        "SELECT v FROM m SLIMIT #{text}",
        "SELECT v FROM m SOFFSET #{text}",
        "SELECT v FROM m SLIMIT #{text} SOFFSET #{text}",
        "SELECT v FROM m GROUP BY #{text}",
        "SELECT v FROM m GROUP BY time(#{text})",
        "SELECT v FROM m GROUP BY host fill(#{text})",
        "SELECT mean(v) FROM m GROUP BY time(1s) fill(#{text})",
        "SELECT v FROM m ORDER BY #{text}",
        "SELECT v FROM m ORDER BY time #{text}",
        "SELECT v AS #{text} FROM m",
        "SELECT v::#{text} FROM m",
        "SHOW TAG KEYS FROM #{text}",
        "SHOW FIELD KEYS FROM #{text}",
        "SHOW TAG VALUES FROM #{text} WITH KEY = #{text}",
        "SHOW #{text}"
      ]

      for statement <- statements do
        ask(&Local.query_influxql(conn, &1, database: "clauses_db"), statement)
        ask(&Local.query_influxql(conn, &1, database: text), statement)
      end

      assert_no_atom(text)
    end

    test "in a SQL statement", %{conn: conn} do
      text = unique_text()

      {:ok, :written} =
        Local.write(conn, "#{text},t=a #{text}=1.5 1000000000", database: "clauses_db")

      statements = [
        "SELECT #{text} FROM #{text}",
        "SELECT \"#{text}\" FROM \"#{text}\"",
        "SELECT #{text}(v) FROM m",
        "SELECT v AS #{text} FROM m",
        "SELECT v FROM m AS #{text}",
        "SELECT #{text}.v FROM m AS #{text}",
        "SELECT v FROM #{text}.m",
        "SELECT v FROM m WHERE #{text} = '#{text}'",
        "SELECT v FROM m WHERE host = #{text}",
        "SELECT v FROM m WHERE v IN (#{text}, 1)",
        "SELECT v FROM m GROUP BY #{text}",
        "SELECT v FROM m ORDER BY #{text}",
        "SELECT v FROM m LIMIT #{text}",
        "SELECT v FROM m LIMIT 1 OFFSET #{text}",
        "SELECT CAST(v AS #{text}) FROM m",
        "SELECT v::#{text} FROM m",
        "SELECT date_trunc('#{text}', time) FROM m",
        "SELECT v FROM m WHERE time > now() - interval '#{text}'",
        "WITH #{text} AS (SELECT v FROM m) SELECT * FROM #{text}",
        "INSERT INTO #{text} (#{text}) VALUES (#{text})",
        "INSERT INTO m (#{text}) VALUES (1)",
        "INSERT INTO m (v) SELECT #{text} FROM #{text}",
        "UPDATE #{text} SET #{text} = #{text} WHERE #{text} = #{text}",
        "UPDATE m SET #{text} = #{text}(v)",
        "DELETE FROM #{text} WHERE #{text} = #{text}",
        "DELETE FROM m WHERE #{text} = '#{text}'",
        "SHOW #{text}",
        "SELECT * FROM information_schema.#{text}"
      ]

      for statement <- statements do
        ask(&Local.query_sql(conn, &1, database: "clauses_db"), statement)
        ask(&Local.query_sql(conn, &1, database: text), statement)
      end

      assert_no_atom(text)
    end

    defp assert_no_atom(text) do
      for spelling <- [text, String.upcase(text)] do
        assert_raise ArgumentError, fn -> String.to_existing_atom(spelling) end
      end
    end
  end
end
