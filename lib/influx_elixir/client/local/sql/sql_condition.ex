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
    Format,
    SQLBatch,
    SQLCast,
    SQLError,
    SQLEval,
    SQLNumber,
    SQLParser,
    SQLPlan,
    SQLRow,
    Store
  }

  @typedoc "A stored point, as `InfluxElixir.Client.Local` keeps it."
  @type point :: SQLRow.point()

  @doc "Whether a point satisfies a parsed `WHERE` conjunction (also used by `DELETE`)."
  @spec matches_all?(point(), [SQLParser.where_node()]) :: boolean()
  def matches_all?(point, conjunction), do: eval_all(point, conjunction) == true

  @doc """
  The points that satisfy a parsed `WHERE` conjunction, row by row, unless an
  operand that can fail stands beside another: then the engine's own order of
  evaluation decides whether the query fails or answers, and
  `InfluxElixir.Client.Local.SQLBatch` models it.
  """
  @spec filter([point()], [SQLParser.where_node()]) :: [point()]
  def filter(points, []), do: points

  def filter(points, conjunction) do
    if SQLBatch.guarded?(conjunction),
      do: SQLBatch.filter(points, conjunction),
      else: Enum.filter(points, &matches_all?(&1, conjunction))
  end

  @doc """
  The value of one node of a `WHERE` for a point: `true`, `false` or `nil`
  (unknown). A failure only a value can show is thrown as `{:query_error, error}`.
  """
  @spec node_value(point(), SQLParser.where_node()) :: boolean() | nil
  def node_value(point, node), do: eval_node(point, node)

  @doc "A three-valued negation: unknown stays unknown."
  @spec negate(boolean() | nil) :: boolean() | nil
  def negate(nil), do: nil
  def negate(value), do: not value

  # SQL's three-valued logic: a comparison with a null operand is unknown
  # (nil), AND is false if any part is false, OR is true if any part is
  # true, NOT of unknown is unknown, and a row is kept only when true.
  # So `NOT (rack = '1')` does not keep a row that has no rack.
  @spec eval_all(point(), [SQLParser.where_node()]) :: boolean() | nil
  defp eval_all(point, conjunction) do
    Enum.reduce_while(conjunction, true, fn node, acc ->
      case eval_node(point, node) do
        false -> {:halt, false}
        nil -> {:cont, nil}
        true -> {:cont, acc}
      end
    end)
  end

  @spec eval_node(point(), SQLParser.where_node()) :: boolean() | nil
  defp eval_node(point, {:or, branches}) do
    Enum.reduce_while(branches, false, fn branch, acc ->
      case eval_all(point, branch) do
        true -> {:halt, true}
        nil -> {:cont, nil}
        false -> {:cont, acc}
      end
    end)
  end

  defp eval_node(point, {:not, conjunction}) do
    case eval_all(point, conjunction) do
      nil -> nil
      value -> not value
    end
  end

  defp eval_node(point, clause), do: matches_condition?(point, clause)

  @time_ops [:eq, :ne, :gt, :lt, :gte, :lte, :between, :not_between, :in, :not_in]
  @pattern_ops [:like, :not_like, :regex, :not_regex]

  @spec matches_condition?(point(), SQLParser.where_clause()) :: boolean() | nil
  defp matches_condition?(point, {:truthy, column, _nil}), do: truthy(point, column)

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

  # A comparison is unknown for a null operand; the float of one that is not a
  # literal is checked against a decimal as it is read.
  @spec compare_values(term(), atom(), term(), term()) :: boolean() | nil
  defp compare_values(nil, _op, _right, _operand), do: nil
  defp compare_values(_left, _op, nil, _operand), do: nil

  defp compare_values(left, op, right, {:expr, _expr}) do
    wide_decimal_float(left, right)
    compare(left, op, right)
  end

  defp compare_values(left, op, right, _literal), do: compare(left, op, right)

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
      {ts, ns} -> compare(ts, op, ns)
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
  defp pattern_match(:regex, {regex, _op}, text), do: Regex.match?(regex, text)
  defp pattern_match(:not_regex, {regex, _op}, text), do: not Regex.match?(regex, text)

  @spec pattern_type_error(atom(), term(), term()) :: binary()
  defp pattern_type_error(op, _regex, value) when op in [:like, :not_like],
    do: like_type_error(value)

  defp pattern_type_error(_op, {_regex, symbol}, value), do: regex_type_error(value, symbol)

  # DataFusion refuses a non-boolean column as a filter at planning.
  @spec non_boolean_predicate(point(), binary(), term()) :: binary()
  defp non_boolean_predicate(point, column, value) do
    "Error during planning: Cannot create filter with non-boolean predicate " <>
      "'#{point.measurement}.#{column}' returning #{SQLPlan.arrow_type(value)}"
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
      Enum.any?(candidates, &(not is_nil(&1) and compare(actual, :eq, &1))) -> true
      Enum.any?(candidates, &is_nil/1) -> nil
      true -> false
    end
  end

  @spec compare3(point(), term(), atom(), term()) :: boolean() | nil
  defp compare3(point, actual, op, bound) do
    case right_value(point, bound) do
      nil -> nil
      value -> compare(actual, op, value)
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
      SQLPlan.pattern_error(:regex, SQLPlan.arrow_type(value), {nil, op})
  end

  # DataFusion: "There isn't a common type to coerce Float64 and Utf8 in
  # LIKE expression", naming the column's real type.
  @spec like_type_error(term()) :: binary()
  defp like_type_error(value) do
    "type_coercion\ncaused by\nError during planning: " <>
      SQLPlan.pattern_error(:like, SQLPlan.arrow_type(value), nil)
  end

  # Both nil-actual (missing column) and nil-value (unparseable comparand)
  # short-circuit to false. Without this guard, Elixir term ordering would
  # silently produce wrong results (e.g. `5 > nil` is `true`).
  #
  # A string literal against a non-string column compares the column's text
  # rendering, which is what DataFusion does (it casts the numeric side to
  # Utf8): `amount >= '1000.00'` is lexical, so 500.0 matches. The double
  # reproduces that so a test written against it fails the same way
  # production would.
  #
  # The other way round — a string column against a numeric literal — the
  # engine keeps the column as text and renders the literal (`rack = 2`
  # matches the tag "2"; `rack > 3` is lexical, so "10" does not match), so
  # the literal is rendered here too.
  @spec compare(term(), atom(), term()) :: boolean()
  defp compare(nil, _op, _value), do: false
  defp compare(_actual, _op, nil), do: false

  defp compare(actual, op, value) when is_integer(actual) and is_integer(value),
    do: term_compare(actual, op, value)

  # Zero is left to `SQLNumber`, which orders -0.0 before 0.0.
  defp compare(actual, op, value)
       when is_float(actual) and is_float(value) and actual != 0.0 and value != 0.0,
       do: term_compare(actual, op, value)

  defp compare(actual, op, value) do
    cond do
      is_binary(value) and not is_binary(actual) -> compare(text(actual), op, value)
      is_binary(actual) and SQLNumber.numeric?(value) -> compare(actual, op, text(value))
      SQLNumber.numeric?(actual) and SQLNumber.numeric?(value) -> ordered(actual, op, value)
      true -> term_compare(actual, op, value)
    end
  end

  # Numbers of any type, ordered as the engine orders them.
  @spec ordered(SQLNumber.t(), atom(), SQLNumber.t()) :: boolean()
  defp ordered(actual, op, value) do
    order = SQLNumber.compare(actual, value)

    case op do
      :eq -> order == :eq
      :ne -> order != :eq
      :gt -> order == :gt
      :lt -> order == :lt
      :gte -> order != :lt
      :lte -> order != :gt
    end
  end

  # The engine casts the float to the decimal's type, which holds a value to
  # about 1e20 at the most, and fails the query for a row with a larger
  # one; how large depends on the decimal's precision.
  @spec wide_decimal_float(term(), term()) :: :ok
  defp wide_decimal_float({:dec, _coefficient, _scale}, float), do: wide_float(float)
  defp wide_decimal_float(float, {:dec, _coefficient, _scale}), do: wide_float(float)
  defp wide_decimal_float(_actual, _value), do: :ok

  @spec wide_float(term()) :: :ok
  defp wide_float(value)
       when value in [:inf, :neg_inf] or (is_float(value) and abs(value) > 1.0e20) do
    throw(
      {:query_error,
       SQLError.refusal(
         "a decimal expression compared with a float past 1e20 in a column: the engine fails " <>
           "its cast of the float to the decimal's type, past a size that depends on the " <>
           "decimal's precision, which is not modelled"
       )}
    )
  end

  defp wide_float(_value), do: :ok

  @spec term_compare(term(), atom(), term()) :: boolean()
  defp term_compare(actual, :eq, value), do: actual == value
  defp term_compare(actual, :ne, value), do: actual != value
  defp term_compare(actual, :gt, value), do: actual > value
  defp term_compare(actual, :lt, value), do: actual < value
  defp term_compare(actual, :gte, value), do: actual >= value
  defp term_compare(actual, :lte, value), do: actual <= value

  # A value as DataFusion casts it to text: a float as the engine writes it
  # (`5000.0`, not Erlang's `5.0e3`), a decimal with its scale, an infinity
  # `inf`.
  @spec text(term()) :: binary()
  defp text(value) when is_float(value), do: Format.render_float(value)
  defp text({:u, value}), do: Integer.to_string(value)
  defp text({:int, _bits, value}), do: Integer.to_string(value)
  defp text({:dec, _coefficient, _scale} = value), do: SQLCast.cast(value, :string)
  defp text(:inf), do: "inf"
  defp text(:neg_inf), do: "-inf"
  defp text(:nan), do: "NaN"
  defp text(value), do: to_string(value)
end
