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
  # The memo is a map keyed by the node itself, so a node is found exactly (never by its
  # place in a list, and never missed for being far back): the type of a node depends only on
  # the node and the types of the columns it is typed against, so a memo belongs to one set of
  # column types and is never shared between two.

  @typedoc "Typed nodes and their types."
  @type t :: %{optional(term()) => term()}

  @doc "A memo with no node typed."
  @spec new() :: t()
  def new, do: %{}

  @doc "The type found for `node`, or `:error` when it was not typed."
  @spec recall(t(), term()) :: {:ok, term()} | :error
  def recall(memo, node), do: Map.fetch(memo, node)

  @doc "The memo with `node` typed as `type`."
  @spec put(t(), term(), term()) :: t()
  def put(memo, node, type), do: Map.put(memo, node, type)
end
