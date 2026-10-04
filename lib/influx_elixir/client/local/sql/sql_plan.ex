defmodule InfluxElixir.Client.Local.SQLPlan do
  @moduledoc false
  # The type errors the engine finds when it plans a SQL query, for
  # `InfluxElixir.Client.Local`, whether or not any row would reach the
  # expression (verified against InfluxDB 3 Core).
  #
  # The Arrow type of a column is read from the first point that has it (a
  # tag is dictionary encoded, a field typed by its value, `time` a timestamp;
  # an integer column the store registered as unsigned is a `UInt64`). An
  # unknown type is never refused. A decimal (the result of an `Int64` with a
  # `UInt64`) has a precision the double does not track, so an error that
  # would print its type is refused by name.

  alias InfluxElixir.Client.Local.{
    SQLAggExpr,
    SQLAggType,
    SQLClauses,
    SQLCommonType,
    SQLConstantCall,
    SQLDecimal,
    SQLError,
    SQLExpr,
    SQLExprCheck,
    SQLExprType,
    SQLFunctions,
    SQLGrouping,
    SQLNativeType,
    SQLNullType,
    SQLParser,
    SQLPredicate,
    SQLSchema,
    SQLSelect,
    SQLSimplify,
    SQLStage,
    SQLTyped,
    SQLWhere
  }

  import SQLExprType, only: [is_decimal_type: 1, is_numeric_type: 1]

  @typedoc "What a check fails with: the engine's error, or its closing of the connection."
  @type failure :: map() | {:connection_error, Mint.TransportError.t()}

  @typedoc "A stored point, as `InfluxElixir.Client.Local` keeps it."
  @type point :: InfluxElixir.Client.Local.SQLRow.point()

  @decimal "Decimal128(?)"

  # A struct given to a function of text is converted by the type coercion, after the
  # planner has found everything else wrong with the query (verified against Core).
  @conversion "type_coercion\ncaused by\nError during planning: Cannot automatically convert"
  @tag "Dictionary(Int32, Utf8)"

  # What `AND` and `OR` accept: a boolean, or the null literal (typed `Null`).
  @logical ["Boolean", "Null"]

  # The engine checks an expression's types when it plans the query, so a
  # wrong one fails it even when no row would reach it: a function's
  # arguments, an arithmetic operator's operands, a comparison's operands, a
  # negation, an aggregate's argument, the operand of a LIKE or a regex. The
  # first problem it meets is the one it reports (verified, each pair of
  # kinds in each pair of clauses). Every item of a check has a stage, the place in the
  # engine's work it is found at (`rank/2`), and `InfluxElixir.Client.Local.SQLStage` is the
  # one table that orders the stages and says what each is. Within a stage the
  # innermost part of a term comes first, and the terms are in the order they are written.
  @typedoc """
  What the executor lends the check: `:group` is a function giving the engine's error for a
  column that is not grouped, `:placeholder` the engine's error for a `$n` with no value.
  Both are errors of the plan the engine finds at their own stages, not before.
  """
  @type plan_options :: [
          group: (-> :ok | {:error, term()}),
          placeholder: nil | failure()
        ]

  @doc """
  The engine's first planning error in the query's expressions, or `:ok`.
  `unsigned?` says which columns are `UInt64`.
  """
  @spec check([point()], SQLParser.parsed_query(), (binary() -> boolean()), plan_options()) ::
          :ok | {:error, failure()}
  def check(points, query, unsigned?, options \\ []) do
    duration? = SQLNullType.duration_misuse?(query)

    case check_types(points, query, unsigned?, duration?, options) do
      :ok when duration? -> {:error, duration_refusal()}
      outcome -> outcome
    end
  end

  @spec duration_refusal() :: map()
  defp duration_refusal do
    SQLError.refusal(
      "a difference of a null and time used in an operation: the engine types it as a " <>
        "Duration(ns), and its error for each use is not modelled"
    )
  end

  @spec check_types(
          [point()],
          SQLParser.parsed_query(),
          (binary() -> boolean()),
          boolean(),
          plan_options()
        ) :: :ok | {:error, failure()}
  defp check_types(points, query, unsigned?, duration?, options) do
    checks =
      (Enum.map(select_items(query), &{:select, &1}) ++
         Enum.map(planned_items(query.where, :where), &{:where, &1}) ++
         logical_items(query.where_tree) ++
         having_items(query) ++
         plan_gates(query, options) ++
         Enum.map(planned_items(ordered_terms(query), :order_by), &{:order_by, &1}))
      |> Enum.map(fn {context, item} ->
        {SQLStage.index(rank(context, item)), check_context(context), item}
      end)
      |> Enum.sort_by(&elem(&1, 0))

    filter = filter_target(query)

    if checks == [] and is_nil(filter) do
      :ok
    else
      aliases = having_aliases(query)
      wanted = plan_columns(checks) ++ alias_fields(aliases, query) ++ filter_fields(filter)
      types = column_types(points, wanted, unsigned?)
      alias_types = SQLAggType.output_types(query.select_columns || [], aliases, types)
      columns = Map.merge(alias_types, types)
      checks = Enum.map(checks, &with_columns(&1, types))

      with :ok <- filter_error(filter, query, columns),
           do: check_items(checks, columns, %{duration?: duration?, pruned?: pruned(query)})
    end
  end

  # The items the engine never meets, whose errors are dropped: the negation of a type it does
  # not support is found only when the physical plan is built, and the optimizer has by then
  # replaced the plan of a query that answers no row with an empty relation, and removed from
  # the `WHERE` what its simplifier proves is not needed (`-u > 1 OR true`, verified against
  # Core).
  @spec pruned(SQLParser.parsed_query()) :: (term(), plan_context() -> boolean())
  defp pruned(query) do
    if SQLSimplify.empty?(query) do
      fn item, _context -> negation?(item) end
    else
      removed = removed_negations(query)
      fn item, _context -> negation?(item) and item in removed end
    end
  end

  # The negations of the `WHERE` that its simplified form no longer holds; the simplifier is
  # run only if there is a negation in the `WHERE` to ask about.
  @spec removed_negations(SQLParser.parsed_query()) :: [term()]
  defp removed_negations(query) do
    if contains_negation?(query.where),
      do: negations(query.where, []) -- negations(SQLSimplify.apply(query).where, []),
      else: []
  end

  @spec negation?(term()) :: boolean()
  defp negation?({:neg, _inner}), do: true
  defp negation?(_item), do: false

  @spec contains_negation?(term()) :: boolean()
  defp contains_negation?({:neg, _inner}), do: true

  defp contains_negation?(tuple) when is_tuple(tuple),
    do: contains_negation?(Tuple.to_list(tuple))

  defp contains_negation?(list) when is_list(list), do: Enum.any?(list, &contains_negation?/1)
  defp contains_negation?(_leaf), do: false

  @spec negations(term(), [term()]) :: [term()]
  defp negations({:neg, inner} = node, found), do: negations(inner, [node | found])
  defp negations(tuple, found) when is_tuple(tuple), do: negations(Tuple.to_list(tuple), found)
  defp negations(list, found) when is_list(list), do: Enum.reduce(list, found, &negations/2)
  defp negations(_leaf, found), do: found

  # The context an item is checked in: a `HAVING` is checked as a `WHERE` is.
  @spec check_context(atom()) :: plan_context()
  defp check_context(:having), do: :where
  defp check_context(context), do: context

  # The errors of the plan that are not found in an expression: the grouping, found when the
  # aggregate is planned, and the placeholders, replaced once the plan is built.
  @spec plan_gates(SQLParser.parsed_query(), plan_options()) :: [{atom(), term()}]
  defp plan_gates(query, options) do
    group =
      case {Keyword.get(options, :group), query.select_columns} do
        {fun, columns} when is_function(fun, 0) and columns != nil ->
          [{:select, {:group_check, fun}}]

        _no_aggregate ->
          []
      end

    placeholder =
      case Keyword.get(options, :placeholder) do
        nil -> []
        error -> [{:select, {:placeholder_check, error}}]
      end

    group ++ placeholder
  end

  # The predicate of a `WHERE` that is one expression or one column, which the planner makes
  # a filter of: it has to be a boolean.
  @spec filter_target(SQLParser.parsed_query()) ::
          nil | {:expr, SQLExpr.t()} | {:column, binary()}
  defp filter_target(%{where_tree: {:leaf, {:truthy_expr, {:expr, expr}, _nil}}}),
    do: {:expr, expr}

  defp filter_target(%{where_tree: {:leaf, {:truthy, column, _nil}}}), do: {:column, column}
  defp filter_target(_query), do: nil

  @spec filter_fields(nil | {:expr, SQLExpr.t()} | {:column, binary()}) :: [binary()]
  defp filter_fields(nil), do: []
  defp filter_fields({:column, column}), do: [column]
  defp filter_fields({:expr, expr}), do: SQLSchema.expr_fields(expr)

  # The first thing the planner does with a `WHERE` is to refuse a predicate that is typed and
  # is no boolean (verified against Core, before the select list, the `ORDER BY` and every
  # type error of the predicate's own parts: a predicate it cannot type is left to the type
  # coercion, which finds the error in it).
  @spec filter_error(
          nil | {:expr, SQLExpr.t()} | {:column, binary()},
          SQLParser.parsed_query(),
          %{binary() => binary()}
        ) :: :ok | {:error, failure()}
  defp filter_error(nil, _query, _columns), do: :ok

  defp filter_error(target, query, columns) do
    type = filter_type(target, columns)

    if is_binary(type) and type not in ["Boolean", "Null"] and typed?(target, columns) and
         not unbound?(target) do
      filter_text(target, query.measurement, type)
    else
      :ok
    end
  end

  # The planner checks that a filter is a boolean by the type of its predicate and ignores the
  # error when it cannot type it (`Filter::try_new`), which it cannot when the predicate holds a
  # `$n` whose type is not known: such a predicate is left to the placeholders' replacement.
  @spec unbound?({:expr, SQLExpr.t()} | {:column, binary()}) :: boolean()
  defp unbound?({:expr, expr}),
    do:
      SQLExpr.any?(expr, &match?({:param, _name}, &1)) and
        not inferred?(expr)

  defp unbound?({:column, _column}), do: false

  # Whether every `$n` of an expression stands in operators alone (`max(n) + $1`), where the
  # planner infers its type from the operand beside it (verified: the filter of `HAVING max(n)
  # + $1` is refused as an `Int64`); under a call (`pow(b, $1) + 1e3`) it cannot.
  @spec inferred?(SQLExpr.t()) :: boolean()
  defp inferred?({:param, _name}), do: true

  defp inferred?({:call, _name, args}),
    do: not Enum.any?(args, &SQLExpr.any?(&1, fn node -> match?({:param, _}, node) end))

  defp inferred?(expr), do: Enum.all?(SQLExpr.children(expr), &inferred?/1)

  # A `HAVING` that is one typed expression that is no boolean is refused by the planner like a
  # `WHERE`, in words that print its aggregates as the engine names them. `scope` types the
  # aggregates by their results. A `HAVING` of several predicates is an `AND`, which the
  # analyzer finds the error of.
  @spec having_filter(
          SQLWhere.tree() | nil,
          %{binary() => binary() | :unrenderable},
          binary(),
          %{binary() => binary()}
        ) :: :ok | {:error, failure()}
  defp having_filter({:leaf, {:truthy_expr, {:expr, expr}, _nil}}, names, measurement, scope) do
    type = SQLExprType.type_of(expr, scope, SQLTyped.new(), :plan)

    # A predicate the planner cannot type is left to the type coercion, which finds the error
    # in it, as for a `WHERE` (see `filter_error/3`).
    if is_binary(type) and type not in ["Boolean", "Null"] and typed?({:expr, expr}, scope) and
         not unbound?({:expr, expr}) do
      case having_text(expr, names, measurement) do
        :unrenderable ->
          {:error,
           SQLError.refusal(
             "a HAVING that is an expression of no boolean type: the engine's text of it is " <>
               "not modelled"
           )}

        text ->
          decimal_guard({:error, SQLPredicate.non_boolean_error(text, type)})
      end
    else
      :ok
    end
  end

  defp having_filter(_nodes, _names, _measurement, _scope), do: :ok

  # The engine's text of a `HAVING`'s expression: an aggregate, or the name of a select item
  # that is one, as the planner names it (`names`; a name the double cannot word refuses it).
  @spec having_text(SQLExpr.t(), %{binary() => binary() | :unrenderable}, binary()) ::
          binary() | :unrenderable
  defp having_text(expr, names, measurement) do
    expr |> name_aggregates(names) |> SQLExpr.render(measurement, :display)
  catch
    :unrenderable -> :unrenderable
  end

  @spec name_aggregates(SQLExpr.t(), %{binary() => binary() | :unrenderable}) :: SQLExpr.t()
  defp name_aggregates({:field, name} = field, names) when is_binary(name) do
    case Map.fetch(names, name) do
      {:ok, text} when is_binary(text) -> {:raw, text}
      {:ok, :unrenderable} -> throw(:unrenderable)
      :error -> field
    end
  end

  defp name_aggregates(expr, names),
    do: SQLExpr.map_children(expr, &name_aggregates(&1, names))

  # The `HAVING`'s filter check once the types of the table's columns are known: the names of
  # the select items that no column of the table has, as the engine would print them.
  @spec with_columns(
          {non_neg_integer(), plan_context(), term()},
          %{binary() => binary()}
        ) :: {non_neg_integer(), plan_context(), term()}
  defp with_columns(
         {rank, context, {:aggs, aggs, {:filter, tree, names, outputs, measurement}}},
         types
       ) do
    aliases =
      for {name, text} <- outputs, not is_map_key(types, name), into: %{}, do: {name, text}

    {rank, context, {:aggs, aggs, {:filter, tree, Map.merge(names, aliases), measurement}}}
  end

  defp with_columns(check, _types), do: check

  @spec filter_type({:expr, SQLExpr.t()} | {:column, binary()}, %{binary() => binary()}) ::
          SQLExprType.type()
  defp filter_type({:column, column}, columns), do: Map.get(columns, column)

  defp filter_type({:expr, expr}, columns),
    do: SQLExprType.type_of(expr, columns, SQLTyped.new(), :plan)

  # Whether the parts of the predicate type without an error of their own: the errors of the
  # type coercion (a negation, a constant the optimizer folds, are found later and do not
  # keep the planner from typing it).
  @spec typed?({:expr, SQLExpr.t()} | {:column, binary()}, %{binary() => binary()}) :: boolean()
  defp typed?({:column, _column}, _columns), do: true

  defp typed?({:expr, expr}, columns) do
    outcome =
      expr
      |> items()
      |> Enum.filter(&planner_typed?/1)
      |> Enum.map(&{SQLStage.index(rank(:where, &1)), :where_plan, &1})
      |> Enum.sort_by(&elem(&1, 0))
      |> check_items(columns, plain_mode())

    # What the double declines to compute, and what the optimizer finds in a constant, are not
    # errors of the planner's: they do not keep it from typing the predicate.
    case outcome do
      :ok -> true
      {:error, %{body: "Optimizer rule " <> _rest}} -> true
      {:error, error} -> SQLError.late?(error)
    end
  end

  # The items of a `WHERE` or an `ORDER BY`, the parts under the operand of a `||` marked
  # `{:planned, item}`. The planner builds a `||` by the types of its operands (it chooses
  # between the concatenation of text and of lists by them), so every operator and call under
  # one is typed as the plan is built, and its error is the planner's, not the type
  # coercion's: unwrapped, and found before the type coercion finds anything, a `WHERE`'s
  # before the select list's and an `ORDER BY`'s after (verified: `WHERE 'a' || (n + 's') = 'x'`
  # is the arithmetic error without the `type_coercion` prefix, and before the error of
  # `abs(s)` in the select list).
  @spec planned_items(term(), :where | :select | :order_by) :: [term()]
  defp planned_items(term, _context),
    do: term |> annotate([]) |> plan_items({false, false, false}) |> flat()

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
  defp planner_typed?({wrapper, item}) when wrapper in [:cut, :planned],
    do: planner_typed?(item)

  # What the planner leaves to the type coercion (the conditions of a `CASE`, its later
  # results, what stands under an `IS NULL` or an operator that types its operands late).
  defp planner_typed?({wrapper, _item}) when wrapper in [:lazy_cut, :null_cut, :case_cut],
    do: false

  defp planner_typed?({kind, _first}) when kind in [:neg, :pos], do: false
  defp planner_typed?({:op, _op, _left, _right}), do: true
  defp planner_typed?({:call, _name, _args}), do: true
  defp planner_typed?({:compare, _op, _left, _right}), do: true

  defp planner_typed?({:expr_check, {kind, _left, _right}})
       when kind in [:cmp, :and, :or, :concat],
       do: true

  defp planner_typed?({:expr_check, {:cmp, _op, _left, _right}}), do: true
  defp planner_typed?({:expr_check, {:is_distinct, _left, _right, _negated}}), do: true
  defp planner_typed?({:expr_check, {:call, name, _args}}), do: name in [:coalesce, :nullif]
  defp planner_typed?(_item), do: false

  @spec filter_text({:expr, SQLExpr.t()} | {:column, binary()}, binary(), binary()) ::
          :ok | {:error, failure()}
  defp filter_text(target, measurement, type) do
    text =
      case target do
        {:column, column} -> "#{measurement}.#{column}"
        {:expr, expr} -> SQLExpr.render(expr, measurement, :display)
      end

    decimal_guard({:error, SQLPredicate.non_boolean_error(text, type)})
  catch
    :unrenderable ->
      {:error,
       SQLError.refusal(
         "a filter that is a cast: the engine's text of it, with the type, is not modelled"
       )}
  end

  # The terms of an `ORDER BY` that are expressions, each name in one that is a select
  # item's output name read as that item (the planner does the same, and the item wins over a
  # column of the table of that name).
  @spec ordered_terms(SQLParser.parsed_query()) :: [term()]
  defp ordered_terms(query) do
    Enum.map(query.order_by, fn
      {{:expr, expr}, _direction} ->
        {:expr, SQLClauses.output_items(expr, query.projection_columns)}

      {term, _direction} ->
        term
    end)
  end

  # The names a `HAVING` reads that a select item is output as: the planner reads such a name
  # as the item's result (a table's column of that name wins, which `column_types/3` is merged
  # over).
  @spec having_aliases(SQLParser.parsed_query()) :: [binary()]
  defp having_aliases(%{having: %{nodes: nodes}, select_columns: columns})
       when is_list(columns),
       do: nodes |> SQLWhere.conjunction_columns() |> Enum.uniq()

  defp having_aliases(_query), do: []

  # The columns the aliased select items read, which their types are found from.
  @spec alias_fields([binary()], SQLParser.parsed_query()) :: [binary()]
  defp alias_fields([], _query), do: []

  defp alias_fields(names, query) do
    query.select_columns
    |> SQLAggType.output_arguments(names)
    |> Enum.flat_map(&SQLSchema.expr_fields/1)
  end

  # The stage an item is found at, given the clause it stands in (`:having` for a `HAVING`,
  # which the analyzer coerces as it does a `WHERE`, after the one below it).
  @spec rank(:select | :where | :having | :order_by, term()) :: SQLStage.t()
  defp rank(:where, {:planned, _item}), do: :where_built
  defp rank(:select, {:planned, _item}), do: :select_built_concat
  defp rank(:order_by, {:planned, _item}), do: :order_built
  defp rank(_context, {kind, _inner}) when kind in [:neg, :pos], do: :negation
  defp rank(:select, {:group_check, _check}), do: :group
  defp rank(:select, {:placeholder_check, _error}), do: :placeholder

  defp rank(context, {:constant, _call, ancestors}) do
    case SQLConstantCall.phase(ancestors, context) do
      :optimizer -> :optimizer
      :bare -> :bare_constant
      _typed -> rank(context, :typed)
    end
  end

  defp rank(:having, {:aggs, _aggs, {:filter, _tree, _names, _outputs, _measurement}}),
    do: :having_filter

  defp rank(:having, {:aggs, _aggs, item}), do: SQLStage.having(rank(:where, item))
  defp rank(context, {:aggs, _aggs, item}), do: rank(context, item)
  defp rank(:select, _item), do: :select_built

  defp rank(:where, {:pattern, kind, _operand, _rest}) when kind in [:like, :not_like],
    do: :where_coerced

  defp rank(:where, {:cut, _call}), do: :where_coerced
  defp rank(:where, {:lazy_cut, _call}), do: :where_coerced
  defp rank(:where, {:null_cut, _call}), do: :where_coerced
  defp rank(:where, {:case_cut, _call}), do: :where_coerced
  defp rank(:where, {:in_list, _operand, _values}), do: :where_coerced
  defp rank(:where, {:logical, _tree}), do: :where_coerced
  defp rank(:where, {:logical_ops, _tree}), do: :where_logical
  defp rank(:where, {:expr_check, {:is_bool, _inner, _value, _negated}}), do: :where_coerced
  # The cast of the operand of a `NOT` to a boolean fails after the errors of the operators and
  # calls over it (verified: `WHERE u % (NOT u)` is the error of the `%`).
  defp rank(:where, {:expr_check, {:not, _inner}}), do: :where_coerced
  # The operators the type coercion types by themselves come after the operators and calls
  # that type their operands (verified: `WHERE floor(host IN (ok, NULL))` is the error of
  # `floor`, not of the `IN` under it).
  defp rank(:where, {:expr_check, node}) when elem(node, 0) in [:in, :between, :like, :case],
    do: :where_coerced

  defp rank(:where, {:range, _operand, _low, _high}), do: :where_coerced
  defp rank(:where, _item), do: :where_calls
  defp rank(:order_by, _item), do: :order_calls

  @spec select_items(SQLParser.parsed_query()) :: [term()]
  defp select_items(query) do
    projected =
      Enum.flat_map(query.projection_columns || [], &planned_items(elem(&1, 0), :select))

    grouped? = (query.group_by_columns || []) != []

    aggregated =
      query.select_columns
      |> List.wrap()
      |> Enum.flat_map(&aggregate_items/1)
      |> Enum.map(&selector_scope(&1, grouped?))

    having =
      Enum.flat_map((query.having && query.having.aggs) || [], &aggregate_items(elem(&1, 1)))

    projected ++ aggregated ++ having
  end

  # The parts of a `HAVING` the planner types, with the aggregates' results: its calls and
  # operators, the booleans of its `AND`s, `OR`s and `NOT`s, and the check that it is a
  # boolean.
  @spec having_items(SQLParser.parsed_query()) :: [{:having, term()}]
  defp having_items(%{having: nil}), do: []

  defp having_items(%{having: %{nodes: nodes, aggs: aggs} = having} = query) do
    parts = for item <- items(nodes), not match?({:agg_ref, _name}, item), do: item
    tree = having[:tree] || having_tree(nodes)

    filter =
      {:filter, tree, filter_names(aggs, query.measurement), filter_outputs(query),
       query.measurement}

    for item <- parts ++ logical_parts(tree) ++ [filter], do: {:having, {:aggs, aggs, item}}
  end

  # The engine's text of the aggregates a `HAVING` names, and of the select items it may name.
  @spec filter_names([{binary(), SQLSelect.column()}], binary()) ::
          %{binary() => binary() | :unrenderable}
  defp filter_names(aggs, measurement),
    do:
      Map.new(aggs, fn {name, column} -> {name, SQLGrouping.filter_term(column, measurement)} end)

  @spec filter_outputs(SQLParser.parsed_query()) :: [{binary(), binary() | :unrenderable}]
  defp filter_outputs(query) do
    for column <- query.select_columns || [] do
      {elem(column, tuple_size(column) - 1), SQLGrouping.filter_term(column, query.measurement)}
    end
  end

  # The conjunction of a `HAVING` as the tree of a `WHERE` is, to type its booleans as one.
  @spec having_tree([SQLWhere.node_t()]) :: SQLWhere.tree() | nil
  defp having_tree([]), do: {:const, true}
  defp having_tree(nodes), do: nodes |> Enum.map(&node_tree/1) |> Enum.reduce(&{:and, &2, &1})

  @spec node_tree(SQLWhere.node_t()) :: SQLWhere.tree()
  defp node_tree({:or, []}), do: {:const, false}

  defp node_tree({:or, branches}),
    do: branches |> Enum.map(&having_tree/1) |> Enum.reduce(&{:or, &2, &1})

  defp node_tree({:not, nodes}), do: {:not, having_tree(nodes)}
  defp node_tree(predicate), do: {:leaf, predicate}

  @spec aggregate_items(SQLParser.select_column()) :: [term()]
  defp aggregate_items({:aggregate, agg, expr, _alias}),
    do: items(expr) ++ [{:aggregate, agg, expr}]

  # The items of an expression over aggregates in the order the engine meets
  # them: each aggregate where its call stands, and the expression's parts
  # typed with the aggregates' results.
  defp aggregate_items({:expression, expr, aggs, _alias}) do
    by_name = Map.new(aggs)
    parts = items(expr)

    items =
      Enum.flat_map(parts, fn
        {:agg_ref, name} -> aggregate_items(Map.fetch!(by_name, name))
        item -> [{:aggs, aggs, item}]
      end)

    referenced = for {:agg_ref, name} <- parts, do: name
    unreferenced = for {name, column} <- aggs, name not in referenced, do: column
    items ++ Enum.flat_map(unreferenced, &aggregate_items/1)
  end

  # A selector's arguments are typed whatever stands above it: the second must be a timestamp.
  defp aggregate_items({:selector, selector, field, ordering, _kind, _alias}),
    do: [{:selector_check, selector, field, ordering, false}]

  defp aggregate_items(_other), do: []

  @spec selector_scope(term(), boolean()) :: term()
  defp selector_scope({:selector_check, selector, field, ordering, _grouped}, grouped?),
    do: {:selector_check, selector, field, ordering, grouped?}

  defp selector_scope(item, _grouped?), do: item

  # The `AND`s, `OR`s and `NOT`s of a `WHERE`, whose operands must be
  # booleans; a `WHERE` that is one predicate has none.
  @spec logical_items(SQLWhere.tree() | nil) :: [{:where, term()}]
  defp logical_items(tree), do: Enum.map(logical_parts(tree), &{:where, &1})

  @spec logical_parts(SQLWhere.tree() | nil) :: [term()]
  defp logical_parts({kind, _left, _right} = tree) when kind in [:and, :or],
    do: [{:logical_ops, tree}, {:logical, tree}]

  defp logical_parts({:not, _inner} = tree), do: [{:logical_ops, tree}, {:logical, tree}]
  defp logical_parts({:leaf, {:truthy_expr, _expr, _nil}} = tree), do: [{:logical, tree}]
  defp logical_parts(_tree), do: []

  @comparisons [:eq, :ne, :gt, :lt, :gte, :lte]

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
  defp items(term), do: term |> annotate([]) |> plan_items({false, false, :never}) |> flat()

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

  @spec operand_expr(SQLParser.operand()) :: SQLParser.expr()
  defp operand_expr({:expr, expr}), do: expr
  defp operand_expr(column), do: {:field, column}

  # The columns the checks name. The parts of a term that are items of their own (an
  # operator under an operator, a call under a comparison) are named by those items, so
  # each item names only what it holds directly: walking its whole term would walk the
  # parts below it once for every item above them, which is quadratic in the length of
  # a nested sum or chain.
  @spec plan_columns([{number(), plan_context(), term()}]) :: [binary()]
  defp plan_columns(checks) do
    items = Enum.map(checks, fn {_rank, _context, item} -> item end)

    # The aggregates of an expression over aggregates are named once for each set of them,
    # not once for each part of the expression.
    aggregated =
      items
      |> Enum.reduce([], fn
        {:aggs, aggs, _item}, seen ->
          if Enum.any?(seen, &(&1 === aggs)), do: seen, else: [aggs | seen]

        _item, seen ->
          seen
      end)
      |> Enum.flat_map(&aggregate_fields/1)

    # The names of the aggregates are no columns: they are typed by the aggregates' results.
    Enum.reject(aggregated ++ Enum.flat_map(items, &item_fields/1), &placeholder?/1)
  end

  @spec placeholder?(term()) :: boolean()
  defp placeholder?(name) when is_binary(name), do: SQLAggExpr.placeholder?(name)
  defp placeholder?(_name), do: false

  @spec aggregate_fields([{binary(), SQLSelect.column()}]) :: [SQLExpr.column_ref()]
  defp aggregate_fields(aggs),
    do: Enum.flat_map(SQLAggType.arguments(aggs), &SQLSchema.expr_fields/1)

  @spec item_fields(term()) :: [SQLExpr.column_ref()]
  defp item_fields({wrapper, item})
       when wrapper in [:cut, :lazy_cut, :null_cut, :case_cut, :planned],
       do: item_fields(item)

  defp item_fields({:expr_check, node}), do: node_fields(node)

  defp item_fields({:aggs, _aggs, item}), do: item_fields(item)
  defp item_fields({:group_check, _check}), do: []
  defp item_fields({:placeholder_check, _error}), do: []

  defp item_fields({:aggregate, _agg, expr}), do: own_fields(expr)
  defp item_fields({:compare, _op, left, right}), do: own_fields([left, right])
  defp item_fields({:pattern, _kind, expr, _rest}), do: own_fields(expr)

  defp item_fields({:in_list, left, values}),
    do: own_fields([left | for({:expr, _expr} = value <- values, do: value)])

  defp item_fields({:range, left, low, high}),
    do: own_fields([left | for({:expr, _expr} = value <- [low, high], do: value)])

  defp item_fields({kind, _first} = node) when kind in [:neg, :pos], do: node_fields(node)
  defp item_fields({:op, _op, _left, _right} = node), do: node_fields(node)
  defp item_fields({:call, _name, _args} = node), do: node_fields(node)
  defp item_fields(item), do: SQLSchema.expr_fields(item)

  @spec node_fields(SQLExpr.t()) :: [SQLExpr.column_ref()]
  defp node_fields(node), do: Enum.flat_map(SQLExpr.children(node), &own_fields/1)

  # The columns a term names that no item of its own names: those of the parts that are
  # not themselves items.
  @spec own_fields(term()) :: [SQLExpr.column_ref()]
  defp own_fields({:expr, expr}), do: own_fields(expr)
  defp own_fields({:field, name}), do: [name]
  defp own_fields({:uint_col, name}), do: [name]
  defp own_fields(terms) when is_list(terms), do: Enum.flat_map(terms, &own_fields/1)
  defp own_fields(term) when is_tuple(term) and tuple_size(term) > 0, do: own_tuple_fields(term)
  defp own_fields(_leaf), do: []

  @spec own_tuple_fields(tuple()) :: [SQLExpr.column_ref()]
  defp own_tuple_fields(term) do
    if item_term?(term), do: [], else: node_fields(term)
  end

  # The expressions `plan_items/2` makes an item of, wherever they stand.
  @spec item_term?(tuple()) :: boolean()
  defp item_term?({:op, _op, _left, _right}), do: true
  defp item_term?({:cmp, _op, _left, _right}), do: true
  defp item_term?({kind, _inner}) when kind in [:neg, :pos], do: true
  defp item_term?({:not, inner}), do: not is_list(inner)
  defp item_term?({kind, _left, _right}) when kind in [:and, :or, :concat], do: true
  defp item_term?({:cast, _inner, _type}), do: true
  defp item_term?({:call, _name, _args}), do: true
  defp item_term?({:constant, _call, _ancestors}), do: true
  defp item_term?({:is_bool, _inner, _value, _negated}), do: true
  defp item_term?({:is_distinct, _left, _right, _negated}), do: true
  defp item_term?({:in, _inner, items, _negated}), do: is_list(items)
  defp item_term?({:between, _inner, _low, _high, _negated}), do: true
  defp item_term?({:like, _inner, _pattern, _negated, _ilike, _regex}), do: true
  defp item_term?({:case, _operand, _whens, _otherwise}), do: true
  defp item_term?(_other), do: false

  # The items are checked in order, each carrying what the ones before it typed (`memo`): an
  # operator is typed from the types of its sides, which the items of the operators below it
  # have typed already, so a long sum is typed once per operator and not again for every
  # operator above it. A `CASE`, a `COALESCE` and a `||` nest the same way.
  #
  # What was typed belongs to the types of the columns it was typed against, so the parts of
  # an expression over aggregates, typed with the aggregates' results, have a scope of their
  # own: made once for a set of aggregates, shared by every part of the expressions over it.
  # A scope is `{columns, memo, nulls}`, `nulls` being the aggregates that are `MIN(NULL)` or
  # `MAX(NULL)`.
  @typep scope :: {%{binary() => binary()}, SQLTyped.t(), [binary()]}

  # The scopes by what makes them: `:base`, or the aggregates of the expression. They are
  # kept in a list, not a map, because the aggregates of a long `HAVING` are a long list and
  # a map would hash all of it for every part of the expression, where a list compares the
  # one term it was given, which is the same term for every part.
  @typep scopes :: [{term(), scope()}]

  # What the planner reports later than the other errors, with the stage it is found at (see
  # `SQLStage`): the select list's errors of the type coercion come once the planner has found
  # nothing wrong with the select list, the `WHERE` and the `HAVING` (verified: `SELECT n LIKE
  # 'x' ... WHERE abs(s) > 1` is the `abs` error, `SELECT n LIKE 'x', ('s' OR n)` the `OR`
  # one), but before the `ORDER BY`'s; a struct given to a function of text is converted
  # after the rest; and the engine closes the connection when it runs the plan, after all
  # of its errors.
  @coercion "type_coercion\ncaused by\n"

  # The stage an error is held back to, as its index among the stages (see `SQLStage`).
  @typep deferred :: nil | {non_neg_integer(), {:error, failure()}}

  # The contexts of the checks: those of the functions, and the one that types a predicate as
  # the planner does (see `typed?/2`).
  @typep plan_context :: SQLFunctions.context() | :where_plan

  # How the items are checked: whether a use of a duration ends the check (see `duration_use?/1`),
  # and which items the engine never meets (see `pruned/1`).
  @typep mode :: %{duration?: boolean(), pruned?: (term(), plan_context() -> boolean())}

  @spec plain_mode() :: mode()
  defp plain_mode, do: %{duration?: false, pruned?: fn _item, _context -> false end}

  @spec check_items(
          [{non_neg_integer(), plan_context(), term()}],
          %{binary() => binary()},
          mode()
        ) ::
          :ok | {:error, failure()}
  defp check_items(checks, columns, mode) do
    checks
    |> Enum.reduce_while({nil, []}, &check_next(&1, &2, columns, mode))
    |> case do
      {:done, outcome} -> outcome
      {nil, _scopes} -> :ok
      {{_position, error}, _scopes} -> error
    end
  end

  @spec check_next(
          {non_neg_integer(), plan_context(), term()},
          {deferred(), scopes()},
          %{binary() => binary()},
          mode()
        ) :: {:cont, {deferred(), scopes()}} | {:halt, {:done, term()}}
  defp check_next({rank, _context, _item}, {{position, error}, _scopes}, _columns, _mode)
       when position < rank,
       do: {:halt, {:done, error}}

  defp check_next({_rank, context, item}, {deferred, scopes}, columns, mode) do
    coerced? = context == :select and elem(item, 0) in [:lazy_cut, :null_cut, :case_cut]
    {key, item, scope} = enter(item, columns, scopes)
    {scope_columns, memo, _nulls} = scope

    # The engine's error for a use of a duration is its own and is found where the use stands,
    # so the double's refusal for it ends the check there (it is not one of the refusals that
    # stand with the errors of the type coercion).
    if mode.duration? and duration_use?(item) do
      {:halt, {:done, {:error, duration_refusal()}}}
    else
      outcome = item |> check_item(context, scope_columns, memo) |> decimal_guard()
      outcome = if mode.pruned?.(item, context), do: :ok, else: outcome
      scopes = List.keystore(scopes, key, 0, {key, remember(item, scope)})
      continue(outcome, {context, coerced?}, deferred, scopes)
    end
  end

  # `coerced?` says the item stands where the planner types it only when it coerces the
  # expression (under a lazy or null cut of the select list): every error it has, the
  # double's refusals too, is found by the type coercion.
  @spec continue(
          :ok | {:error, failure()},
          {plan_context(), boolean()},
          deferred(),
          scopes()
        ) :: {:cont, {deferred(), scopes()}} | {:halt, {:done, term()}}
  defp continue(:ok, _where, deferred, scopes), do: {:cont, {deferred, scopes}}

  defp continue({:error, error} = outcome, {context, coerced?}, deferred, scopes) do
    case {position(error, context), coerced?} do
      {nil, false} -> {:halt, {:done, outcome}}
      {nil, true} -> {:cont, {defer(deferred, :select_coerced, outcome), scopes}}
      {position, _coerced?} -> {:cont, {defer(deferred, position, outcome), scopes}}
    end
  end

  # Whether an item is typed where it stands: not cut by an operator over it that leaves its
  # operands to the type coercion.
  @spec uncut?(term()) :: boolean()
  defp uncut?({wrapper, _item}) when wrapper in [:cut, :lazy_cut, :null_cut, :case_cut],
    do: false

  defp uncut?({:aggs, _aggs, item}), do: uncut?(item)
  defp uncut?(_item), do: true

  # Where a deferred error stands, `nil` for an error that ends the check.
  @spec position(term(), plan_context()) :: SQLStage.t() | nil
  defp position(%{body: @conversion <> _rest}, _context), do: :conversion
  defp position({:connection_error, _reason}, _context), do: :closed
  defp position(%{body: @coercion <> _rest}, :select), do: :select_coerced

  # The conversion of the conditions of a `CASE` to booleans comes after the errors of the
  # operators around it (verified: `ok = CASE WHEN time THEN 1 ELSE 2 END` is the error of
  # the comparison, wherever it stands).
  defp position(%{body: @coercion <> "WHEN expressions in CASE" <> _rest}, _context),
    do: :select_coerced

  # So does the coercion of the results of a `CASE` to one type: the error of an operator or
  # a call above it, or beside it, comes first
  # (verified: `WHERE (CASE WHEN true THEN 'a' ELSE true END) AND (n + 'a')` is the
  # arithmetic error).
  defp position(
         %{body: @coercion <> "Error during planning: Failed to coerce then" <> _rest},
         _context
       ),
       do: :select_coerced

  # The refusal of the results of a `CASE` that share no type stands for the error the type
  # coercion has for them, which comes with the others of its pass.
  defp position(%{body: "Client.Local: a CASE whose results have no common type" <> _rest}, _ctx),
    do: :select_coerced

  # The optimizer folds a constant after the planner has typed the whole query.
  defp position(%{body: "Optimizer rule " <> _rest}, _context), do: :optimizer

  # The negation of a type it does not support is found when the physical plan is built, after
  # the optimizer (verified: `HAVING -y AND true` is the `AND` error, `HAVING -y` the
  # non-boolean filter).
  defp position(%{body: "Error during planning: Negation only supports" <> _rest}, _context),
    do: :physical

  # The double declines to compute what the engine computes without a planning error (a
  # `CASE` condition that is no boolean is cast): any error the rest of the query has is the
  # answer.
  defp position(error, _context), do: if(SQLError.late?(error), do: :unmodelled)

  # The earliest of the errors deferred, the first of those at the same place.
  @spec defer(deferred(), SQLStage.t(), {:error, failure()}) :: deferred()
  defp defer(deferred, stage, outcome) do
    position = SQLStage.index(stage)

    case deferred do
      {held, _error} when held <= position -> deferred
      _later_or_none -> {position, outcome}
    end
  end

  # The scope an item is checked in, made once, and the item as it is checked there: the
  # aggregates that are the null read as the null literal.
  @spec enter(term(), %{binary() => binary()}, scopes()) :: {term(), term(), scope()}
  defp enter({:aggs, aggs, item}, columns, scopes) do
    scope =
      case List.keyfind(scopes, aggs, 0) do
        {_aggs, scope} ->
          scope

        nil ->
          nulls = for {name, _column} = agg <- aggs, null_extreme?(agg), do: name
          {Map.merge(columns, SQLAggType.types(aggs, columns)), SQLTyped.new(), nulls}
      end

    {aggs, nullify(item, elem(scope, 2)), scope}
  end

  defp enter(item, columns, scopes) do
    scope =
      case List.keyfind(scopes, :base, 0) do
        {:base, scope} -> scope
        nil -> {columns, SQLTyped.new(), []}
      end

    {:base, item, scope}
  end

  # What an item typed, added to what was typed before it: the type of an expression
  # whatever it stands in.
  @spec remember(term(), scope()) :: scope()
  defp remember({wrapper, item}, scope)
       when wrapper in [:cut, :lazy_cut, :null_cut, :case_cut, :planned],
       do: remember(item, scope)

  defp remember({:expr_check, node}, scope), do: remember_node(node, scope)

  defp remember(item, scope) when is_tuple(item) and elem(item, 0) in [:op, :neg, :pos, :call],
    do: remember_node(item, scope)

  defp remember(_item, scope), do: scope

  @spec remember_node(SQLExpr.t(), scope()) :: scope()
  defp remember_node(node, {columns, memo, nulls}),
    do: {columns, SQLTyped.put(memo, node, SQLExprType.types_of(node, columns, memo)), nulls}

  # Whether an item operates on the difference of a null and `time` (`time - NULL`), which the
  # engine types as a `Duration(ns)`: the error of each use is its own, and not modelled.
  @spec duration_use?(term()) :: boolean()
  defp duration_use?({wrapper, item})
       when wrapper in [:cut, :lazy_cut, :null_cut, :case_cut, :planned],
       do: duration_use?(item)

  defp duration_use?({:aggs, _aggs, item}), do: duration_use?(item)
  defp duration_use?({:expr_check, node}), do: Enum.any?(SQLExpr.children(node), &duration?/1)
  defp duration_use?({:aggregate, _agg, expr}), do: duration?(expr)
  defp duration_use?({:compare, _op, left, right}), do: Enum.any?([left, right], &duration?/1)
  defp duration_use?({:pattern, _kind, expr, _rest}), do: duration?(expr)
  defp duration_use?({:in_list, left, values}), do: Enum.any?([left | values], &duration?/1)

  defp duration_use?({:range, left, low, high}),
    do: Enum.any?([left, low, high], &duration?/1)

  defp duration_use?({kind, _first} = node) when kind in [:neg, :pos],
    do: Enum.any?(SQLExpr.children(node), &duration?/1)

  defp duration_use?({:op, _op, _left, _right} = node),
    do: Enum.any?(SQLExpr.children(node), &duration?/1)

  defp duration_use?({:call, _name, _args} = node),
    do: Enum.any?(SQLExpr.children(node), &duration?/1)

  defp duration_use?(_item), do: false

  @spec duration?(term()) :: boolean()
  defp duration?({:expr, expr}), do: SQLNullType.duration?(expr)
  defp duration?(expr), do: SQLNullType.duration?(expr)

  # An error that would print a decimal's type cannot be worded: the
  # precision of an `Int64` with a `UInt64` is not tracked.
  @spec decimal_guard(:ok | {:error, failure()}) :: :ok | {:error, failure()}
  defp decimal_guard({:error, %{body: body}} = error) do
    if String.contains?(body, @decimal),
      do:
        {:error,
         SQLError.refusal(
           "a type error over a decimal (an Int64 with a UInt64, or a division of one): its " <>
             "precision is not modelled, so the engine's message cannot be worded"
         )},
      else: error
  end

  defp decimal_guard({:error, {:connection_error, _reason}} = closed), do: closed
  defp decimal_guard(:ok), do: :ok

  @spec check_item(term(), plan_context(), %{binary() => binary()}, SQLTyped.t()) ::
          :ok | {:error, failure()}
  # The check of the parts the planner types, as it types them (the arguments as written, not
  # as the type coercion makes them), which says whether it can type a predicate.
  defp check_item({wrapper, item}, :where_plan, columns, memo)
       when wrapper in [:cut, :lazy_cut, :null_cut, :case_cut, :planned],
       do: check_item(item, :where_plan, columns, memo)

  defp check_item({:call, function, args}, :where_plan, columns, memo) do
    nulls = Enum.map(args, &SQLNullType.null_valued?/1)
    planned = Enum.map(args, &known_mix(elem(SQLExprType.pair(&1, columns, memo), 1)))
    SQLFunctions.check(function, planned, :where, nulls)
  end

  defp check_item({:op, op, left, right}, :where_plan, columns, memo) do
    {_left_coerced, left_planned} = SQLExprType.pair(left, columns, memo)
    {_right_coerced, right_planned} = SQLExprType.pair(right, columns, memo)
    arithmetic_error(op, {left_planned, right_planned}, :where)
  end

  defp check_item({:expr_check, node}, :where_plan, columns, memo),
    do: SQLExprCheck.check_planned(node, columns, memo)

  defp check_item(item, :where_plan, columns, memo), do: check_item(item, :where, columns, memo)

  # An operand of a `||` is typed as the plan is built, whatever stands over it: the cuts of
  # the parts over it do not apply.
  defp check_item({:planned, {wrapper, item}}, context, columns, memo)
       when wrapper in [:cut, :lazy_cut, :null_cut, :case_cut],
       do: check_item({:planned, item}, context, columns, memo)

  defp check_item({:planned, item}, _context, columns, memo),
    do: check_item(item, :select, columns, memo)

  defp check_item({:cut, call}, :where, columns, memo),
    do: check_item(call, :where_cut, columns, memo)

  defp check_item({:cut, call}, context, columns, memo),
    do: check_item(call, context, columns, memo)

  # Only an IS NULL cuts the error of a call in the select list (verified against Core: a
  # CAST, BETWEEN, IN, LIKE or NOT there leaves the planner's whole message).
  defp check_item({:null_cut, call}, :select, columns, memo),
    do: check_item(call, :select_cut, columns, memo)

  # An operator the select list types only when it coerces the expression.
  defp check_item({:lazy_cut, node}, :select, columns, memo),
    do: check_item(node, :select_cut, columns, memo)

  # A call among the later results of a `CASE` keeps the planner's words for its error, found
  # with the others of the coercion (verified: a bad first result's error comes before it).
  defp check_item({:case_cut, call}, :select, columns, memo),
    do: check_item(call, :select, columns, memo)

  defp check_item({:case_cut, call}, context, columns, memo),
    do: check_item({:cut, call}, context, columns, memo)

  defp check_item({:lazy_cut, node}, context, columns, memo),
    do: check_item({:cut, node}, context, columns, memo)

  defp check_item({:null_cut, call}, context, columns, memo),
    do: check_item({:cut, call}, context, columns, memo)

  defp check_item({:constant, call, ancestors}, context, _columns, _memo),
    do: SQLConstantCall.check(call, ancestors, context)

  defp check_item({:call, function, args}, context, columns, memo) do
    nulls = Enum.map(args, &SQLNullType.null_valued?/1)
    pairs = Enum.map(args, &SQLExprType.pair(&1, columns, memo))
    types = Enum.map(pairs, &known_mix(elem(&1, 0)))

    planned = Enum.map(pairs, &known_mix(elem(&1, 1)))

    cond do
      # A tag of numbers (`coalesce(host, 1)`) is a type the functions are not checked by.
      function != :abs and Enum.any?(pairs, &tag_numbers_pair?/1) ->
        {:error,
         SQLError.refusal(
           "a function of a tag of numbers (a tag beside a number in COALESCE, GREATEST or " <>
             "LEAST): the engine's answer for it is not modelled"
         )}

      # The planner types the arguments as they are written; the type coercion types them
      # again once they are coerced, and its errors are the wrapped ones, worded by the first
      # sentence where the arguments it coerced are not the ones written (verified:
      # `sqrt(CASE WHEN true THEN 0 ELSE s END)`).
      context == :select ->
        with :ok <- SQLFunctions.check(function, planned, :select, nulls),
             do:
               if(planned == types,
                 do: :ok,
                 else: SQLFunctions.check(function, types, :select_cut, nulls)
               )

      context == :where and planned != types ->
        SQLFunctions.check(function, types, :where_cut, nulls)

      true ->
        SQLFunctions.check(function, types, context, nulls)
    end
  end

  defp check_item({:op, op, left, right}, context, columns, memo),
    do: check_arithmetic(op, left, right, context, columns, memo)

  # The first sentence of a call's error where the planning is cut.
  defp check_item({:expr_check, node}, cut, columns, memo)
       when cut in [:where_cut, :select_cut],
       do: SQLExprCheck.check(node, columns, :order_by, memo)

  defp check_item({:expr_check, node}, context, columns, memo),
    do: SQLExprCheck.check(node, columns, context, memo)

  # The engine words a negation the same wherever it stands.
  defp check_item({:neg, inner}, _context, columns, memo),
    do: check_negation(inner, columns, memo)

  defp check_item({:pos, inner}, _context, columns, memo) do
    case SQLExprType.type_of(inner, columns, memo) do
      type when type in [nil, :mixed, "Timestamp(ns)"] or is_numeric_type(type) ->
        :ok

      _not_numeric ->
        planning_error(
          "Unary operator '+' only supports numeric, interval and timestamp types",
          :select
        )
    end
  end

  defp check_item({:aggregate, agg, expr}, _context, columns, _memo),
    do: check_aggregate(agg, expr, columns)

  defp check_item(
         {:selector_check, selector, field, ordering, grouped?},
         _context,
         columns,
         _memo
       ),
       do: check_selector(selector, columns[field], columns[ordering], grouped?)

  # The errors of the plan that are no expression's: the grouping, a placeholder with no
  # value, and a `HAVING` that is no boolean (its aggregates typed by their results).
  defp check_item({:group_check, check}, _context, _columns, _memo), do: check.()
  defp check_item({:placeholder_check, error}, _context, _columns, _memo), do: {:error, error}

  defp check_item({:filter, tree, names, measurement}, _context, columns, _memo),
    do: having_filter(tree, names, measurement, columns)

  defp check_item(item, context, columns, _memo), do: check_where_item(item, context, columns)

  @spec tag_numbers_pair?({SQLExprType.type(), SQLExprType.type()}) :: boolean()
  defp tag_numbers_pair?({coerced, planned}),
    do: SQLCommonType.tag_numbers?(coerced) or SQLCommonType.tag_numbers?(planned)

  # The type of an argument of a call: one that has none (a mix of results that share no
  # type, which the check of the mix has refused or let pass) is a type not known.
  @spec known_mix(SQLExprType.type()) :: binary() | nil
  defp known_mix(:mixed), do: nil
  defp known_mix(type), do: if(SQLCommonType.tag_numbers?(type), do: nil, else: type)

  # A selector's second argument must be a timestamp (verified against Core); the first, a
  # tag, closes the connection under `selector_min` and `selector_max` where the query is not
  # grouped (a grouped one fails when a group is read, see `SQLAggregate`).
  @spec check_selector(atom(), binary() | nil, binary() | nil, boolean()) ::
          :ok | {:error, failure()}
  defp check_selector(selector, _value, ordering, _grouped?)
       when ordering not in [nil, "Timestamp(ns)"] do
    {:error,
     SQLError.planning(
       "selector_#{selector} second argument must be a timestamp, but got #{ordering}"
     )}
  end

  defp check_selector(selector, @tag, _ordering, false) when selector in [:min, :max],
    do: {:error, SQLError.closed()}

  defp check_selector(_selector, _value, _ordering, _grouped?), do: :ok

  # The plan item with the aggregates called `names` read as the null literal.
  @spec nullify(term(), [binary()]) :: term()
  defp nullify(item, []), do: item

  defp nullify({:field, name}, names) when is_binary(name),
    do: if(name in names, do: {:lit, nil}, else: {:field, name})

  defp nullify(term, names) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&nullify(&1, names)) |> List.to_tuple()

  defp nullify(terms, names) when is_list(terms), do: Enum.map(terms, &nullify(&1, names))
  defp nullify(other, _names), do: other

  # `MIN(NULL)` and `MAX(NULL)` are the null to the planner (verified against Core:
  # `MIN(NULL) + 'a'` fails as `Utf8 + Utf8` does, `MIN(NULL) + 1` is null).
  @spec null_extreme?({binary(), term()}) :: boolean()
  defp null_extreme?({_name, {:aggregate, agg, {:lit, nil}, _alias}}), do: agg in [:min, :max]
  defp null_extreme?(_agg), do: false

  @spec check_where_item(term(), SQLFunctions.context(), %{binary() => binary()}) ::
          :ok | {:error, map()}
  # A `time` compared with a number is a type error when `time` is the
  # timestamp; a CTE's column of that name that is not one is an ordinary
  # column, whose comparison the double does not model.
  defp check_where_item({:time_type, error}, _context, columns) do
    case columns do
      %{"time" => "Timestamp(ns)"} ->
        {:error, error}

      _not_a_timestamp ->
        {:error,
         SQLError.refusal(
           "a number compared with a CTE column named time that is not a timestamp: the " <>
             "engine's answer for it is not modelled"
         )}
    end
  end

  defp check_where_item({:pattern, kind, expr, rest}, context, columns),
    do: check_pattern(kind, expr, rest, context, columns)

  defp check_where_item({:compare, op, left, right}, _context, columns),
    do: check_comparison(op, left, right, columns)

  defp check_where_item({:in_list, left, values}, _context, columns),
    do: check_in_list(left, values, columns)

  defp check_where_item({:range, left, low, high}, _context, columns),
    do: check_range(left, low, high, columns)

  defp check_where_item({:logical, tree}, _context, columns) do
    case logical_type(tree, columns, :full) do
      {:error, _reason} = error -> error
      _type -> :ok
    end
  end

  # The errors of the operators and calls the planner types, and of the `AND`s and `OR`s
  # between them, in the order of the predicate, left to right (verified: `WHERE (1 AND 'a') OR
  # (n + 'a')` is the error of the `AND`, `WHERE (n + 'a') OR (1 AND 'a')` that of the sum).
  defp check_where_item({:logical_ops, tree}, _context, columns) do
    case logical_type(tree, columns, :planner) do
      {:error, _reason} = error -> error
      _type -> :ok
    end
  end

  # The type of a `WHERE` operand as the engine's type coercion sees it, the
  # innermost, leftmost operator first: a comparison, a `LIKE`, an `IN`, an
  # `IS NULL` are booleans, a lone column or literal is what it is, and the
  # operator of anything else is the error. `nil` is a type not known.
  @spec logical_type(SQLWhere.tree(), %{binary() => binary()}, :full | :planner) ::
          binary() | nil | {:error, map()}
  defp logical_type({:leaf, {:truthy, column, _nil}}, columns, _mode),
    do: Map.get(columns, column)

  defp logical_type({:leaf, {:non_boolean, _operand, {_text, type}}}, _columns, _mode), do: type

  defp logical_type({:leaf, {:truthy_expr, {:expr, {:lit, nil}}, _nil}}, _columns, _mode),
    do: "Null"

  defp logical_type({:leaf, {:truthy_expr, {:expr, expr}, _nil}}, columns, :planner) do
    case leaf_error(expr, columns) do
      :ok -> SQLExprType.type_of(expr, columns)
      {:error, _reason} = error -> error
    end
  end

  defp logical_type({:leaf, {:truthy_expr, {:expr, expr}, _nil}}, columns, :full),
    do: SQLExprType.type_of(expr, columns)

  defp logical_type({:leaf, predicate}, columns, :planner) do
    case leaf_error(predicate, columns) do
      :ok -> "Boolean"
      {:error, _reason} = error -> error
    end
  end

  defp logical_type({:leaf, _predicate}, _columns, :full), do: "Boolean"
  defp logical_type({:const, _value}, _columns, _mode), do: "Boolean"

  defp logical_type({kind, left, right}, columns, mode) when kind in [:and, :or] do
    with left_type when not is_tuple(left_type) <- logical_type(left, columns, mode),
         right_type when not is_tuple(right_type) <- logical_type(right, columns, mode) do
      cond do
        is_nil(left_type) or is_nil(right_type) ->
          nil

        left_type in @logical and right_type in @logical ->
          "Boolean"

        true ->
          logical_error("logical boolean operation #{left_type} #{word(kind)} #{right_type}")
      end
    end
  end

  # What stands under a `NOT` is cut by it (its calls word their errors by the first
  # sentence), which the items of the predicate check.
  defp logical_type({:not, _inner}, _columns, :planner), do: "Boolean"

  defp logical_type({:not, inner}, columns, :full) do
    case logical_type(inner, columns, :full) do
      "Null" -> "Boolean"
      type when type in [nil, "Boolean"] -> type
      {:error, _reason} = error -> error
      type -> logical_error("comparison operation #{type} IS DISTINCT FROM Boolean")
    end
  end

  # A shape the double does not type is a type not known, which is never refused.
  defp logical_type(_other, _columns, _mode), do: nil

  # The errors of the operators and calls of a predicate the planner types, the first of them.
  @spec leaf_error(term(), %{binary() => binary()}) :: :ok | {:error, failure()}
  defp leaf_error(expr, columns) do
    expr
    |> items()
    |> Enum.filter(&(uncut?(&1) and (planner_typed?(&1) or regex?(&1))))
    |> Enum.map(&{SQLStage.index(rank(:where, &1)), :where, &1})
    |> Enum.sort_by(&elem(&1, 0))
    |> check_items(columns, plain_mode())
  end

  @spec regex?(term()) :: boolean()
  defp regex?({:pattern, kind, _operand, _rest}), do: kind in [:regex, :not_regex]
  defp regex?(_item), do: false

  @spec word(:and | :or) :: binary()
  defp word(:and), do: "AND"
  defp word(:or), do: "OR"

  @spec logical_error(binary()) :: {:error, map()}
  defp logical_error(operation),
    do: {:error, SQLError.coercion("Cannot infer common argument type for #{operation}")}

  @spec check_arithmetic(
          atom(),
          SQLParser.expr(),
          SQLParser.expr(),
          SQLFunctions.context(),
          %{binary() => binary()},
          SQLTyped.t()
        ) :: :ok | {:error, map()}
  defp check_arithmetic(op, left, right, :select, columns, memo) do
    # The planner types the operands as they are written; the type coercion types them again
    # once they are coerced, and its errors are the wrapped ones.
    {left_coerced, left_planned} = SQLExprType.pair(left, columns, memo)
    {right_coerced, right_planned} = SQLExprType.pair(right, columns, memo)
    planned = {left_planned, right_planned}
    coerced = {left_coerced, right_coerced}

    with :ok <- arithmetic_error(op, planned, :select),
         do: if(planned == coerced, do: :ok, else: arithmetic_error(op, coerced, :where))
  end

  # A `WHERE` types the operands of an operator the planner types as they are written first.
  defp check_arithmetic(op, left, right, :where, columns, memo) do
    {left_coerced, left_planned} = SQLExprType.pair(left, columns, memo)
    {right_coerced, right_planned} = SQLExprType.pair(right, columns, memo)
    planned = {left_planned, right_planned}
    coerced = {left_coerced, right_coerced}

    with :ok <- arithmetic_error(op, planned, :where),
         do: if(planned == coerced, do: :ok, else: arithmetic_error(op, coerced, :where))
  end

  defp check_arithmetic(op, left, right, context, columns, memo) do
    {left_coerced, _left_planned} = SQLExprType.pair(left, columns, memo)
    {right_coerced, _right_planned} = SQLExprType.pair(right, columns, memo)
    arithmetic_error(op, {left_coerced, right_coerced}, context)
  end

  @spec arithmetic_error(
          atom(),
          {SQLExprType.type(), SQLExprType.type()},
          SQLFunctions.context()
        ) :: :ok | {:error, map()}
  defp arithmetic_error(op, {left, right} = types, context) do
    if tag_arithmetic?(left, right),
      do: :ok,
      else: arithmetic_typed(op, types, context)
  end

  # A tag of numbers beside a number is arithmetic the engine computes (it closes the
  # connection when a value does not read as a number).
  @spec tag_arithmetic?(SQLExprType.type(), SQLExprType.type()) :: boolean()
  defp tag_arithmetic?(left, right) do
    (SQLCommonType.tag_numbers?(left) or SQLCommonType.tag_numbers?(right)) and
      arithmetic_operand?(left) and arithmetic_operand?(right)
  end

  @spec arithmetic_operand?(SQLExprType.type()) :: boolean()
  defp arithmetic_operand?(type),
    do: type == "Null" or SQLCommonType.tag_numbers?(type) or SQLExprType.numeric?(type)

  @spec arithmetic_typed(
          atom(),
          {SQLExprType.type(), SQLExprType.type()},
          SQLFunctions.context()
        ) :: :ok | {:error, map()}
  defp arithmetic_typed(op, types, context) do
    case types do
      {"Null", type} when is_binary(type) ->
        null_operand(op, type, context)

      {type, "Null"} when is_binary(type) ->
        null_operand(op, type, context)

      {"Timestamp(ns)", "Timestamp(ns)"} when op == :- ->
        {:error,
         SQLError.refusal(
           "the difference of two timestamps: the engine answers a Duration(ns), which this " <>
             "double does not model"
         )}

      {"Timestamp(ns)", "Timestamp(ns)"} ->
        planning_error(
          "Cannot get result type for temporal operation Timestamp(ns) #{SQLExpr.symbol(op)} " <>
            "Timestamp(ns): Invalid argument error: Invalid timestamp arithmetic operation: " <>
            "Timestamp(ns) #{SQLExpr.symbol(op)} Timestamp(ns)",
          context
        )

      {left_type, right_type}
      when is_binary(left_type) and is_binary(right_type) and
             not (is_numeric_type(left_type) and is_numeric_type(right_type)) ->
        planning_error(
          "Cannot coerce arithmetic expression #{left_type} #{SQLExpr.symbol(op)} #{right_type} " <>
            "to valid types",
          context
        )

      _typed_or_unknown ->
        :ok
    end
  end

  # An operator with the null on one side: the engine types the null as the other side, so
  # a number is fine and a text or a boolean is an operation on that type with itself.
  @spec null_operand(atom(), binary(), SQLFunctions.context()) :: :ok | {:error, map()}
  defp null_operand(_op, type, _context) when type == "Null" or is_numeric_type(type), do: :ok

  # The null beside a timestamp is a timestamp: a difference of them is null, and any other
  # operator is the temporal operation the engine has no result type for.
  defp null_operand(:-, "Timestamp(ns)", _context), do: :ok

  defp null_operand(op, "Timestamp(ns)", context) do
    operation = "Timestamp(ns) #{SQLExpr.symbol(op)} Timestamp(ns)"

    planning_error(
      "Cannot get result type for temporal operation #{operation}: Invalid argument error: " <>
        "Invalid timestamp arithmetic operation: #{operation}",
      context
    )
  end

  defp null_operand(op, type, context) when type in ["Utf8", "Boolean", @tag] do
    operation = "#{type} #{SQLExpr.symbol(op)} #{type}"

    planning_error(
      "Cannot get result type for arithmetic operation #{operation}: Invalid argument error: " <>
        "Invalid arithmetic operation: #{operation}",
      context
    )
  end

  defp null_operand(_op, type, _context) do
    {:error,
     SQLError.refusal(
       "an arithmetic operator with the null beside a #{type}: the engine's error for it is " <>
         "not modelled"
     )}
  end

  # A negation takes a number that is signed, a timestamp or an interval; the null is the
  # null (`-NULL`), and a type not known is never refused.
  @spec check_negation(SQLParser.expr(), %{binary() => binary()}, SQLTyped.t()) ::
          :ok | {:error, map()}
  defp check_negation(inner, columns, memo) do
    case SQLExprType.type_of(inner, columns, memo) do
      type
      when type in [nil, :mixed, "Null", "Timestamp(ns)", "Int64", "Int32", "Int16", "Int8"] or
             type in ["Float64"] or is_decimal_type(type) ->
        :ok

      _not_signed ->
        planning_error("Negation only supports numeric, interval and timestamp types", :select)
    end
  end

  @spec check_aggregate(SQLParser.aggregate(), SQLParser.expr(), %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp check_aggregate(:sum_distinct, expr, columns), do: check_aggregate(:sum, expr, columns)

  defp check_aggregate(agg, expr, columns) do
    with :ok <- unary_plus(expr, columns) do
      case SQLExprType.type_of(expr, columns) do
        nil -> unknown_aggregate(expr)
        "Null" when agg in [:sum, :avg] -> aggregate_refusal(agg, "Null")
        "Null" -> :ok
        type when is_binary(type) -> aggregate_of(agg, type)
        :mixed -> :ok
      end
    end
  end

  # The engine reads a tag of numbers (`coalesce(host, 1)`) as the numbers it holds: every
  # aggregate takes it (it closes the connection when a value of the tag reads as no number,
  # and answers the null of an aggregate over no row), so no planning error is worded for it
  # (the `COALESCE` that made it is refused by name).
  @spec aggregate_of(SQLParser.aggregate(), binary()) :: :ok | {:error, map()}
  defp aggregate_of(agg, type) do
    if SQLCommonType.tag_numbers?(type), do: :ok, else: aggregate_refusal(agg, type)
  end

  # `count(DISTINCT +NULL)`: the unary plus is the first thing the planner finds wrong.
  @spec unary_plus(SQLParser.expr(), %{binary() => binary()}) :: :ok | {:error, failure()}
  defp unary_plus({:pos, _inner} = plus, columns),
    do: check_item(plus, :select, columns, SQLTyped.new())

  defp unary_plus(_expr, _columns), do: :ok

  # An aggregate of an expression whose type is not known: one that reads a column is the
  # column's (never refused); one that reads none is an expression the table does not type
  # (`SUM(NULL)` and `AVG(NULL)` are planning errors, verified against Core, the other
  # aggregates of a null are null).
  @spec unknown_aggregate(SQLParser.expr()) :: :ok | {:error, map()}
  defp unknown_aggregate(expr) do
    if SQLExpr.columns(expr) == [] do
      {:error,
       SQLError.refusal(
         "an aggregate of a NULL expression whose type the double does not know: the " <>
           "engine's error for it is not modelled"
       )}
    else
      :ok
    end
  end

  @spec check_pattern(
          atom(),
          SQLParser.expr(),
          term(),
          SQLFunctions.context(),
          %{binary() => binary()}
        ) :: :ok | {:error, map()}
  defp check_pattern(kind, expr, rest, context, columns) do
    case SQLExprType.known_type(expr, columns) do
      type when type in ["Boolean", "Timestamp(ns)"] or is_numeric_type(type) ->
        planning_error(pattern_error(kind, type, rest), context)

      _text_or_unknown ->
        :ok
    end
  end

  # A boolean is comparable only with a boolean: against another type the
  # comparison, the IN list and the BETWEEN have no common type.
  @spec check_comparison(atom(), SQLParser.expr(), term(), %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp check_comparison(op, left, right, columns) do
    with :ok <- boolean_comparison(op, left, right, columns),
         do: SQLDecimal.check(left, [right], columns)
  end

  @spec boolean_comparison(atom(), SQLParser.expr(), term(), %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp boolean_comparison(op, left, right, columns) do
    case {SQLExprType.known_type(left, columns, SQLTyped.new(), :plan),
          value_type(right, columns)} do
      {column, value} when is_binary(column) and is_binary(value) ->
        if boolean_mismatch?(column, value),
          do:
            {:error,
             SQLError.coercion(
               "Cannot infer common argument type for comparison operation " <>
                 "#{column} #{SQLExpr.symbol(op)} #{value}"
             )},
          else: :ok

      _unknown ->
        :ok
    end
  end

  @spec check_in_list(SQLParser.expr(), [term()], %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp check_in_list(left, values, columns) do
    with :ok <- boolean_list(left, values, columns),
         do: SQLDecimal.check(left, values, columns)
  end

  @spec boolean_list(SQLParser.expr(), [term()], %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp boolean_list(left, values, columns),
    do:
      SQLExprCheck.in_types(
        SQLExprType.type_of(left, columns),
        Enum.map(values, &list_type(&1, columns))
      )

  @spec check_range(SQLParser.expr(), term(), term(), %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp check_range(left, low, high, columns) do
    with :ok <- boolean_range(left, low, high, columns),
         do: SQLDecimal.check(left, [low, high], columns)
  end

  @spec boolean_range(SQLParser.expr(), term(), term(), %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp boolean_range(left, low, high, columns),
    do:
      SQLExprCheck.between_types(
        SQLExprType.type_of(left, columns),
        list_type(low, columns),
        list_type(high, columns)
      )

  # The type a literal has to the engine: a bound non-negative integer
  # parameter is a `UInt64`, a bare one an `Int64`. `nil` is the null, and
  # an expression's type is not known here.
  @spec value_type(term()) :: binary() | nil | :unknown
  defp value_type(nil), do: nil
  defp value_type(value) when is_boolean(value), do: "Boolean"
  defp value_type({:uint, _value}), do: "UInt64"
  defp value_type(value) when is_integer(value), do: "Int64"
  defp value_type(value) when is_float(value), do: "Float64"
  defp value_type(value) when is_binary(value), do: "Utf8"
  defp value_type(_expression), do: :unknown

  # The same, with the type of an expression read from the columns' types.
  @spec value_type(term(), %{binary() => binary()}) :: binary() | nil | :unknown
  defp value_type({:expr, expr}, columns),
    do: SQLExprType.known_type(expr, columns) || :unknown

  defp value_type(value, _columns), do: value_type(value)

  @spec boolean_mismatch?(binary(), binary()) :: boolean()
  defp boolean_mismatch?(left, right),
    do:
      left == "Boolean" != (right == "Boolean") or
        SQLNativeType.struct?(left) != SQLNativeType.struct?(right)

  # The type of an item of an `IN` list or a bound of a `BETWEEN`: `Null` for the null, and
  # anything that is no type name for a type not known.
  @spec list_type(term(), %{binary() => binary()}) :: SQLExprType.type()
  defp list_type(nil, _columns), do: "Null"
  defp list_type({:expr, expr}, columns), do: SQLExprType.type_of(expr, columns)

  defp list_type(value, _columns) do
    case value_type(value) do
      :unknown -> nil
      type -> type
    end
  end

  # In WHERE and ORDER BY the planner's message is wrapped by the type
  # coercion pass; in the select list it is not.
  @spec planning_error(binary(), SQLFunctions.context()) :: {:error, map()}
  defp planning_error(message, :select), do: {:error, SQLError.planning(message)}
  defp planning_error(message, _where_or_order_by), do: {:error, SQLError.coercion(message)}

  @doc "The engine's message for a pattern match over a column of `type`."
  @spec pattern_error(atom(), binary(), term()) :: binary()
  def pattern_error(kind, type, rest) when kind in [:like, :not_like],
    do: "There isn't a common type to coerce #{type} and Utf8 in #{like_word(rest)} expression"

  def pattern_error(_kind, type, {_regex, op}),
    do: "Cannot infer common argument type for regex operation #{type} #{op} Utf8"

  # `ILIKE` is a `LIKE` whose pattern ignores case; the engine names it in
  # its message.
  @spec like_word(term()) :: binary()
  defp like_word({:like_param, _name, true}), do: "ILIKE"

  defp like_word(%Regex{} = regex),
    do: if(:caseless in Regex.opts(regex), do: "ILIKE", else: "LIKE")

  defp like_word(_pattern), do: "LIKE"

  # COUNT, MIN and MAX take any type; the others need a number. DataFusion
  # words each family differently (verified against Core).
  @spec aggregate_refusal(SQLParser.aggregate(), binary()) :: :ok | {:error, map()}
  defp aggregate_refusal(agg, _type) when agg in [:count, :count_distinct, :min, :max], do: :ok
  defp aggregate_refusal(_agg, type) when is_numeric_type(type), do: :ok

  defp aggregate_refusal(agg, type) do
    name = Atom.to_string(agg)

    planning_error(
      aggregate_head(agg, type) <>
        " No function matches the given name and argument types '#{name}(#{type})'. " <>
        "You might need to add explicit type casts.\n\tCandidate functions:\n\t" <>
        aggregate_candidate(agg),
      :select
    )
  end

  @spec aggregate_head(SQLParser.aggregate(), binary()) :: binary()
  defp aggregate_head(:sum, type) do
    "Execution error: Function 'sum' user-defined coercion failed with " <>
      ~s|"Execution error: Sum not supported for #{unwrapped(type)}"|
  end

  defp aggregate_head(:avg, type) do
    "Execution error: Function 'avg' user-defined coercion failed with " <>
      ~s|"Error during planning: Avg does not support inputs of type #{unwrapped(type)}."|
  end

  defp aggregate_head(agg, type) do
    "Function '#{agg}' expects NativeType::Numeric but received " <>
      "NativeType::#{SQLNativeType.native(type)}"
  end

  @spec aggregate_candidate(SQLParser.aggregate()) :: binary()
  defp aggregate_candidate(agg) when agg in [:sum, :avg], do: "#{agg}(UserDefined)"
  defp aggregate_candidate(agg), do: "#{agg}(Numeric(1))"

  # A tag is dictionary encoded; the engine's messages name the type inside.
  @spec unwrapped(binary()) :: binary()
  defp unwrapped("Dictionary(Int32, Utf8)"), do: "Utf8"
  defp unwrapped(type), do: type

  # The Arrow type of the columns the checks name, as the engine has them: a
  # tag is dictionary encoded, a field typed by its values, `time` a
  # timestamp. A type is read from the first point that has the column, and
  # the scan stops once every column is known, so it costs no more than the
  # points that name them. A column no point has stays unknown, and an
  # unknown type is never refused.
  @doc """
  The Arrow types of the named columns, as the engine has them, read from the
  rows; a column no row has is left out.
  """
  @spec column_types([point()], [binary()], (binary() -> boolean())) :: %{binary() => binary()}
  def column_types(points, wanted, unsigned?) do
    pending = wanted |> MapSet.new() |> MapSet.delete("time")

    points
    |> find_types(pending, %{"time" => time_type(points)})
    |> Map.new(fn
      {column, "Int64"} -> {column, if(unsigned?.(column), do: "UInt64", else: "Int64")}
      other -> other
    end)
  end

  # `time` is a timestamp unless a CTE gave it another type.
  @spec time_type([point()]) :: binary()
  defp time_type([%{fields: %{"time" => value}} | _rest]),
    do: arrow_type(value) || "Timestamp(ns)"

  defp time_type(_points), do: "Timestamp(ns)"

  @spec find_types([point()], MapSet.t(binary()), %{binary() => binary()}) ::
          %{binary() => binary()}
  defp find_types([], _pending, found), do: found

  defp find_types([point | rest], pending, found) do
    {pending, found} =
      Enum.reduce(pending, {pending, found}, fn column, {open, known} ->
        case column_type(point, column) do
          nil -> {open, known}
          type -> {MapSet.delete(open, column), Map.put(known, column, type)}
        end
      end)

    if MapSet.size(pending) == 0, do: found, else: find_types(rest, pending, found)
  end

  @spec column_type(point(), binary()) :: binary() | nil
  defp column_type(point, column) do
    case point.tags do
      %{^column => _value} -> "Dictionary(Int32, Utf8)"
      _no_tag -> arrow_type(Map.get(point.fields, column))
    end
  end

  @doc """
  The Arrow type of a stored or computed value, or `nil` for a null.
  """
  @spec arrow_type(term()) :: binary() | nil
  def arrow_type(nil), do: nil
  def arrow_type(value) when is_boolean(value), do: "Boolean"
  def arrow_type(value) when is_integer(value), do: "Int64"
  def arrow_type(value) when is_float(value) or value in [:inf, :neg_inf, :nan], do: "Float64"
  def arrow_type({:u, _value}), do: "UInt64"
  def arrow_type({:int, bits, _value}), do: "Int#{bits}"
  def arrow_type({:dec, _coefficient, _scale}), do: @decimal
  def arrow_type(_string), do: "Utf8"
end
