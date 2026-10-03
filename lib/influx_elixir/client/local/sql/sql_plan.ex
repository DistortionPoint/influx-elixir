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
    SQLConstantCall,
    SQLDecimal,
    SQLError,
    SQLExpr,
    SQLExprCheck,
    SQLExprType,
    SQLFunctions,
    SQLNativeType,
    SQLParser,
    SQLSchema,
    SQLWhere
  }

  import SQLFunctions, only: [is_numeric_type: 1]

  @typedoc "A stored point, as `InfluxElixir.Client.Local` keeps it."
  @type point :: InfluxElixir.Client.Local.SQLRow.point()

  @decimal "Decimal128(?)"
  @tag "Dictionary(Int32, Utf8)"

  # What `AND` and `OR` accept: a boolean, or the null literal (typed `Null`).
  @logical ["Boolean", "Null"]

  # The engine checks an expression's types when it plans the query, so a
  # wrong one fails it even when no row would reach it: a function's
  # arguments, an arithmetic operator's operands, a comparison's operands, a
  # negation, an aggregate's argument, the operand of a LIKE or a regex. The
  # first problem it meets is the one it reports (verified, each pair of
  # kinds in each pair of clauses), which `rank/2` orders:
  #
  #   0. the select list's calls, operators and aggregates, which fail the
  #      plan before it is analysed, and so carry no `type_coercion` prefix
  #   1. WHERE's calls, operators, comparisons and regexes, as written
  #   2. WHERE's LIKEs, IN lists and BETWEENs, and its parts under a CAST,
  #      IS [NOT] NULL, BETWEEN, LIKE, IN or NOT (`{:cut, item}`; see
  #      `plan_items/2`), as written, then the booleans of its `AND`, `OR`, `NOT` and
  #      `IS TRUE`, which the engine checks once the calls under them have planned
  #   3. ORDER BY's calls and operators
  #   4. a negation, wherever it stands
  #
  # and within a term the innermost part comes first.
  @doc """
  The engine's first planning error in the query's expressions, or `:ok`.
  `unsigned?` says which columns are `UInt64`.
  """
  @spec check([point()], SQLParser.parsed_query(), (binary() -> boolean())) ::
          :ok | {:error, map()}
  def check(points, query, unsigned?) do
    checks =
      Enum.sort_by(
        Enum.map(select_items(query), &{:select, &1}) ++
          Enum.map(items(query.where), &{:where, &1}) ++
          logical_items(query.where_tree) ++
          Enum.map(having_items(query.having), &{:where, &1}) ++
          Enum.map(items(Enum.map(query.order_by, &elem(&1, 0))), &{:order_by, &1}),
        fn {context, item} -> rank(context, item) end
      )

    case checks do
      [] -> :ok
      _checks -> check_items(checks, column_types(points, plan_columns(checks), unsigned?))
    end
  end

  @spec rank(SQLFunctions.context(), term()) :: 0..6
  defp rank(_context, {:neg, _inner}), do: 4

  defp rank(context, {:constant, _call, ancestors}) do
    case SQLConstantCall.phase(ancestors, context) do
      :optimizer -> 5
      :bare -> 6
      _typed -> rank(context, :typed)
    end
  end

  defp rank(context, {:aggs, _aggs, item}), do: rank(context, item)
  defp rank(:select, _item), do: 0
  defp rank(:where, {:pattern, kind, _operand, _rest}) when kind in [:like, :not_like], do: 2
  defp rank(:where, {:cut, _call}), do: 2
  defp rank(:where, {:lazy_cut, _call}), do: 2
  defp rank(:where, {:null_cut, _call}), do: 2
  defp rank(:where, {:in_list, _operand, _values}), do: 2
  defp rank(:where, {:logical, _tree}), do: 2
  defp rank(:where, {:expr_check, {:is_bool, _inner, _value, _negated}}), do: 2
  defp rank(:where, {:range, _operand, _low, _high}), do: 2
  defp rank(:where, _item), do: 1
  defp rank(:order_by, _item), do: 3

  @spec select_items(SQLParser.parsed_query()) :: [term()]
  defp select_items(query) do
    projected = Enum.flat_map(query.projection_columns || [], &items(elem(&1, 0)))

    aggregated = Enum.flat_map(query.select_columns || [], &aggregate_items/1)

    having =
      Enum.flat_map((query.having && query.having.aggs) || [], &aggregate_items(elem(&1, 1)))

    projected ++ aggregated ++ having
  end

  # The parts of a `HAVING` the planner types, with the aggregates' results.
  @spec having_items(SQLAggExpr.having_t() | nil) :: [term()]
  defp having_items(nil), do: []

  defp having_items(%{nodes: nodes, aggs: aggs}) do
    for item <- items(nodes), not match?({:agg_ref, _name}, item), do: {:aggs, aggs, item}
  end

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

  defp aggregate_items(_other), do: []

  # The `AND`s, `OR`s and `NOT`s of a `WHERE`, whose operands must be
  # booleans; a `WHERE` that is one predicate has none.
  @spec logical_items(SQLWhere.tree() | nil) :: [{:where, term()}]
  defp logical_items({kind, _left, _right} = tree) when kind in [:and, :or],
    do: [{:where, {:logical, tree}}]

  defp logical_items({:not, _inner} = tree), do: [{:where, {:logical, tree}}]

  defp logical_items({:leaf, {:truthy_expr, _expr, _nil}} = tree),
    do: [{:where, {:logical, tree}}]

  defp logical_items(_tree), do: []

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
  # The state is `{function_above?, cut?}`.
  @typep state :: {boolean(), boolean()}

  # The parts of a term the planner types (see `plan_items/2`), the calls with no
  # argument among them with what stands above each.
  @spec items(term()) :: [term()]
  defp items(term), do: term |> annotate([]) |> plan_items({false, false})

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
  defp constant_operand?(operand), do: SQLExpr.columns(operand) == []

  @spec ancestor(atom()) :: :cast | :neg | :isnull | :other
  defp ancestor(:cast), do: :cast
  defp ancestor(:neg), do: :neg
  defp ancestor(tag) when tag in [:is_null, :is_not_null], do: :isnull
  defp ancestor(_tag), do: :other

  @spec plan_items(term(), state()) :: [term()]
  defp plan_items(term, state)

  defp plan_items({:constant, _call, _ancestors} = constant, _state), do: [constant]

  defp plan_items({:call, name, args} = call, {_function_above, cut} = state)
       when name in [:coalesce, :nullif],
       do: plan_items(args, state) ++ [mark({:expr_check, call}, cut)]

  defp plan_items({:cmp, _op, left, right} = node, state),
    do: plan_items([left, right], state) ++ [mark({:expr_check, node}, elem(state, 1))]

  defp plan_items({kind, left, right} = node, state) when kind in [:and, :or, :concat],
    do: plan_items([left, right], state) ++ [mark({:expr_check, node}, elem(state, 1))]

  defp plan_items({:not, inner} = node, state) when not is_list(inner),
    do: lazy(inner, state) ++ [mark({:expr_check, node}, elem(state, 1))]

  defp plan_items({:is_bool, inner, _value, _negated} = node, state),
    do: deferred(inner, state) ++ [mark({:expr_check, node}, elem(state, 1))]

  defp plan_items({:is_distinct, left, right, _negated} = node, state),
    do: plan_items([left, right], state) ++ [mark({:expr_check, node}, elem(state, 1))]

  defp plan_items(term, state), do: plan_predicate_items(term, state)

  @spec plan_predicate_items(term(), state()) :: [term()]
  defp plan_predicate_items({:in, left, items, _negated} = node, state)
       when is_list(items) and not is_nil(left),
       do:
         lazy(left, state) ++
           slot_items(left, items, state) ++ [mark({:expr_check, node}, elem(state, 1))]

  defp plan_predicate_items({:between, inner, low, high, _negated} = node, state),
    do:
      lazy(inner, state) ++
        slot_items(inner, [low, high], state) ++ [mark({:expr_check, node}, elem(state, 1))]

  defp plan_predicate_items({:like, inner, pattern, _negated, _ilike, _regex} = node, state),
    do:
      lazy(inner, state) ++
        slot_items(inner, pattern, state) ++ [mark({:expr_check, node}, elem(state, 1))]

  defp plan_predicate_items({:case, operand, whens, otherwise} = node, state) do
    conditions = List.wrap(operand) ++ Enum.map(whens, &elem(&1, 0))
    [first | later] = Enum.map(whens, &elem(&1, 1))

    deferred(conditions, state) ++
      plan_items(first, state) ++
      lazy(later ++ List.wrap(otherwise), state) ++
      [mark({:expr_check, node}, elem(state, 1))]
  end

  defp plan_predicate_items({:call, _function, args} = call, {_function_above, cut}),
    do: plan_items(args, {true, cut}) ++ [mark(call, cut)]

  defp plan_predicate_items({:cast, inner, _type} = node, {function_above, cut}),
    do:
      plan_items(inner, {function_above, cut or not function_above}) ++
        [mark({:expr_check, node}, cut)]

  defp plan_predicate_items({:op, _op, left, right} = op, state),
    do: plan_items(left, state) ++ plan_items(right, state) ++ [mark(op, elem(state, 1))]

  defp plan_predicate_items({:neg, inner} = neg, state), do: plan_items(inner, state) ++ [neg]

  defp plan_predicate_items({:field, name}, _state) when is_binary(name),
    do: if(SQLAggExpr.placeholder?(name), do: [{:agg_ref, name}], else: [])

  defp plan_predicate_items(term, state), do: plan_condition_items(term, state)

  @spec plan_condition_items(term(), state()) :: [term()]
  defp plan_condition_items({kind, left, rest}, {function_above, _cut})
       when kind in [:like, :not_like, :regex, :not_regex] do
    operand = operand_expr(left)
    plan_items(operand, {function_above, true}) ++ [{:pattern, kind, operand, rest}]
  end

  defp plan_condition_items({op, left, right}, state) when op in @comparisons and left != "time",
    do:
      plan_items(left, state) ++
        plan_items(right, state) ++
        [mark({:compare, op, operand_expr(left), right}, elem(state, 1))]

  defp plan_condition_items({op, left, values}, {function_above, _cut})
       when op in [:in, :not_in] and left != "time",
       do:
         plan_items(left, {function_above, true}) ++
           plan_items(values, {function_above, true}) ++ [{:in_list, operand_expr(left), values}]

  defp plan_condition_items({op, left, {low, high}}, {function_above, _cut})
       when op in [:between, :not_between] and left != "time",
       do:
         plan_items(left, {function_above, true}) ++
           plan_items([low, high], {function_above, true}) ++
           [{:range, operand_expr(left), low, high}]

  defp plan_condition_items({op, left, _nil}, {function_above, _cut})
       when op in [:is_null, :is_not_null],
       do: left |> plan_items({function_above, true}) |> Enum.map(&null_mark/1)

  defp plan_condition_items({:not, nodes}, {function_above, _cut}),
    do: plan_items(nodes, {function_above, true})

  defp plan_condition_items({:time_type_error, "time", error}, _state), do: [{:time_type, error}]

  defp plan_condition_items(terms, state) when is_list(terms),
    do: Enum.flat_map(terms, &plan_items(&1, state))

  defp plan_condition_items(term, state) when is_tuple(term),
    do: term |> Tuple.to_list() |> plan_items(state)

  defp plan_condition_items(_other, _state), do: []

  # The parts the planner types only when it coerces the expression are cut like
  # what stands under an `IS [NOT] NULL`.
  @spec deferred(term(), state()) :: [term()]
  defp deferred(parts, {function_above, _cut}),
    do: parts |> plan_items({function_above, true}) |> Enum.map(&null_mark/1)

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
  defp lazy(parts, {function_above, _cut}),
    do: parts |> plan_items({function_above, true}) |> Enum.map(&lazy_mark/1)

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

  @spec mark(term(), boolean()) :: term()
  defp mark(item, true), do: {:cut, item}
  defp mark(item, false), do: item

  @spec operand_expr(SQLParser.operand()) :: SQLParser.expr()
  defp operand_expr({:expr, expr}), do: expr
  defp operand_expr(column), do: {:field, column}

  @spec plan_columns([{SQLFunctions.context(), term()}]) :: [binary()]
  defp plan_columns(checks),
    do: Enum.flat_map(checks, fn {_context, item} -> SQLSchema.expr_fields(item) end)

  @spec check_items([{SQLFunctions.context(), term()}], %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp check_items(checks, columns) do
    Enum.reduce_while(checks, :ok, fn {context, item}, :ok ->
      case item |> check_item(context, columns) |> decimal_guard() do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # An error that would print a decimal's type cannot be worded: the
  # precision of an `Int64` with a `UInt64` is not tracked.
  @spec decimal_guard(:ok | {:error, map()}) :: :ok | {:error, map()}
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

  defp decimal_guard(:ok), do: :ok

  @spec check_item(term(), SQLFunctions.context(), %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp check_item({:cut, call}, :where, columns), do: check_item(call, :where_cut, columns)
  defp check_item({:cut, call}, context, columns), do: check_item(call, context, columns)

  # Only an IS NULL cuts the error of a call in the select list (verified against Core: a
  # CAST, BETWEEN, IN, LIKE or NOT there leaves the planner's whole message).
  defp check_item({:null_cut, call}, :select, columns),
    do: check_item(call, :select_cut, columns)

  # An operator the select list types only when it coerces the expression.
  defp check_item({:lazy_cut, node}, :select, columns),
    do: check_item(node, :select_cut, columns)

  defp check_item({:lazy_cut, node}, context, columns),
    do: check_item({:cut, node}, context, columns)

  defp check_item({:null_cut, call}, context, columns),
    do: check_item({:cut, call}, context, columns)

  # The parts of an expression over aggregates are typed with the aggregates'
  # results. `MIN(NULL)` and `MAX(NULL)` are the null to the planner (verified against
  # Core: `MIN(NULL) + 'a'` fails as `Utf8 + Utf8` does, `MIN(NULL) + 1` is null).
  defp check_item({:aggs, aggs, item}, context, columns) do
    nulls = for {name, _column} = agg <- aggs, null_extreme?(agg), do: name

    check_item(
      nullify(item, nulls),
      context,
      Map.merge(columns, SQLAggType.types(aggs, columns))
    )
  end

  defp check_item({:constant, call, ancestors}, context, _columns),
    do: SQLConstantCall.check(call, ancestors, context)

  defp check_item({:call, function, args}, context, columns) do
    types = Enum.map(args, &argument_type(function, &1, columns))
    SQLFunctions.check(function, types, context)
  end

  defp check_item({:op, op, left, right}, context, columns),
    do: check_arithmetic(op, left, right, context, columns)

  # The first sentence of a call's error where the planning is cut.
  defp check_item({:expr_check, node}, cut, columns) when cut in [:where_cut, :select_cut],
    do: SQLExprCheck.check(node, columns, :order_by)

  defp check_item({:expr_check, node}, context, columns),
    do: SQLExprCheck.check(node, columns, context)

  # The engine words a negation the same wherever it stands.
  defp check_item({:neg, inner}, _context, columns), do: check_negation(inner, columns)

  defp check_item({:aggregate, agg, expr}, _context, columns),
    do: check_aggregate(agg, expr, columns)

  defp check_item(item, context, columns), do: check_where_item(item, context, columns)

  # The `NULL` literal has the type `Null` to the functions whose signatures coerce it with the
  # other arguments (`left(NULL, 1.5)` is a type error); to any other it is a type not known.
  @spec argument_type(atom(), SQLExpr.t(), %{binary() => binary()}) :: binary() | nil
  defp argument_type(function, {:lit, nil}, _columns)
       when function in [:left, :right, :starts_with],
       do: "Null"

  defp argument_type(_function, arg, columns), do: SQLExprType.type_of(arg, columns)

  # The plan item with the aggregates called `names` read as the null literal.
  @spec nullify(term(), [binary()]) :: term()
  defp nullify({:field, name}, names) when is_binary(name),
    do: if(name in names, do: {:lit, nil}, else: {:field, name})

  defp nullify(term, names) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&nullify(&1, names)) |> List.to_tuple()

  defp nullify(terms, names) when is_list(terms), do: Enum.map(terms, &nullify(&1, names))
  defp nullify(other, _names), do: other

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
    case logical_type(tree, columns) do
      {:error, _reason} = error -> error
      _type -> :ok
    end
  end

  # The type of a `WHERE` operand as the engine's type coercion sees it, the
  # innermost, leftmost operator first: a comparison, a `LIKE`, an `IN`, an
  # `IS NULL` are booleans, a lone column or literal is what it is, and the
  # operator of anything else is the error. `nil` is a type not known.
  @spec logical_type(SQLWhere.tree(), %{binary() => binary()}) ::
          binary() | nil | {:error, map()}
  defp logical_type({:leaf, {:truthy, column, _nil}}, columns), do: Map.get(columns, column)
  defp logical_type({:leaf, {:non_boolean, _operand, {_text, type}}}, _columns), do: type

  defp logical_type({:leaf, {:truthy_expr, {:expr, {:lit, nil}}, _nil}}, _columns), do: "Null"

  defp logical_type({:leaf, {:truthy_expr, {:expr, expr}, _nil}}, columns),
    do: SQLExprType.type_of(expr, columns)

  defp logical_type({:leaf, _predicate}, _columns), do: "Boolean"
  defp logical_type({:const, _value}, _columns), do: "Boolean"

  defp logical_type({kind, left, right}, columns) when kind in [:and, :or] do
    with left_type when not is_tuple(left_type) <- logical_type(left, columns),
         right_type when not is_tuple(right_type) <- logical_type(right, columns) do
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

  defp logical_type({:not, inner}, columns) do
    case logical_type(inner, columns) do
      "Null" -> "Boolean"
      type when type in [nil, "Boolean"] -> type
      {:error, _reason} = error -> error
      type -> logical_error("comparison operation #{type} IS DISTINCT FROM Boolean")
    end
  end

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
          %{binary() => binary()}
        ) :: :ok | {:error, map()}
  defp check_arithmetic(op, left, right, context, columns) do
    case {arithmetic_type(left, columns), arithmetic_type(right, columns)} do
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

  # The type of an operand of an arithmetic operator: the null literal is `Null` (which the
  # engine coerces to the other operand's type), and an operation over it has the type of
  # its other side.
  @spec arithmetic_type(SQLParser.expr(), %{binary() => binary()}) :: binary() | nil | :mixed
  defp arithmetic_type({:lit, nil}, _columns), do: "Null"

  defp arithmetic_type({:op, _op, left, right} = expr, columns) do
    case {arithmetic_type(left, columns), arithmetic_type(right, columns)} do
      {"Null", "Null"} -> "Null"
      {"Null", type} -> if is_numeric_type(type), do: type, else: nil
      {type, "Null"} -> if is_numeric_type(type), do: type, else: nil
      _typed -> SQLExprType.type_of(expr, columns)
    end
  end

  defp arithmetic_type(expr, columns), do: SQLExprType.type_of(expr, columns)

  # An operator with the null on one side: the engine types the null as the other side, so
  # a number is fine and a text or a boolean is an operation on that type with itself.
  @spec null_operand(atom(), binary(), SQLFunctions.context()) :: :ok | {:error, map()}
  defp null_operand(_op, type, _context) when type == "Null" or is_numeric_type(type), do: :ok

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

  @spec check_negation(SQLParser.expr(), %{binary() => binary()}) :: :ok | {:error, map()}
  defp check_negation(inner, columns) do
    case SQLFunctions.type_of(inner, columns) do
      type
      when type in [nil, "Timestamp(ns)", "Int64", "Int32", "Int16", "Int8", "Float64", @decimal] ->
        :ok

      _not_signed ->
        planning_error("Negation only supports numeric, interval and timestamp types", :select)
    end
  end

  @spec check_aggregate(SQLParser.aggregate(), SQLParser.expr(), %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp check_aggregate(agg, expr, columns) do
    case SQLExprType.type_of(expr, columns) do
      nil -> null_aggregate(agg, expr)
      type when is_binary(type) -> aggregate_refusal(agg, type)
      :mixed -> :ok
    end
  end

  # `SUM(NULL)` and `AVG(NULL)` are planning errors (verified against Core); the
  # other aggregates of a null are null.
  @spec null_aggregate(SQLParser.aggregate(), SQLParser.expr()) :: :ok | {:error, map()}
  defp null_aggregate(agg, {:lit, nil}) when agg in [:sum, :avg],
    do: aggregate_refusal(agg, "Null")

  defp null_aggregate(_agg, _expr), do: :ok

  @spec check_pattern(
          atom(),
          SQLParser.expr(),
          term(),
          SQLFunctions.context(),
          %{binary() => binary()}
        ) :: :ok | {:error, map()}
  defp check_pattern(kind, expr, rest, context, columns) do
    case SQLFunctions.type_of(expr, columns) do
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
    case {SQLFunctions.type_of(left, columns), value_type(right)} do
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
  defp boolean_list(left, values, columns) do
    types = Enum.map(values, &value_type(&1, columns))

    with column when is_binary(column) <- SQLFunctions.type_of(left, columns),
         true <- Enum.all?(types, &(&1 != :unknown)),
         true <- Enum.any?(types, &(&1 != nil and boolean_mismatch?(column, &1))) do
      names = Enum.map_join(types, ", ", &(&1 || "Null"))

      {:error,
       SQLError.coercion("Can not find compatible types to compare #{column} with [#{names}]")}
    else
      _compatible_or_unknown -> :ok
    end
  end

  @spec check_range(SQLParser.expr(), term(), term(), %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp check_range(left, low, high, columns) do
    with :ok <- boolean_range(left, low, high, columns),
         do: SQLDecimal.check(left, [low, high], columns)
  end

  @spec boolean_range(SQLParser.expr(), term(), term(), %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp boolean_range(left, low, high, columns) do
    with column when is_binary(column) <- SQLFunctions.type_of(left, columns),
         bound when is_binary(bound) <-
           Enum.find(
             [value_type(low, columns), value_type(high, columns)],
             &boolean_mismatch_with?(column, &1)
           ) do
      {:error, SQLError.between_coercion(column, bound)}
    else
      _compatible_or_unknown -> :ok
    end
  end

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
  defp value_type({:expr, expr}, columns), do: SQLFunctions.type_of(expr, columns) || :unknown
  defp value_type(value, _columns), do: value_type(value)

  @spec boolean_mismatch?(binary(), binary()) :: boolean()
  defp boolean_mismatch?(left, right),
    do:
      left == "Boolean" != (right == "Boolean") or
        SQLExprType.struct?(left) != SQLExprType.struct?(right)

  @spec boolean_mismatch_with?(binary(), binary() | nil | :unknown) :: boolean()
  defp boolean_mismatch_with?(column, type) when is_binary(type),
    do: boolean_mismatch?(column, type)

  defp boolean_mismatch_with?(_column, _null_or_unknown), do: false

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
