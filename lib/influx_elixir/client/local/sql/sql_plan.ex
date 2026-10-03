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
    SQLDecimal,
    SQLError,
    SQLExpr,
    SQLFunctions,
    SQLParser,
    SQLPredicate,
    SQLSchema
  }

  import SQLFunctions, only: [is_numeric_type: 1]

  @typedoc "A stored point, as `InfluxElixir.Client.Local` keeps it."
  @type point :: InfluxElixir.Client.Local.SQLRow.point()

  @decimal "Decimal128(?)"

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
  #      `plan_items/2`), as written
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
          Enum.map(plan_items(query.where), &{:where, &1}) ++
          Enum.map(plan_items(Enum.map(query.order_by, &elem(&1, 0))), &{:order_by, &1}),
        fn {context, item} -> rank(context, item) end
      )

    case checks do
      [] -> :ok
      _checks -> check_items(checks, column_types(points, plan_columns(checks), unsigned?))
    end
  end

  @spec rank(SQLFunctions.context(), term()) :: 0..4
  defp rank(_context, {:neg, _inner}), do: 4
  defp rank(:select, _item), do: 0
  defp rank(:where, {:pattern, kind, _operand, _rest}) when kind in [:like, :not_like], do: 2
  defp rank(:where, {:cut, _call}), do: 2
  defp rank(:where, {:in_list, _operand, _values}), do: 2
  defp rank(:where, {:range, _operand, _low, _high}), do: 2
  defp rank(:where, _item), do: 1
  defp rank(:order_by, _item), do: 3

  @spec select_items(SQLParser.parsed_query()) :: [term()]
  defp select_items(query) do
    projected = Enum.flat_map(query.projection_columns || [], &plan_items(elem(&1, 0)))

    aggregated =
      Enum.flat_map(query.select_columns || [], fn
        {:aggregate, agg, expr, _alias} -> plan_items(expr) ++ [{:aggregate, agg, expr}]
        _other -> []
      end)

    projected ++ aggregated
  end

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

  @spec plan_items(term(), state()) :: [term()]
  defp plan_items(term, state \\ {false, false})

  defp plan_items({:call, _function, args} = call, {_function_above, cut}),
    do: plan_items(args, {true, cut}) ++ [mark(call, cut)]

  defp plan_items({:cast, inner, _type}, {function_above, cut}),
    do: plan_items(inner, {function_above, cut or not function_above})

  defp plan_items({:op, _op, left, right} = op, state),
    do: plan_items(left, state) ++ plan_items(right, state) ++ [mark(op, elem(state, 1))]

  defp plan_items({:neg, inner} = neg, state), do: plan_items(inner, state) ++ [neg]

  defp plan_items({kind, left, rest}, {function_above, _cut})
       when kind in [:like, :not_like, :regex, :not_regex] do
    operand = operand_expr(left)
    plan_items(operand, {function_above, true}) ++ [{:pattern, kind, operand, rest}]
  end

  defp plan_items({op, left, right}, state) when op in @comparisons and left != "time",
    do:
      plan_items(left, state) ++
        plan_items(right, state) ++
        [mark({:compare, op, operand_expr(left), right}, elem(state, 1))]

  defp plan_items({op, left, values}, {function_above, _cut})
       when op in [:in, :not_in] and left != "time",
       do:
         plan_items(left, {function_above, true}) ++
           plan_items(values, {function_above, true}) ++ [{:in_list, operand_expr(left), values}]

  defp plan_items({op, left, {low, high}}, {function_above, _cut})
       when op in [:between, :not_between] and left != "time",
       do:
         plan_items(left, {function_above, true}) ++
           plan_items([low, high], {function_above, true}) ++
           [{:range, operand_expr(left), low, high}]

  defp plan_items({op, left, _nil}, {function_above, _cut}) when op in [:is_null, :is_not_null],
    do: plan_items(left, {function_above, true})

  defp plan_items({:not, nodes}, {function_above, _cut}),
    do: plan_items(nodes, {function_above, true})

  defp plan_items({:time_type_error, "time", error}, _state), do: [{:time_type, error}]

  defp plan_items(terms, state) when is_list(terms),
    do: Enum.flat_map(terms, &plan_items(&1, state))

  defp plan_items(term, state) when is_tuple(term),
    do: term |> Tuple.to_list() |> plan_items(state)

  defp plan_items(_other, _state), do: []

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

  defp check_item({:call, function, args}, context, columns),
    do: SQLFunctions.check(function, Enum.map(args, &SQLFunctions.type_of(&1, columns)), context)

  defp check_item({:op, op, left, right}, context, columns),
    do: check_arithmetic(op, left, right, context, columns)

  # The engine words a negation the same wherever it stands.
  defp check_item({:neg, inner}, _context, columns), do: check_negation(inner, columns)

  defp check_item({:aggregate, agg, expr}, _context, columns),
    do: check_aggregate(agg, expr, columns)

  # A `time` compared with a number is a type error when `time` is the
  # timestamp; a CTE's column of that name that is not one is an ordinary
  # column, whose comparison the double does not model.
  defp check_item({:time_type, error}, _context, columns) do
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

  defp check_item({:pattern, kind, expr, rest}, context, columns),
    do: check_pattern(kind, expr, rest, context, columns)

  defp check_item({:compare, op, left, right}, _context, columns),
    do: check_comparison(op, left, right, columns)

  defp check_item({:in_list, left, values}, _context, columns),
    do: check_in_list(left, values, columns)

  defp check_item({:range, left, low, high}, _context, columns),
    do: check_range(left, low, high, columns)

  @spec check_arithmetic(
          atom(),
          SQLParser.expr(),
          SQLParser.expr(),
          SQLFunctions.context(),
          %{binary() => binary()}
        ) :: :ok | {:error, map()}
  defp check_arithmetic(op, left, right, context, columns) do
    case {SQLFunctions.type_of(left, columns), SQLFunctions.type_of(right, columns)} do
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
    case SQLFunctions.type_of(expr, columns) do
      nil -> :ok
      type -> aggregate_refusal(agg, type)
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
    case SQLFunctions.type_of(expr, columns) do
      type when type == "Boolean" or is_numeric_type(type) ->
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
                 "#{column} #{SQLPredicate.symbol(op)} #{value}"
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
    types = Enum.map(values, &value_type/1)

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
           Enum.find([value_type(low), value_type(high)], &boolean_mismatch_with?(column, &1)) do
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

  @spec boolean_mismatch?(binary(), binary()) :: boolean()
  defp boolean_mismatch?(left, right), do: left == "Boolean" != (right == "Boolean")

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
  def pattern_error(kind, type, _rest) when kind in [:like, :not_like],
    do: "There isn't a common type to coerce #{type} and Utf8 in LIKE expression"

  def pattern_error(_kind, type, {_regex, op}),
    do: "Cannot infer common argument type for regex operation #{type} #{op} Utf8"

  # COUNT, MIN and MAX take any type; the others need a number. DataFusion
  # words each family differently (verified against Core).
  @spec aggregate_refusal(SQLParser.aggregate(), binary()) :: :ok | {:error, map()}
  defp aggregate_refusal(agg, _type) when agg in [:count, :min, :max], do: :ok
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
      "NativeType::#{SQLFunctions.native(type)}"
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
  @spec column_types([point()], [binary()], (binary() -> boolean())) :: %{binary() => binary()}
  defp column_types(points, wanted, unsigned?) do
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
