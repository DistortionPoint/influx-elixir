defmodule InfluxElixir.Client.Local.SQLCondition do
  @moduledoc false
  # Evaluates a parsed `WHERE` against a point for `InfluxElixir.Client.Local`
  # with SQL's three-valued logic and DataFusion's comparison semantics
  # (verified against InfluxDB 3 Core).
  #
  # A comparison with a null operand is unknown (`nil`); `AND` is false if any
  # part is false, `OR` is true if any part is true, `NOT` of unknown is
  # unknown, and a row is kept only when the whole is true. A string literal
  # against a number compares the number's text, a number against a text column
  # compares the number rendered; numbers compare as
  # `InfluxElixir.Client.Local.SQLNumber` orders them.
  #
  # A failure only a value can show (a `LIKE` over a number, a bare column
  # that is not a boolean) is thrown as `{:query_error, error}` for the
  # executor to answer.

  alias InfluxElixir.Client.Local.{
    SQLCompare,
    SQLError,
    SQLEval,
    SQLExpr,
    SQLExprType,
    SQLParser,
    SQLPlan,
    SQLPredicate,
    SQLRow,
    SQLRustRegex,
    Store
  }

  @typedoc "A stored point, as `InfluxElixir.Client.Local` keeps it."
  @type point :: SQLRow.point()

  @doc "Whether a point satisfies a parsed `WHERE` conjunction (also used by `DELETE`)."
  @spec matches_all?(point(), [SQLParser.where_node()]) :: boolean()
  def matches_all?(point, conjunction), do: eval_all(point, conjunction) == true

  @doc """
  The value of one node of a `WHERE` for a point: `true`, `false` or `nil`
  (unknown). A failure only a value can show is thrown as `{:query_error, error}`.
  """
  @spec node_value(point(), SQLParser.where_node()) :: boolean() | nil
  def node_value(point, node), do: eval_node(point, node)

  @doc "A three-valued negation: unknown stays unknown."
  @spec negate(boolean() | nil) :: boolean() | nil
  defdelegate negate(value), to: SQLCompare

  # SQL's three-valued logic: a comparison with a null operand is unknown
  # (nil), AND is false if any part is false, OR is true if any part is
  # true, NOT of unknown is unknown, and a row is kept only when true.
  # So `NOT (rack = '1')` does not keep a row that has no rack.
  @spec eval_all(point(), [SQLParser.where_node()]) :: boolean() | nil
  defp eval_all(point, conjunction), do: all_of(conjunction, point, true)

  @spec all_of([SQLParser.where_node()], point(), boolean() | nil) :: boolean() | nil
  defp all_of([], _point, acc), do: acc

  defp all_of([node | rest], point, acc) do
    case eval_node(point, node) do
      false -> false
      nil -> all_of(rest, point, nil)
      true -> all_of(rest, point, acc)
    end
  end

  @spec eval_node(point(), SQLParser.where_node()) :: boolean() | nil
  defp eval_node(point, {:or, branches}), do: any_of(branches, point, false)

  defp eval_node(point, {:not, conjunction}) do
    case eval_all(point, conjunction) do
      nil -> nil
      value -> not value
    end
  end

  defp eval_node(point, clause), do: matches_condition?(point, clause)

  @spec any_of([[SQLParser.where_node()]], point(), boolean() | nil) :: boolean() | nil
  defp any_of([], _point, acc), do: acc

  defp any_of([branch | rest], point, acc) do
    case eval_all(point, branch) do
      true -> true
      nil -> any_of(rest, point, nil)
      false -> any_of(rest, point, acc)
    end
  end

  @time_ops [:eq, :ne, :gt, :lt, :gte, :lte, :between, :not_between, :in, :not_in]
  @pattern_ops [:like, :not_like, :regex, :not_regex]

  @spec matches_condition?(point(), SQLParser.where_clause()) :: boolean() | nil
  defp matches_condition?(_point, {:eq, :null, nil}), do: nil

  defp matches_condition?(point, {:truthy, column, _nil}), do: truthy(point, column)

  defp matches_condition?(point, {:truthy_expr, {:expr, expr}, _nil}),
    do: truthy_expression(point, expr)

  defp matches_condition?(_point, {:non_boolean, _operand, {expression, type}}),
    do: throw({:query_error, SQLPredicate.non_boolean_error(expression, type)})

  defp matches_condition?(point, {op, "time", value}) when op in @time_ops,
    do: time_condition(point.timestamp, op, value)

  defp matches_condition?(point, {op, left, rest}) when op in @pattern_ops,
    do: pattern_condition(left_value(point, left), op, rest)

  # SQL's three-valued logic: a null bound makes its comparison unknown,
  # and `AND` of an unknown is false only if the other side is false
  # (`v BETWEEN NULL AND 5` keeps no row; `v NOT BETWEEN NULL AND 5` keeps
  # the rows above 5).
  defp matches_condition?(point, {:between, left, {low, high}}) do
    case left_value(point, left, [low, high]) do
      nil -> nil
      actual -> both(compare3(point, actual, :gte, low), compare3(point, actual, :lte, high))
    end
  end

  defp matches_condition?(point, {:not_between, key, range}),
    do: negate(matches_condition?(point, {:between, key, range}))

  # A null in the list (or a null parameter) makes a miss unknown, not
  # false: `v NOT IN (1, NULL)` keeps nothing.
  defp matches_condition?(point, {:in, key, values}) do
    case left_value(point, key, values) do
      nil -> nil
      actual -> in_list(actual, Enum.map(values, &right_value(point, &1)))
    end
  end

  defp matches_condition?(point, {:not_in, key, values}),
    do: negate(matches_condition?(point, {:in, key, values}))

  defp matches_condition?(point, {:is_null, key, _nil}), do: is_nil(left_value(point, key))

  defp matches_condition?(point, {:is_not_null, key, _nil}),
    do: not is_nil(left_value(point, key))

  defp matches_condition?(point, {op, {:expr, expr}, right}) do
    compare_values(
      SQLEval.eval_compared(expr, point, literals([right])),
      op,
      right_value(point, right),
      right
    )
  end

  defp matches_condition?(point, {op, column, right}),
    do: compare_values(SQLRow.column_value(point, column), op, right_value(point, right), right)

  # A `WHERE` that is an expression: a boolean, or the engine's error for any other value.
  @spec truthy_expression(point(), SQLExpr.t()) :: boolean() | nil
  defp truthy_expression(point, expr) do
    case SQLEval.eval(expr, point) do
      value when is_boolean(value) or is_nil(value) ->
        value

      other ->
        throw(
          {:query_error,
           SQLPredicate.non_boolean_error(
             filter_text(expr, point),
             viewed_type(expr, point) || SQLPlan.arrow_type(other)
           )}
        )
    end
  end

  # A comparison is unknown for a null operand; the float of one that is not a
  # literal is checked against a decimal as it is read.
  @spec compare_values(term(), atom(), term(), term()) :: boolean() | nil
  defp compare_values(nil, _op, _right, _operand), do: nil
  defp compare_values(_left, _op, nil, _operand), do: nil

  defp compare_values(left, op, right, {:expr, _expr}) do
    SQLCompare.wide_decimal_float(left, right)
    SQLCompare.compare(left, op, right)
  end

  defp compare_values(left, op, right, _literal), do: SQLCompare.compare(left, op, right)

  @spec truthy(point(), binary()) :: boolean() | nil
  defp truthy(point, column) do
    case SQLRow.column_value(point, column) do
      value when is_boolean(value) or is_nil(value) ->
        value

      other ->
        throw({:query_error, %{status: 400, body: non_boolean_predicate(point, column, other)}})
    end
  end

  # A `time` comparison, range or set. A null bound, or a point with no
  # time, makes it unknown, as for any other column.
  @spec time_condition(integer() | nil, atom(), term()) :: boolean() | nil
  defp time_condition(ts, :between, {low, high}),
    do: both(time_compare(ts, :gte, low), time_compare(ts, :lte, high))

  defp time_condition(ts, :not_between, range), do: negate(time_condition(ts, :between, range))
  defp time_condition(ts, :in, values), do: time_in(ts, values)
  defp time_condition(ts, :not_in, values), do: negate(time_in(ts, values))
  defp time_condition(ts, op, value), do: time_compare(ts, op, value)

  @spec time_compare(integer() | nil, atom(), SQLParser.time_value()) :: boolean() | nil
  defp time_compare(ts, op, bound) do
    case {ts, to_nanoseconds(bound)} do
      {nil, _bound} -> nil
      {_ts, nil} -> nil
      {ts, ns} -> SQLCompare.compare(ts, op, ns)
    end
  end

  @spec time_in(integer() | nil, [SQLParser.time_value()]) :: boolean() | nil
  defp time_in(nil, _values), do: nil

  defp time_in(ts, values) do
    bounds = Enum.map(values, &to_nanoseconds/1)

    cond do
      Enum.any?(bounds, &(&1 == ts)) -> true
      Enum.any?(bounds, &is_nil/1) -> nil
      true -> false
    end
  end

  # LIKE, ILIKE and the regular-expression operators over a text value; a
  # number or a boolean has no text to match.
  @spec pattern_condition(term(), atom(), term()) :: boolean() | nil
  defp pattern_condition(nil, _op, _rest), do: nil

  defp pattern_condition(text, op, rest) when is_binary(text),
    do: pattern_match(op, rest, text)

  defp pattern_condition(other, op, rest),
    do: throw({:query_error, %{status: 400, body: pattern_type_error(op, rest, other)}})

  @spec pattern_match(atom(), term(), binary()) :: boolean()
  defp pattern_match(:like, regex, text), do: Regex.match?(regex, text)
  defp pattern_match(:not_like, regex, text), do: not Regex.match?(regex, text)
  defp pattern_match(:regex, {regex, _op, guard}, text), do: regex_match?(regex, guard, text)

  defp pattern_match(:not_regex, {regex, _op, guard}, text),
    do: not regex_match?(regex, guard, text)

  # PCRE is the double's matcher. For a text that is not ASCII the engine's crate reads `\w`,
  # `\d`, `\s` and `\b` as other sets of characters and folds other characters in a
  # case-insensitive match, and for a text with a newline it ends a line, a text and a
  # `$` elsewhere (`InfluxElixir.Client.Local.SQLRustRegex.guard/1`). The double declines such a
  # match rather than answer: it depends on the data, so one such row in a table refuses a
  # query that was answered before the row was written.
  @spec regex_match?(Regex.t(), SQLRustRegex.guard(), binary()) :: boolean()
  defp regex_match?(regex, guard, text) do
    if SQLRustRegex.differs?(guard, text) do
      throw(
        {:query_error,
         SQLError.refusal(
           "a regular expression over a text where PCRE and the engine's crate differ (a " <>
             "non-ASCII text beside \\w, \\d, \\s, \\b or a case-insensitive match; a newline " <>
             "beside $, \\z or (?m))"
         )}
      )
    end

    Regex.match?(regex, text)
  end

  @spec pattern_type_error(atom(), term(), term()) :: binary()
  defp pattern_type_error(op, _regex, value) when op in [:like, :not_like],
    do: like_type_error(value)

  defp pattern_type_error(_op, {_regex, symbol, _guard}, value),
    do: regex_type_error(value, symbol)

  # The planner's text of a filter that is no condition.
  @spec filter_text(SQLExpr.t(), point()) :: binary()
  defp filter_text(expr, point) do
    SQLExpr.render(expr, point.measurement, :display)
  catch
    :unrenderable ->
      throw(
        {:query_error,
         SQLError.refusal(
           "a filter that is a cast: the engine's text of it, with the type, is not modelled"
         )}
      )
  end

  # The engine types the text of a `substr` (and of what is made of it) as a view, which
  # the value read from a row does not tell.
  @spec viewed_type(SQLExpr.t(), point()) :: binary() | nil
  defp viewed_type(expr, point) do
    names = for name <- SQLExpr.columns(expr), is_binary(name), do: name
    columns = SQLPlan.column_types([point], names, fn _name -> false end)
    if SQLExprType.type_of(expr, columns) == "Utf8View", do: "Utf8View"
  end

  # DataFusion refuses a non-boolean column as a filter at planning.
  @spec non_boolean_predicate(point(), binary(), term()) :: binary()
  defp non_boolean_predicate(point, column, value) do
    type =
      if is_map_key(point.tags, column),
        do: "Dictionary(Int32, Utf8)",
        else: SQLPlan.arrow_type(value)

    "Error during planning: Cannot create filter with non-boolean predicate " <>
      "'#{point.measurement}.#{column}' returning #{type}"
  end

  # The left operand is a column name or an arithmetic expression; the right
  # one is a literal unless the parser tagged it as an expression. `compared`
  # is what the operand is compared with: an expression reads a cast of
  # itself against integers (see `SQLEval.eval_compared/3`).
  @spec left_value(point(), SQLParser.operand(), [term()]) :: term()
  defp left_value(point, operand, compared \\ [])

  defp left_value(point, {:expr, expr}, compared),
    do: SQLEval.eval_compared(expr, point, literals(compared))

  defp left_value(point, key, _compared), do: SQLRow.column_value(point, key)

  # The integers an operand is compared with, when all of what it is compared
  # with are integers (the engine then reads a cast of the operand against
  # them; see `SQLEval.eval_compared/3`).
  @spec literals([term()]) :: [integer()]
  defp literals(values), do: if(Enum.all?(values, &is_integer/1), do: values, else: [])

  @spec right_value(point(), term()) :: term()
  defp right_value(point, {:expr, expr}), do: SQLEval.eval(expr, point)
  defp right_value(_point, {:uint, value}), do: value
  defp right_value(_point, literal), do: literal

  @spec in_list(term(), [term()]) :: boolean() | nil
  defp in_list(actual, candidates) do
    cond do
      Enum.any?(candidates, &(not is_nil(&1) and SQLCompare.compare(actual, :eq, &1))) -> true
      Enum.any?(candidates, &is_nil/1) -> nil
      true -> false
    end
  end

  @spec compare3(point(), term(), atom(), term()) :: boolean() | nil
  defp compare3(point, actual, op, bound) do
    case right_value(point, bound) do
      nil -> nil
      value -> SQLCompare.compare(actual, op, value)
    end
  end

  @spec both(boolean() | nil, boolean() | nil) :: boolean() | nil
  defp both(false, _other), do: false
  defp both(_other, false), do: false
  defp both(nil, _other), do: nil
  defp both(_other, nil), do: nil
  defp both(true, true), do: true

  # The parser has already turned every `time` comparand into nanoseconds or
  # a `now()` offset; `now()` is resolved here, at execution, as the engine
  # does.
  @spec to_nanoseconds(SQLParser.time_value()) :: integer() | nil
  defp to_nanoseconds(nil), do: nil
  defp to_nanoseconds(value) when is_integer(value), do: value
  defp to_nanoseconds({:now, offset_ns}), do: Store.now_ns() + offset_ns

  # A regular expression against a non-string column (verified). The planner
  # finds this first (`check_item/3`) when it knows the column's type; this
  # is the answer when it only learns it from a value.
  @spec regex_type_error(term(), binary()) :: binary()
  defp regex_type_error(value, op) do
    "type_coercion\ncaused by\nError during planning: " <>
      SQLPlan.pattern_error(:regex, SQLPlan.arrow_type(value), {nil, op, nil})
  end

  # DataFusion: "There isn't a common type to coerce Float64 and Utf8 in
  # LIKE expression", naming the column's real type.
  @spec like_type_error(term()) :: binary()
  defp like_type_error(value) do
    "type_coercion\ncaused by\nError during planning: " <>
      SQLPlan.pattern_error(:like, SQLPlan.arrow_type(value), nil)
  end
end
