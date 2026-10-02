defmodule InfluxElixir.Client.Local.SQLPredicates do
  @moduledoc """
  Flattens a parsed `WHERE` into its conjuncts, pushing a `NOT` in as the
  engine's optimizer does, for the modules that reason about what a filter
  leaves (`InfluxElixir.Client.Local.SQLBounds` for a numeric column,
  `InfluxElixir.Client.Local.SQLRange` for `time`).

  The structure is the same for both and the leaves differ, so the caller
  gives `flatten/3` what to put for each kind of leaf:

    * `:never` — a constant false (`{:or, []}`, or the negation of an empty
      conjunction)
    * `:opaque` — a function from what hides its conjuncts (an `OR`, the
      negation of several conjuncts) to the leaf for it
    * `:clause` — a function from a predicate and whether a `NOT` is pushed
      into it to the leaves it contributes
  """

  alias InfluxElixir.Client.Local.SQLParser

  @typedoc "What a caller makes of each kind of leaf."
  @type leaves :: %{
          never: term(),
          opaque: (term() -> term()),
          clause: (SQLParser.where_clause(), boolean() -> [term()])
        }

  @negations %{
    gt: :lte,
    gte: :lt,
    lt: :gte,
    lte: :gt,
    eq: :ne,
    ne: :eq,
    between: :not_between,
    not_between: :between,
    in: :not_in,
    not_in: :in,
    is_null: :is_not_null,
    is_not_null: :is_null,
    like: :not_like,
    not_like: :like,
    regex: :not_regex,
    not_regex: :regex
  }

  @doc """
  The operator that holds when the predicate is negated, or the operator
  itself when it has no negation here.
  """
  @spec negate_op(atom()) :: atom()
  def negate_op(op), do: Map.get(@negations, op, op)

  @doc "Whether the operator has a negation."
  @spec negatable?(atom()) :: boolean()
  def negatable?(op), do: is_map_key(@negations, op)

  @doc """
  The leaves of a conjunction. `negated` says that a `NOT` has been pushed in
  front of it.
  """
  @spec flatten([SQLParser.where_node()], boolean(), leaves()) :: [term()]
  def flatten(nodes, false, leaves), do: Enum.flat_map(nodes, &node(&1, false, leaves))
  def flatten([], true, %{never: never}), do: [never]
  def flatten([node], true, leaves), do: node(node, true, leaves)
  def flatten(nodes, true, %{opaque: opaque}), do: [opaque.(nodes)]

  @spec node(SQLParser.where_node(), boolean(), leaves()) :: [term()]
  defp node({:or, []}, false, %{never: never}), do: [never]
  defp node({:or, []}, true, _leaves), do: []
  defp node({:or, _branches} = node, false, %{opaque: opaque}), do: [opaque.(node)]

  defp node({:or, branches}, true, leaves),
    do: Enum.flat_map(branches, &flatten(&1, true, leaves))

  defp node({:not, nodes}, negated, leaves), do: flatten(nodes, not negated, leaves)
  defp node(clause, negated, %{clause: clause_leaves}), do: clause_leaves.(clause, negated)
end
