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
  #     `x AND true` and `x OR false` are `x`; `NULL AND NULL` and `NULL OR NULL` are `NULL`
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
  # That last rule, and the one of `BETWEEN`, are about the rows a filter reads: a row is never
  # run through a conjunct once another is NULL. They are not what the optimizer proves: it
  # replaces the plan with an empty relation only for a filter that is a constant false or NULL
  # as a whole, so `n = 1 AND NULL` is not empty to it and `n = NULL AND n = NULL` is. The
  # `strict` reading of a `WHERE` leaves those two rules out and adds the contradictory
  # equalities of `InfluxElixir.Client.Local.SQLContradict`; it is what decides whether the
  # physical plan is built for the select list (`InfluxElixir.Client.Local.SQLPrune`).
  #
  # In a select list an arithmetic operation with a NULL literal operand is
  # NULL without reading the other operand, when that reads a column.
  #
  # The result is the `WHERE` as a conjunction list again, or the list it was
  # when nothing is removed.

  alias InfluxElixir.Client.Local.{
    SQLContradict,
    SQLExpr,
    SQLFold,
    SQLParser,
    SQLPredicate,
    SQLWhere
  }

  @comparisons [:eq, :ne, :gt, :lt, :gte, :lte]

  @typep tree :: SQLWhere.tree() | :null
  @typep context :: %{
           required(:strict) => boolean(),
           required(:types) => %{binary() => binary()},
           optional(:negated) => boolean()
         }

  @plain %{strict: false, types: %{}}

  @doc """
  The query with the part of its `WHERE` and select list the engine's
  simplifier removes taken out.
  """
  @spec apply(SQLParser.parsed_query()) :: SQLParser.parsed_query()
  def apply(query), do: simplify_query(query, @plain)

  @doc """
  The same, read as the optimizer reads a filter (see the top of this module): `types` are the
  Arrow types of the columns of the equalities, to know which of them contradict.
  """
  @spec apply_strict(SQLParser.parsed_query(), %{binary() => binary()}) ::
          SQLParser.parsed_query()
  def apply_strict(query, types), do: simplify_query(query, strict(types))

  @spec simplify_query(SQLParser.parsed_query(), context()) :: SQLParser.parsed_query()
  defp simplify_query(query, context) do
    %{
      query
      | where: where(query, context),
        projection_columns: projection(query.projection_columns)
    }
  end

  @spec strict(%{binary() => binary()}) :: context()
  defp strict(types), do: %{strict: true, types: types}

  @doc "Whether the `WHERE` is false for every row once the simplifier has folded it."
  @spec never?(SQLParser.parsed_query()) :: boolean()
  def never?(query) do
    nodes = where(query, @plain)
    {:or, []} in nodes or {:eq, :null, nil} in nodes
  end

  @doc """
  Whether the engine's optimizer proves that the query answers no row, and replaces its plan
  with an empty relation: no physical plan is then built for its select list, so what the
  physical planner would refuse (a negation of an unsigned integer) is never met (verified
  against Core). It is a `LIMIT 0`; a `HAVING` that is false; and a `WHERE` that is, as a whole,
  false or `NULL` once the simplifier has folded it (a constant, an `AND` with a false, equalities
  of one expression to different values, or `IN` lists that share none, see
  `InfluxElixir.Client.Local.SQLContradict`), but not for an aggregate that is not grouped,
  which answers its one row whatever the `WHERE` leaves. `types` are the Arrow types of the
  columns the equalities read.
  """
  @spec empty?(SQLParser.parsed_query(), %{binary() => binary()}) :: boolean()
  def empty?(query, types \\ %{}) do
    query.limit == 0 or having_never?(query.having) or
      (filter_false?(query, types) and not one_group?(query))
  end

  @doc """
  Whether the query reads no row of what it selects from, so that the optimizer plans nothing
  below it: a `LIMIT 0`, a `HAVING` that is false, or a `WHERE` that is, as a whole, false or
  `NULL` (an aggregate that is not grouped still answers its one row, but of no row, so what it
  reads is not planned either).
  """
  @spec reads_nothing?(SQLParser.parsed_query(), %{binary() => binary()}) :: boolean()
  def reads_nothing?(query, types \\ %{}) do
    query.limit == 0 or having_never?(query.having) or filter_false?(query, types)
  end

  @spec having_never?(map() | nil) :: boolean()
  defp having_never?(%{nodes: nodes}), do: {:or, []} in nodes
  defp having_never?(_none), do: false

  # An aggregate with no `GROUP BY` answers one row of the aggregates of no row.
  @spec one_group?(SQLParser.parsed_query()) :: boolean()
  defp one_group?(query),
    do:
      query.select_columns != nil and (query.group_by_columns || []) == [] and
        is_nil(query.group_by_interval)

  # The strict `WHERE` is a constant false or NULL as a whole.
  @spec filter_false?(SQLParser.parsed_query(), %{binary() => binary()}) :: boolean()
  defp filter_false?(query, types) do
    context = strict(types)

    case bound(query) do
      {:ok, tree} ->
        nested_empty?(tree, types) or null_pair_empty?(tree, types) or
          simplified_false?(tree, context)

      :error ->
        {:or, []} in query.where or {:eq, :null, nil} in query.where
    end
  end

  @spec tree_leaves(SQLWhere.tree()) :: [SQLPredicate.clause()]
  defp tree_leaves({:leaf, clause}), do: [clause]

  defp tree_leaves({op, left, right}) when op in [:and, :or],
    do: tree_leaves(left) ++ tree_leaves(right)

  defp tree_leaves({:not, inner}), do: tree_leaves(inner)
  defp tree_leaves(_const), do: []

  @spec simplified_false?(SQLWhere.tree(), context()) :: boolean()
  defp simplified_false?(bound, context),
    do: bound |> simplify(context) |> finish(context) |> false_filter?()

  @spec false_filter?(tree()) :: boolean()
  defp false_filter?({:const, false}), do: true
  defp false_filter?(:null), do: true

  defp false_filter?({:leaf, {op, _operand, [nil | _more] = list}}) when op in [:in, :not_in],
    do: Enum.all?(list, &is_nil/1)

  defp false_filter?(_tree), do: false

  # `A AND (B AND R)` as the whole filter, with two `IN` lists of one operand that share no
  # value, each of two or more literals (an `IN` of one is an equality, which does not fold
  # this way), and nothing in `R` that tests that operand: the engine folds the two although
  # `B` is not the right side of the node (verified for every `R` that tests another column).
  # The same shape anywhere else, or lists that share values, is not known, see `nested_in?/1`.
  @spec nested_empty?(SQLWhere.tree(), %{binary() => binary()}) :: boolean()
  defp nested_empty?(
         {:and, {:leaf, {:in, operand, xs} = left},
          {:and, {:leaf, {:in, _other, ys} = right}, rest}},
         types
       )
       when is_list(xs) and is_list(ys) do
    match?([_, _ | _], Enum.uniq(xs)) and match?([_, _ | _], Enum.uniq(ys)) and
      SQLContradict.intersect(left, right, types) == :empty and
      not Enum.any?(tree_leaves(rest), &tests?(&1, operand))
  end

  defp nested_empty?(_tree, _types), do: false

  # Two `IN` lists, one with a `NULL`, as the whole filter.
  @spec null_pair_empty?(SQLWhere.tree(), %{binary() => binary()}) :: boolean()
  defp null_pair_empty?({:and, {:leaf, left}, {:leaf, right}}, types),
    do: SQLContradict.intersect_nulls(left, right, types) == :empty

  defp null_pair_empty?(_tree, _types), do: false

  @spec tests?(SQLPredicate.clause(), term()) :: boolean()
  defp tests?(clause, operand) when tuple_size(clause) == 3, do: elem(clause, 1) == operand
  defp tests?(_clause, _operand), do: false

  @doc """
  Whether the `WHERE` holds an `IN` list as the left side of an `AND` whose right side starts
  with another `IN` list of the same operand (`A AND (B AND R)`): the engine folds them in some
  places and not in others (the whole filter, or the first conjuncts of it, but not after
  another conjunct, or as the left of a larger `AND`), so what the double leaves of it is not
  known.
  """
  @spec nested_in?(SQLParser.parsed_query()) :: boolean()
  def nested_in?(query) do
    case bound(query) do
      {:ok, tree} -> nested_in_tree?(tree)
      :error -> false
    end
  end

  @spec nested_in_tree?(SQLWhere.tree()) :: boolean()
  defp nested_in_tree?({:and, {:leaf, {:in, operand, _list}}, {:and, _left, _right} = right}) do
    match?({:in, ^operand, _literals}, spine_leaf(right)) or nested_in_tree?(right)
  end

  defp nested_in_tree?({op, left, right}) when op in [:and, :or],
    do: nested_in_tree?(left) or nested_in_tree?(right)

  defp nested_in_tree?({:not, inner}), do: nested_in_tree?(inner)
  defp nested_in_tree?(_leaf), do: false

  # The first predicate of a conjunction, however deep on its left.
  @spec spine_leaf(SQLWhere.tree()) :: SQLPredicate.clause() | nil
  defp spine_leaf({:and, left, _right}), do: spine_leaf(left)
  defp spine_leaf({:leaf, clause}), do: clause
  defp spine_leaf(_other), do: nil

  @spec where(SQLParser.parsed_query(), context()) :: [SQLParser.where_node()]
  defp where(%{where: where} = query, context) do
    with {:ok, bound} <- bound(query),
         simplified when simplified != bound <- bound |> simplify(context) |> finish(context) do
      flatten(simplified)
    else
      _unchanged -> where
    end
  end

  # The `WHERE` as written, with the predicates the query now has.
  @spec bound(SQLParser.parsed_query()) :: {:ok, SQLWhere.tree()} | :error
  defp bound(%{where_tree: nil}), do: :error
  defp bound(%{where_tree: tree, where: where}), do: bind_leaves(tree, leaves(where))

  # What is left once the rules have run over the tree: the rows' reading of a NULL conjunct,
  # or the optimizer's reading of the equalities.
  @spec finish(tree(), context()) :: tree()
  defp finish(tree, %{strict: false}), do: top_level_null(tree)

  defp finish(tree, %{strict: true, types: types}) do
    clauses = for {:leaf, clause} <- conjuncts(tree), do: clause
    if SQLContradict.conflict?(clauses, types), do: {:const, false}, else: tree
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
  defp flatten(:null), do: [{:eq, :null, nil}]

  @spec branches(tree()) :: [tree()]
  defp branches({:or, left, right}), do: branches(left) ++ branches(right)
  defp branches(other), do: [other]

  # ---------------------------------------------------------------------------
  # The rules
  # ---------------------------------------------------------------------------

  @spec simplify(tree(), context()) :: tree()
  # An `IN (NULL)` beside an `IN` list folds with it (to nothing) before it is read as a NULL.
  defp simplify({:and, {:leaf, left_clause} = left, {:leaf, right_clause} = right}, context) do
    case SQLContradict.intersect(left_clause, right_clause, context.types) do
      :empty -> {:const, false}
      _no_fold -> conjoin(simplify(left, context), simplify(right, context), context)
    end
  end

  defp simplify({:and, left, right}, context),
    do: conjoin(simplify(left, context), simplify(right, context), context)

  defp simplify({:or, left, right}, context),
    do: disjoin(simplify(left, context), simplify(right, context))

  defp simplify({:not, inner}, context),
    do: negate(simplify(inner, Map.put(context, :negated, true)))

  defp simplify({:leaf, clause}, context), do: leaf(clause, context)
  defp simplify(other, _context), do: other

  @spec conjoin(tree(), tree(), context()) :: tree()
  defp conjoin({:const, false} = never, _right, _context), do: never
  defp conjoin(_left, {:const, false} = never, _context), do: never
  defp conjoin({:const, true}, right, _context), do: right
  defp conjoin(left, {:const, true}, _context), do: left
  defp conjoin(:null, :null, _context), do: :null

  # Two `IN` lists beside each other fold into the list of the values they share.
  defp conjoin({:leaf, left} = lhs, {:leaf, right} = rhs, context) do
    case SQLContradict.intersect(left, right, context.types) do
      :empty -> {:const, false}
      {:ok, shared} -> {:leaf, shared}
      :none -> absorb(lhs, rhs)
    end
  end

  defp conjoin(left, right, _context), do: absorb(left, right)

  @spec absorb(tree(), tree()) :: tree()
  defp absorb(left, right) do
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
  defp disjoin(:null, :null), do: :null

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

  # A predicate the engine reads as a constant before it reads its operands. A `BETWEEN` with
  # a NULL bound is NULL for the rows (its other operand is never read), but for the optimizer
  # only when both bounds are: `n BETWEEN 1 AND NULL` is `n >= 1 AND NULL`.
  @spec leaf(SQLPredicate.clause(), context()) :: tree()
  defp leaf({op, _left, nil}, _context) when op in @comparisons, do: :null
  defp leaf({op, {:expr, {:lit, nil}}, _right}, _context) when op in @comparisons, do: :null
  defp leaf({:truthy_expr, {:expr, {:lit, nil}}, _nil}, _context), do: :null

  # A list of nothing but `NULL` is a `NULL` to the rows; to the optimizer only when it is the
  # whole filter (`n IN (NULL) AND n > 0` is not empty, verified: see `simplified_false?/2`).
  defp leaf({op, left, [nil | _more] = list}, %{strict: false}) when op in [:in, :not_in] do
    if Enum.all?(list, &is_nil/1), do: :null, else: {:leaf, {op, left, list}}
  end

  defp leaf({:between, _operand, {nil, nil}}, %{strict: true}), do: :null

  defp leaf({:between, _operand, {low, high}} = clause, %{strict: true})
       when low == nil or high == nil,
       do: {:leaf, clause}

  # Under a `NOT` the bound that is `NULL` is not the NULL of the whole (`n BETWEEN 100 AND NULL`
  # is false for a row below 100, so its `NOT` holds, verified).
  defp leaf({:between, operand, {low, high}} = clause, %{strict: false} = context)
       when low == nil or high == nil do
    if constant_operand?(operand) or Map.get(context, :negated, false),
      do: {:leaf, clause},
      else: :null
  end

  defp leaf({:eq, {:expr, expr}, {:expr, expr}} = clause, _context),
    do: if(pure?(expr), do: {:const, true}, else: {:leaf, clause})

  defp leaf({:is_null, {:expr, expr}, _nil} = clause, _context),
    do: if(pure?(expr), do: {:const, null_constant?(expr)}, else: {:leaf, clause})

  defp leaf({:is_not_null, {:expr, expr}, _nil} = clause, _context),
    do: if(pure?(expr), do: {:const, not null_constant?(expr)}, else: {:leaf, clause})

  defp leaf(clause, _context), do: {:leaf, clause}

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
