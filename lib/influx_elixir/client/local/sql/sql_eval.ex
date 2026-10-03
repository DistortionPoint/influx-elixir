defmodule InfluxElixir.Client.Local.SQLEval do
  @moduledoc false
  # Evaluates a SQL expression (`InfluxElixir.Client.Local.SQLExpr`) against one
  # point, with the engine's number types (see
  # `InfluxElixir.Client.Local.SQLNumber`): a `UInt64` column
  # (`{:uint_col, name}`, which `InfluxElixir.Client.Local.SQLTyping` puts where
  # the store registered one) reads as a `UInt64`, so `u / 2` is the decimal
  # division the engine makes of it.
  #
  # A missing field or a non-numeric operand makes an arithmetic result null,
  # which the aggregates skip. `time` is the point's timestamp; the parser only
  # lets it reach MIN, MAX and COUNT, the aggregates DataFusion accepts over a
  # Timestamp. A failure only a value can show (a division by zero, a cast
  # that cannot be performed) is thrown as `{:query_error, error}` for the
  # executor to answer.

  alias InfluxElixir.Client.Local.{
    SQLCast,
    SQLCompare,
    SQLError,
    SQLExpr,
    SQLFunctions,
    SQLNumber,
    SQLPlan,
    SQLRow,
    SQLScalar
  }

  @typedoc "What an expression evaluates to."
  @type value :: SQLNumber.t() | binary() | boolean() | DateTime.t() | nil

  @doc "The expression's value for the point."
  @spec eval(SQLExpr.t(), SQLRow.point()) :: value()
  def eval({:field, name}, point), do: SQLRow.column_value(point, name)
  def eval({:uint_col, name}, point), do: unsigned(SQLRow.column_value(point, name))
  def eval({:lit, value}, _point), do: value
  def eval({:uint, value}, _point), do: {:u, value}
  def eval({:cast, inner, type}, point), do: SQLCast.cast(eval(inner, point), type)

  def eval({:call, :coalesce, args}, point), do: first_value(args, point)

  def eval({:call, name, args}, point) when name in [:greatest, :least],
    do: SQLScalar.extreme(name, Enum.map(args, &eval(&1, point)))

  def eval({:call, :nullif, [left, right]}, point) do
    value = eval(left, point)
    other = eval(right, point)

    if is_nil(value) or is_nil(other) or not SQLCompare.compare(value, :eq, other),
      do: value
  end

  # The optimizer folds a `log` whose base is its argument, of a column, to
  # `1.0` for every row, a null one too (verified against InfluxDB 3 Core:
  # `log(x, x)`, `log(n, n)`, `log(x + 1, x + 1)`), once it has put the two in
  # one form: a product or a quotient by one dropped (`log(x, 1 * x)`) and the
  # operands of a sum or a product in one order (`log(x + 1, 1 + x)`). It does not
  # drop a sum of zero (`log(x, x + 0)` is not folded), and a constant is computed.
  def eval({:call, :log, [base, argument]} = call, point) do
    {base, argument} = {log_form(base), log_form(argument)}

    cond do
      constant?(base) -> call_function(call, point)
      base == argument -> 1.0
      without_cast(base) == without_cast(argument) -> throw({:query_error, log_cast_refusal()})
      true -> call_function(call, point)
    end
  end

  def eval({:call, _function, _args} = call, point), do: call_function(call, point)

  def eval({:cmp, op, left, right}, point), do: compare(op, eval(left, point), eval(right, point))

  def eval({:and, left, right}, point) do
    case eval(left, point) do
      false -> false
      value -> both(value, eval(right, point))
    end
  end

  def eval({:or, left, right}, point) do
    case eval(left, point) do
      true -> true
      value -> either(value, eval(right, point))
    end
  end

  def eval({:not, inner}, point), do: negate(eval(inner, point))
  def eval({:is_null, inner, negated}, point), do: is_nil(eval(inner, point)) != negated

  def eval({:is_bool, inner, expected, negated}, point),
    do: eval(inner, point) == expected != negated

  def eval({:is_distinct, left, right, negated}, point) do
    distinct =
      case {eval(left, point), eval(right, point)} do
        {nil, nil} -> false
        {nil, _value} -> true
        {_value, nil} -> true
        {value, other} -> not SQLCompare.compare(value, :eq, other)
      end

    distinct != negated
  end

  def eval({:in, inner, items, negated}, point) do
    case eval(inner, point) do
      nil -> nil
      value -> value |> member(Enum.map(items, &eval(&1, point))) |> negate_if(negated)
    end
  end

  def eval({:between, inner, low, high, negated}, point) do
    case eval(inner, point) do
      nil ->
        nil

      value ->
        value
        |> between(eval(low, point), eval(high, point))
        |> negate_if(negated)
    end
  end

  def eval({:like, inner, pattern, negated, ilike, regex}, point) do
    with value when value != nil <- eval(inner, point),
         %Regex{} = regex <- regex || pattern_regex(eval(pattern, point), ilike) do
      value |> like(ilike) |> then(&Regex.match?(regex, &1)) |> negate_if(negated)
    else
      nil -> nil
    end
  end

  def eval({:concat, left, right}, point) do
    with value when value != nil <- eval(left, point),
         other when other != nil <- eval(right, point) do
      SQLCompare.text(value) <> SQLCompare.text(other)
    end
  end

  def eval({:case, nil, whens, otherwise}, point) do
    branch = Enum.find(whens, fn {condition, _result} -> eval(condition, point) == true end)
    case_result(branch, otherwise, point)
  end

  def eval({:case, operand, whens, otherwise}, point) do
    case eval(operand, point) do
      nil ->
        case_result(nil, otherwise, point)

      value ->
        branch =
          Enum.find(whens, fn {candidate, _result} ->
            case eval(candidate, point) do
              nil -> false
              other -> SQLCompare.compare(value, :eq, other)
            end
          end)

        case_result(branch, otherwise, point)
    end
  end

  def eval({:neg, inner}, point) do
    case eval(inner, point) do
      nil -> nil
      # The engine cannot negate a timestamp and closes the connection (verified).
      %DateTime{} -> throw({:query_error, SQLError.closed()})
      value -> if SQLNumber.numeric?(value), do: SQLNumber.negate(value, constant?(inner))
    end
  end

  def eval({:op, op, left, right}, point) do
    left_value = eval(left, point)
    right_value = eval(right, point)

    if SQLNumber.numeric?(left_value) and SQLNumber.numeric?(right_value),
      do: SQLNumber.arithmetic(op, left_value, right_value)
  end

  @spec call_function(SQLExpr.t(), SQLRow.point()) :: value()
  defp call_function({:call, function, args}, point),
    do: SQLFunctions.call(function, Enum.map(args, &eval(&1, point)))

  @spec first_value([SQLExpr.t()], SQLRow.point()) :: value()
  defp first_value([], _point), do: nil

  defp first_value([arg | rest], point) do
    case eval(arg, point) do
      nil -> first_value(rest, point)
      value -> value
    end
  end

  @spec case_result({SQLExpr.t(), SQLExpr.t()} | nil, SQLExpr.t() | nil, SQLRow.point()) ::
          value()
  defp case_result({_condition, result}, _otherwise, point), do: eval(result, point)
  defp case_result(nil, nil, _point), do: nil
  defp case_result(nil, otherwise, point), do: eval(otherwise, point)

  # A comparison with a null side is unknown.
  @spec compare(SQLExpr.comparison(), value(), value()) :: boolean() | nil
  defp compare(_op, nil, _right), do: nil
  defp compare(_op, _left, nil), do: nil

  defp compare(op, left, right) do
    SQLCompare.wide_decimal_float(left, right)
    SQLCompare.compare(left, op, right)
  end

  # SQL's three-valued logic: false decides an AND and true an OR; with
  # neither, a null on either side is unknown.
  @spec both(boolean() | nil, boolean() | nil) :: boolean() | nil
  defp both(false, _right), do: false
  defp both(_left, false), do: false
  defp both(true, true), do: true
  defp both(_left, _right), do: nil

  @spec either(boolean() | nil, boolean() | nil) :: boolean() | nil
  defp either(_left, true), do: true
  defp either(false, false), do: false
  defp either(_left, _right), do: nil

  @spec negate(boolean() | nil) :: boolean() | nil
  defp negate(nil), do: nil
  defp negate(value), do: not value

  @spec negate_if(boolean() | nil, boolean()) :: boolean() | nil
  defp negate_if(value, true), do: negate(value)
  defp negate_if(value, false), do: value

  # `v IN (...)`: true for a member, unknown when a null stands in the list
  # and there is none, false otherwise.
  @spec member(value(), [value()]) :: boolean() | nil
  defp member(value, candidates) do
    cond do
      Enum.any?(candidates, &(not is_nil(&1) and SQLCompare.compare(value, :eq, &1))) -> true
      Enum.any?(candidates, &is_nil/1) -> nil
      true -> false
    end
  end

  @spec between(value(), value(), value()) :: boolean() | nil
  defp between(value, low, high),
    do: both(compare(:gte, value, low), compare(:lte, value, high))

  # The text a `LIKE` matches: the value itself, which must be text.
  @spec like(value(), boolean()) :: binary()
  defp like(value, _ilike) when is_binary(value), do: value

  defp like(value, ilike) do
    word = if ilike, do: "ILIKE", else: "LIKE"

    throw(
      {:query_error,
       SQLError.coercion(
         "There isn't a common type to coerce #{SQLPlan.arrow_type(value)} and Utf8 in #{word} " <>
           "expression"
       )}
    )
  end

  @spec pattern_regex(value(), boolean()) :: Regex.t() | nil
  defp pattern_regex(pattern, ilike) when is_binary(pattern),
    do: SQLCompare.like_regex(pattern, ilike)

  defp pattern_regex(_pattern, _ilike), do: nil

  @doc """
  The value of an expression that a comparison sets against integer
  `literals`, as the engine's optimizer leaves it: a `CAST` to an integer
  type is removed when the literals fit that type and then the type of what
  it casts (verified: `CAST(big AS INT) > 1` compares `big` with `1` and
  fails for no value, while `CAST(big AS INT) > 3000000000` casts, and fails
  for a `big` past `Int32`). A cast that stays is the cast; with no literals
  it is the plain value.
  """
  @spec eval_compared(SQLExpr.t(), SQLRow.point(), [integer()]) :: value()
  def eval_compared(expr, point, []), do: eval(expr, point)

  def eval_compared({:cast, inner, type} = cast, point, literals) do
    case SQLCast.bits(type) do
      nil -> eval(cast, point)
      bits -> unwrap(inner, type, bits, point, literals)
    end
  end

  def eval_compared(expr, point, _literals), do: eval(expr, point)

  @spec unwrap(SQLExpr.t(), SQLExpr.cast_type(), 8 | 16 | 32 | 64, SQLRow.point(), [integer()]) ::
          value()
  defp unwrap(inner, type, bits, point, literals) do
    if Enum.all?(literals, &SQLCast.fits?(&1, bits)) do
      value = eval_compared(inner, point, literals)
      if admits?(value, literals), do: value, else: SQLCast.cast(value, type)
    else
      SQLCast.cast(eval(inner, point), type)
    end
  end

  # Whether the literals can be read in the value's own type, so that the
  # cast above it can go: an integer type takes the literals that fit it, a
  # `UInt64` those that are not negative, and nothing else is unwrapped.
  @spec admits?(value(), [integer()]) :: boolean()
  defp admits?(nil, _literals), do: true
  defp admits?(value, _literals) when is_integer(value), do: true
  defp admits?({:u, _value}, literals), do: Enum.all?(literals, &(&1 >= 0))
  defp admits?({:int, bits, _value}, literals), do: Enum.all?(literals, &SQLCast.fits?(&1, bits))
  defp admits?(_other, _literals), do: false

  @spec unsigned(term()) :: term()
  defp unsigned(value) when is_integer(value) and value >= 0, do: {:u, value}
  defp unsigned(value), do: value

  # An argument of `log` in the form the optimizer compares it in.
  @spec log_form(SQLExpr.t()) :: SQLExpr.t()
  defp log_form(expr), do: expr |> canonical() |> outermost()

  @spec canonical(SQLExpr.t()) :: SQLExpr.t()
  defp canonical(expr), do: expr |> SQLExpr.map_children(&canonical/1) |> rewrite()

  @spec rewrite(SQLExpr.t()) :: SQLExpr.t()
  defp rewrite({:op, :*, {:lit, 1}, inner}), do: inner
  defp rewrite({:op, :*, inner, {:lit, 1}}), do: inner
  defp rewrite({:op, :/, inner, {:lit, 1}}), do: inner

  defp rewrite({:op, op, left, right}) when op in [:+, :*],
    do: if(left <= right, do: {:op, op, left, right}, else: {:op, op, right, left})

  defp rewrite(expr), do: expr

  # What only the whole argument loses: a product or quotient by a float one, which `log`
  # makes of an integer anyway.
  @spec outermost(SQLExpr.t()) :: SQLExpr.t()
  defp outermost({:op, :*, {:lit, one}, inner}) when one == 1.0, do: outermost(inner)
  defp outermost({:op, :*, inner, {:lit, one}}) when one == 1.0, do: outermost(inner)
  defp outermost({:op, :/, inner, {:lit, one}}) when one == 1.0, do: outermost(inner)
  defp outermost(expr), do: expr

  @spec without_cast(SQLExpr.t()) :: SQLExpr.t()
  defp without_cast({:cast, inner, :float}), do: without_cast(inner)
  defp without_cast(expr), do: expr

  # The cast of a column to a float is dropped for an integer and kept for a float, which
  # a value does not tell.
  @spec log_cast_refusal() :: SQLError.t()
  defp log_cast_refusal do
    SQLError.refusal(
      "log of an expression and its cast to a float: whether the engine folds it to 1.0 " <>
        "depends on the column's type"
    )
  end

  @spec constant?(SQLExpr.t()) :: boolean()
  defp constant?(expr), do: SQLExpr.columns(expr) == []
end
