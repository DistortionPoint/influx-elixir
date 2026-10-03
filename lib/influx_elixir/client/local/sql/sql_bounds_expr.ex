defmodule InfluxElixir.Client.Local.SQLBoundsExpr do
  @moduledoc false
  # The conjuncts of a `WHERE` that compare an expression, as the engine's
  # interval analysis reads them (verified against InfluxDB 3 Core; see
  # `InfluxElixir.Client.Local.SQLBounds` for the analysis itself).
  #
  #   * A `CAST` of an integer column to an integer type is removed, as the
  #     optimizer removes it, when the integers it is compared with fit that
  #     type (`CAST(j AS TINYINT) > 5` bounds `j`; against `300` the cast stays
  #     and says nothing). The column's own type is the bound's: an unsigned
  #     column is `UInt64` through any cast.
  #   * An unsigned column's cast against a negative number is the Arrow
  #     kernel's error `Casting from <type> to Null not supported`, where the
  #     comparison is `=`, `<`, `<=` or a one-element `IN`; the other
  #     comparisons close the connection.
  #   * `=` or a one-element `IN` of an expression with an integer division by
  #     zero in it (`1 / 0 = 1`, `i / 0 = 1`) fails the analysis when the other
  #     conjuncts bound every column the expression reads.
  #   * An expression that is `+`, `-`, `*`, `/` or a negation of one column
  #     with constants is solved for the column, and what it leaves the column
  #     meets the other bounds of the column in the analysis. Where they
  #     leave no value the engine fails in an operation of the interval
  #     arithmetic, in words that depend on the operation and the order of the
  #     conjuncts, which the double does not model.

  alias InfluxElixir.Client.Local.{SQLCast, SQLExpr, SQLFold, SQLFunctions, SQLNumber}

  @typedoc "What the interval analysis reads a numeric column as."
  @type column_type :: :int64 | :uint64 | :float64 | :other

  @typedoc """
  The values a numeric column may have: from the low end, open or closed, to
  the high end, open or closed; `:neg_inf` and `:inf` are no end.
  """
  @type interval :: {number() | :neg_inf, boolean(), number() | :inf, boolean()}

  @typedoc """
  The value of the column a division by zero forces (`i / 0 = 1` forces `i = 0`,
  `(i + 1) / 0 = 1` forces `i = -1`), as the interval of that one value, and
  whether the dividend is the bare column, a sum or difference of it with a
  constant, or another shape.
  """
  @type point :: {binary(), column_type(), :bare | :additive | :other, interval()}

  @typedoc "What an expression conjunct is to the analysis."
  @type result ::
          {:column, binary()}
          | {:cast_null, atom(), binary()}
          | {:divzero, [binary()], point() | :other | nil}
          | {:linear, binary(), column_type(), interval(), boolean()}
          | :unknown

  @bounds [:gt, :gte, :lt, :lte, :eq]

  @doc """
  Classifies the comparison `op` of `expr` with `rhs`: as a comparison of a
  bare column (the cast removed), one of the failures above, or unknown.
  """
  @spec classify(atom(), SQLExpr.t(), term(), (binary() -> column_type() | nil)) :: result()
  def classify(op, expr, rhs, type_of) do
    integral? = integers(op, rhs) != []
    expr = collapse(expr, type_of, integral?)

    case {expr, bare(collapse(expr, type_of, true))} do
      {{kind, name}, _bare} when kind in [:field, :uint_col] and is_binary(name) ->
        {:column, name}

      {_expression, bare} when bare != nil and not integral? ->
        :unknown

      {_expression, _bare} ->
        with :unknown <- cast(op, expr, rhs, type_of),
             :unknown <- division_by_zero(op, expr, type_of) do
          linear(op, expr, rhs, type_of)
        end
    end
  end

  # The column an expression is once what the optimizer removes is gone.
  @spec bare(SQLExpr.t()) :: binary() | nil
  defp bare({kind, name}) when kind in [:field, :uint_col] and is_binary(name), do: name
  defp bare(_expression), do: nil

  # What the optimizer removes before the analysis reads an expression: a
  # double negation, and a product or quotient with one. The one is the
  # integer one when the expression is compared with integers (compared with
  # a float, an integer column is cast to a double first and the cast stays),
  # and either one beside a float column.
  @spec collapse(SQLExpr.t(), (binary() -> column_type() | nil), boolean()) :: SQLExpr.t()
  defp collapse(expr, type_of, integral?) do
    expr
    |> SQLExpr.map_children(&collapse(&1, type_of, integral?))
    |> identity(type_of, integral?)
  end

  @spec identity(SQLExpr.t(), (binary() -> column_type() | nil), boolean()) :: SQLExpr.t()
  defp identity({:neg, {:neg, inner}}, _type_of, _integral?), do: inner

  defp identity({:op, :*, left, right} = expr, type_of, integral?) do
    cond do
      one?(right, left, type_of, integral?) -> left
      one?(left, right, type_of, integral?) -> right
      true -> expr
    end
  end

  defp identity({:op, :/, x, one} = expr, type_of, integral?),
    do: if(one?(one, x, type_of, integral?), do: x, else: expr)

  defp identity(expr, _type_of, _integral?), do: expr

  @spec one?(SQLExpr.t(), SQLExpr.t(), (binary() -> column_type() | nil), boolean()) ::
          boolean()
  defp one?({:lit, 1}, other, type_of, integral?), do: integral? or float_column?(other, type_of)
  defp one?({:lit, 1.0}, other, type_of, _integral?), do: float_column?(other, type_of)
  defp one?(_literal, _other, _type_of, _integral?), do: false

  @spec float_column?(SQLExpr.t(), (binary() -> column_type() | nil)) :: boolean()
  defp float_column?({kind, name}, type_of) when kind in [:field, :uint_col] and is_binary(name),
    do: type_of.(name) == :float64

  defp float_column?(_other, _type_of), do: false

  # ---------------------------------------------------------------------------
  # Casts
  # ---------------------------------------------------------------------------

  @spec cast(atom(), SQLExpr.t(), term(), (binary() -> column_type() | nil)) :: result()
  defp cast(op, {:cast, _inner, _type} = expr, rhs, type_of) do
    with :unknown <- negative_cast(op, expr, numbers(op, rhs), type_of) do
      case integers(op, rhs) do
        [] ->
          :unknown

        literals ->
          negative? = Enum.any?(literals, &(&1 < 0))

          case uncast(expr, literals, type_of) do
            {:ok, _column, :uint64, _target} when negative? -> :unknown
            {:ok, column, _type, _target} -> {:column, column}
            :error -> :unknown
          end
      end
    end
  end

  defp cast(_op, _expr, _rhs, _type_of), do: :unknown

  # An unsigned column's cast against a negative number stays a cast, whether
  # or not the number fits the type.
  @spec negative_cast(atom(), SQLExpr.t(), [number()], (binary() -> column_type() | nil)) ::
          result()
  defp negative_cast(op, {:cast, {kind, name}, type}, numbers, type_of)
       when kind in [:field, :uint_col] and is_binary(name) do
    if SQLCast.bits(type) != nil and type_of.(name) == :uint64 and Enum.any?(numbers, &(&1 < 0)),
      do: {:cast_null, op, SQLCast.arrow_type(type)},
      else: :unknown
  end

  defp negative_cast(_op, _expr, _numbers, _type_of), do: :unknown

  # The column a cast of integer columns leaves when every cast goes: each
  # one needs the literals to fit its type. The outermost cast's type is the
  # one the engine names, and only a single cast is read that way.
  @spec uncast(SQLExpr.t(), [integer()], (binary() -> column_type() | nil)) ::
          {:ok, binary(), column_type(), binary() | nil} | :error
  defp uncast(expr, literals, type_of), do: uncast(expr, literals, type_of, nil, 0)

  defp uncast({:cast, inner, type}, literals, type_of, target, depth) do
    bits = SQLCast.bits(type)

    if bits != nil and Enum.all?(literals, &SQLCast.fits?(&1, bits)),
      do: uncast(inner, literals, type_of, target || SQLCast.arrow_type(type), depth + 1),
      else: :error
  end

  defp uncast({kind, name}, _literals, type_of, target, depth)
       when kind in [:field, :uint_col] and is_binary(name) do
    case type_of.(name) do
      type when type in [:int64, :uint64] ->
        {:ok, name, type, if(depth == 1, do: target)}

      _other ->
        :error
    end
  end

  defp uncast(_other, _literals, _type_of, _target, _depth), do: :error

  # The integers a comparison sets its operand against, when it does so only
  # with integers.
  @spec integers(atom(), term()) :: [integer()]
  defp integers(op, rhs) when op in @bounds, do: integers_in([rhs])
  defp integers(:between, {low, high}), do: integers_in([low, high])
  defp integers(:in, [value]), do: integers_in([value])
  defp integers(_op, _rhs), do: []

  @spec integers_in([term()]) :: [integer()]
  defp integers_in(values) do
    values =
      Enum.map(values, fn
        {:uint, n} -> n
        other -> other
      end)

    if Enum.all?(values, &is_integer/1), do: values, else: []
  end

  # The numbers (integers or floats) of the comparison.
  @spec numbers(atom(), term()) :: [number()]
  defp numbers(op, rhs) when op in @bounds, do: numbers_in([rhs])
  defp numbers(:in, [value]), do: numbers_in([value])
  defp numbers(_op, _rhs), do: []

  @spec numbers_in([term()]) :: [number()]
  defp numbers_in(values) do
    values =
      Enum.map(values, fn
        {:uint, n} -> n
        other -> other
      end)

    if Enum.all?(values, &is_number/1), do: values, else: []
  end

  # ---------------------------------------------------------------------------
  # Division by zero
  # ---------------------------------------------------------------------------

  @spec division_by_zero(atom(), SQLExpr.t(), (binary() -> column_type() | nil)) :: result()
  defp division_by_zero(op, expr, type_of) when op in [:eq, :in] do
    cond do
      SQLExpr.any?(expr, &match?({:call, _function, _args}, &1)) ->
        :unknown

      match?({:op, :/, _dividend, _divisor}, expr) and zero_divisor?(expr, type_of) ->
        forced(expr, type_of)

      true ->
        unforced(expr, type_of)
    end
  end

  defp division_by_zero(_op, _expr, _type_of), do: :unknown

  # `dividend / 0` with the dividend a column or a sum of one with a constant:
  # the analysis forces the dividend to zero, so the column to one value. A
  # dividend of another shape fails the analysis the same way when the column's
  # bounds leave that value out, in words the double does not know. An unsigned
  # column divides as a decimal, which the analysis does not take.
  @spec forced(SQLExpr.t(), (binary() -> column_type() | nil)) :: result()
  defp forced({:op, :/, dividend, _divisor} = expr, type_of) do
    case solve(dividend, {0.0, false, 0.0, false}, type_of) do
      {:ok, _column, :uint64, _point} ->
        :unknown

      {:ok, column, type, point} ->
        if solvable_type?(type, dividend),
          do: {:divzero, [column], {column, type, shape(dividend), point}},
          else: :unknown

      :error ->
        unforced(expr, type_of)
    end
  end

  # An integer division by zero somewhere in the expression that the analysis
  # does not solve for a column. One whose dividend reads no column fails the
  # analysis whatever the bounds leave; with a column in the dividend (a cast, a
  # negation, a sum of columns, the division inside a sum) the failure is in
  # words the double does not know.
  @spec unforced(SQLExpr.t(), (binary() -> column_type() | nil)) :: result()
  defp unforced(expr, type_of) do
    columns = for column <- SQLExpr.columns(expr), is_binary(column), do: column

    cond do
      SQLExpr.any?(expr, &(integer_zero_division?(&1, type_of) and column_dividend?(&1))) ->
        {:divzero, columns, :other}

      SQLExpr.any?(expr, &integer_zero_division?(&1, type_of)) ->
        {:divzero, columns, nil}

      true ->
        :unknown
    end
  end

  @spec column_dividend?(SQLExpr.t()) :: boolean()
  defp column_dividend?({:op, :/, dividend, _divisor}), do: SQLExpr.columns(dividend) != []

  @spec shape(SQLExpr.t()) :: :bare | :additive | :other
  defp shape({kind, _name}) when kind in [:field, :uint_col], do: :bare
  defp shape({:cast, inner, _type}), do: shape(inner)
  defp shape(expr), do: if(additive?(expr), do: :additive, else: :other)

  # An integer column is divided by an integer zero; a float column by a zero
  # of either type.
  @spec zero_divisor?(SQLExpr.t(), (binary() -> column_type() | nil)) :: boolean()
  defp zero_divisor?({:op, :/, dividend, divisor}, type_of) do
    case SQLFold.constant(divisor) do
      {:ok, 0} -> true
      {:ok, zero} when zero == 0.0 -> not integer_valued?(dividend, type_of)
      _other -> false
    end
  end

  @spec integer_zero_division?(SQLExpr.t(), (binary() -> column_type() | nil)) :: boolean()
  defp integer_zero_division?({:op, :/, dividend, divisor}, type_of),
    do: zero?(divisor) and integer_valued?(dividend, type_of)

  defp integer_zero_division?(_other, _type_of), do: false

  @spec zero?(SQLExpr.t()) :: boolean()
  defp zero?(expr), do: match?({:ok, 0}, SQLFold.constant(expr))

  @spec integer_valued?(SQLExpr.t(), (binary() -> column_type() | nil)) :: boolean()
  defp integer_valued?(expr, type_of) do
    columns =
      for column <- SQLExpr.columns(expr), is_binary(column), into: %{} do
        {column, arrow(type_of.(column))}
      end

    SQLFunctions.type_of(expr, columns) in ["Int64", "UInt64", "Int32", "Int16", "Int8"]
  end

  @spec arrow(column_type() | nil) :: binary() | nil
  defp arrow(:int64), do: "Int64"
  defp arrow(:uint64), do: "UInt64"
  defp arrow(:float64), do: "Float64"
  defp arrow(_other), do: nil

  # ---------------------------------------------------------------------------
  # Linear expressions
  # ---------------------------------------------------------------------------

  @spec linear(atom(), SQLExpr.t(), term(), (binary() -> column_type() | nil)) :: result()
  defp linear(op, expr, rhs, type_of) do
    with {:ok, interval} <- compared(op, rhs),
         {:ok, column, type, solved} <- solve(expr, interval, type_of),
         true <- solvable_type?(type, expr) do
      {:linear, column, type, solved, additive?(expr)}
    else
      _unsolved -> :unknown
    end
  end

  # The analysis solves arithmetic on a column in the column's own type. An
  # unsigned column's arithmetic is a decimal's, and an integer column's
  # with a fractional or an unsigned constant is a float's or a decimal's:
  # neither is solved, and the comparison says nothing about the column.
  @spec solvable_type?(column_type(), SQLExpr.t()) :: boolean()
  defp solvable_type?(:uint64, _expr), do: false
  defp solvable_type?(:int64, expr), do: not SQLExpr.any?(expr, &wider_literal?/1)
  defp solvable_type?(_float, _expr), do: true

  @spec wider_literal?(SQLExpr.t()) :: boolean()
  defp wider_literal?({:lit, value}), do: is_float(value) or value in [:inf, :neg_inf]
  defp wider_literal?({:uint, _value}), do: true
  defp wider_literal?(_other), do: false

  # Whether the expression only adds and subtracts constants: the engine
  # solves it for the column without an operation of its own that can fail.
  @spec additive?(SQLExpr.t()) :: boolean()
  defp additive?(expr), do: not SQLExpr.any?(expr, &non_additive?/1)

  @spec non_additive?(SQLExpr.t()) :: boolean()
  defp non_additive?({:neg, _inner}), do: true
  defp non_additive?({:op, op, _left, _right}), do: op not in [:+, :-]
  defp non_additive?(_other), do: false

  # The interval a comparison leaves its operand.
  @spec compared(atom(), term()) :: {:ok, interval()} | :error
  defp compared(:between, {low, high}) do
    with {:ok, {l, lo_open, _h, _ho}} <- compared(:gte, low),
         {:ok, {_l, _lo, h, hi_open}} <- compared(:lte, high),
         do: {:ok, {l, lo_open, h, hi_open}}
  end

  defp compared(:in, [value]), do: compared(:eq, value)

  defp compared(op, rhs) when op in @bounds do
    case number(rhs) do
      nil -> :error
      x -> {:ok, interval(op, x)}
    end
  end

  defp compared(_op, _rhs), do: :error

  @spec interval(atom(), number()) :: interval()
  defp interval(:gt, x), do: {x, true, :inf, false}
  defp interval(:gte, x), do: {x, false, :inf, false}
  defp interval(:lt, x), do: {:neg_inf, false, x, true}
  defp interval(:lte, x), do: {:neg_inf, false, x, false}
  defp interval(:eq, x), do: {x, false, x, false}

  @spec number(term()) :: float() | nil
  defp number({:uint, n}), do: n * 1.0
  defp number(x) when is_integer(x) or is_float(x), do: x * 1.0
  defp number(_other), do: nil

  @spec solve(SQLExpr.t(), interval(), (binary() -> column_type() | nil)) ::
          {:ok, binary(), column_type(), interval()} | :error
  defp solve({kind, name}, interval, type_of)
       when kind in [:field, :uint_col] and is_binary(name) do
    case type_of.(name) do
      type when type in [:int64, :uint64, :float64] -> {:ok, name, type, interval}
      _other -> :error
    end
  end

  defp solve({:neg, inner}, interval, type_of), do: solve(inner, negate(interval), type_of)

  # A cast of an `Int64` column to `Int64` changes nothing and is removed.
  defp solve({:cast, {kind, name} = inner, :int64}, interval, type_of)
       when kind in [:field, :uint_col] and is_binary(name) do
    if type_of.(name) == :int64, do: solve(inner, interval, type_of), else: :error
  end

  defp solve({:op, op, left, right}, interval, type_of) do
    case {constant(left), constant(right)} do
      {nil, k} when k != nil -> solve_left(op, left, k, interval, type_of)
      {k, nil} when k != nil -> solve_right(op, right, k, interval, type_of)
      _neither_or_both -> :error
    end
  end

  defp solve(_other, _interval, _type_of), do: :error

  # `x op k`.
  @spec solve_left(atom(), SQLExpr.t(), float(), interval(), function()) ::
          {:ok, binary(), column_type(), interval()} | :error
  defp solve_left(:+, x, k, iv, type_of), do: solve(x, shift(iv, -k), type_of)
  defp solve_left(:-, x, k, iv, type_of), do: solve(x, shift(iv, k), type_of)
  defp solve_left(:*, x, k, iv, type_of) when k != 0.0, do: solve(x, scale(iv, 1 / k), type_of)
  defp solve_left(:/, x, k, iv, type_of) when k != 0.0, do: solve(x, widen(scale(iv, k)), type_of)
  defp solve_left(_op, _x, _k, _iv, _type_of), do: :error

  # `k op x`.
  @spec solve_right(atom(), SQLExpr.t(), float(), interval(), function()) ::
          {:ok, binary(), column_type(), interval()} | :error
  defp solve_right(:+, x, k, iv, type_of), do: solve(x, shift(iv, -k), type_of)
  defp solve_right(:-, x, k, iv, type_of), do: solve(x, negate(shift(iv, -k)), type_of)
  defp solve_right(:*, x, k, iv, type_of) when k != 0.0, do: solve(x, scale(iv, 1 / k), type_of)
  defp solve_right(_op, _x, _k, _iv, _type_of), do: :error

  @spec constant(SQLExpr.t()) :: float() | nil
  defp constant(expr) do
    with [] <- SQLExpr.columns(expr),
         {:ok, value} <- SQLFold.constant(expr),
         true <- SQLNumber.numeric?(value),
         float when is_float(float) <- SQLNumber.to_float(value) do
      float
    else
      _not_a_finite_number -> nil
    end
  end

  @spec negate(interval()) :: interval()
  defp negate({lo, lo_open, hi, hi_open}), do: {neg(hi), hi_open, neg(lo), lo_open}

  @spec neg(number() | :neg_inf | :inf) :: number() | :neg_inf | :inf
  defp neg(:inf), do: :neg_inf
  defp neg(:neg_inf), do: :inf
  defp neg(x), do: -x

  @spec shift(interval(), float()) :: interval()
  defp shift({lo, lo_open, hi, hi_open}, k), do: {add(lo, k), lo_open, add(hi, k), hi_open}

  @spec add(number() | :neg_inf | :inf, float()) :: number() | :neg_inf | :inf
  defp add(end_, _k) when end_ in [:inf, :neg_inf], do: end_
  defp add(x, k), do: x + k

  @spec scale(interval(), float()) :: interval()
  defp scale(interval, k) when k > 0.0, do: scaled(interval, k)
  defp scale(interval, k), do: interval |> negate() |> scaled(-k)

  @spec scaled(interval(), float()) :: interval()
  defp scaled({lo, lo_open, hi, hi_open}, k), do: {times(lo, k), lo_open, times(hi, k), hi_open}

  @spec times(number() | :neg_inf | :inf, float()) :: number() | :neg_inf | :inf
  defp times(end_, _k) when end_ in [:inf, :neg_inf], do: end_
  defp times(x, k), do: x * k

  # An integer division rounds, so what it leaves is not exact: a unit on
  # either side stands for it.
  @spec widen(interval()) :: interval()
  defp widen({lo, _lo_open, hi, _hi_open}), do: {add(lo, -1.0), false, add(hi, 1.0), false}

  # ---------------------------------------------------------------------------
  # Where they meet
  # ---------------------------------------------------------------------------

  @doc """
  Whether the intervals of a column leave it no value, or so few that the
  engine's own rounding could decide: an integer column's by whole numbers,
  a float's within a relative `1.0e-9`.
  """
  @spec empty?(column_type(), [interval()]) :: boolean()
  def empty?(type, intervals) do
    {lo, lo_open, hi, hi_open} = Enum.reduce(intervals, {:neg_inf, false, :inf, false}, &meet/2)

    cond do
      lo == :neg_inf or hi == :inf ->
        false

      type == :float64 ->
        hi - lo <= 1.0e-9 * max(abs(lo), abs(hi)) or (lo == hi and (lo_open or hi_open))

      true ->
        whole_low(lo, lo_open) > whole_high(hi, hi_open)
    end
  end

  @doc """
  Whether the one value of `point` (an interval of a single number) lies in
  every one of the intervals.
  """
  @spec contains?([interval()], interval()) :: boolean()
  def contains?(intervals, {value, _lo_open, value, _hi_open}) do
    {lo, lo_open, hi, hi_open} = Enum.reduce(intervals, {:neg_inf, false, :inf, false}, &meet/2)

    (lo == :neg_inf or lo < value or (lo == value and not lo_open)) and
      (hi == :inf or hi > value or (hi == value and not hi_open))
  end

  @spec meet(interval(), interval()) :: interval()
  defp meet({l1, o1, h1, p1}, {l2, o2, h2, p2}) do
    {lo, lo_open} = higher({l1, o1}, {l2, o2})
    {hi, hi_open} = lower({h1, p1}, {h2, p2})
    {lo, lo_open, hi, hi_open}
  end

  defp higher({:neg_inf, _open}, b), do: b
  defp higher(a, {:neg_inf, _open}), do: a
  defp higher({x, ox}, {y, oy}), do: if(x > y or (x == y and ox), do: {x, ox}, else: {y, oy})

  defp lower({:inf, _open}, b), do: b
  defp lower(a, {:inf, _open}), do: a
  defp lower({x, ox}, {y, oy}), do: if(x < y or (x == y and ox), do: {x, ox}, else: {y, oy})

  @spec whole_low(number(), boolean()) :: integer()
  defp whole_low(x, open) do
    ceiling = ceil(x)
    if open and ceiling == x, do: ceiling + 1, else: ceiling
  end

  @spec whole_high(number(), boolean()) :: integer()
  defp whole_high(x, open) do
    floor = floor(x)
    if open and floor == x, do: floor - 1, else: floor
  end
end
