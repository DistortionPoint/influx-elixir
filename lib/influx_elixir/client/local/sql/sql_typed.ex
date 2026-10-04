defmodule InfluxElixir.Client.Local.SQLTyped do
  @moduledoc false
  # The nodes of an expression whose type is already known, so that a check reaching a node
  # again takes its type instead of typing the whole tree under it once more.
  #
  # `SQLPlan` checks the parts of an expression innermost first: the operator of a long sum
  # is checked after the operators below it, and the parts of a nested `CASE`, `COALESCE` or
  # `||` likewise. Each is typed from the types of its own parts, which the checks of those
  # parts have just found, so a part is looked for among the few nodes typed last. Those are
  # kept in a short list and compared whole (`==`, which is a pointer comparison for the very
  # node that was typed, and stops at the first difference for any other): a map keyed by the
  # node would hash the whole tree under it at every look, which for a chain of a thousand
  # operators is a million nodes hashed.
  #
  # The list only saves work: a node that is not found is typed from its parts again, and so
  # the answer of a look never depends on what is in it. The type of a node depends only on
  # the node and the types of the columns it is typed against, so a memo belongs to one set of
  # column types and is never shared between two.

  # The nodes kept: the parts of one node are typed together, a few (a call's arguments, the
  # results of a `CASE`) before it is, and that is as far back as a part is looked for.
  @kept 6

  @typedoc "The nodes last typed, with their types, the last first."
  @type t :: [{term(), term()}]

  @doc "A memo with no node typed."
  @spec new() :: t()
  def new, do: []

  @doc "The type found for `node`, or `:error` when it is not among those typed last."
  @spec recall(t(), term()) :: {:ok, term()} | :error
  def recall([], _node), do: :error

  def recall([{typed, type} | rest], node) do
    if typed == node, do: {:ok, type}, else: recall(rest, node)
  end

  @doc "The memo with `node` typed as `type`, the oldest of the nodes kept forgotten."
  @spec put(t(), term(), term()) :: t()
  def put(memo, node, type), do: [{node, type} | Enum.take(memo, @kept - 1)]
end
