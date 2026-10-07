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
  # `UInt64`) has the precision `InfluxElixir.Client.Local.SQLDecimal` knows for the shapes it
  # models; an error that would print the type of one whose precision is not known is refused by
  # name (`Decimal128(?)`).
  #
  # The parts a term is checked in come from `InfluxElixir.Client.Local.SQLPlanItems`, the
  # order the engine finds the errors in from `InfluxElixir.Client.Local.SQLStage`, and the
  # negations it never plans from `InfluxElixir.Client.Local.SQLPrune`.

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
    SQLPlanItems,
    SQLPredicate,
    SQLPrune,
    SQLSchema,
    SQLSelect,
    SQLStage,
    SQLTime,
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
          placeholder: nil | failure(),
          limit: nil | failure(),
          ordinal: nil | failure(),
          unused: SQLPrune.marks() | nil
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
      :ok when duration? -> {:error, duration_refusal("a place the check does not walk")}
      outcome -> outcome
    end
  end

  @doc """
  `:ok` for the outcome of `check/4` unless it is an error of the engine's physical plan, which
  is found after every error of the optimizer and of the scan: the caller holds that one, runs
  what is left of its checks, and answers it only if they find nothing.
  """
  @spec unless_physical(:ok | {:error, failure()}) :: :ok | {:error, failure()}
  def unless_physical(
        {:error, %{body: "Error during planning: Negation only supports" <> _rest}}
      ),
      do: :ok

  def unless_physical(outcome), do: outcome

  @spec duration_refusal(binary()) :: map()
  defp duration_refusal(use) do
    SQLError.refusal(
      "a difference of a null and time used in #{use}: the engine types it as a " <>
        "Duration(ns), and its error for that use is not modelled"
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
      (Enum.map(select_items(query), &select_check/1) ++
         Enum.map(SQLPlanItems.planned_items(query.where), &{:where, &1}) ++
         logical_items(query.where_tree) ++
         having_items(query) ++
         plan_gates(query, options) ++
         Enum.map(SQLPlanItems.planned_items(ordered_terms(query)), &{:order_by, &1}))
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
           do:
             check_items(checks, columns, %{
               duration?: duration?,
               prune: prune(points, query, unsigned?, Keyword.get(options, :unused))
             })
    end
  end

  # The negations the engine never meets, whose errors are dropped (see `SQLPrune`): asked
  # about only for a negation that fails, so a query without one pays nothing.
  @spec prune(
          [point()],
          SQLParser.parsed_query(),
          (binary() -> boolean()),
          SQLPrune.marks() | nil
        ) ::
          (term() -> SQLPrune.verdict())
  defp prune(points, query, unsigned?, unused) do
    types = fn names -> column_types(points, names, unsigned?) end
    fn item -> SQLPrune.verdict(item, query, types, unused) end
  end

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

    limit =
      case Keyword.get(options, :limit) do
        nil -> []
        error -> [{:select, {:limit_check, error}}]
      end

    ordinal =
      case Keyword.get(options, :ordinal) do
        nil -> []
        error -> [{:select, {:ordinal_check, error}}]
      end

    group ++ placeholder ++ limit ++ ordinal
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
      |> SQLPlanItems.items()
      |> Enum.filter(&SQLPlanItems.planner_typed?/1)
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
  defp rank(:aggregate, item), do: rank(:select, item)
  defp rank(:select, {:planned, _item}), do: :select_built_concat
  defp rank(:order_by, {:planned, _item}), do: :order_built
  defp rank(_context, {kind, _inner}) when kind in [:neg, :pos], do: :negation
  defp rank(:select, {:group_check, _check}), do: :group
  defp rank(:select, {:placeholder_check, _error}), do: :placeholder
  defp rank(:select, {:limit_check, _error}), do: :limit_coerced
  defp rank(:select, {:ordinal_check, _error}), do: :order_ordinal

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

  # The context of a select item: the argument of an aggregate is typed with the aggregate,
  # below the `HAVING`, the rest of the select list above it.
  @spec select_check(term()) :: {:select | :aggregate, term()}
  defp select_check({:argument, item}), do: {:aggregate, item}
  defp select_check(item), do: {:select, item}

  @spec select_items(SQLParser.parsed_query()) :: [term()]
  defp select_items(query) do
    projected =
      Enum.flat_map(query.projection_columns || [], &SQLPlanItems.planned_items(elem(&1, 0)))

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
    parts = for item <- SQLPlanItems.items(nodes), not match?({:agg_ref, _name}, item), do: item
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
    do: Enum.map(SQLPlanItems.items(expr), &{:argument, &1}) ++ [{:aggregate, agg, expr}]

  # The items of an expression over aggregates in the order the engine meets
  # them: each aggregate where its call stands, and the expression's parts
  # typed with the aggregates' results.
  defp aggregate_items({:expression, expr, aggs, _alias}) do
    by_name = Map.new(aggs)
    parts = SQLPlanItems.items(expr)

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
  defp item_fields({:limit_check, _error}), do: []
  defp item_fields({:ordinal_check, _error}), do: []

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
  @typep plan_context :: SQLFunctions.context() | :where_plan | :aggregate

  # How the items are checked: whether a use of a duration ends the check (see `duration_use?/1`),
  # and which negations the engine never meets (see `prune/3`).
  @typep mode :: %{duration?: boolean(), prune: (term() -> SQLPrune.verdict())}

  @spec plain_mode() :: mode()
  defp plain_mode, do: %{duration?: false, prune: fn _item -> :keep end}

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

  defp check_next({_rank, :aggregate, item}, state, columns, mode),
    do: check_item_next(:select, true, item, state, columns, mode)

  defp check_next({_rank, context, item}, state, columns, mode),
    do: check_item_next(context, false, item, state, columns, mode)

  defp check_item_next(context, aggregate?, item, {deferred, scopes}, columns, mode) do
    coerced? = context == :select and elem(item, 0) in [:lazy_cut, :null_cut, :case_cut]
    {key, item, scope} = enter(item, columns, scopes, context)
    {scope_columns, memo, _nulls} = scope

    # The engine's error for a use of a duration is its own and is found where the use stands,
    # so the double's refusal for it ends the check there (it is not one of the refusals that
    # stand with the errors of the type coercion).
    use = if mode.duration?, do: duration_use(item)

    if use do
      {:halt, {:done, {:error, duration_refusal(use)}}}
    else
      outcome = item |> check_item(context, scope_columns, memo) |> decimal_guard()
      outcome = pruned(outcome, item, mode)
      scopes = List.keystore(scopes, key, 0, {key, remember(item, scope)})
      continue(outcome, {context, coerced?, aggregate?}, deferred, scopes)
    end
  end

  # The error of a negation the engine never meets is dropped; where whether it meets it is not
  # known, the double refuses.
  @spec pruned(:ok | {:error, failure()}, term(), mode()) :: :ok | {:error, failure()}
  defp pruned({:error, _error} = outcome, {:neg, _inner} = item, mode) do
    case mode.prune.(item) do
      :keep -> outcome
      :drop -> :ok
      {:unknown, cause} -> {:error, unknown_prune(cause)}
    end
  end

  defp pruned(outcome, _item, _mode), do: outcome

  @spec unknown_prune(SQLPrune.cause()) :: map()
  defp unknown_prune(:literals) do
    SQLError.refusal(
      "a negation that fails beside equalities of one expression to literals of a kind not " <>
        "modelled: whether the engine proves the query empty before it plans the negation is " <>
        "not known"
    )
  end

  defp unknown_prune(:time_null), do: not_proved("a test of time for NULL (time is never null)")

  defp unknown_prune(:null_list),
    do: not_proved("a NULL in an IN list, beside a clause the engine folds it with")

  defp unknown_prune(:not_in), do: not_proved("a NOT IN list and another test of its operand")

  defp unknown_prune(:respelled),
    do: not_proved("an IN list that writes one value in two spellings (IN (1, '1'))")

  defp unknown_prune(:float),
    do: not_proved("an integer equal to a float and to something else, with a third test")

  defp unknown_prune(:late_conflict),
    do:
      not_proved(
        "an expression compared to different values, the first conjunct being none of them"
      )

  defp unknown_prune(:nested) do
    SQLError.refusal(
      "a negation that fails beside two IN lists of one operand where the second starts a " <>
        "nested AND: whether the engine folds them, and so proves the query empty before it " <>
        "plans the negation, is not known"
    )
  end

  defp unknown_prune(:grouped) do
    SQLError.refusal(
      "a negation that fails beside an operand that the conjunction and an OR or NOT of it " <>
        "both test: whether the engine folds them, and so proves the query empty before it " <>
        "plans the negation, is not known"
    )
  end

  defp unknown_prune(:outer) do
    SQLError.refusal(
      "a negation in a common table expression beside a query that may fold its WHERE to " <>
        "nothing, which the double cannot tell without the types of the expression's columns: " <>
        "whether the engine plans the expression is not known"
    )
  end

  # What the refusals of a negation that fails beside a shape the double has no rule for share.
  @spec not_proved(binary()) :: map()
  defp not_proved(beside) do
    SQLError.refusal(
      "a negation that fails beside #{beside}: whether the engine proves the query empty " <>
        "before it plans the negation is not known"
    )
  end

  # `coerced?` says the item stands where the planner types it only when it coerces the

  # expression (under a lazy or null cut of the select list): every error it has, the
  # double's refusals too, is found by the type coercion.
  @spec continue(
          :ok | {:error, failure()},
          {plan_context(), boolean(), boolean()},
          deferred(),
          scopes()
        ) :: {:cont, {deferred(), scopes()}} | {:halt, {:done, term()}}
  defp continue(:ok, _where, deferred, scopes), do: {:cont, {deferred, scopes}}

  defp continue({:error, error} = outcome, {context, coerced?, aggregate?}, deferred, scopes) do
    case {position(error, context), coerced?} do
      {nil, false} ->
        {:halt, {:done, outcome}}

      {nil, true} ->
        {:cont, {defer(deferred, :select_coerced, outcome), scopes}}

      {:select_coerced, _coerced?} when aggregate? ->
        {:cont, {defer(deferred, :aggregate_coerced, outcome), scopes}}

      {position, _coerced?} ->
        {:cont, {defer(deferred, position, outcome), scopes}}
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
  @spec enter(term(), %{binary() => binary()}, scopes(), plan_context()) ::
          {term(), term(), scope()}
  defp enter({:aggs, aggs, item}, columns, scopes, context) do
    # A `HAVING` is built over the aggregates' output, which the engine has typed already: it
    # sees the type coercion's types of them, not the planner's.
    key = if context == :where, do: {:having, aggs}, else: aggs

    scope =
      case List.keyfind(scopes, key, 0) do
        {_key, scope} ->
          scope

        nil ->
          nulls = for {name, _column} = agg <- aggs, null_extreme?(agg), do: name
          {Map.merge(columns, aggregate_types(aggs, columns, context)), SQLTyped.new(), nulls}
      end

    {key, nullify(item, elem(scope, 2)), scope}
  end

  defp enter(item, columns, scopes, _context) do
    scope =
      case List.keyfind(scopes, :base, 0) do
        {:base, scope} -> scope
        nil -> {columns, SQLTyped.new(), []}
      end

    {:base, item, scope}
  end

  @spec aggregate_types([{binary(), term()}], %{binary() => binary()}, plan_context()) ::
          %{binary() => binary()}
  defp aggregate_types(aggs, columns, context) do
    types = SQLAggType.types(aggs, columns)

    if context == :where,
      do: Map.reject(types, fn {name, _type} -> SQLAggType.plan_key?(name) end),
      else: types
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

  # What an item does with the difference of a null and `time` (`time - NULL`), which the engine
  # types as a `Duration(ns)`: the error of each use is its own, and not modelled. `nil` for an
  # item that does not use one.
  @spec duration_use(term()) :: binary() | nil
  defp duration_use({wrapper, item})
       when wrapper in [:cut, :lazy_cut, :null_cut, :case_cut, :planned],
       do: duration_use(item)

  defp duration_use({:aggs, _aggs, item}), do: duration_use(item)

  defp duration_use({:expr_check, node}),
    do: if(Enum.any?(SQLExpr.children(node), &duration?/1), do: node_use(node))

  defp duration_use({:aggregate, agg, expr}),
    do: if(duration?(expr), do: "the aggregate #{agg}")

  defp duration_use({:compare, _op, left, right}),
    do: if(Enum.any?([left, right], &duration?/1), do: "a comparison")

  defp duration_use({:pattern, _kind, expr, _rest}),
    do: if(duration?(expr), do: "a LIKE or a regular expression")

  defp duration_use({:in_list, left, values}),
    do: if(Enum.any?([left | values], &duration?/1), do: "an IN list")

  defp duration_use({:range, left, low, high}),
    do: if(Enum.any?([left, low, high], &duration?/1), do: "a BETWEEN")

  defp duration_use({kind, _first} = node) when kind in [:neg, :pos],
    do: if(Enum.any?(SQLExpr.children(node), &duration?/1), do: "a sign")

  defp duration_use({:op, _op, _left, _right} = node),
    do: if(Enum.any?(SQLExpr.children(node), &duration?/1), do: node_use(node))

  defp duration_use({:call, _name, _args} = node),
    do: if(Enum.any?(SQLExpr.children(node), &duration?/1), do: node_use(node))

  defp duration_use(_item), do: nil

  @spec node_use(tuple()) :: binary()
  defp node_use({:op, op, _left, _right}), do: "the operator #{op}"
  defp node_use({:call, name, _args}), do: "the function #{name}"
  defp node_use({:cmp, _op, _left, _right}), do: "a comparison"
  defp node_use({kind, _left, _right}) when kind in [:and, :or], do: "AND or OR"
  defp node_use({:concat, _left, _right}), do: "||"
  defp node_use({:not, _inner}), do: "NOT"
  defp node_use({:cast, _inner, _type}), do: "a CAST"
  defp node_use({:case, _operand, _whens, _otherwise}), do: "a CASE"
  defp node_use({:is_bool, _inner, _value, _negated}), do: "IS TRUE or IS FALSE"
  defp node_use({:is_distinct, _left, _right, _negated}), do: "IS DISTINCT FROM"
  defp node_use({:in, _inner, _items, _negated}), do: "an IN list"
  defp node_use({:between, _inner, _low, _high, _negated}), do: "a BETWEEN"
  defp node_use({:like, _inner, _pattern, _negated, _ilike, _regex}), do: "a LIKE"
  defp node_use(_node), do: "another expression"

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
  defp check_item({:limit_check, error}, _context, _columns, _memo), do: {:error, error}
  defp check_item({:ordinal_check, error}, _context, _columns, _memo), do: {:error, error}

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
    |> SQLPlanItems.items()
    |> Enum.filter(&(uncut?(&1) and (SQLPlanItems.planner_typed?(&1) or regex?(&1))))
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
        cond do
          boolean_mismatch?(column, value) ->
            {:error,
             SQLError.coercion(
               "Cannot infer common argument type for comparison operation " <>
                 "#{column} #{SQLExpr.symbol(op)} #{value}"
             )}

          column == "Timestamp(ns)" and is_binary(right) ->
            timestamp_text(right)

          true ->
            :ok
        end

      _unknown ->
        :ok
    end
  end

  @spec check_in_list(SQLParser.expr(), [term()], %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp check_in_list(left, values, columns) do
    with :ok <- boolean_list(left, values, columns),
         :ok <- timestamp_texts(left, values, columns),
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
         :ok <- timestamp_texts(left, [low, high], columns),
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

  defp value_type(value) when is_integer(value) and value > 9_223_372_036_854_775_807,
    do: if(value <= 18_446_744_073_709_551_615, do: "UInt64", else: "Float64")

  defp value_type(value) when is_integer(value) and value < -9_223_372_036_854_775_808,
    do: "Float64"

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
        SQLNativeType.struct?(left) != SQLNativeType.struct?(right) or
        timestamp_and_number?(left, right)

  # A number has no order against a timestamp (verified: `max(time) > 5`, `max(time) > count(*)`
  # and `5 < min(time)` are all the type error).
  @spec timestamp_and_number?(binary(), binary()) :: boolean()
  defp timestamp_and_number?(left, right) do
    numbers = ["Int64", "UInt64", "Float64"]

    ("Timestamp(ns)" == left and right in numbers) or
      ("Timestamp(ns)" == right and left in numbers)
  end

  @spec timestamp_texts(SQLParser.expr(), [term()], %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp timestamp_texts(left, values, columns) do
    if SQLExprType.known_type(left, columns, SQLTyped.new(), :plan) == "Timestamp(ns)" do
      values
      |> Enum.filter(&is_binary/1)
      |> Enum.find_value(:ok, fn text ->
        case timestamp_text(text) do
          :ok -> nil
          error -> error
        end
      end)
    else
      :ok
    end
  end

  # A text beside a timestamp that is not the column `time` is read by the engine as a
  # timestamp; one it cannot read is the optimizer's error, which comes after the planner's.
  @spec timestamp_text(binary()) :: :ok | {:error, map()}
  defp timestamp_text(text) do
    case SQLTime.param(text) do
      {:invalid_time, _error} ->
        {:error,
         SQLError.refusal(
           "a text the engine cannot read as a timestamp, beside a timestamp that is not the " <>
             "column time: the optimizer's error for it comes after the planner's"
         )}

      _instant ->
        :ok
    end
  end

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

  def pattern_error(_kind, type, {_regex, op, _guard}),
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
