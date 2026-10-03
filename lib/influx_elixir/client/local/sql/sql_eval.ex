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

  alias InfluxElixir.Client.Local.{SQLCast, SQLExpr, SQLFunctions, SQLNumber, SQLRow}

  @typedoc "What an expression evaluates to."
  @type value :: SQLNumber.t() | binary() | boolean() | DateTime.t() | nil

  @doc "The expression's value for the point."
  @spec eval(SQLExpr.t(), SQLRow.point()) :: value()
  def eval({:field, name}, point), do: SQLRow.column_value(point, name)
  def eval({:uint_col, name}, point), do: unsigned(SQLRow.column_value(point, name))
  def eval({:lit, value}, _point), do: value
  def eval({:uint, value}, _point), do: {:u, value}
  def eval({:cast, inner, type}, point), do: SQLCast.cast(eval(inner, point), type)

  def eval({:call, function, args}, point),
    do: SQLFunctions.call(function, Enum.map(args, &eval(&1, point)))

  def eval({:neg, inner}, point) do
    case eval(inner, point) do
      nil -> nil
      value -> if SQLNumber.numeric?(value), do: SQLNumber.negate(value, constant?(inner))
    end
  end

  def eval({:op, op, left, right}, point) do
    left_value = eval(left, point)
    right_value = eval(right, point)

    if SQLNumber.numeric?(left_value) and SQLNumber.numeric?(right_value),
      do: SQLNumber.arithmetic(op, left_value, right_value)
  end

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

  @spec constant?(SQLExpr.t()) :: boolean()
  defp constant?(expr), do: SQLExpr.columns(expr) == []
end
