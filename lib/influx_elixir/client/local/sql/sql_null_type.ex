defmodule InfluxElixir.Client.Local.SQLNullType do
  @moduledoc false
  # What the double knows of an expression that is the null whatever the rows, and of the
  # difference of a null and `time`. The types the engine gives an expression with a `NULL`
  # in it (`NULL + 1.5` is `Float64`, `NULL + NULL` an `Int64`, `abs(NULL)` a `Float64`) are
  # in `InfluxElixir.Client.Local.SQLExprType`, the one table of types.
  #
  # `null_valued?/1` says whether an expression is the null whatever the rows: a call of a
  # function of numbers or text with such an argument is null, so the planner's typing of
  # the other arguments decides nothing the double has to compute.

  alias InfluxElixir.Client.Local.{SQLExpr, SQLScalar}

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

  @doc "Whether an expression is the difference of a null and `time` (`time - NULL`, `NULL - time`)."
  @spec duration?(term()) :: boolean()
  def duration?({:op, :-, {:field, "time"}, other}), do: constant_null?(other)
  def duration?({:op, :-, other, {:field, "time"}}), do: constant_null?(other)
  def duration?(_other), do: false

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
end
