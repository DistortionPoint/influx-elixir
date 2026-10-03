defmodule InfluxElixir.Client.Local.SQLSimplify do
  @moduledoc false
  # What the engine's expression simplifier removes from a `WHERE` before any
  # row is read, so that what it removes is not evaluated (verified against
  # InfluxDB 3 Core). A constant that fails when it is folded fails the query
  # whatever surrounds it (`InfluxElixir.Client.Local.SQLFold`); these are the
  # ones that fail only when a row meets them, and are gone before one does.
  #
  # Over the `WHERE` as written, in binary `AND` and `OR` nodes taken left to
  # right (`InfluxElixir.Client.Local.SQLWhere.tree/1`):
  #
  #   * `x AND false` is false and `x OR true` is true, in either order, and
  #     `x AND true` and `x OR false` are `x`
  #   * absorption, purely on the syntax of two binary nodes: `A AND (A OR B)`
  #     and `A OR (A AND B)` are `A`, with `A` on either side of either node,
  #     and the pair standing anywhere in a larger `AND` or `OR`. A third
  #     conjunct beside them does not matter, but one that makes the node's
  #     own side something other than `A` does: the flat `X AND Y AND (K OR
  #     X)` is `(X AND Y) AND (K OR X)`, which absorbs nothing
  #   * a comparison or `IN` with a NULL literal operand is NULL and its other
  #     operand is never read; so is a `BETWEEN` with a NULL bound over an
  #     expression that reads a column
  #   * `x = x` is true, and `x IS NULL` false and `x IS NOT NULL` true, for an
  #     `x` that reads no column and calls no function
  #   * a NULL conjunct makes the whole filter false, whatever the other
  #     conjuncts that read a column would do (a constant that fails is
  #     folded first and fails the query, and the comparisons of `time` the
  #     scan takes its range from stay)
  #
  # In a select list an arithmetic operation with a NULL literal operand is
  # NULL without reading the other operand, when that reads a column.
  #
  # The result is the `WHERE` as a conjunction list again, or the list it was
  # when nothing is removed.

  alias InfluxElixir.Client.Local.{SQLExpr, SQLFold, SQLParser, SQLPredicate, SQLWhere}

  @comparisons [:eq, :ne, :gt, :lt, :gte, :lte]

  @typep tree :: SQLWhere.tree() | :null

  @doc """
  The query with the part of its `WHERE` and select list the engine's
  simplifier removes taken out.
  """
  @spec apply(SQLParser.parsed_query()) :: SQLParser.parsed_query()
  def apply(query) do
    %{query | where: where(query), projection_columns: projection(query.projection_columns)}
  end

  @spec where(SQLParser.parsed_query()) :: [SQLParser.where_node()]
  defp where(%{where_tree: nil, where: where}), do: where

  defp where(%{where_tree: tree, where: where}) do
    leaves = leaves(where)

    with {:ok, bound} <- bind_leaves(tree, leaves),
         simplified when simplified != bound <- bound |> simplify() |> top_level_null() do
      flatten(simplified)
    else
      _unchanged -> where
    end
  end

  # ---------------------------------------------------------------------------
  # The tree
  # ---------------------------------------------------------------------------

  # The predicates of a conjunction list, in the order they were written.
  @spec leaves([SQLParser.where_node()]) :: [SQLPredicate.clause()]
  defp leaves(nodes) do
    Enum.flat_map(nodes, fn
      {:or, branches} -> Enum.flat_map(branches, &leaves/1)
      {:not, conjunction} -> leaves(conjunction)
      clause -> [clause]
    end)
  end

  # The tree with the predicates the query now has (bound, typed): the
  # same ones in the same order, or no tree when they are not.
  @spec bind_leaves(SQLWhere.tree(), [SQLPredicate.clause()]) :: {:ok, SQLWhere.tree()} | :error
  defp bind_leaves(tree, leaves) do
    {bound, rest} = put_leaves(tree, leaves)
    if rest == [], do: {:ok, bound}, else: :error
  catch
    :mismatch -> :error
  end

  @spec put_leaves(SQLWhere.tree(), [SQLPredicate.clause()]) ::
          {SQLWhere.tree(), [SQLPredicate.clause()]}
  defp put_leaves({:leaf, _clause}, [leaf | rest]), do: {{:leaf, leaf}, rest}
  defp put_leaves({:leaf, _clause}, []), do: throw(:mismatch)
  defp put_leaves({:const, _value} = const, leaves), do: {const, leaves}

  defp put_leaves({:not, inner}, leaves) do
    {inner, rest} = put_leaves(inner, leaves)
    {{:not, inner}, rest}
  end

  defp put_leaves({op, left, right}, leaves) when op in [:and, :or] do
    {left, rest} = put_leaves(left, leaves)
    {right, rest} = put_leaves(right, rest)
    {{op, left, right}, rest}
  end

  @spec flatten(tree()) :: [SQLParser.where_node()]
  defp flatten({:and, left, right}), do: flatten(left) ++ flatten(right)
  defp flatten({:or, _left, _right} = node), do: [{:or, Enum.map(branches(node), &flatten/1)}]
  defp flatten({:not, inner}), do: [{:not, flatten(inner)}]
  defp flatten({:leaf, clause}), do: [clause]
  defp flatten({:const, true}), do: []
  defp flatten({:const, false}), do: [{:or, []}]
  defp flatten(:null), do: [{:eq, "time", nil}]

  @spec branches(tree()) :: [tree()]
  defp branches({:or, left, right}), do: branches(left) ++ branches(right)
  defp branches(other), do: [other]

  # ---------------------------------------------------------------------------
  # The rules
  # ---------------------------------------------------------------------------

  @spec simplify(tree()) :: tree()
  defp simplify({:and, left, right}), do: conjoin(simplify(left), simplify(right))
  defp simplify({:or, left, right}), do: disjoin(simplify(left), simplify(right))
  defp simplify({:not, inner}), do: negate(simplify(inner))
  defp simplify({:leaf, clause}), do: leaf(clause)
  defp simplify(other), do: other

  @spec conjoin(tree(), tree()) :: tree()
  defp conjoin({:const, false} = never, _right), do: never
  defp conjoin(_left, {:const, false} = never), do: never
  defp conjoin({:const, true}, right), do: right
  defp conjoin(left, {:const, true}), do: left

  defp conjoin(left, right) do
    cond do
      absorbs?(left, right, :or) -> left
      absorbs?(right, left, :or) -> right
      true -> {:and, left, right}
    end
  end

  @spec disjoin(tree(), tree()) :: tree()
  defp disjoin({:const, true} = always, _right), do: always
  defp disjoin(_left, {:const, true} = always), do: always
  defp disjoin({:const, false}, right), do: right
  defp disjoin(left, {:const, false}), do: left

  defp disjoin(left, right) do
    cond do
      absorbs?(left, right, :and) -> left
      absorbs?(right, left, :and) -> right
      true -> {:or, left, right}
    end
  end

  # `a` stands beside a node of the other operator that has `a` as a side:
  # `A AND (A OR B)`.
  @spec absorbs?(tree(), tree(), :and | :or) :: boolean()
  defp absorbs?(a, {op, left, right}, op), do: a == left or a == right
  defp absorbs?(_a, _other, _op), do: false

  @spec negate(tree()) :: tree()
  defp negate({:const, value}), do: {:const, not value}
  defp negate(:null), do: :null
  defp negate(inner), do: {:not, inner}

  # A predicate the engine reads as a constant before it reads its operands.
  @spec leaf(SQLPredicate.clause()) :: tree()
  defp leaf({op, _left, nil}) when op in @comparisons, do: :null
  defp leaf({:in, _left, [nil]}), do: :null
  defp leaf({:not_in, _left, [nil]}), do: :null

  defp leaf({:between, operand, {low, high}} = clause) when low == nil or high == nil,
    do: if(constant_operand?(operand), do: {:leaf, clause}, else: :null)

  defp leaf({:eq, {:expr, expr}, {:expr, expr}} = clause),
    do: if(pure?(expr), do: {:const, true}, else: {:leaf, clause})

  defp leaf({:is_null, {:expr, expr}, _nil} = clause),
    do: if(pure?(expr), do: {:const, null_constant?(expr)}, else: {:leaf, clause})

  defp leaf({:is_not_null, {:expr, expr}, _nil} = clause),
    do: if(pure?(expr), do: {:const, not null_constant?(expr)}, else: {:leaf, clause})

  defp leaf(clause), do: {:leaf, clause}

  # No column, no placeholder and no function: nothing the optimizer cannot
  # fold, and nothing a row changes.
  @spec pure?(SQLExpr.t()) :: boolean()
  defp pure?(expr), do: not SQLExpr.any?(expr, &impure?/1)

  @spec impure?(SQLExpr.t()) :: boolean()
  defp impure?({kind, _name}) when kind in [:field, :uint_col, :param], do: true
  defp impure?({:call, _function, _args}), do: true
  defp impure?(_other), do: false

  # Whether a pure expression is NULL (`NULL`, `1 + NULL`); one that cannot be
  # computed (`1 / 0`) is not.
  @spec null_constant?(SQLExpr.t()) :: boolean()
  defp null_constant?(expr), do: SQLFold.constant(expr) == {:ok, nil}

  @spec constant?(SQLExpr.t()) :: boolean()
  defp constant?(expr), do: SQLExpr.columns(expr) == []

  # A NULL conjunct makes the filter false: the conjuncts that read a column
  # are not run (a conjunct that reads none is folded, and its failure stays).
  @spec top_level_null(tree()) :: tree()
  defp top_level_null(tree) do
    conjuncts = conjuncts(tree)

    if :null in conjuncts do
      conjuncts
      |> Enum.filter(&survives_null?/1)
      |> Enum.reduce(:null, &{:and, &2, &1})
    else
      tree
    end
  end

  @spec conjuncts(tree()) :: [tree()]
  defp conjuncts({:and, left, right}), do: conjuncts(left) ++ conjuncts(right)
  defp conjuncts(other), do: [other]

  # What a NULL conjunct leaves of the others: a constant (folded, so it
  # fails whatever else is there), and a comparison of `time`, which the scan
  # still takes its range from.
  @spec survives_null?(tree()) :: boolean()
  defp survives_null?({:leaf, {_op, "time", _right}}), do: true

  defp survives_null?({:leaf, {_op, left, right}}),
    do: constant_operand?(left) and constant_operand?(right)

  defp survives_null?(_other), do: false

  @spec constant_operand?(term()) :: boolean()
  defp constant_operand?({:expr, expr}), do: constant?(expr)
  defp constant_operand?(operand) when is_binary(operand), do: false
  defp constant_operand?(list) when is_list(list), do: Enum.all?(list, &constant_operand?/1)
  defp constant_operand?({low, high}), do: constant_operand?(low) and constant_operand?(high)
  defp constant_operand?(_literal), do: true

  # ---------------------------------------------------------------------------
  # The select list
  # ---------------------------------------------------------------------------

  @spec projection([SQLParser.projection()] | nil) :: [SQLParser.projection()] | nil
  defp projection(nil), do: nil

  defp projection(columns) do
    Enum.map(columns, fn
      {source, output} when is_binary(source) -> {source, output}
      {expr, output} -> {null_operation(expr), output}
    end)
  end

  # An operation with a NULL literal operand is NULL, though the other
  # operand reads a column and fails.
  @spec null_operation(SQLExpr.t()) :: SQLExpr.t()
  defp null_operation(expr) do
    expr
    |> SQLExpr.map_children(&null_operation/1)
    |> case do
      {:op, _op, {:lit, nil}, other} = operation -> nullify(operation, other)
      {:op, _op, other, {:lit, nil}} = operation -> nullify(operation, other)
      other -> other
    end
  end

  @spec nullify(SQLExpr.t(), SQLExpr.t()) :: SQLExpr.t()
  defp nullify(operation, other),
    do: if(constant?(other), do: operation, else: {:lit, nil})
end
