defmodule InfluxElixir.Client.Local.SQLFunctions do
  @moduledoc """
  The scalar math functions `Client.Local` evaluates in SQL expressions,
  wherever an expression stands (`WHERE`, the select list, `ORDER BY`, an
  aggregate's argument), as InfluxDB 3 does (verified against Core):

    * `abs(x)` — the magnitude, in the argument's type
    * `round(x)`, `round(x, n)` — half away from zero (`round(-2.5)` is
      `-3.0`), to `n` decimal places (negative `n` rounds left of the
      point: `round(1234.5678, -2)` is `1200.0`); always a float
    * `floor(x)`, `ceil(x)` — always a float

  A null argument makes the result null. Names are case-insensitive.

  The engine checks the arguments' types when it plans the query, so a
  wrong one fails the query even when no row would reach the call
  (`check/3`). The message depends on where the call stands: in `WHERE`
  it carries the `type_coercion` prefix, in `ORDER BY` it is cut after its
  first sentence, and in the select list it has neither. `floor` and `ceil`
  with a second argument are the engine's 405.
  """

  alias InfluxElixir.Client.Local.SQLParser

  @type name :: :abs | :round | :floor | :ceil
  @type context :: :where | :select | :order_by

  @names %{"abs" => :abs, "round" => :round, "floor" => :floor, "ceil" => :ceil}

  @numeric ~w(Int64 UInt64 Float64)

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

  @spec compute(name(), [number()]) :: number()
  defp compute(:abs, [x]), do: Kernel.abs(x)
  defp compute(:round, [x]), do: Kernel.round(x) * 1.0
  defp compute(:round, [x, 0]), do: Kernel.round(x) * 1.0

  # DataFusion scales, rounds half away from zero (as `Kernel.round/1`
  # does) and scales back.
  defp compute(:round, [x, scale]) do
    factor = :math.pow(10, scale)
    Kernel.round(x * factor) / factor
  end

  defp compute(:floor, [x]), do: Float.floor(x * 1.0)
  defp compute(:ceil, [x]), do: Float.ceil(x * 1.0)

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
    if type in @numeric,
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

  defp refusal(:round, [type], _context) when type in @numeric, do: :ok

  defp refusal(:round, [type, scale], _context) when type in @numeric and scale == "Int64",
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

  defp refusal(name, [type], context) when name in [:floor, :ceil] do
    if type in @numeric,
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

  defp refusal(name, _types, _context) when name in [:floor, :ceil] do
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

    body =
      case context do
        :where -> "type_coercion\ncaused by\nError during planning: " <> head <> tail
        :order_by -> "type_coercion\ncaused by\nError during planning: " <> head
        :select -> "Error during planning: " <> head <> tail
      end

    {:error, %{status: 400, body: body}}
  end

  @spec candidates(name()) :: binary()
  defp candidates(:abs), do: "\tabs(Numeric(1))"

  defp candidates(:round),
    do: "\tround(Float64, Int64)\n\tround(Float32, Int64)\n\tround(Float64)\n\tround(Float32)"

  defp candidates(name), do: "\t#{name}(Float64/Float32)"

  # DataFusion's NativeType for an Arrow type, as its message names it.
  @spec native(binary()) :: binary()
  defp native("Utf8"), do: "String"
  defp native("Dictionary(Int32, Utf8)"), do: "String"
  defp native("Timestamp(ns)"), do: "Timestamp(Nanosecond, None)"
  defp native(type), do: type

  @doc """
  The Arrow type an expression has, given the columns' types, or `nil`
  when it cannot be known.
  """
  @spec type_of(SQLParser.expr(), %{binary() => binary()}) :: binary() | nil
  def type_of({:field, name}, columns), do: Map.get(columns, name)
  def type_of({:lit, value}, _columns) when is_integer(value), do: "Int64"
  def type_of({:lit, value}, _columns) when is_float(value), do: "Float64"
  def type_of({:lit, value}, _columns) when is_binary(value), do: "Utf8"
  def type_of({:neg, inner}, columns), do: type_of(inner, columns)
  def type_of({:cast, _inner, :integer}, _columns), do: "Int64"
  def type_of({:cast, _inner, :float}, _columns), do: "Float64"
  def type_of({:cast, _inner, :string}, _columns), do: "Utf8"
  def type_of({:call, :abs, [arg]}, columns), do: type_of(arg, columns)
  def type_of({:call, _name, _args}, _columns), do: "Float64"

  def type_of({:op, _op, left, right}, columns) do
    case {type_of(left, columns), type_of(right, columns)} do
      {"Float64", type} when type in @numeric -> "Float64"
      {type, "Float64"} when type in @numeric -> "Float64"
      {left_type, right_type} when left_type in @numeric and right_type in @numeric -> "Int64"
      _not_arithmetic -> nil
    end
  end

  def type_of(_other, _columns), do: nil
end
