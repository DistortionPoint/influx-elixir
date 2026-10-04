defmodule InfluxElixir.Client.Local.SQLNullType do
  @moduledoc false
  # What the engine makes of an expression that reads no column and has a `NULL` in it
  # (verified against InfluxDB 3 Core with `arrow_typeof`):
  #
  #   * the literal `NULL` is `Null`, as is its negation, a `CASE` whose results are all
  #     `NULL` (or are missing), and a `COALESCE` of them
  #   * an arithmetic operator takes the type of its other side (`NULL + 1.5` is `Float64`),
  #     and `Int64` where both sides are `Null` (`NULL + NULL`)
  #   * `NULLIF(NULL, NULL)` is `Utf8View`, `abs(NULL)` is `Float64`, `CAST(NULL AS t)` is `t`
  #
  # A type the double does not know is `:unknown`, never a guess. `null_valued?/1` says
  # whether an expression is the null whatever the rows: a call of a function of numbers
  # or text with such an argument is null, so the planner's typing of the other arguments
  # decides nothing the double has to compute.

  alias InfluxElixir.Client.Local.{SQLCast, SQLExpr, SQLNumber, SQLScalar}

  @typedoc "An Arrow type name, or `:unknown`."
  @type type :: binary() | :unknown

  @doc "The type of an expression that reads no column (`:unknown` for any other)."
  @spec constant_type(SQLExpr.t()) :: type()
  def constant_type({:lit, nil}), do: "Null"
  def constant_type({:lit, value}) when is_integer(value), do: "Int64"

  def constant_type({:lit, value}) when is_float(value) or value in [:inf, :neg_inf],
    do: "Float64"

  def constant_type({:lit, value}) when is_binary(value), do: "Utf8"
  def constant_type({:lit, value}) when is_boolean(value), do: "Boolean"
  def constant_type({:uint, _value}), do: "UInt64"
  def constant_type({:cast, _inner, type}), do: SQLCast.arrow_type(type)
  def constant_type({:neg, inner}), do: signed(constant_type(inner))

  def constant_type({:op, op, left, right}),
    do: arithmetic(op, constant_type(left), constant_type(right))

  def constant_type({:case, _operand, whens, otherwise}),
    do: results(Enum.map(whens, &elem(&1, 1)) ++ [otherwise])

  def constant_type({:call, :coalesce, args}), do: results(args)

  def constant_type({:call, :nullif, [first, second]}) do
    case {constant_type(first), constant_type(second)} do
      {"Null", "Null"} -> "Utf8View"
      {"Null", _typed} -> :unknown
      {type, _other} -> type
    end
  end

  def constant_type({:call, :abs, [argument]}) do
    case constant_type(argument) do
      "Null" -> "Float64"
      type -> type
    end
  end

  def constant_type({:call, name, args}) do
    if SQLScalar.function?(name) and name not in [:greatest, :least] do
      case SQLScalar.type_of(name, Enum.map(args, &constant_type/1)) do
        nil -> :unknown
        type -> type
      end
    else
      :unknown
    end
  end

  def constant_type(_other), do: :unknown

  @doc """
  The type of `left op right` given the types of its sides, where one or both is `Null`;
  the type of the numbers otherwise, `:unknown` for any other pair.
  """
  @spec arithmetic(atom(), type(), type()) :: type()
  def arithmetic(_op, "Null", "Null"), do: "Int64"

  def arithmetic(_op, "Null", type), do: numeric(type)
  def arithmetic(_op, type, "Null"), do: numeric(type)

  def arithmetic(_op, left, right) when is_binary(left) and is_binary(right) do
    if numeric(left) != :unknown and numeric(right) != :unknown,
      do: SQLNumber.result_type(left, right),
      else: :unknown
  end

  def arithmetic(_op, _left, _right), do: :unknown

  @doc """
  Whether an expression is the null whatever the rows: the null literal, and an operator,
  a negation, a cast or a call of one of the functions of numbers and text with one.
  """
  @spec null_valued?(SQLExpr.t()) :: boolean()
  def null_valued?({:lit, nil}), do: true
  def null_valued?({kind, inner}) when kind in [:neg, :pos], do: null_valued?(inner)
  def null_valued?({:cast, inner, _type}), do: null_valued?(inner)
  def null_valued?({:op, _op, left, right}), do: null_valued?(left) or null_valued?(right)

  def null_valued?({:call, name, args}) do
    (name in [:abs, :round, :trunc, :floor, :ceil] or
       (SQLScalar.function?(name) and name not in [:greatest, :least])) and
      Enum.any?(args, &null_valued?/1)
  end

  def null_valued?(_other), do: false

  @doc """
  Whether a query uses the difference of a null and `time` (`NULL - time`, `time - NULL`) other
  than as a whole select item, a whole `ORDER BY` term or the operand of `IS [NOT] NULL`.

  The engine types it as a `Duration(ns)`, which the double does not: every use of one (`NULL -
  time - time`, `NULL - time > 0`, `abs(NULL - time)`, `sum(NULL - time)`) has an error of its own
  that was verified one by one, and the wrong one is not worth guessing.
  """
  @spec duration_misuse?(map()) :: boolean()
  def duration_misuse?(query) do
    projected = for {expr, _output} <- query.projection_columns || [], is_tuple(expr), do: expr
    ordered = for {{:expr, expr}, _direction} <- query.order_by, do: expr

    Enum.any?(projected ++ ordered, &misuse?(&1, true)) or
      misuse?(query.where, false) or
      misuse?(query.select_columns, false) or
      misuse?(query.having, false) or
      Enum.any?(ordered, &misuse?(&1, true))
  end

  @spec misuse?(term(), boolean()) :: boolean()
  defp misuse?(term, allowed?) do
    cond do
      duration?(term) -> not allowed?
      match?({:expr, _inner}, term) -> misuse?(elem(term, 1), allowed?)
      is_tuple(term) -> tuple_misuse?(term)
      is_list(term) -> Enum.any?(term, &misuse?(&1, false))
      is_map(term) -> term |> Map.values() |> Enum.any?(&misuse?(&1, false))
      true -> false
    end
  end

  @spec tuple_misuse?(tuple()) :: boolean()
  defp tuple_misuse?(term) do
    allowed? = elem(term, 0) in [:is_null, :is_not_null]
    term |> Tuple.to_list() |> Enum.any?(&misuse?(&1, allowed?))
  end

  @spec duration?(term()) :: boolean()
  defp duration?({:op, :-, {:field, "time"}, other}), do: constant_null?(other)
  defp duration?({:op, :-, other, {:field, "time"}}), do: constant_null?(other)
  defp duration?(_other), do: false

  # A null that reads no column (`NULL - time` is null too, but is a duration itself).
  @spec constant_null?(SQLExpr.t()) :: boolean()
  defp constant_null?(expr), do: not reads_column?(expr) and null_valued?(expr)

  # Whether an expression reads a column (so that this module need not call the module of the
  # expressions, which calls the functions that call this one).
  @spec reads_column?(term()) :: boolean()
  defp reads_column?({kind, _name}) when kind in [:field, :uint_col], do: true
  defp reads_column?(term) when is_tuple(term), do: term |> Tuple.to_list() |> reads_column?()
  defp reads_column?(terms) when is_list(terms), do: Enum.any?(terms, &reads_column?/1)
  defp reads_column?(_other), do: false

  @spec signed(type()) :: type()
  defp signed("Null"), do: "Null"
  defp signed(type), do: numeric(type)

  @spec numeric(type()) :: type()
  defp numeric(type) when type in ["Int64", "Int32", "Int16", "Int8", "UInt64", "Float64"],
    do: type

  defp numeric(_other), do: :unknown

  # The one type that results share, ignoring the nulls; `Null` where all are.
  @spec results([SQLExpr.t() | nil]) :: type()
  defp results(results) do
    results
    |> Enum.map(fn
      nil -> "Null"
      result -> constant_type(result)
    end)
    |> Enum.reject(&(&1 == "Null"))
    |> Enum.uniq()
    |> case do
      [] -> "Null"
      [type] -> type
      _several -> :unknown
    end
  end
end
