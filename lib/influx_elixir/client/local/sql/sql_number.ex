defmodule InfluxElixir.Client.Local.SQLNumber do
  @moduledoc false
  # The numbers a SQL expression computes with in `InfluxElixir.Client.Local`,
  # typed as the engine types them (verified against InfluxDB 3 Core).
  #
  # A value is one of:
  #
  #   * an `Int64` as a bare integer, wrapping in two's complement
  #   * a `UInt64` as `{:u, n}`, wrapping at 2^64
  #   * a `Float64` as a bare float, or `:inf`, `:neg_inf`, `:nan` where the IEEE
  #     result is not a float Elixir can hold (an overflow raises there)
  #   * a `Decimal128` as `{:dec, coefficient, scale}`, the value `coefficient /
  #     10^scale`
  #   * an `Int8`, `Int16` or `Int32` (what a `CAST` to `TINYINT`, `SMALLINT` or
  #     `INTEGER` makes) as `{:int, bits, n}`, wrapping at its own width
  #
  # Mixing types follows the engine's coercion: a `Float64` with anything is a
  # `Float64`; two `Int64`s are an `Int64` and two `UInt64`s a `UInt64`; two
  # narrow integers are the wider of the two (an `Int32` and an `Int16` are an
  # `Int32`), and a narrow integer with an `Int64` is an `Int64`; an `Int64`
  # with a `UInt64`, or anything with a decimal, is a decimal. A narrow integer
  # with a `UInt64` or a decimal is refused by name. A
  # decimal sum, difference and remainder keep the larger scale, a product adds
  # the scales, and a quotient has four places more than its dividend and is
  # truncated toward zero. A decimal that needs more than 38 digits is outside
  # what the double models and is refused by name.
  #
  # An infinity or a NaN shows as `null` in a response. An infinity compares as
  # a number (it is larger than every finite value); a NaN is ordered by its
  # sign bit, which the CPU that produced it chooses, so a comparison of a NaN
  # is refused by name. A float compares as the engine's total order does:
  # `-0.0` is less than `0.0`.

  alias InfluxElixir.Client.Local.{SQLError, SQLLimits}

  require SQLLimits

  @typedoc "A float Elixir cannot hold."
  @type special :: :inf | :neg_inf | :nan

  @typedoc "A `Decimal128`: `{:dec, coefficient, scale}`."
  @type decimal :: {:dec, integer(), non_neg_integer()}

  @typedoc "An `Int8`, `Int16` or `Int32`: `{:int, bits, n}`."
  @type narrow :: {:int, 8 | 16 | 32, integer()}

  @typedoc "A number the evaluator computes with."
  @type t ::
          integer() | float() | special() | {:u, non_neg_integer()} | decimal() | narrow()

  @typedoc "An arithmetic operator."
  @type op :: :+ | :- | :* | :/ | :rem

  @narrow_types ["Int8", "Int16", "Int32"]
  @max_digits 38
  @division_places 4
  @specials [:inf, :neg_inf, :nan]

  @doc "Whether the value is a number the evaluator computes with."
  @spec numeric?(term()) :: boolean()
  def numeric?(value) when is_integer(value) or is_float(value), do: true
  def numeric?(value) when value in @specials, do: true
  def numeric?({:u, value}) when is_integer(value), do: true
  def numeric?({:int, bits, value}) when bits in [8, 16, 32] and is_integer(value), do: true

  def numeric?({:dec, coefficient, scale}) when is_integer(coefficient) and is_integer(scale),
    do: true

  def numeric?(_other), do: false

  @doc """
  The value as a response carries it: a `UInt64` and a scale-0 decimal as an
  integer, another decimal as a float, an infinity or a NaN as `nil`
  (a `null` that is there), anything else as it is.
  """
  @spec row_value(term()) :: term()
  def row_value({:u, value}), do: value
  def row_value({:int, _bits, value}), do: value
  def row_value({:dec, coefficient, 0}), do: coefficient

  def row_value({:dec, coefficient, scale}) do
    {value, ""} = Float.parse("#{coefficient}e-#{scale}")
    value
  end

  def row_value(value) when value in @specials, do: nil
  def row_value(value), do: value

  @doc """
  The number as a `Float64`: a float, or a special. A decimal is its
  coefficient as a double over `10^scale` as a double, as the engine converts
  it (verified: it differs from the nearest double of the decimal value for a
  coefficient past 2^53).
  """
  @spec to_float(t()) :: float() | special()
  def to_float(value) when is_float(value) or value in @specials, do: value
  def to_float(value) when is_integer(value), do: value * 1.0
  def to_float({:u, value}), do: value * 1.0
  def to_float({:int, _bits, value}), do: value * 1.0
  def to_float({:dec, coefficient, 0}), do: coefficient * 1.0
  def to_float({:dec, coefficient, scale}), do: coefficient * 1.0 / :math.pow(10.0, scale)

  @doc """
  The Arrow type name of an arithmetic result given its operands' type names;
  `"Decimal128(?)"` stands for a decimal whose precision is not tracked.
  """
  @spec result_type(binary(), binary()) :: binary()
  def result_type("Float64", _right), do: "Float64"
  def result_type(_left, "Float64"), do: "Float64"
  def result_type("Int64", "Int64"), do: "Int64"
  def result_type("UInt64", "UInt64"), do: "UInt64"

  def result_type(left, right) when left in @narrow_types and right in @narrow_types,
    do: if(narrow_bits(left) >= narrow_bits(right), do: left, else: right)

  def result_type(left, "Int64") when left in @narrow_types, do: "Int64"
  def result_type("Int64", right) when right in @narrow_types, do: "Int64"
  def result_type(_left, _right), do: "Decimal128(?)"

  @spec narrow_bits(binary()) :: 8 | 16 | 32
  defp narrow_bits("Int8"), do: 8
  defp narrow_bits("Int16"), do: 16
  defp narrow_bits("Int32"), do: 32

  # ---------------------------------------------------------------------------
  # Arithmetic
  # ---------------------------------------------------------------------------

  @doc """
  `left op right` as the engine computes it. An integer divided by zero, and
  the `Int64` minimum by -1, close the engine's connection; a decimal that
  needs more than 38 digits is refused by name.
  """
  @spec arithmetic(op(), t(), t()) :: t()
  def arithmetic(op, left, right) do
    case {kind(left), kind(right)} do
      {:float, _right} -> float_op(op, to_float(left), to_float(right))
      {_left, :float} -> float_op(op, to_float(left), to_float(right))
      {:int, :int} -> integer_op(op, left, right, :int64)
      {:uint, :uint} -> {:u, integer_op(op, uint(left), uint(right), :uint64)}
      {:narrow, :narrow} -> narrow_op(op, left, right)
      {:narrow, :int} -> integer_op(op, integer_of(left), right, :int64)
      {:int, :narrow} -> integer_op(op, left, integer_of(right), :int64)
      {:narrow, _wide} -> refuse_narrow()
      {_wide, :narrow} -> refuse_narrow()
      _mixed -> decimal_op(op, decimal(left), decimal(right))
    end
  end

  @spec kind(t()) :: :int | :uint | :float | :dec | :narrow
  defp kind(value) when is_integer(value), do: :int
  defp kind({:int, _bits, _value}), do: :narrow
  defp kind({:u, _value}), do: :uint
  defp kind({:dec, _coefficient, _scale}), do: :dec
  defp kind(_float), do: :float

  @spec uint({:u, non_neg_integer()}) :: non_neg_integer()
  defp uint({:u, value}), do: value

  @spec decimal(t()) :: decimal()
  defp decimal({:dec, _coefficient, _scale} = decimal), do: decimal
  defp decimal({:u, value}), do: {:dec, value, 0}
  defp decimal(value) when is_integer(value), do: {:dec, value, 0}
  defp decimal({:int, _bits, value}), do: {:dec, value, 0}

  # Two narrow integers are computed, wrapping, at the wider's width.
  @spec narrow_op(op(), narrow(), narrow()) :: narrow()
  defp narrow_op(op, {:int, left_bits, left}, {:int, right_bits, right}) do
    bits = max(left_bits, right_bits)
    {:int, bits, integer_op(op, left, right, bits)}
  end

  @spec refuse_narrow() :: no_return()
  defp refuse_narrow do
    refused(
      "arithmetic of a narrow integer (CAST AS INT, SMALLINT or TINYINT) with a UInt64 or a " <>
        "decimal: the engine's result type for it is not modelled"
    )
  end

  # Two integers of one type; the type is where the result wraps around.
  @spec integer_op(op(), integer(), integer(), :int64 | :uint64 | 8 | 16 | 32) :: integer()
  defp integer_op(:+, left, right, type), do: wrap(left + right, type)
  defp integer_op(:-, left, right, type), do: wrap(left - right, type)
  defp integer_op(:*, left, right, type), do: wrap(left * right, type)
  defp integer_op(_division, _left, 0, _type), do: closed()

  defp integer_op(:/, left, right, type) do
    if right == -1 and left == minimum(type), do: closed(), else: div(left, right)
  end

  defp integer_op(:rem, left, right, _type), do: rem(left, right)

  @spec wrap(integer(), :int64 | :uint64 | 8 | 16 | 32) :: integer()
  defp wrap(value, :int64), do: SQLLimits.wrap_int64(value)
  defp wrap(value, :uint64), do: SQLLimits.wrap_uint64(value)

  defp wrap(value, bits) do
    half = Bitwise.bsl(1, bits - 1)
    Integer.mod(value + half, Bitwise.bsl(1, bits)) - half
  end

  @doc "The smallest value of a signed integer type, or 0 for `:uint64`."
  @spec minimum(:int64 | :uint64 | 8 | 16 | 32) :: integer()
  def minimum(:int64), do: SQLLimits.int64_min()
  def minimum(:uint64), do: 0
  def minimum(bits), do: -Bitwise.bsl(1, bits - 1)

  @spec closed() :: no_return()
  defp closed, do: throw({:query_error, SQLError.closed()})

  @spec refused(binary()) :: no_return()
  defp refused(message), do: throw({:query_error, SQLError.refusal(message)})

  @spec decimal_op(op(), decimal(), decimal()) :: decimal()
  defp decimal_op(op, {:dec, c1, s1}, {:dec, c2, s2}) when op in [:+, :-] do
    scale = max(s1, s2)
    left = c1 * pow10(scale - s1)
    right = c2 * pow10(scale - s2)
    fit({:dec, if(op == :+, do: left + right, else: left - right), scale})
  end

  defp decimal_op(:*, {:dec, c1, s1}, {:dec, c2, s2}), do: fit({:dec, c1 * c2, s1 + s2})
  defp decimal_op(_division, _left, {:dec, 0, _scale}), do: closed()

  defp decimal_op(:/, {:dec, c1, s1}, {:dec, c2, s2}),
    do: fit({:dec, div(c1 * pow10(@division_places + s2), c2), s1 + @division_places})

  defp decimal_op(:rem, {:dec, c1, s1}, {:dec, c2, s2}) do
    scale = max(s1, s2)
    fit({:dec, rem(c1 * pow10(scale - s1), c2 * pow10(scale - s2)), scale})
  end

  @spec pow10(non_neg_integer()) :: pos_integer()
  defp pow10(exponent), do: Integer.pow(10, exponent)

  @spec fit(decimal()) :: decimal()
  defp fit({:dec, coefficient, scale} = decimal) do
    if abs(coefficient) >= pow10(@max_digits) or scale > @max_digits,
      do:
        refused(
          "a decimal past 38 digits (an Int64 with a UInt64, or a division of one): the " <>
            "engine rescales it, which the double does not model"
        ),
      else: decimal
  end

  # ---------------------------------------------------------------------------
  # Floats, with the IEEE results Elixir cannot hold
  # ---------------------------------------------------------------------------

  @spec float_op(op(), float() | special(), float() | special()) :: float() | special()
  defp float_op(:+, left, right), do: add(left, right)
  defp float_op(:-, left, right), do: add(left, negate_float(right))
  defp float_op(:*, left, right), do: multiply(left, right)
  defp float_op(:/, left, right), do: divide(left, right)
  defp float_op(:rem, left, right), do: remainder(left, right)

  @doc "The float negated; an infinity turns around, a NaN stays a NaN."
  @spec negate_float(float() | special()) :: float() | special()
  def negate_float(:inf), do: :neg_inf
  def negate_float(:neg_inf), do: :inf
  def negate_float(:nan), do: :nan
  def negate_float(value), do: -value

  @spec add(float() | special(), float() | special()) :: float() | special()
  defp add(:nan, _right), do: :nan
  defp add(_left, :nan), do: :nan
  defp add(:inf, :neg_inf), do: :nan
  defp add(:neg_inf, :inf), do: :nan
  defp add(:inf, _right), do: :inf
  defp add(:neg_inf, _right), do: :neg_inf
  defp add(_left, :inf), do: :inf
  defp add(_left, :neg_inf), do: :neg_inf

  defp add(left, right) do
    left + right
  rescue
    ArithmeticError -> infinity(left >= 0)
  end

  @spec multiply(float() | special(), float() | special()) :: float() | special()
  defp multiply(:nan, _right), do: :nan
  defp multiply(_left, :nan), do: :nan

  defp multiply(left, right) when left in [:inf, :neg_inf] or right in [:inf, :neg_inf] do
    if zero?(left) or zero?(right), do: :nan, else: infinity(positive?(left) == positive?(right))
  end

  defp multiply(left, right) do
    left * right
  rescue
    ArithmeticError -> infinity(positive?(left) == positive?(right))
  end

  @spec divide(float() | special(), float() | special()) :: float() | special()
  defp divide(:nan, _right), do: :nan
  defp divide(_left, :nan), do: :nan
  defp divide(left, right) when left in [:inf, :neg_inf] and right in [:inf, :neg_inf], do: :nan

  defp divide(left, right) when left in [:inf, :neg_inf],
    do: infinity(positive?(left) == positive?(right))

  defp divide(left, right) when right in [:inf, :neg_inf],
    do: if(positive?(left) == positive?(right), do: 0.0, else: -0.0)

  defp divide(left, right) when right == 0.0 do
    if left == 0.0, do: :nan, else: infinity(positive?(left) == positive?(right))
  end

  defp divide(left, right) do
    left / right
  rescue
    ArithmeticError -> infinity(positive?(left) == positive?(right))
  end

  @spec remainder(float() | special(), float() | special()) :: float() | special()
  defp remainder(:nan, _right), do: :nan
  defp remainder(_left, :nan), do: :nan
  defp remainder(left, _right) when left in [:inf, :neg_inf], do: :nan
  defp remainder(left, right) when right in [:inf, :neg_inf], do: left
  defp remainder(_left, right) when right == 0, do: :nan
  defp remainder(left, right), do: :math.fmod(left, right)

  @spec infinity(boolean()) :: :inf | :neg_inf
  defp infinity(true), do: :inf
  defp infinity(false), do: :neg_inf

  # The sign bit, so that `-0.0` is negative.
  @spec positive?(float() | special()) :: boolean()
  defp positive?(:inf), do: true
  defp positive?(:neg_inf), do: false
  defp positive?(value), do: not match?(<<1::1, _rest::63>>, <<value::float>>)

  @spec zero?(float() | special()) :: boolean()
  defp zero?(value) when value in @specials, do: false
  defp zero?(value), do: value == 0.0

  # ---------------------------------------------------------------------------
  # Negation
  # ---------------------------------------------------------------------------

  @doc """
  The number negated. The `Int64` minimum overflows: the engine folds a
  constant (`constant?`) and fails the query, closing the connection; over a
  column the kernel wraps and the minimum is its own negation (both verified).
  """
  @spec negate(t(), boolean()) :: t()
  def negate(SQLLimits.int64_min(), true), do: closed()
  def negate(SQLLimits.int64_min(), false), do: SQLLimits.int64_min()

  def negate({:int, bits, value}, constant?) do
    cond do
      value != minimum(bits) -> {:int, bits, -value}
      constant? -> closed()
      true -> {:int, bits, value}
    end
  end

  def negate(value, _constant?) when is_integer(value), do: -value
  def negate({:dec, coefficient, scale}, _constant?), do: {:dec, -coefficient, scale}
  def negate({:u, _value}, _constant?), do: refused("a UInt64 cannot be negated")
  def negate(value, _constant?), do: negate_float(value)

  # ---------------------------------------------------------------------------
  # Ordering
  # ---------------------------------------------------------------------------

  @doc """
  Orders two numbers as the engine does: exactly for integers and decimals,
  as doubles when either is a float (`-0.0` below `0.0`, an infinity beyond
  every finite value). A NaN is refused by name.
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(left, right) do
    case {kind(left), kind(right)} do
      {:float, _right} -> compare_floats(to_float(left), to_float(right))
      {_left, :float} -> compare_floats(to_float(left), to_float(right))
      {:dec, _right} -> compare_decimals(decimal(left), decimal(right))
      {_left, :dec} -> compare_decimals(decimal(left), decimal(right))
      _integers -> compare_integers(integer_of(left), integer_of(right))
    end
  end

  @spec integer_of(integer() | {:u, non_neg_integer()} | narrow()) :: integer()
  defp integer_of({:u, value}), do: value
  defp integer_of({:int, _bits, value}), do: value
  defp integer_of(value), do: value

  @spec compare_integers(integer(), integer()) :: :lt | :eq | :gt
  defp compare_integers(left, right) do
    cond do
      left < right -> :lt
      left > right -> :gt
      true -> :eq
    end
  end

  @spec compare_decimals(decimal(), decimal()) :: :lt | :eq | :gt
  defp compare_decimals({:dec, c1, s1}, {:dec, c2, s2}) do
    scale = max(s1, s2)
    compare_integers(c1 * pow10(scale - s1), c2 * pow10(scale - s2))
  end

  @spec compare_floats(float() | special(), float() | special()) :: :lt | :eq | :gt
  defp compare_floats(left, right) when left == :nan or right == :nan do
    refused(
      "a comparison or ordering of a NaN: the engine orders a NaN by its sign bit, which " <>
        "the CPU that computed it chooses"
    )
  end

  defp compare_floats(left, right) do
    case {rank(left), rank(right)} do
      {same, same} when same != 0 -> :eq
      {0, 0} -> compare_finite(left, right)
      {left_rank, right_rank} -> compare_integers(left_rank, right_rank)
    end
  end

  @spec rank(float() | special()) :: -1 | 0 | 1
  defp rank(:neg_inf), do: -1
  defp rank(:inf), do: 1
  defp rank(_finite), do: 0

  @spec compare_finite(float(), float()) :: :lt | :eq | :gt
  defp compare_finite(left, right) when left < right, do: :lt
  defp compare_finite(left, right) when left > right, do: :gt

  defp compare_finite(left, right) do
    case {positive?(left), positive?(right)} do
      {false, true} -> :lt
      {true, false} -> :gt
      _same_sign -> :eq
    end
  end
end
