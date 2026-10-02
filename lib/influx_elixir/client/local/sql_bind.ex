defmodule InfluxElixir.Client.Local.SQLBind do
  @moduledoc """
  Binds the `$name` placeholders of a parsed query.

  A `$name` is read as a value wherever a value may stand: a comparand, an
  item of an IN list, a bound of BETWEEN, a LIKE or regex pattern, an operand
  of an expression, a select-list constant, LIMIT or OFFSET. The parser keeps
  it as a node and `bind/2` replaces the node with the value the engine would
  read for it from the request's JSON: a non-negative integer is a `UInt64`
  (`{:uint, n}`), any other integer an `Int64`, a float a `Float64`, a string
  a `Utf8`; text is never substituted, so a value is data whatever it
  contains.
  """

  alias InfluxElixir.Client.Local.{
    SQLClauses,
    SQLError,
    SQLExpr,
    SQLLimit,
    SQLParser,
    SQLSelect,
    SQLTime,
    SQLWhere
  }

  @comparison_ops [:eq, :ne, :gt, :lt, :gte, :lte]

  @doc """
  Binds a parsed query's `$name` placeholders to `params`, whose values are
  what the engine reads from the request (see
  `InfluxElixir.Client.QueryParams.engine_values/1`).

  A placeholder with no value is the engine's planning error; a value the
  placeholder's place cannot take is the engine's error for it: a `time`
  compared with a number is a type error naming the number's type (`UInt64`
  for a non-negative integer), `LIMIT` takes an integer or null. A query
  without placeholders is returned as it is. Only the query's own clauses
  are bound, not its CTEs.
  """
  @spec bind(SQLParser.parsed_query(), %{binary() => term()}) ::
          {:ok, SQLParser.parsed_query()} | {:error, map()}
  def bind(query, params) do
    parts = [
      query.projection_columns,
      query.select_columns,
      query.where,
      query.order_by,
      query.limit,
      query.offset
    ]

    case placeholders(parts) do
      [] ->
        {:ok, query}

      names ->
        with :ok <- all_bound(names, params),
             {:ok, where} <- bind_where_nodes(query.where, params),
             {:ok, limit, offset, limit_error} <-
               SQLLimit.bind(query.limit, query.offset, params) do
          {:ok,
           %{
             query
             | where: where,
               projection_columns: bind_projection(query.projection_columns, params),
               select_columns: bind_select_columns(query.select_columns, params),
               order_by: bind_order_by(query.order_by, params),
               limit: limit,
               offset: offset,
               limit_error: limit_error || query.limit_error
           }}
        end
    end
  end

  # Every `$name` in a term, in order.
  @spec placeholders(term()) :: [binary()]
  defp placeholders(terms) when is_list(terms), do: Enum.flat_map(terms, &placeholders/1)
  defp placeholders({:param, name}) when is_binary(name), do: [name]
  defp placeholders({:param, name, :left}) when is_binary(name), do: [name]
  defp placeholders({:like_param, name, _case_insensitive}), do: [name]
  defp placeholders({:regex_param, name, _op}), do: [name]
  defp placeholders(%{__struct__: _module}), do: []
  defp placeholders(term) when is_tuple(term), do: term |> Tuple.to_list() |> placeholders()
  defp placeholders(_other), do: []

  @doc """
  Checks that a statement that binds no parameters names none: a `$name` is
  the engine's planning error for a placeholder with no value.
  """
  @spec reject_placeholders([SQLWhere.node_t()]) :: :ok | {:error, map()}
  def reject_placeholders(nodes), do: all_bound(placeholders(nodes), %{})

  @spec all_bound([binary()], %{binary() => term()}) :: :ok | {:error, map()}
  defp all_bound(names, params) do
    Enum.find_value(names, :ok, fn name ->
      case Map.fetch(params, name) do
        {:ok, value} when is_map(value) or is_list(value) ->
          {:error, SQLError.refusal("the parameter $#{name} is a JSON object or array")}

        {:ok, _scalar} ->
          nil

        :error ->
          {:error, SQLError.planning("No value found for placeholder with name $#{name}")}
      end
    end)
  end

  @spec map_ok([term()], (term() -> {:ok, term()} | {:error, map()})) ::
          {:ok, [term()]} | {:error, map()}
  defp map_ok(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  @spec bind_where_nodes([SQLWhere.node_t()], %{binary() => term()}) ::
          {:ok, [SQLWhere.node_t()]} | {:error, map()}
  defp bind_where_nodes(nodes, params), do: map_ok(nodes, &bind_node(&1, params))

  @spec bind_node(SQLWhere.node_t(), %{binary() => term()}) ::
          {:ok, SQLWhere.node_t()} | {:error, map()}
  defp bind_node({:or, branches}, params) do
    with {:ok, bound} <- map_ok(branches, &bind_where_nodes(&1, params)),
         do: {:ok, {:or, bound}}
  end

  defp bind_node({:not, nodes}, params) do
    with {:ok, bound} <- bind_where_nodes(nodes, params), do: {:ok, {:not, bound}}
  end

  defp bind_node({op, "time", {low, high}}, params) when op in [:between, :not_between] do
    case SQLTime.between(op, resolve_time(low, params), resolve_time(high, params)) do
      {:error, error} -> {:ok, SQLWhere.deferred_clause(error)}
      ok -> ok
    end
  end

  defp bind_node({op, "time", items}, params) when op in [:in, :not_in] do
    case SQLTime.in_list(Enum.map(items, &resolve_time(&1, params))) do
      {:ok, bounds} -> {:ok, {op, "time", bounds}}
      {:error, error} -> {:ok, SQLWhere.deferred_clause(error)}
    end
  end

  defp bind_node({op, "time", value}, params) when op in @comparison_ops,
    do: bind_time_comparison(op, value, params)

  defp bind_node({op, left, {:like_param, name, case_insensitive}}, params)
       when op in [:like, :not_like] do
    with {:ok, pattern} <- pattern_param(Map.fetch!(params, name), "LIKE") do
      {:ok, {op, bind_operand(left, params), SQLWhere.like_regex(pattern, case_insensitive)}}
    end
  end

  defp bind_node({op, left, {:regex_param, name, symbol}}, params)
       when op in [:regex, :not_regex] do
    with {:ok, pattern} <- pattern_param(Map.fetch!(params, name), "regex"),
         {:ok, regex} <- SQLWhere.compile_regex(pattern, symbol) do
      {:ok, {op, bind_operand(left, params), {regex, symbol}}}
    end
  end

  defp bind_node({op, left, right}, params) when op in @comparison_ops do
    with {:ok, value} <- bind_comparand(right, params),
         do: {:ok, {op, bind_operand(left, params), value}}
  end

  defp bind_node({op, left, values}, params) when op in [:in, :not_in] do
    with {:ok, bound} <- map_ok(values, &bind_comparand(&1, params)),
         do: {:ok, {op, bind_operand(left, params), bound}}
  end

  defp bind_node({op, left, {low, high}}, params) when op in [:between, :not_between] do
    with {:ok, low} <- bind_comparand(low, params),
         {:ok, high} <- bind_comparand(high, params),
         do: {:ok, {op, bind_operand(left, params), {low, high}}}
  end

  defp bind_node({op, left, right}, params), do: {:ok, {op, bind_operand(left, params), right}}

  @spec bind_operand(SQLWhere.operand(), %{binary() => term()}) :: SQLWhere.operand()
  defp bind_operand({:expr, expr}, params), do: {:expr, bind_expr(expr, params)}
  defp bind_operand(column, _params), do: column

  # A value on the right of a comparison, or in a list or a BETWEEN. A
  # boolean turned around (`$p = col`) is refused: the engine words a type
  # error in the order the sides are written.
  @spec bind_comparand(term(), %{binary() => term()}) :: {:ok, term()} | {:error, map()}
  defp bind_comparand({:param, name}, params), do: {:ok, comparand(Map.fetch!(params, name))}

  defp bind_comparand({:param, name, :left}, params) do
    case Map.fetch!(params, name) do
      value when is_boolean(value) ->
        {:error,
         SQLError.refusal(
           "a boolean parameter on the left of a comparison is outside the double's " <>
             "subset; write the column first: $#{name}"
         )}

      value ->
        {:ok, comparand(value)}
    end
  end

  defp bind_comparand({:expr, expr}, params), do: {:ok, {:expr, bind_expr(expr, params)}}
  defp bind_comparand(value, _params), do: {:ok, value}

  @spec comparand(term()) :: term()
  defp comparand(value) when is_integer(value) and value >= 0, do: {:uint, value}
  defp comparand(value), do: value

  @spec bind_expr(SQLExpr.t(), %{binary() => term()}) :: SQLExpr.t()
  defp bind_expr({:param, name}, params), do: param_expr(Map.fetch!(params, name))

  defp bind_expr({:op, op, left, right}, params),
    do: {:op, op, bind_expr(left, params), bind_expr(right, params)}

  defp bind_expr({:neg, inner}, params), do: {:neg, bind_expr(inner, params)}
  defp bind_expr({:cast, inner, type}, params), do: {:cast, bind_expr(inner, params), type}

  defp bind_expr({:call, function, args}, params),
    do: {:call, function, Enum.map(args, &bind_expr(&1, params))}

  defp bind_expr(expr, _params), do: expr

  @spec param_expr(term()) :: SQLExpr.t()
  defp param_expr(value) when is_integer(value) and value >= 0, do: {:uint, value}
  defp param_expr(value), do: {:lit, value}

  @spec bind_projection([SQLParser.projection()] | nil, %{binary() => term()}) ::
          [SQLParser.projection()] | nil
  defp bind_projection(nil, _params), do: nil

  defp bind_projection(projection, params) do
    Enum.map(projection, fn
      {source, output} when is_binary(source) -> {source, output}
      {expr, output} -> {bind_expr(expr, params), output}
    end)
  end

  @spec bind_select_columns([SQLSelect.column()] | nil, %{binary() => term()}) ::
          [SQLSelect.column()] | nil
  defp bind_select_columns(nil, _params), do: nil

  defp bind_select_columns(columns, params) do
    Enum.map(columns, fn
      {:aggregate, agg, expr, output} -> {:aggregate, agg, bind_expr(expr, params), output}
      {:constant, {:param, name}, output} -> {:constant, Map.fetch!(params, name), output}
      column -> column
    end)
  end

  @spec bind_order_by(SQLClauses.order_by(), %{binary() => term()}) :: SQLClauses.order_by()
  defp bind_order_by(order_by, params) do
    Enum.map(order_by, fn
      {{:expr, expr}, direction} -> {{:expr, bind_expr(expr, params)}, direction}
      term -> term
    end)
  end

  # A pattern is a string; the engine words the error for another type with
  # the column's type too, which is not known here.
  @spec pattern_param(term(), binary()) :: {:ok, binary()} | {:error, map()}
  defp pattern_param(value, _kind) when is_binary(value), do: {:ok, value}

  defp pattern_param(_value, kind),
    do: {:error, SQLError.refusal("a #{kind} pattern parameter must be a string")}

  # `time` against a parameter: a string is an instant, a null is unknown, a
  # number or a boolean is the engine's type error.
  @spec bind_time_comparison(SQLWhere.op(), term(), %{binary() => term()}) ::
          {:ok, SQLWhere.clause()} | {:error, map()}
  defp bind_time_comparison(op, {:param, name}, params) do
    case SQLTime.param(Map.fetch!(params, name)) do
      {:number, type} ->
        {:ok,
         SQLWhere.deferred_clause(
           SQLTime.comparison_type_error("Timestamp(ns)", SQLWhere.symbol(op), type)
         )}

      bound ->
        {:ok, {op, "time", bound}}
    end
  end

  defp bind_time_comparison(op, {:param, name, :left}, params) do
    case SQLTime.param(Map.fetch!(params, name)) do
      {:number, type} ->
        {:ok,
         SQLWhere.deferred_clause(
           SQLTime.comparison_type_error(
             type,
             SQLWhere.symbol(SQLWhere.mirror(op)),
             "Timestamp(ns)"
           )
         )}

      bound ->
        {:ok, {op, "time", bound}}
    end
  end

  defp bind_time_comparison(op, value, _params), do: {:ok, {op, "time", value}}

  @spec resolve_time(SQLTime.bound(), %{binary() => term()}) :: SQLTime.bound()
  defp resolve_time({:param, name}, params), do: SQLTime.param(Map.fetch!(params, name))
  defp resolve_time({:param, name, :left}, params), do: SQLTime.param(Map.fetch!(params, name))
  defp resolve_time(bound, _params), do: bound
end
