defmodule InfluxElixir.Client.Local.SQLPlanItems do
  @moduledoc false
  # The parts of a term the planner types, for `InfluxElixir.Client.Local.SQLPlan`: what it
  # checks, in the order the engine meets it (verified against InfluxDB 3 Core).

  alias InfluxElixir.Client.Local.{SQLAggExpr, SQLExpr, SQLParser}

  @doc """
  The items of a `WHERE` or an `ORDER BY`, the parts under the operand of a `||` marked
  `{:planned, item}`. The planner builds a `||` by the types of its operands (it chooses
  between the concatenation of text and of lists by them), so every operator and call under
  one is typed as the plan is built, and its error is the planner's, not the type
  coercion's: unwrapped, and found before the type coercion finds anything, a `WHERE`'s
  before the select list's and an `ORDER BY`'s after (verified: `WHERE 'a' || (n + 's') = 'x'`
  is the arithmetic error without the `type_coercion` prefix, and before the error of
  `abs(s)` in the select list).
  """
  @spec planned_items(term()) :: [term()]
  def planned_items(term), do: term |> annotate([]) |> plan_items({false, false, false}) |> flat()

  @comparisons [:eq, :ne, :gt, :lt, :gte, :lte]

  # The expression of an operand of a `WHERE`: a column is a field.
  @spec operand_expr(SQLParser.operand()) :: SQLExpr.t()
  defp operand_expr({:expr, expr}), do: expr
  defp operand_expr(column), do: {:field, column}

  # Every part of a term the planner types, the innermost first. The engine
  # types a part in one of two passes (verified, over every pairing of a
  # call, a CAST, a function, an arithmetic operator and a negation under a
  # comparison, an IS [NOT] NULL, a BETWEEN, an IN list, a LIKE and a NOT):
  # the plain one, and a later one for the parts that are `cut`, which
  # words a failing call by its first sentence, without the tail naming its
  # signatures. A part is cut when it stands
  #
  #   * under an IS [NOT] NULL, a BETWEEN, an IN list, a LIKE or a NOT, or
  #   * under a CAST that no function call stands above (`CAST(abs(s) AS INT)
  #     > 1`, but not `abs(CAST(abs(s) AS INT)) > 1`).
  #
  # The state is `{function_above?, cut?, planned?}`: `planned?` says the part stands under the
  # operand of a `||`, which the planner types as it builds it (`false` where it does not,
  # `:never` where the parts under a `||` are not told from the others, see `planned_items/2`).
  @typep state :: {boolean(), boolean(), boolean() | :never}

  # The parts of a term the planner types (see `plan_items/2`), the calls with no
  # argument among them with what stands above each.
  @spec items(term()) :: [term()]
  def items(term), do: term |> annotate([]) |> plan_items({false, false, :never}) |> flat()

  # Each call with no argument as `{:constant, call, ancestors}`, the ancestors
  # nearest first (see `InfluxElixir.Client.Local.SQLConstantCall`).
  @spec annotate(term(), [atom()]) :: term()
  defp annotate({:call, name, []} = call, ancestors) when is_atom(name),
    do: {:constant, call, ancestors}

  # The parts of these the planner types only later, when it coerces them.
  defp annotate({:in, left, items, negated}, ancestors) when is_list(items) do
    {:in, annotate(left, [:other | ancestors]), annotate(items, slot(left, [:other | ancestors])),
     negated}
  end

  defp annotate({:is_bool, inner, value, negated}, ancestors),
    do: {:is_bool, annotate(inner, [:deferred, :other | ancestors]), value, negated}

  defp annotate({:between, inner, low, high, negated}, ancestors) do
    bounds = slot(inner, [:other | ancestors])

    {:between, annotate(inner, [:other | ancestors]), annotate(low, bounds),
     annotate(high, bounds), negated}
  end

  defp annotate({:like, inner, pattern, negated, ilike, regex}, ancestors) do
    {:like, annotate(inner, [:other | ancestors]),
     annotate(pattern, slot(inner, [:other | ancestors])), negated, ilike, regex}
  end

  defp annotate({:case, operand, whens, otherwise}, ancestors) do
    deferred = [:deferred, :other | ancestors]
    plain = [:other | ancestors]

    {:case, annotate(operand, deferred),
     Enum.map(whens, fn {condition, result} ->
       {annotate(condition, if(operand, do: deferred, else: [:when | deferred])),
        annotate(result, plain)}
     end), annotate(otherwise, plain)}
  end

  defp annotate({:expr, _expr} = operand, ancestors),
    do: operand |> Tuple.to_list() |> Enum.map(&annotate(&1, ancestors)) |> List.to_tuple()

  defp annotate(term, ancestors) when is_tuple(term) and tuple_size(term) > 0 do
    inner = if is_atom(elem(term, 0)), do: [ancestor(elem(term, 0)) | ancestors], else: ancestors
    term |> Tuple.to_list() |> Enum.map(&annotate(&1, inner)) |> List.to_tuple()
  end

  defp annotate(terms, ancestors) when is_list(terms),
    do: Enum.map(terms, &annotate(&1, ancestors))

  defp annotate(other, _ancestors), do: other

  # The ancestors of a list item, a bound or a pattern: the engine types them only when
  # it coerces the expression, unless the operand beside them is a constant, which it
  # folds at once.
  @spec slot(SQLExpr.t(), [atom()]) :: [atom()]
  defp slot(operand, ancestors),
    do: if(constant_operand?(operand), do: ancestors, else: [:deferred | ancestors])

  @spec constant_operand?(SQLExpr.t()) :: boolean()
  defp constant_operand?({:is_null, _inner, _negated}), do: true
  defp constant_operand?(operand), do: SQLExpr.columns(operand) == []

  @spec ancestor(atom()) :: :cast | :neg | :isnull | :other
  defp ancestor(:cast), do: :cast
  defp ancestor(:neg), do: :neg
  defp ancestor(tag) when tag in [:is_null, :is_not_null], do: :isnull
  defp ancestor(_tag), do: :other

  # The items come as nested lists (a part's, then another's, then its own): joining the lists
  # of the parts would copy the items of everything under an operator once for each operator
  # above it, which is quadratic in the length of a chain; `flat/1` makes the one list.
  @spec plan_items(term(), state()) :: [term()]
  defp plan_items(term, state)

  defp plan_items({:constant, _call, _ancestors} = constant, _state), do: [constant]

  defp plan_items({:call, name, args} = call, state) when name in [:coalesce, :nullif],
    do: [plan_items(args, state), mark({:expr_check, call}, state)]

  defp plan_items({:cmp, _op, left, right} = node, state),
    do: [plan_items(left, state), plan_items(right, state), mark({:expr_check, node}, state)]

  # The operands of a `||` are typed as the plan is built.
  defp plan_items({:concat, left, right} = node, state) do
    operands = planned(state)

    [plan_items(left, operands), plan_items(right, operands), mark({:expr_check, node}, state)]
  end

  defp plan_items({kind, left, right} = node, state) when kind in [:and, :or],
    do: [plan_items(left, state), plan_items(right, state), mark({:expr_check, node}, state)]

  defp plan_items({:not, inner} = node, state) when not is_list(inner),
    do: [lazy(inner, state), mark({:expr_check, node}, state)]

  defp plan_items({:is_bool, inner, _value, _negated} = node, state),
    do: [deferred(inner, unplanned(state)), mark({:expr_check, node}, state)]

  defp plan_items({:is_distinct, left, right, _negated} = node, state),
    do: [plan_items(left, state), plan_items(right, state), mark({:expr_check, node}, state)]

  defp plan_items(term, state), do: plan_predicate_items(term, state)

  @spec plan_predicate_items(term(), state()) :: [term()]
  defp plan_predicate_items({:in, left, items, _negated} = node, state)
       when is_list(items) and not is_nil(left),
       do: [
         lazy(left, state),
         slot_items(left, items, state),
         mark({:expr_check, node}, state)
       ]

  defp plan_predicate_items({:between, inner, low, high, _negated} = node, state),
    do: [
      lazy(inner, state),
      slot_items(inner, [low, high], state),
      mark({:expr_check, node}, state)
    ]

  defp plan_predicate_items({:like, inner, pattern, _negated, _ilike, _regex} = node, state),
    do: [
      lazy(inner, state),
      slot_items(inner, pattern, state),
      mark({:expr_check, node}, state)
    ]

  # The planner types a `CASE` by its first result: the conditions and the later results are
  # left to the type coercion.
  defp plan_predicate_items({:case, operand, whens, otherwise} = node, state) do
    conditions = List.wrap(operand) ++ Enum.map(whens, &elem(&1, 0))
    [first | later] = Enum.map(whens, &elem(&1, 1))

    [
      deferred(conditions, unplanned(state)),
      plan_items(first, state),
      case_lazy(later ++ List.wrap(otherwise), unplanned(state)),
      mark({:expr_check, node}, state)
    ]
  end

  defp plan_predicate_items(
         {:call, _function, args} = call,
         {_function_above, cut, planned} = state
       ),
       do: [plan_items(args, {true, cut, planned}), mark(call, state)]

  defp plan_predicate_items({:cast, inner, _type} = node, {function_above, cut, planned} = state),
    do: [
      plan_items(inner, {function_above, cut or not function_above, planned}),
      mark({:expr_check, node}, state)
    ]

  defp plan_predicate_items({:op, _op, left, right} = op, state),
    do: [plan_items(left, state), plan_items(right, state), mark(op, state)]

  defp plan_predicate_items({:neg, inner} = neg, state), do: [plan_items(inner, state), neg]
  defp plan_predicate_items({:pos, inner} = pos, state), do: [plan_items(inner, state), pos]

  defp plan_predicate_items({:field, name}, _state) when is_binary(name),
    do: if(SQLAggExpr.placeholder?(name), do: [{:agg_ref, name}], else: [])

  defp plan_predicate_items(term, state), do: plan_condition_items(term, state)

  @spec plan_condition_items(term(), state()) :: [term()]
  defp plan_condition_items({kind, left, rest}, state)
       when kind in [:like, :not_like, :regex, :not_regex] do
    operand = operand_expr(left)
    [plan_items(operand, cut_state(state)), {:pattern, kind, operand, rest}]
  end

  defp plan_condition_items({:eq, :null, nil}, _state), do: []

  defp plan_condition_items({op, left, right}, state) when op in @comparisons and left != "time",
    do: [
      plan_items(left, state),
      plan_items(right, state),
      mark({:compare, op, operand_expr(left), right}, state)
    ]

  defp plan_condition_items({op, left, values}, state)
       when op in [:in, :not_in] and left != "time",
       do: [
         plan_items(left, cut_state(state)),
         plan_items(values, cut_state(state)),
         {:in_list, operand_expr(left), values}
       ]

  defp plan_condition_items({op, left, {low, high}}, state)
       when op in [:between, :not_between] and left != "time",
       do: [
         plan_items(left, cut_state(state)),
         plan_items([low, high], cut_state(state)),
         {:range, operand_expr(left), low, high}
       ]

  # What an `IS [NOT] NULL` tests is not among the parts the planner types for a `||`.
  defp plan_condition_items({op, left, _nil}, state) when op in [:is_null, :is_not_null],
    do:
      left |> plan_items(state |> cut_state() |> unplanned()) |> flat() |> Enum.map(&null_mark/1)

  defp plan_condition_items({:not, nodes}, state), do: plan_items(nodes, cut_state(state))

  defp plan_condition_items({:time_type_error, "time", error}, _state), do: [{:time_type, error}]

  defp plan_condition_items(terms, state) when is_list(terms),
    do: Enum.map(terms, &plan_items(&1, state))

  defp plan_condition_items(term, state) when is_tuple(term),
    do: term |> Tuple.to_list() |> plan_items(state)

  defp plan_condition_items(_other, _state), do: []

  @spec flat([term()]) :: [term()]
  defp flat(items), do: List.flatten(items)

  # The parts the planner types only when it coerces the expression are cut like
  # what stands under an `IS [NOT] NULL`.
  @spec deferred(term(), state()) :: [term()]
  defp deferred(parts, state),
    do: parts |> plan_items(cut_state(state)) |> flat() |> Enum.map(&null_mark/1)

  # The list items, bounds and pattern of an operand: deferred, but a call beside a
  # constant operand is typed at once.
  @spec slot_items(SQLExpr.t(), term(), state()) :: [term()]
  defp slot_items(operand, parts, state) do
    if constant_operand?(operand), do: lazy(parts, state), else: deferred(parts, state)
  end

  # The parts the planner types only when it coerces the expression, which it does
  # for an operator (not for a call) in the select list: they are cut like what
  # stands under an `IS [NOT] NULL`.
  @spec lazy(term(), state()) :: [term()]
  defp lazy(parts, state) do
    # The arguments of a call are typed as the call is, wherever it stands.
    typed = call_arguments(parts, %{})

    parts
    |> plan_items(cut_state(state))
    |> flat()
    |> Enum.map(fn item ->
      if is_map_key(typed, item_node(item)), do: item, else: lazy_mark(item)
    end)
  end

  @spec cut_state(state()) :: state()
  defp cut_state({function_above, _cut, planned}), do: {function_above, true, planned}

  # The state of what stands under the operand of a `||`, and of what does not.
  @spec planned(state()) :: state()
  defp planned({function_above, cut, false}), do: {function_above, cut, true}
  defp planned(state), do: state

  @spec unplanned(state()) :: state()
  defp unplanned({function_above, cut, true}), do: {function_above, cut, false}
  defp unplanned(state), do: state

  # Every part of the arguments of the calls among the parts.
  @spec call_arguments(term(), %{term() => true}) :: %{term() => true}
  defp call_arguments({:call, _name, args} = call, nodes),
    do: call |> Tuple.to_list() |> Enum.reduce(subtree(args, nodes), &call_arguments/2)

  defp call_arguments(tuple, nodes) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(nodes, &call_arguments/2)

  defp call_arguments(terms, nodes) when is_list(terms),
    do: Enum.reduce(terms, nodes, &call_arguments/2)

  defp call_arguments(_leaf, nodes), do: nodes

  # The later results of a `CASE`: the planner types only the first, so a call among the
  # others is met when the expression is coerced, like an operator (verified: with a bad
  # `BETWEEN` as the first result, the error is the `BETWEEN`'s, not the later call's).
  @spec case_lazy(term(), state()) :: [term()]
  defp case_lazy(parts, state) do
    parts
    |> lazy(state)
    |> Enum.map(fn
      {:cut, {:call, _name, _args} = call} -> {:case_cut, call}
      item -> item
    end)
  end

  @spec lazy_mark(term()) :: term()
  defp lazy_mark({:cut, {:op, _op, _left, _right}} = item), do: lazy_cut(item)
  defp lazy_mark({:cut, {:expr_check, {:call, _name, _args}}} = item), do: item
  defp lazy_mark({:cut, {:expr_check, _node}} = item), do: lazy_cut(item)
  defp lazy_mark(item), do: item

  @spec lazy_cut({:cut, term()}) :: {:lazy_cut, term()}
  defp lazy_cut({:cut, item}), do: {:lazy_cut, item}

  # What stands under an IS [NOT] NULL is cut by it, which the select list tells
  # from a cut by anything else.
  @spec null_mark(term()) :: term()
  defp null_mark({:cut, item}), do: {:null_cut, item}
  defp null_mark(item), do: item

  # An item the cuts over it and the `||` under which it stands (see `planned_items/2`) mark.
  @spec mark(term(), state()) :: term()
  defp mark(item, {_function_above, cut, planned}) do
    item |> cut_item(cut) |> planned_item(planned)
  end

  @spec cut_item(term(), boolean()) :: term()
  defp cut_item(item, true), do: {:cut, item}
  defp cut_item(item, false), do: item

  # The operators and calls the planner types, under the operand of a `||`.
  @spec planned_item(term(), boolean() | :never) :: term()
  defp planned_item(item, true) do
    if item_node(item) != nil and planner_typed?(unwrap(item)),
      do: {:planned, item},
      else: item
  end

  defp planned_item(item, _not_planned), do: item

  # An item without the cuts over it.
  @spec unwrap(term()) :: term()
  defp unwrap({wrapper, item}) when wrapper in [:cut, :lazy_cut, :null_cut, :case_cut],
    do: unwrap(item)

  defp unwrap(item), do: item

  @spec item_node(term()) :: term()
  defp item_node({wrapper, item}) when wrapper in [:cut, :lazy_cut, :null_cut, :case_cut],
    do: item_node(item)

  defp item_node({:expr_check, node}), do: node
  defp item_node({:op, _op, _left, _right} = node), do: node
  defp item_node({:call, _name, _args} = node), do: node
  defp item_node(_item), do: nil

  # Every part of a term, the term itself among them.
  @spec subtree(term(), %{term() => true}) :: %{term() => true}
  defp subtree(tuple, nodes) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(Map.put(nodes, tuple, true), &subtree/2)

  defp subtree(terms, nodes) when is_list(terms), do: Enum.reduce(terms, nodes, &subtree/2)
  defp subtree(_leaf, nodes), do: nodes

  # The parts of an expression the planner types as it builds the plan, whose errors keep it
  # from typing the expression: the operators and the calls of functions. The rest (a `LIKE`,
  # an `IN` list, a `CASE`, a `NOT`) is typed by the type coercion.
  @spec planner_typed?(term()) :: boolean()
  def planner_typed?({wrapper, item}) when wrapper in [:cut, :planned],
    do: planner_typed?(item)

  # What the planner leaves to the type coercion (the conditions of a `CASE`, its later
  # results, what stands under an `IS NULL` or an operator that types its operands late).
  def planner_typed?({wrapper, _item}) when wrapper in [:lazy_cut, :null_cut, :case_cut],
    do: false

  def planner_typed?({kind, _first}) when kind in [:neg, :pos], do: false
  def planner_typed?({:op, _op, _left, _right}), do: true
  def planner_typed?({:call, _name, _args}), do: true
  def planner_typed?({:compare, _op, _left, _right}), do: true

  def planner_typed?({:expr_check, {kind, _left, _right}})
      when kind in [:cmp, :and, :or, :concat],
      do: true

  def planner_typed?({:expr_check, {:cmp, _op, _left, _right}}), do: true
  def planner_typed?({:expr_check, {:is_distinct, _left, _right, _negated}}), do: true
  def planner_typed?({:expr_check, {:call, name, _args}}), do: name in [:coalesce, :nullif]
  def planner_typed?(_item), do: false
end
