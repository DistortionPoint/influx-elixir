defmodule InfluxElixir.Contract.InfluxQLPlannerTest do
  # The contract writes the position of a parse error once, for the three-character
  # placeholders of the measurements; the engine counts the names of the run. A map
  # from one to the other that sent a wrong position to a right one would let a
  # wrong engine answer pass, so the map is pinned here.
  use ExUnit.Case, async: true

  alias InfluxElixir.Contract.InfluxQLPlanner

  @names %{"f1" => "run_0001_f1", "f2" => "run_0001_f2", "p" => "run_0001"}
  @statement "SELECT v FROM run_0001_f1, run_0001_f2 WHERE v >"

  defp positions(pos),
    do: InfluxQLPlanner.template_positions("error at pos #{pos}", @statement, @names)

  test "a position before every name is unchanged" do
    assert positions(0) === "error at pos 0"
    assert positions(14) === "error at pos 14"
  end

  test "the start of a name and the end of a name are the template's start and end" do
    start = byte_size("SELECT v FROM ")
    name = byte_size("run_0001_f1")

    assert positions(start) === "error at pos #{start}"
    assert positions(start + name) === "error at pos #{start + 3}"
  end

  test "a position after names is shifted by what each name is longer than its placeholder" do
    assert positions(byte_size("SELECT v FROM run_0001_f1, run_0001_f2 WHERE")) ===
             "error at pos #{byte_size("SELECT v FROM ~f1, ~f2 WHERE")}"
  end

  test "a position inside a name is no position of the template, and matches no case" do
    start = byte_size("SELECT v FROM ")

    for inside <- (start + 1)..(start + 10) do
      assert positions(inside) === "error at pos within ~f1 (#{inside})"
    end

    second = start + byte_size("run_0001_f1, ")
    assert positions(second + 4) === "error at pos within ~f2 (#{second + 4})"
  end

  test "a prefix shared by the names is not read inside the longer name" do
    assert InfluxQLPlanner.template_positions(
             "error at pos 22",
             "SELECT v FROM run_0001_f1 x",
             @names
           ) ===
             "error at pos within ~f1 (22)"
  end
end
