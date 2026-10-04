defmodule InfluxElixir.Client.Local.SQLFold do
  @moduledoc false
  # What the engine's optimizer finds when it folds the constants of a SQL
  # query, for `InfluxElixir.Client.Local` (verified against InfluxDB 3 Core).
  #
  # A `CAST` of a constant that cannot be performed (`CAST('abc' AS INT)`,
  # `CAST(3000000000 AS INT)`, a float outside the integer's range) is
  # evaluated while the plan is simplified, so it fails the query before a row
  # is read, wherever it stands (the select list, `WHERE`, `ORDER BY`, an
  # aggregate's argument, an expression nothing reads) and whatever the table
  # holds: status 500,
  #
  #     Optimizer rule 'simplify_expressions' failed
  #     caused by
  #     Arrow error: Cast error: Can't cast value 3000000000 to type Int32
  #
  # A cast of a column fails per value instead (`InfluxElixir.Client.Local.SQLCast`).
  # An expression that fails at run time on a constant (a division by zero, an
  # `abs` or a negation of the smallest integer) is not folded; it fails when a
  # row is evaluated.

  alias InfluxElixir.Client.Local.{SQLCast, SQLError, SQLEval, SQLExpr, SQLNumber, SQLParser}

  # An expression that reads no column reads no point.
  @no_point %{measurement: "", tags: %{}, fields: %{}, timestamp: nil}

  @doc """
  The optimizer's error for the first constant cast the query cannot
  perform, or `:ok`. The query has its parameters bound.
  """
  @spec check(SQLParser.parsed_query()) :: :ok | {:error, SQLError.t()}
  def check(query) do
    query
    |> expressions()
    |> Enum.find_value(:ok, &cast_failure/1)
  end

  @doc """
  The smallest integer, as text, whose negation a constant sub-expression
  of `expr` performs (`-(-9223372036854775807 - 1)`), or `nil`. A constant
  that fails some other way is not one.
  """
  @spec negation_overflow(SQLExpr.t()) :: binary() | nil
  def negation_overflow(expr), do: SQLExpr.find_value(expr, &own_overflow/1)

  @doc """
  Whether a constant sub-expression of `expr` divides the smallest integer of
  a type by -1 (`(-9223372036854775807 - 1) / -1`), which overflows.
  """
  @spec division_overflow?(SQLExpr.t()) :: boolean()
  def division_overflow?(expr), do: SQLExpr.any?(expr, &own_division?/1)

  @spec own_division?(SQLExpr.t()) :: boolean()
  defp own_division?({:op, :/, left, right}) do
    with {:ok, dividend} <- constant(left),
         {:ok, divisor} <- constant(right) do
      overflowing_division?(dividend, divisor)
    else
      _not_constant -> false
    end
  end

  defp own_division?(_other), do: false

  # An integer type's minimum over -1, in the wider of the two types.
  @spec overflowing_division?(term(), term()) :: boolean()
  defp overflowing_division?(dividend, divisor) when is_integer(dividend) and is_integer(divisor),
    do: divisor == -1 and dividend == SQLNumber.minimum(:int64)

  defp overflowing_division?({:int, left_bits, dividend}, {:int, right_bits, divisor}),
    do: divisor == -1 and dividend == SQLNumber.minimum(max(left_bits, right_bits))

  defp overflowing_division?(_dividend, _divisor), do: false

  @spec own_overflow(SQLExpr.t()) :: binary() | nil
  defp own_overflow({:neg, inner}) do
    case constant(inner) do
      {:ok, value} when is_integer(value) -> minimum_text(value, 64)
      {:ok, {:int, bits, value}} -> minimum_text(value, bits)
      _not_a_constant_minimum -> nil
    end
  end

  defp own_overflow(_other), do: nil

  @spec minimum_text(integer(), 8 | 16 | 32 | 64) :: binary() | nil
  defp minimum_text(value, bits) do
    if value == SQLNumber.minimum(if(bits == 64, do: :int64, else: bits)),
      do: Integer.to_string(value)
  end

  # ---------------------------------------------------------------------------
  # Constant casts
  # ---------------------------------------------------------------------------

  @spec cast_failure(SQLExpr.t()) :: {:error, SQLError.t()} | nil
  defp cast_failure(expr), do: SQLExpr.find_value(expr, &fold_cast/1)

  @spec fold_cast(SQLExpr.t()) :: {:error, SQLError.t()} | nil
  defp fold_cast({:cast, inner, type}) do
    with {:ok, value} <- constant(inner),
         {:error, message} <- SQLCast.fold(value, type) do
      {:error, SQLError.simplify("Arrow error: Cast error: " <> message)}
    else
      _performed_or_not_constant -> nil
    end
  end

  defp fold_cast(_other), do: nil

  @doc """
  The value of an expression that reads no column, or `:error` when it
  cannot be known before a row is read (a failure at run time, a refusal).
  """
  @spec constant(SQLExpr.t()) :: {:ok, term()} | :error
  def constant(expr) do
    if foldable?(expr), do: {:ok, SQLEval.eval(expr, @no_point)}, else: :error
  rescue
    # An expression the type check has not seen yet may be one the evaluator is not given
    # (`NOT 0`): it has no value to know.
    _error in [ArgumentError, FunctionClauseError, ArithmeticError] -> :error
  catch
    {:query_error, _error} -> :error
  end

  @spec foldable?(SQLExpr.t()) :: boolean()
  defp foldable?(expr), do: not SQLExpr.any?(expr, &reads_row?/1)

  @spec reads_row?(SQLExpr.t()) :: boolean()
  defp reads_row?({kind, _name}) when kind in [:field, :uint_col, :param], do: true
  defp reads_row?(_other), do: false

  # ---------------------------------------------------------------------------
  # The query's expressions
  # ---------------------------------------------------------------------------

  # Every expression a query holds, in the order written.
  @spec expressions(SQLParser.parsed_query()) :: [SQLExpr.t()]
  defp expressions(query) do
    projected = for {expr, _output} <- query.projection_columns || [], is_tuple(expr), do: expr

    aggregated =
      for {:aggregate, _agg, expr, _output} <- query.select_columns || [], do: expr

    ordered = for {{:expr, expr}, _direction} <- query.order_by, do: expr

    projected ++ aggregated ++ conditions(query.where) ++ ordered
  end

  @spec conditions([SQLParser.where_node()]) :: [SQLExpr.t()]
  defp conditions(nodes), do: Enum.flat_map(nodes, &condition/1)

  @spec condition(SQLParser.where_node()) :: [SQLExpr.t()]
  defp condition({:or, branches}), do: Enum.flat_map(branches, &conditions/1)
  defp condition({:not, nodes}), do: conditions(nodes)

  defp condition({op, left, {low, high}}) when op in [:between, :not_between],
    do: operands([left, low, high])

  defp condition({op, left, values}) when op in [:in, :not_in] and is_list(values),
    do: operands([left | values])

  defp condition({op, left, right}) when op in [:eq, :ne, :gt, :lt, :gte, :lte],
    do: operands([left, right])

  defp condition({_op, left, _rest}), do: operands([left])

  @spec operands([term()]) :: [SQLExpr.t()]
  defp operands(list), do: for({:expr, expr} <- list, do: expr)
end
