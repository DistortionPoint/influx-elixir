defmodule InfluxElixir.Client.Local.SQLTyped do
  @moduledoc false
  # The nodes of an expression whose type is already known, so that a check reaching a node
  # again takes its type instead of typing the whole tree under it once more.
  #
  # `SQLPlan` checks the parts of an expression innermost first: the operator of a long sum
  # is checked after the operators below it, and the parts of a nested `CASE`, `COALESCE` or
  # `||` likewise. Each is typed from the types of its own parts, which the checks of those
  # parts found, and so every node is typed once; typing a node from its whole tree is
  # quadratic in the length of a chain.
  #
  # The list is the latest first and only its first `@window` nodes are looked in: the parts
  # a node is typed from were checked just before it. A node not found is typed from its
  # parts, which is the same answer found slower. The answer for a node depends only on the
  # node and the columns' types, so a node is never wrong for being found by equality.

  @window 256

  @typedoc "Typed nodes and their types, the latest first."
  @type t :: [{term(), term()}]

  @doc "The type found for `node`, or `:error` when it was not typed lately."
  @spec recall(t(), term()) :: {:ok, term()} | :error
  def recall(typed, node), do: recall(typed, node, @window)

  @spec recall(t(), term(), non_neg_integer()) :: {:ok, term()} | :error
  defp recall([{node, type} | _rest], node, _budget), do: {:ok, type}
  defp recall([_other | rest], node, budget) when budget > 0, do: recall(rest, node, budget - 1)
  defp recall(_typed, _node, _budget), do: :error
end
