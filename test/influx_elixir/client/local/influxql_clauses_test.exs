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

  test "no atom is made from the text of a statement" do
    # The first statement in a fresh VM met an atom that did not exist yet, and raised; a
    # test cannot make a VM fresh, so the source is read for the calls that make atoms.
    offenders =
      for file <- Path.wildcard("lib/influx_elixir/client/local/influxql/*.ex"),
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          String.match?(
            line,
            ~r/\b(?:to_atom|to_existing_atom|binary_to_atom|binary_to_existing_atom)\b/
          ),
          do: "#{file}:#{number}"

    assert offenders === []
  end
end
