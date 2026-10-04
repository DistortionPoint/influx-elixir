defmodule InfluxElixir.Client.Local.SQLStageTest do
  @moduledoc """
  The one table that orders the stages at which the engine finds a query's errors
  (`SQLStage`): every stage has one place, and a `HAVING` finds the errors of a kind
  after the `WHERE`'s of the same kind and before the stages that follow.
  """

  use ExUnit.Case, async: true

  alias InfluxElixir.Client.Local.SQLStage

  test "each stage stands once, and index/1 is its place in all/0" do
    stages = SQLStage.all()

    assert stages === Enum.uniq(stages)
    assert Enum.map(stages, &SQLStage.index/1) === Enum.to_list(0..(length(stages) - 1))
  end

  test "the engine builds the plan, then replaces placeholders, then coerces, then runs" do
    order = fn stage -> SQLStage.index(stage) end

    assert order.(:select_built) < order.(:group)
    assert order.(:group) < order.(:having_filter)
    assert order.(:having_filter) < order.(:placeholder)
    assert order.(:placeholder) < order.(:where_logical)
    assert order.(:having_coerced) < order.(:select_coerced)
    assert order.(:select_coerced) < order.(:negation)
    assert order.(:closed) < order.(:unmodelled)
  end

  test "a HAVING finds an error of a kind at the stage of its own, after the WHERE's" do
    for kind <- [:logical, :calls, :coerced] do
      where = String.to_existing_atom("where_#{kind}")
      having = String.to_existing_atom("having_#{kind}")

      assert SQLStage.having(where) === having
      assert SQLStage.index(where) < SQLStage.index(having)
    end

    assert SQLStage.having(:select_coerced) === :select_coerced
    assert SQLStage.having(:negation) === :negation
  end
end
