defmodule InfluxElixir.Client.Local.SQLFunctions do
  @moduledoc """
  The scalar math functions `Client.Local` evaluates in SQL expressions,
  wherever an expression stands (`WHERE`, the select list, `ORDER BY`, an
  aggregate's argument), as InfluxDB 3 does (verified against Core):

    * `abs(x)` — the magnitude, in the argument's type
    * `round(x)`, `round(x, n)` — half away from zero (`round(-2.5)` is
      `-3.0`), to `n` decimal places (negative `n` rounds left of the
      point: `round(1234.5678, -2)` is `1200.0`); always a float, and a zero
      result keeps the sign of its argument (`round(-0.3)` is `-0.0`)
    * `trunc(x)` — toward zero (`trunc(-2.75)` is `-2.0`), always a float; a
      zero it leaves keeps the sign of a fraction (`trunc(-0.4)` is `-0.0`)
      but not of a zero (`trunc(-0.0)` is `0.0`). `trunc(x, n)` is `round(x, n)`:
      the engine rounds there (`trunc(1234.5678, 2)` is `1234.57`)
    * `floor(x)`, `ceil(x)` — always a float

  An argument that is a decimal (an `Int64` with a `UInt64`) is read as a
  double, except by `abs`, which keeps it. An infinity or a NaN is passed on
  (`round(inf)` is infinity); `round(x, n)` that overflows is null on the
  engine, and here (see `InfluxElixir.Client.Local.SQLNumber`).

  A null argument makes the result null. Names are case-insensitive.

  The engine checks the arguments' types when it plans the query, so a
  wrong one fails the query even when no row would reach the call
  (`check/3`). The message depends on where the call stands: in `WHERE`
  it carries the `type_coercion` prefix, in `ORDER BY` it is cut after its
  first sentence, and in the select list it has neither. A call in `WHERE`
  under a `CAST`, `IS [NOT] NULL`, `BETWEEN`, `LIKE`, `IN` or `NOT` is cut
  after its first sentence too (`:where_cut`; see `InfluxElixir.Client.Local.SQLPlan`
  for the order the engine reports them in). `floor` and `ceil` with a second
  argument are the engine's 405.
  """

  alias InfluxElixir.Client.Local.{SQLCast, SQLError, SQLLimits, SQLNumber, SQLParser}

  require SQLLimits

  @type name :: :abs | :round | :trunc | :floor | :ceil
  @type context :: :where | :where_cut | :select | :order_by

  @names %{
    "abs" => :abs,
    "round" => :round,
    "trunc" => :trunc,
    "floor" => :floor,
    "ceil" => :ceil
  }

  @doc "Whether an Arrow type name is one of the engine's numeric types."
  defguard is_numeric_type(type)
           when type in ["Int64", "UInt64", "Float64", "Decimal128(?)", "Int32", "Int16", "Int8"]

  @integer_types ["Int64", "Int32", "Int16", "Int8"]

  @int32_min -2_147_483_648
  @int32_max 2_147_483_647
  @two_32 4_294_967_296

  @round_signature "OneOf([Exact([Float64, Int64]), Exact([Float32, Int64]), " <>
                     "Exact([Float64]), Exact([Float32])])"
  @trunc_signature "OneOf([Exact([Float32, Int64]), Exact([Float64, Int64]), " <>
                     "Exact([Float64]), Exact([Float32])])"

  @doc "The function a name (any case) calls, or `nil` for any other name."
  @spec lookup(binary()) :: name() | nil
  def lookup(name), do: Map.get(@names, String.downcase(name))

  @doc """
  Evaluates a call the planner has accepted (`check/3`), its arguments
  already evaluated: numbers (see `InfluxElixir.Client.Local.SQLNumber`), or
  `nil`, which makes the result `nil`.
  """
  @spec call(name(), [SQLNumber.t() | nil]) :: SQLNumber.t() | nil
  def call(name, args) do
    if Enum.any?(args, &is_nil/1), do: nil, else: compute(name, args)
  end

  @spec compute(name(), [SQLNumber.t()]) :: SQLNumber.t()
  # The magnitude of the `Int64` minimum overflows, whether the engine folds
  # a constant or reads a column (verified): it closes the connection.
  defp compute(:abs, [SQLLimits.int64_min()]), do: throw({:query_error, SQLError.closed()})

  defp compute(:abs, [{:int, bits, x}]) do
    if x == SQLNumber.minimum(bits),
      do: throw({:query_error, SQLError.closed()}),
      else: {:int, bits, Kernel.abs(x)}
  end

  defp compute(:abs, [x]) when is_integer(x), do: Kernel.abs(x)
  defp compute(:abs, [{:u, _value} = x]), do: x
  defp compute(:abs, [{:dec, coefficient, scale}]), do: {:dec, Kernel.abs(coefficient), scale}
  defp compute(:abs, [x]), do: absolute_float(x)
  defp compute(:round, [x]), do: x |> SQLNumber.to_float() |> round_away()
  defp compute(:round, [x, {:int, _bits, scale}]), do: compute(:round, [x, scale])
  defp compute(:round, [x, 0]), do: x |> SQLNumber.to_float() |> round_away()

  # A scale past `Int32` closes the connection (verified, in both directions).
  defp compute(:round, [_x, scale]) when scale > @int32_max or scale < @int32_min,
    do: throw({:query_error, SQLError.closed()})

  defp compute(:round, [x, scale]), do: scaled(SQLNumber.to_float(x), scale)

  # With a scale `trunc` rounds, exactly as `round` does (verified over a
  # range of values and scales), after the engine reads the scale as an
  # `Int32`, wrapping what does not fit (`trunc(3.25, 4294967296)` is `3.0`,
  # `trunc(3.25, 9223372036854775807)` is `0.0`); without one it truncates
  # toward zero, and a zero it leaves keeps the sign of a fraction
  # (`trunc(-0.4)` is `-0.0`) but not of a zero (`trunc(-0.0)` is `0.0`).
  defp compute(:trunc, [x]), do: x |> SQLNumber.to_float() |> truncate()
  defp compute(:trunc, [x, {:int, _bits, scale}]), do: compute(:trunc, [x, scale])
  defp compute(:trunc, [x, scale]), do: compute(:round, [x, wrap_int32(scale)])
  defp compute(:floor, [x]), do: x |> SQLNumber.to_float() |> floor_float()
  defp compute(:ceil, [x]), do: x |> SQLNumber.to_float() |> ceil_float()

  @spec wrap_int32(integer()) :: integer()
  defp wrap_int32(scale), do: Integer.mod(scale - @int32_min, @two_32) + @int32_min

  @spec absolute_float(float() | SQLNumber.special()) :: float() | SQLNumber.special()
  defp absolute_float(x) when x in [:inf, :neg_inf], do: :inf
  defp absolute_float(:nan), do: :nan
  defp absolute_float(x), do: Kernel.abs(x)

  @spec floor_float(float() | SQLNumber.special()) :: float() | SQLNumber.special()
  defp floor_float(x) when is_float(x), do: Float.floor(x)
  defp floor_float(special), do: special

  @spec ceil_float(float() | SQLNumber.special()) :: float() | SQLNumber.special()
  defp ceil_float(x) when is_float(x), do: Float.ceil(x)
  defp ceil_float(special), do: special

  @spec truncate(float() | SQLNumber.special()) :: float() | SQLNumber.special()
  defp truncate(x) when x == 0, do: 0.0
  defp truncate(x) when is_float(x), do: toward_zero(x)
  defp truncate(special), do: special

  @spec toward_zero(float()) :: float()
  defp toward_zero(x) do
    case Kernel.trunc(x) do
      0 -> if negative?(x), do: -0.0, else: 0.0
      n -> n * 1.0
    end
  end

  # DataFusion scales, rounds half away from zero (as `Kernel.round/1`
  # does) and scales back, in IEEE doubles: `x * 10^scale` that overflows is
  # infinity, a `10^scale` of 0 (`scale <= -309`) or of infinity (`scale >=
  # 309`) leaves NaN or infinity, and JSON renders both as null (verified:
  # `round(v, 400)` and `round(v, -400)` are `{"r":null}`).
  @spec scaled(float() | SQLNumber.special(), integer()) :: float() | SQLNumber.special()
  defp scaled(x, scale) do
    factor = power_of_ten(scale)

    :*
    |> SQLNumber.arithmetic(x, factor)
    |> round_away()
    |> then(&SQLNumber.arithmetic(:/, &1, factor))
  end

  # Half away from zero, `Kernel.round/1`'s way, but a zero keeps the sign of
  # the number it came from (`round(-0.3)` is `-0.0`, as in IEEE; verified).
  @spec round_away(float() | SQLNumber.special()) :: float() | SQLNumber.special()
  defp round_away(x) when is_float(x) do
    case Kernel.round(x) do
      0 -> if negative?(x), do: -0.0, else: 0.0
      n -> n * 1.0
    end
  end

  defp round_away(special), do: special

  @spec negative?(float()) :: boolean()
  defp negative?(x), do: match?(<<1::1, _rest::63>>, <<x::float>>)

  @spec signature(:round | :trunc) :: binary()
  defp signature(:round), do: @round_signature
  defp signature(:trunc), do: @trunc_signature

  # `10.0.powi(n)` as the engine's runtime computes it (square and multiply,
  # then the reciprocal for a negative `n`), so the last bits match: a
  # power computed another way differs in the final digit for large `n`.
  # An overflow is infinity.
  @spec power_of_ten(integer()) :: float() | :inf
  defp power_of_ten(scale) do
    case square_and_multiply(10.0, abs(scale), 1.0) do
      nil when scale < 0 -> 0.0
      nil -> :inf
      power when scale < 0 -> 1.0 / power
      power -> power
    end
  end

  @spec square_and_multiply(float(), non_neg_integer(), float()) :: float() | nil
  defp square_and_multiply(_base, 0, acc), do: acc

  defp square_and_multiply(base, exponent, acc) do
    acc = if Bitwise.band(exponent, 1) == 1, do: acc * base, else: acc
    exponent = Bitwise.bsr(exponent, 1)

    if exponent == 0, do: acc, else: square_and_multiply(base * base, exponent, acc)
  rescue
    ArithmeticError -> nil
  end

  @doc """
  The engine's planning error for a call, given its arguments' Arrow types
  (`nil` where unknown, which is never refused), or `:ok`.
  """
  @spec check(name(), [binary() | nil], context()) :: :ok | {:error, map()}
  def check(name, types, context) do
    if Enum.any?(types, &is_nil/1), do: :ok, else: refusal(name, types, context)
  end

  @spec refusal(name(), [binary()], context()) :: :ok | {:error, map()}
  defp refusal(name, [], context),
    do: planning(name, [], "'#{name}' does not support zero arguments", context)

  defp refusal(:abs, [type], context) do
    if is_numeric_type(type),
      do: :ok,
      else:
        planning(
          :abs,
          [type],
          "Function 'abs' expects NativeType::Numeric but received NativeType::#{native(type)}",
          context
        )
  end

  defp refusal(:abs, types, context),
    do:
      planning(
        :abs,
        types,
        "Function 'abs' expects 1 arguments but received #{length(types)}",
        context
      )

  defp refusal(name, [type], _context) when name in [:round, :trunc] and is_numeric_type(type),
    do: :ok

  defp refusal(name, [type, scale], _context)
       when name in [:round, :trunc] and is_numeric_type(type) and scale in @integer_types,
       do: :ok

  defp refusal(name, types, context) when name in [:round, :trunc] do
    planning(
      name,
      types,
      "Failed to coerce arguments to satisfy a call to '#{name}' function: coercion from " <>
        "#{Enum.join(types, ", ")} to the signature #{signature(name)} failed",
      context
    )
  end

  defp refusal(name, types, context) when name in [:floor, :ceil],
    do: rounding_refusal(name, types, context)

  @spec rounding_refusal(:floor | :ceil, [binary()], context()) :: :ok | {:error, map()}
  defp rounding_refusal(name, [type], context) do
    if is_numeric_type(type),
      do: :ok,
      else:
        planning(
          name,
          [type],
          "Failed to coerce arguments to satisfy a call to '#{name}' function: coercion from " <>
            "#{type} to the signature Uniform(1, [Float64, Float32]) failed",
          context
        )
  end

  defp rounding_refusal(name, _types, _context) do
    {:error,
     %{
       status: 405,
       body:
         "This feature is not implemented: #{name |> Atom.to_string() |> String.upcase()} " <>
           "with scale is not supported"
     }}
  end

  @spec planning(name(), [binary()], binary(), context()) :: {:error, map()}
  defp planning(name, types, head, context) do
    tail =
      " No function matches the given name and argument types " <>
        "'#{name}(#{Enum.join(types, ", ")})'. You might need to add explicit type casts.\n" <>
        "\tCandidate functions:\n" <> candidates(name)

    error =
      case context do
        :where -> SQLError.coercion(head <> tail)
        cut when cut in [:order_by, :where_cut] -> SQLError.coercion(head)
        :select -> SQLError.planning(head <> tail)
      end

    {:error, error}
  end

  @spec candidates(name()) :: binary()
  defp candidates(:abs), do: "\tabs(Numeric(1))"

  defp candidates(:round),
    do: "\tround(Float64, Int64)\n\tround(Float32, Int64)\n\tround(Float64)\n\tround(Float32)"

  defp candidates(:trunc),
    do: "\ttrunc(Float32, Int64)\n\ttrunc(Float64, Int64)\n\ttrunc(Float64)\n\ttrunc(Float32)"

  defp candidates(name), do: "\t#{name}(Float64/Float32)"

  @doc "DataFusion's NativeType for an Arrow type, as its messages name it."
  @spec native(binary()) :: binary()
  def native("Utf8"), do: "String"
  def native("Dictionary(Int32, Utf8)"), do: "String"
  def native("Timestamp(ns)"), do: "Timestamp(Nanosecond, None)"
  def native(type), do: type

  @doc """
  The Arrow type an expression has, given the columns' types, or `nil`
  when it cannot be known.
  """
  @spec type_of(SQLParser.expr(), %{binary() => binary()}) :: binary() | nil
  def type_of({:field, ref}, columns), do: Map.get(columns, ref)
  def type_of({:lit, value}, _columns) when is_integer(value), do: "Int64"
  def type_of({:lit, value}, _columns) when is_float(value), do: "Float64"
  def type_of({:lit, value}, _columns) when value in [:inf, :neg_inf], do: "Float64"
  def type_of({:lit, value}, _columns) when is_binary(value), do: "Utf8"
  def type_of({:lit, value}, _columns) when is_boolean(value), do: "Boolean"
  def type_of({:uint, _value}, _columns), do: "UInt64"
  def type_of({:uint_col, _name}, _columns), do: "UInt64"
  def type_of({:neg, inner}, columns), do: type_of(inner, columns)
  def type_of({:cast, _inner, type}, _columns), do: SQLCast.arrow_type(type)
  def type_of({:call, :abs, [arg]}, columns), do: type_of(arg, columns)
  def type_of({:call, _name, _args}, _columns), do: "Float64"

  def type_of({:op, _op, left, right}, columns) do
    case {type_of(left, columns), type_of(right, columns)} do
      {left_type, right_type} when is_numeric_type(left_type) and is_numeric_type(right_type) ->
        SQLNumber.result_type(left_type, right_type)

      _not_arithmetic ->
        nil
    end
  end

  def type_of(_other, _columns), do: nil
end
