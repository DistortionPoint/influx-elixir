defmodule InfluxElixir.Client.Local.InfluxQLArithmetic do
  @moduledoc false
  # Arithmetic on the integer fields of InfluxQL, as the engine does it
  # (verified; the SQL engine `InfluxElixir.Client.Local` runs a `WHERE` with
  # does not follow these rules, so a comparison that needs them is evaluated
  # here, and the SQL reads its answer from a column of the point).
  #
  # The engine types an expression, and an unsigned field makes it unsigned:
  #
  #   * both sides of an operator are cast to the common type: an integer next
  #     to an unsigned becomes unsigned, and a negative one wraps as
  #     `2^64 + n - 1` (the lowest 64-bit integer is null), so `u * -1` is
  #     `u * (2^64 - 2)`; next to a float both are floats
  #   * `+`, `-` and `*` wrap at the range of the type, signed as well as
  #     unsigned; `/` of two signed integers is a float division, of unsigned ones it
  #     truncates, and a division by zero is zero, whatever the type
  #     (verified: `n / 0 = 0` and `v / 0 = 0` keep every point that has the field, `> 0` none)
  #   * `abs(x)` is the absolute value, in the type of `x`; of the smallest 64-bit integer it
  #     breaks the connection (verified)
  #   * `-x` is `x * -1`, so `-u` is not the negation of `u`
  #   * a comparison with a null is false, and an unsigned and an integer
  #     compare as unsigned: `j > u` for `j = -5` is `2^64 - 6 > u`
  #   * a `SUM` wraps at the range of its field's type, and a float one that
  #     overflows is null
  #
  # The comparisons handled here are those of numbers: fields, constants,
  # `+ - * /`, signs and parentheses.
  alias InfluxElixir.Client.Local.{InfluxQLKernel, SQLLimits}

  require SQLLimits

  @comparison ["=", "!=", "<>", "<", "<=", ">", ">="]

  @typedoc "A value: a signed or unsigned integer, a float, or `nil` for null."
  @type value :: {:int, integer()} | {:uint, non_neg_integer()} | {:float, float()} | nil

  @typedoc "A numeric expression."
  @type expr ::
          {:lit, value()}
          | {:field, binary(), :int | :uint | :float}
          | {:op, binary(), expr(), expr()}
          | {:abs, expr()}

  @typedoc "A comparison to evaluate over rows."
  @type check :: {:check, binary(), expr(), expr()}

  # ---------------------------------------------------------------------------
  # Aggregates
  # ---------------------------------------------------------------------------

  @doc """
  `SUM` or `MEAN` of the numbers of a field of `type` (`nil` when unknown:
  the values say). An integer sum wraps at its type's range; a float one that
  overflows is `nil`.
  """
  @spec fold(binary(), [number(), ...], atom() | nil) :: number() | nil
  def fold(fun, values, type) do
    kind = type || if(Enum.all?(values, &is_integer/1), do: :integer, else: :float)
    fold_kind(fun, kind, values)
  end

  @spec fold_kind(binary(), atom(), [number(), ...]) :: number() | nil
  defp fold_kind("sum", :unsigned, values), do: SQLLimits.wrap_uint64(Enum.sum(values))
  defp fold_kind("sum", :integer, values), do: SQLLimits.wrap_int64(Enum.sum(values))
  defp fold_kind("sum", _float, values), do: float_sum(values)
  defp fold_kind(_mean, :float, values), do: values |> float_sum() |> divided(length(values))
  defp fold_kind(_mean, _integer, values), do: Enum.sum(values) / length(values)

  @spec float_sum([number()]) :: float() | nil
  defp float_sum(values) do
    Enum.sum(values)
  rescue
    ArithmeticError -> nil
  end

  @spec divided(number() | nil, pos_integer()) :: float() | nil
  defp divided(nil, _count), do: nil
  defp divided(sum, count), do: sum / count

  # ---------------------------------------------------------------------------
  # Comparisons
  # ---------------------------------------------------------------------------

  @doc """
  The comparison of `tokens` (those of `InfluxElixir.Client.Local.InfluxQLTokens`)
  to evaluate over rows, when it is one of numbers with an unsigned field, a division or
  an `abs()` in it; `:unsupported` for anything else. `types` maps each field to its type.
  """
  @spec compile(list(), %{binary() => atom()}) :: {:ok, check()} | :unsupported
  def compile(tokens, types) do
    with {left, op, right} <- split(tokens),
         {l, []} <- sum(left, types),
         {r, []} <- sum(right, types),
         true <- evaluated?(l) or evaluated?(r) do
      {:ok, {:check, op, l, r}}
    else
      _other -> :unsupported
    end
  end

  # The tokens around the one comparison operator outside parentheses.
  @spec split(list()) :: {list(), binary(), list()} | :error
  defp split(tokens) do
    {before, rest} = Enum.split_while(tokens, &(not match?({:op, _op}, &1)))

    case rest do
      [{:op, op} | after_op] when op in @comparison ->
        if Enum.any?(after_op, &match?({:op, _op}, &1)), do: :error, else: {before, op, after_op}

      _none_or_other ->
        :error
    end
  end

  # The SQL engine does not follow the engine's rules for an unsigned field, a division
  # (by zero) or an `abs()`.
  @spec evaluated?(expr()) :: boolean()
  defp evaluated?({:field, _name, :uint}), do: true
  defp evaluated?({:op, "/", _left, _right}), do: true
  defp evaluated?({:op, _op, left, right}), do: evaluated?(left) or evaluated?(right)
  defp evaluated?({:abs, _operand}), do: true
  defp evaluated?(_expr), do: false

  # `sum := product (("+" | "-") product)*`, `product := unary (("*" | "/") unary)*`.
  @spec sum(list(), map()) :: {expr(), list()} | :error
  defp sum(tokens, types) do
    with {left, rest} <- product(tokens, types),
         do: more(rest, left, ["+", "-"], &product/2, types)
  end

  @spec product(list(), map()) :: {expr(), list()} | :error
  defp product(tokens, types) do
    with {left, rest} <- unary(tokens, types), do: more(rest, left, ["*", "/"], &unary/2, types)
  end

  defp more([{:raw, op} | rest] = tokens, left, ops, next, types) do
    if op in ops do
      with {right, after_right} <- next.(rest, types),
           do: more(after_right, {:op, op, left, right}, ops, next, types)
    else
      {left, tokens}
    end
  end

  defp more(tokens, left, _ops, _next, _types), do: {left, tokens}

  # `-x` is `x * -1`, a negative number is a constant.
  @spec unary(list(), map()) :: {expr(), list()} | :error
  defp unary([{:raw, "-"}, {:number, text} | rest], _types) do
    with {:ok, value} <- number(text, -1), do: {{:lit, value}, rest}
  end

  defp unary([{:raw, "-"} | rest], types) do
    with {expr, after_expr} <- unary(rest, types),
         do: {{:op, "*", expr, {:lit, {:int, -1}}}, after_expr}
  end

  defp unary([{:raw, "+"} | rest], types), do: unary(rest, types)

  defp unary([{:ident, name}, {:raw, "("} | rest], types) do
    with true <- String.downcase(name) == "abs",
         {expr, [{:raw, ")"} | after_call]} <- sum(rest, types) do
      {{:abs, expr}, after_call}
    else
      _other -> :error
    end
  end

  defp unary([{:raw, "("} | rest], types) do
    case sum(rest, types) do
      {expr, [{:raw, ")"} | after_group]} -> {expr, after_group}
      _unbalanced -> :error
    end
  end

  defp unary([{:number, text} | rest], _types) do
    with {:ok, value} <- number(text, 1), do: {{:lit, value}, rest}
  end

  defp unary([{:ident, name} | rest], types) do
    case Map.get(types, name) do
      :integer -> {{:field, name, :int}, rest}
      :unsigned -> {{:field, name, :uint}, rest}
      :float -> {{:field, name, :float}, rest}
      _other -> :error
    end
  end

  defp unary(_tokens, _types), do: :error

  @spec number(binary(), 1 | -1) :: {:ok, value()} | :error
  defp number(text, sign) do
    case Integer.parse(text) do
      {n, ""} -> integer(sign * n)
      _fraction -> {:ok, {:float, sign * (text |> fraction() |> String.to_float())}}
    end
  end

  defp fraction("." <> digits), do: "0." <> digits
  defp fraction(text), do: text

  # A literal is signed when it fits, else unsigned.
  @spec integer(integer()) :: {:ok, value()} | :error
  defp integer(n) when SQLLimits.is_int64(n), do: {:ok, {:int, n}}

  defp integer(n) when n > SQLLimits.int64_max() and n <= SQLLimits.uint64_max(),
    do: {:ok, {:uint, n}}

  defp integer(_n), do: :error

  @doc """
  The name of the column that carries a check's answer: the planner writes
  the SQL of a `WHERE` with it in place of the comparison, so that `AND`,
  `OR` and parentheses combine it with the rest as the engine does.
  """
  @spec column(check()) :: binary()
  def column(check) do
    "__influxql_check_" <> Base.encode16(:erlang.md5(:erlang.term_to_binary(check)), case: :lower)
  end

  @doc "Whether a row (field name to value) satisfies a check."
  @spec holds?(check(), map()) :: boolean()
  def holds?({:check, op, left, right}, row),
    do: compare(op, eval(left, row), eval(right, row))

  @spec eval(expr(), map()) :: value()
  defp eval({:lit, value}, _row), do: value

  defp eval({:field, name, kind}, row), do: field_value(kind, Map.get(row, name))

  defp eval({:op, op, left, right}, row) do
    if lowest_beside_unsigned?(left, right), do: throw(:closed_connection)
    apply_op(op, eval(left, row), eval(right, row))
  end

  defp eval({:abs, operand}, row), do: absolute(eval(operand, row))

  # The lowest 64-bit integer written as a constant beside an unsigned operand breaks the
  # engine's connection (verified: `u * -9223372036854775808 > 0`, whatever the operator).
  @spec lowest_beside_unsigned?(expr(), expr()) :: boolean()
  defp lowest_beside_unsigned?(left, right) do
    lowest = {:lit, {:int, SQLLimits.int64_min()}}
    (left == lowest and kind(right) == :uint) or (right == lowest and kind(left) == :uint)
  end

  @spec kind(expr()) :: :int | :uint | :float
  defp kind({:field, _name, kind}), do: kind
  defp kind({:lit, {kind, _n}}), do: kind
  defp kind({:abs, operand}), do: kind(operand)
  defp kind({:op, "/", left, right}), do: division_kind(kind(left), kind(right))
  defp kind({:op, _op, left, right}), do: common_kind(kind(left), kind(right))

  defp division_kind(:int, :int), do: :float
  defp division_kind(left, right), do: common_kind(left, right)

  defp common_kind(:float, _other), do: :float
  defp common_kind(_other, :float), do: :float
  defp common_kind(:uint, _other), do: :uint
  defp common_kind(_other, :uint), do: :uint
  defp common_kind(_int, _other), do: :int

  @spec absolute(value()) :: value()
  defp absolute({:int, n}) when n == -9_223_372_036_854_775_808, do: throw(:closed_connection)

  defp absolute({:int, n}), do: {:int, abs(n)}
  defp absolute({:float, x}), do: {:float, abs(x)}
  defp absolute(other), do: other

  defp field_value(:int, n) when is_integer(n), do: {:int, n}
  defp field_value(:uint, n) when is_integer(n), do: {:uint, n}
  defp field_value(:float, x) when is_number(x), do: {:float, x * 1.0}
  defp field_value(_kind, _value), do: nil

  @spec apply_op(binary(), value(), value()) :: value()
  defp apply_op(op, left, right), do: InfluxQLKernel.apply_op(op, left, right)

  @spec compare(binary(), value(), value()) :: boolean()
  defp compare(op, left, right), do: InfluxQLKernel.compare(op, left, right)
end
