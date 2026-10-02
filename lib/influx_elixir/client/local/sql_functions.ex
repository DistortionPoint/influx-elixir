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
    * `floor(x)`, `ceil(x)` — always a float

  A null argument makes the result null. Names are case-insensitive.

  The engine checks the arguments' types when it plans the query, so a
  wrong one fails the query even when no row would reach the call
  (`check/3`). The message depends on where the call stands: in `WHERE`
  it carries the `type_coercion` prefix, in `ORDER BY` it is cut after its
  first sentence, and in the select list it has neither. `floor` and `ceil`
  with a second argument are the engine's 405.
  """

  alias InfluxElixir.Client.Local.{SQLError, SQLParser}

  @type name :: :abs | :round | :floor | :ceil
  @type context :: :where | :select | :order_by

  @names %{"abs" => :abs, "round" => :round, "floor" => :floor, "ceil" => :ceil}

  @doc "Whether an Arrow type name is one of the engine's numeric types."
  defguard is_numeric_type(type) when type in ["Int64", "UInt64", "Float64"]

  @round_signature "OneOf([Exact([Float64, Int64]), Exact([Float32, Int64]), " <>
                     "Exact([Float64]), Exact([Float32])])"

  @doc "The function a name (any case) calls, or `nil` for any other name."
  @spec lookup(binary()) :: name() | nil
  def lookup(name), do: Map.get(@names, String.downcase(name))

  @doc """
  Evaluates a call the planner has accepted (`check/3`), its arguments
  already evaluated: numbers, or `nil`, which makes the result `nil`.
  """
  @spec call(name(), [number() | nil]) :: number() | nil
  def call(name, args) do
    if Enum.any?(args, &is_nil/1), do: nil, else: compute(name, args)
  end

  @spec compute(name(), [number()]) :: number() | nil
  defp compute(:abs, [x]), do: Kernel.abs(x)
  defp compute(:round, [x]), do: round_away(x)
  defp compute(:round, [x, 0]), do: round_away(x)

  # DataFusion scales, rounds half away from zero (as `Kernel.round/1`
  # does) and scales back, in IEEE doubles: `x * 10^scale` that overflows is
  # infinity, a `10^scale` of 0 (`scale <= -309`) or of infinity (`scale >=
  # 309`) leaves NaN or infinity, and JSON renders both as null (verified:
  # `round(v, 400)` and `round(v, -400)` are `{"r":null}`). Erlang raises on
  # those. A null that is not a missing value cannot be a result row here
  # (the engine omits missing values, and a row map without the key is how
  # this double says so), so the query is refused by name.
  defp compute(:round, [x, scale]) do
    case power_of_ten(scale) do
      factor when is_float(factor) -> round_away(x * factor) / factor
      nil -> out_of_range(scale)
    end
  rescue
    ArithmeticError -> out_of_range(scale)
  end

  defp compute(:floor, [x]), do: Float.floor(x * 1.0)
  defp compute(:ceil, [x]), do: Float.ceil(x * 1.0)

  # Half away from zero, `Kernel.round/1`'s way, but a zero keeps the sign of
  # the number it came from (`round(-0.3)` is `-0.0`, as in IEEE; verified).
  @spec round_away(number()) :: float()
  defp round_away(x) when is_integer(x), do: x * 1.0

  defp round_away(x) do
    case Kernel.round(x) do
      0 -> if match?(<<1::1, _rest::63>>, <<x::float>>), do: -0.0, else: 0.0
      n -> n * 1.0
    end
  end

  @spec out_of_range(integer()) :: no_return()
  defp out_of_range(scale) do
    throw(
      {:query_error,
       SQLError.refusal(
         "round(x, #{scale}) leaves the range of a double: InfluxDB answers null (a NaN or " <>
           "infinity as JSON), which a result row here cannot hold"
       )}
    )
  end

  # `10.0.powi(n)` as the engine's runtime computes it (square and multiply,
  # then the reciprocal for a negative `n`), so the last bits match: a
  # power computed another way differs in the final digit for large `n`.
  # `nil` is infinity, which a float cannot hold here.
  @spec power_of_ten(integer()) :: float() | nil
  defp power_of_ten(scale) do
    case square_and_multiply(10.0, abs(scale), 1.0) do
      nil when scale < 0 -> 0.0
      nil -> nil
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

  defp refusal(:round, [type], _context) when is_numeric_type(type), do: :ok

  defp refusal(:round, [type, scale], _context) when is_numeric_type(type) and scale == "Int64",
    do: :ok

  defp refusal(:round, types, context) do
    planning(
      :round,
      types,
      "Failed to coerce arguments to satisfy a call to 'round' function: coercion from " <>
        "#{Enum.join(types, ", ")} to the signature #{@round_signature} failed",
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
        :order_by -> SQLError.coercion(head)
        :select -> SQLError.planning(head <> tail)
      end

    {:error, error}
  end

  @spec candidates(name()) :: binary()
  defp candidates(:abs), do: "\tabs(Numeric(1))"

  defp candidates(:round),
    do: "\tround(Float64, Int64)\n\tround(Float32, Int64)\n\tround(Float64)\n\tround(Float32)"

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
  def type_of({:field, name}, columns), do: Map.get(columns, name)
  def type_of({:lit, value}, _columns) when is_integer(value), do: "Int64"
  def type_of({:lit, value}, _columns) when is_float(value), do: "Float64"
  def type_of({:lit, value}, _columns) when is_binary(value), do: "Utf8"
  def type_of({:lit, value}, _columns) when is_boolean(value), do: "Boolean"
  def type_of({:uint, _value}, _columns), do: "UInt64"
  def type_of({:neg, inner}, columns), do: type_of(inner, columns)
  def type_of({:cast, _inner, :integer}, _columns), do: "Int64"
  def type_of({:cast, _inner, :float}, _columns), do: "Float64"
  def type_of({:cast, _inner, :string}, _columns), do: "Utf8"
  def type_of({:call, :abs, [arg]}, columns), do: type_of(arg, columns)
  def type_of({:call, _name, _args}, _columns), do: "Float64"

  def type_of({:op, _op, left, right}, columns) do
    case {type_of(left, columns), type_of(right, columns)} do
      {"Float64", type} when is_numeric_type(type) ->
        "Float64"

      {type, "Float64"} when is_numeric_type(type) ->
        "Float64"

      {left_type, right_type} when is_numeric_type(left_type) and is_numeric_type(right_type) ->
        "Int64"

      _not_arithmetic ->
        nil
    end
  end

  def type_of(_other, _columns), do: nil
end
