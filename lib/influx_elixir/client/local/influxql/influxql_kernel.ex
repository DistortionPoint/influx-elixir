defmodule InfluxElixir.Client.Local.InfluxQLKernel do
  @moduledoc false
  # The typed arithmetic of the engine on the values of InfluxQL, one kernel for the select
  # list (`InfluxQLExpr`) and the `WHERE` (`InfluxQLArithmetic`) (verified):
  #
  #   * both sides of an operator are cast to the common type: an integer next to an unsigned
  #     becomes unsigned, and a negative one wraps as `2^64 + n - 1`, so `u * -1` is
  #     `u * (2^64 - 2)`; next to a float both are floats
  #   * the lowest 64-bit integer has no unsigned cast: beside an unsigned it is null, in an
  #     operation and in a comparison (as a constant in an operation it breaks the engine's
  #     connection, see `InfluxQLArithmetic`)
  #   * `+`, `-`, `*` and `%` wrap at the range of the type, signed as well as unsigned; `/` of
  #     two signed integers is a float division, of unsigned ones it truncates, and a division
  #     by zero is zero, whatever the type
  #   * a remainder by zero breaks the connection: refused by name
  #   * a float result that overflows is null
  #   * a comparison with a null is false, and an unsigned and an integer compare as unsigned

  alias InfluxElixir.Client.Local.SQLLimits

  require SQLLimits

  @typedoc "A value: a signed or unsigned integer, a float, null, or `:nan`, a number that is not finite."
  @type value ::
          {:int, integer()} | {:uint, non_neg_integer()} | {:float, float()} | nil | :nan

  @typep common :: {:float | :uint | :int, number(), number()} | :lowest

  @doc "The result of `op` (`+ - * / %`) over two values; null in, null out."
  @spec apply_op(binary(), value(), value()) :: value()
  def apply_op(_op, nil, _right), do: nil
  def apply_op(_op, _left, nil), do: nil
  def apply_op(_op, :nan, _right), do: :nan
  def apply_op(_op, _left, :nan), do: :nan

  def apply_op(op, left, right) do
    case common(left, right) do
      {:float, x, y} -> float_op(op, x, y)
      {:uint, x, y} -> uint_op(op, x, y)
      {:int, x, y} -> int_op(op, x, y)
      :lowest -> nil
    end
  end

  @doc "Whether the comparison `op` holds between two values; false with a null."
  @spec compare(binary(), value(), value()) :: boolean()
  def compare(_op, nil, _right), do: false
  def compare(_op, _left, nil), do: false
  def compare(_op, :nan, _right), do: false
  def compare(_op, _left, :nan), do: false

  def compare(op, left, right) do
    case common(left, right) do
      {_type, x, y} -> relation(op, x, y)
      :lowest -> false
    end
  end

  # Both values as the type the engine casts them to.
  @spec common(value(), value()) :: common()
  defp common({:float, x}, {_kind, y}), do: {:float, x, y * 1.0}
  defp common({_kind, x}, {:float, y}), do: {:float, x * 1.0, y}
  defp common({:int, x}, {:int, y}), do: {:int, x, y}

  defp common(left, right) do
    with x when x != :lowest <- unsigned(left), y when y != :lowest <- unsigned(right) do
      {:uint, x, y}
    end
  end

  @spec unsigned(value()) :: non_neg_integer() | :lowest
  defp unsigned({:uint, n}), do: n
  defp unsigned({:int, n}) when n >= 0, do: n
  defp unsigned({:int, n}) when n == SQLLimits.int64_min(), do: :lowest
  defp unsigned({:int, n}), do: SQLLimits.uint64_max() + n

  @spec int_op(binary(), integer(), integer()) :: value()
  defp int_op("/", x, y), do: float_op("/", x * 1.0, y * 1.0)
  defp int_op("%", _x, 0), do: refuse_remainder()
  defp int_op("%", x, y), do: {:int, SQLLimits.wrap_int64(rem(x, y))}
  defp int_op(op, x, y), do: {:int, SQLLimits.wrap_int64(arith(op, x, y))}

  @spec uint_op(binary(), non_neg_integer(), non_neg_integer()) :: value()
  defp uint_op("/", _x, 0), do: {:uint, 0}
  defp uint_op("/", x, y), do: {:uint, div(x, y)}
  defp uint_op("%", _x, 0), do: refuse_remainder()
  defp uint_op("%", x, y), do: {:uint, rem(x, y)}
  defp uint_op(op, x, y), do: {:uint, SQLLimits.wrap_uint64(arith(op, x, y))}

  @spec float_op(binary(), float(), float()) :: value()
  defp float_op("/", _x, y) when y == 0.0, do: {:float, 0.0}
  defp float_op("%", _x, y) when y == 0.0, do: refuse_remainder()

  defp float_op(op, x, y) do
    {:float, float_arith(op, x, y)}
  rescue
    ArithmeticError -> nil
  end

  @spec refuse_remainder() :: no_return()
  defp refuse_remainder, do: throw({:refused, "unsupported InfluxQL (a remainder by zero)"})

  defp arith("+", x, y), do: x + y
  defp arith("-", x, y), do: x - y
  defp arith("*", x, y), do: x * y

  defp float_arith("%", x, y), do: :math.fmod(x, y)
  defp float_arith("/", x, y), do: x / y
  defp float_arith(op, x, y), do: arith(op, x, y)

  defp relation("=", x, y), do: x == y
  defp relation(op, x, y) when op in ["!=", "<>"], do: x != y
  defp relation("<", x, y), do: x < y
  defp relation("<=", x, y), do: x <= y
  defp relation(">", x, y), do: x > y
  defp relation(">=", x, y), do: x >= y
end
