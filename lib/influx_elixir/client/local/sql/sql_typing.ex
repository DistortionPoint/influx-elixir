defmodule InfluxElixir.Client.Local.SQLTyping do
  @moduledoc false
  # Gives a SQL query's expressions the types the engine gives them, for
  # `InfluxElixir.Client.Local`.
  #
  # The store keeps an integer field as an integer whether it was written as
  # `Int64` (`5i`) or `UInt64` (`5u`) and registers which, per column. An
  # expression has to know: `u / 2` is a decimal division of a `UInt64` by an
  # `Int64`, `u + u` wraps at 2^64, `-u` is a planning error. `retype/2` marks
  # each read of an unsigned column in an expression as
  # `{:uint_col, name}` (see `InfluxElixir.Client.Local.SQLEval`), once per
  # query, before anything evaluates it.
  #
  # A CTE's rows hold the values its query computed: an expression's result
  # carries its type, and `unsigned_outputs/3` names the columns that pass an
  # unsigned column through unchanged, which the executor tags in the CTE's
  # rows so the next query reads them as `UInt64` too.

  alias InfluxElixir.Client.Local.{SQLError, SQLExpr, SQLParser}

  @typedoc "Says whether a column is `UInt64`."
  @type unsigned :: (binary() -> boolean())

  @doc "The query with each read of an unsigned column in an expression retyped."
  @spec retype(SQLParser.parsed_query(), unsigned()) :: SQLParser.parsed_query()
  def retype(query, unsigned?) do
    %{
      query
      | projection_columns: projection(query.projection_columns, unsigned?),
        select_columns: select_columns(query.select_columns, unsigned?),
        where: nodes(query.where, unsigned?),
        order_by: order_by(query.order_by, unsigned?)
    }
  end

  @spec projection([SQLParser.projection()] | nil, unsigned()) ::
          [SQLParser.projection()] | nil
  defp projection(nil, _unsigned?), do: nil

  defp projection(columns, unsigned?) do
    Enum.map(columns, fn
      {source, output} when is_binary(source) -> {source, output}
      {expr, output} -> {expr(expr, unsigned?), output}
    end)
  end

  @spec select_columns([SQLParser.select_column()] | nil, unsigned()) ::
          [SQLParser.select_column()] | nil
  defp select_columns(nil, _unsigned?), do: nil

  defp select_columns(columns, unsigned?) do
    Enum.map(columns, fn
      {:aggregate, agg, expr, output} -> {:aggregate, agg, expr(expr, unsigned?), output}
      column -> column
    end)
  end

  @spec order_by(SQLParser.order_by(), unsigned()) :: SQLParser.order_by()
  defp order_by(terms, unsigned?) do
    Enum.map(terms, fn
      {{:expr, expr}, direction} -> {{:expr, expr(expr, unsigned?)}, direction}
      term -> term
    end)
  end

  @spec nodes([SQLParser.where_node()], unsigned()) :: [SQLParser.where_node()]
  defp nodes(nodes, unsigned?), do: Enum.map(nodes, &node(&1, unsigned?))

  @spec node(SQLParser.where_node(), unsigned()) :: SQLParser.where_node()
  defp node({:or, branches}, unsigned?),
    do: {:or, Enum.map(branches, &nodes(&1, unsigned?))}

  defp node({:not, conjunction}, unsigned?), do: {:not, nodes(conjunction, unsigned?)}

  defp node({op, left, {low, high}}, unsigned?) when op in [:between, :not_between],
    do: {op, operand(left, unsigned?), {operand(low, unsigned?), operand(high, unsigned?)}}

  defp node({op, left, values}, unsigned?) when op in [:in, :not_in] and is_list(values),
    do: {op, operand(left, unsigned?), Enum.map(values, &operand(&1, unsigned?))}

  defp node({op, left, right}, unsigned?)
       when op in [:eq, :ne, :gt, :lt, :gte, :lte],
       do: {op, operand(left, unsigned?), operand(right, unsigned?)}

  defp node({op, left, right}, unsigned?), do: {op, operand(left, unsigned?), right}

  @spec operand(term(), unsigned()) :: term()
  defp operand({:expr, expr}, unsigned?), do: {:expr, expr(expr, unsigned?)}
  defp operand(other, _unsigned?), do: other

  @spec expr(SQLExpr.t(), unsigned()) :: SQLExpr.t()
  defp expr({:field, name} = field, unsigned?) when is_binary(name),
    do: if(unsigned?.(name), do: {:uint_col, name}, else: field)

  # Two negations in a row cancel before the planner types them (verified:
  # `-(-u)` is `u`, `-(-(-u))` is the engine's negation error).
  defp expr({:neg, {:neg, inner}}, unsigned?), do: expr(inner, unsigned?)
  defp expr(other, unsigned?), do: SQLExpr.map_children(other, &expr(&1, unsigned?))

  @doc """
  Refuses a CTE whose select list casts to a narrow integer (`CAST(x AS INT)`
  is an `Int32`, `SMALLINT` an `Int16`, `TINYINT` an `Int8`): the rows of a
  CTE are read back as `Int64`, so the next query would wrap at the wrong
  width.
  """
  @spec check_cte_outputs(SQLParser.parsed_query()) :: :ok | {:error, SQLError.t()}
  def check_cte_outputs(query) do
    projected = for {expr, _output} <- query.projection_columns || [], is_tuple(expr), do: expr
    aggregated = for {:aggregate, _agg, expr, _output} <- query.select_columns || [], do: expr

    if Enum.any?(projected ++ aggregated, &narrow_cast?/1),
      do:
        {:error,
         SQLError.refusal(
           "a CTE that casts to INT, SMALLINT or TINYINT: its rows would be read back as " <>
             "Int64, and the engine's narrower type is not carried through a CTE"
         )},
      else: :ok
  end

  @spec narrow_cast?(SQLExpr.t()) :: boolean()
  defp narrow_cast?(expr), do: SQLExpr.any?(expr, &narrow_cast_node?/1)

  @spec narrow_cast_node?(SQLExpr.t()) :: boolean()
  defp narrow_cast_node?({:cast, _inner, type}), do: type in [:int8, :int16, :int32]
  defp narrow_cast_node?(_other), do: false

  @doc """
  The output columns of a (CTE) query that are an unsigned column passed
  through as it is. `columns` are the query's output columns in order.
  """
  @spec unsigned_outputs(SQLParser.parsed_query(), [binary()] | nil, unsigned()) ::
          MapSet.t(binary())
  def unsigned_outputs(query, columns, unsigned?) do
    outputs =
      cond do
        query.distinct_columns ->
          Enum.filter(query.distinct_columns, unsigned?)

        query.select_columns ->
          Enum.flat_map(query.select_columns, &select_output(&1, unsigned?))

        query.projection_columns ->
          Enum.flat_map(query.projection_columns, &projected(&1, unsigned?))

        true ->
          Enum.filter(columns || [], unsigned?)
      end

    MapSet.new(outputs)
  end

  @spec projected(SQLParser.projection(), unsigned()) :: [binary()]
  defp projected({source, output}, unsigned?) when is_binary(source),
    do: if(unsigned?.(source), do: [output], else: [])

  defp projected(_expression, _unsigned?), do: []

  @spec select_output(SQLParser.select_column(), unsigned()) :: [binary()]
  defp select_output({:grouping_column, source, output}, unsigned?),
    do: if(unsigned?.(source), do: [output], else: [])

  defp select_output({:ordered_aggregate, _agg, field, _ordering, output}, unsigned?),
    do: if(unsigned?.(field), do: [output], else: [])

  defp select_output({:selector, _kind, field, _ordering, :value, output}, unsigned?),
    do: if(unsigned?.(field), do: [output], else: [])

  defp select_output(_column, _unsigned?), do: []
end
