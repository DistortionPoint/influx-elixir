defmodule InfluxElixir.Client.Local.SQLCoerce do
  @moduledoc false
  # The common type of a `CASE`, a `COALESCE` and a `NULLIF`, for
  # `InfluxElixir.Client.Local` (verified against InfluxDB 3 Core): the type
  # of the whole is the one its results share, so `CASE WHEN b THEN 1 ELSE 2.5
  # END` is `Float64` for the row that takes `1` too (`1.0`), and `CASE WHEN b
  # THEN 1 ELSE 'a' END` is `Utf8` (`"1"`). The type of a result is read once
  # per query, from the columns it names, and each result of another type is
  # cast to the common one, so that the evaluator sees the types the engine
  # does. See `InfluxElixir.Client.Local.SQLExprType.common/2`.

  alias InfluxElixir.Client.Local.{SQLExpr, SQLExprType, SQLParser, SQLPlan}

  @numbers ["Int64", "UInt64", "Float64"]

  @doc """
  The query with each result of a `CASE`, `COALESCE` and `NULLIF` cast to the
  type they share. `points` are the rows the columns' types are read from.
  """
  @spec apply(SQLParser.parsed_query(), [SQLPlan.point()], (binary() -> boolean())) ::
          SQLParser.parsed_query()
  def apply(query, points, unsigned?) do
    if Enum.any?(expressions(query), fn expr ->
         SQLExpr.any?(expr, fn node -> coerced?(node) end)
       end) do
      names =
        for expr <- expressions(query), name <- SQLExpr.columns(expr), is_binary(name), do: name

      types = SQLPlan.column_types(points, Enum.uniq(names), unsigned?)
      coerce_query(query, types)
    else
      query
    end
  end

  @spec coerced?(SQLExpr.t()) :: boolean()
  defp coerced?({:case, _operand, _whens, _otherwise}), do: true
  defp coerced?({:call, name, _args}), do: name in [:coalesce, :nullif, :greatest, :least]
  defp coerced?(_expr), do: false

  @spec expressions(SQLParser.parsed_query()) :: [SQLExpr.t()]
  defp expressions(query) do
    projected = for {expr, _output} <- query.projection_columns || [], is_tuple(expr), do: expr
    aggregated = Enum.flat_map(query.select_columns || [], &aggregate_expressions/1)
    ordered = for {{:expr, expr}, _direction} <- query.order_by, do: expr
    projected ++ aggregated ++ ordered ++ filter_expressions(query.where)
  end

  # The expressions a `WHERE` holds: its operands that are expressions.
  @spec filter_expressions(term()) :: [SQLExpr.t()]
  defp filter_expressions({:expr, expr}), do: [expr]

  defp filter_expressions(terms) when is_list(terms),
    do: Enum.flat_map(terms, &filter_expressions/1)

  defp filter_expressions(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> filter_expressions()

  defp filter_expressions(_other), do: []

  @spec coerce_filter(term(), %{binary() => binary()}) :: term()
  defp coerce_filter({:expr, expr}, types), do: {:expr, coerce(expr, types)}

  defp coerce_filter(terms, types) when is_list(terms),
    do: Enum.map(terms, &coerce_filter(&1, types))

  defp coerce_filter(term, types) when is_tuple(term),
    do: term |> Tuple.to_list() |> coerce_filter(types) |> List.to_tuple()

  defp coerce_filter(other, _types), do: other

  @spec aggregate_expressions(SQLParser.select_column()) :: [SQLExpr.t()]
  defp aggregate_expressions({:aggregate, _agg, expr, _output}), do: [expr]
  defp aggregate_expressions({:expression, expr, _aggs, _output}), do: [expr]
  defp aggregate_expressions(_column), do: []

  @spec coerce_query(SQLParser.parsed_query(), %{binary() => binary()}) ::
          SQLParser.parsed_query()
  defp coerce_query(query, types) do
    %{
      query
      | projection_columns:
          query.projection_columns &&
            Enum.map(query.projection_columns, fn
              {source, output} when is_binary(source) -> {source, output}
              {expr, output} -> {coerce(expr, types), output}
            end),
        select_columns:
          query.select_columns &&
            Enum.map(query.select_columns, fn
              {:aggregate, agg, expr, output} ->
                {:aggregate, agg, coerce(expr, types), output}

              {:expression, expr, aggs, output} ->
                {:expression, coerce(expr, types), aggs, output}

              column ->
                column
            end),
        order_by:
          Enum.map(query.order_by, fn
            {{:expr, expr}, direction} -> {{:expr, coerce(expr, types)}, direction}
            term -> term
          end),
        where: coerce_filter(query.where, types),
        where_tree: coerce_filter(query.where_tree, types)
    }
  end

  @spec coerce(SQLExpr.t(), %{binary() => binary()}) :: SQLExpr.t()
  defp coerce(expr, types) do
    expr |> SQLExpr.map_children(&coerce(&1, types)) |> coerce_node(types)
  end

  defp coerce_node({:case, operand, whens, otherwise}, types) do
    {operand, whens} = compared_as_text(operand, whens, types)
    results = Enum.map(whens, &elem(&1, 1)) ++ List.wrap(otherwise)
    target = target(results, :case, types)

    {:case, operand,
     Enum.map(whens, fn {condition, result} -> {condition, cast(result, target, types)} end),
     otherwise && cast(otherwise, target, types)}
  end

  defp coerce_node({:call, name, args}, types)
       when name in [:coalesce, :nullif, :greatest, :least] do
    target = target(args, :coalesce, types)
    {:call, name, Enum.map(args, &cast(&1, target, types))}
  end

  defp coerce_node(expr, _types), do: expr

  # A `CASE operand WHEN value ...` compares the operand and every `WHEN` value in
  # the one type they share, and the engine makes it text when any of them is
  # text: the operand `n = 1` against `1.0` and a column of text is `'1'` against
  # `'1.0'`, which differ.
  @spec compared_as_text(SQLExpr.t() | nil, [{SQLExpr.t(), SQLExpr.t()}], %{
          binary() => binary()
        }) :: {SQLExpr.t() | nil, [{SQLExpr.t(), SQLExpr.t()}]}
  defp compared_as_text(nil, whens, _types), do: {nil, whens}

  defp compared_as_text(operand, whens, types) do
    values = [operand | Enum.map(whens, &elem(&1, 0))]
    families = values |> Enum.map(&SQLExprType.known_type(&1, types)) |> Enum.map(&family/1)

    if "Utf8" in families and Enum.all?(families, &(&1 in [nil, "Utf8" | @numbers])) do
      {cast(operand, "Utf8", types),
       Enum.map(whens, fn {value, result} -> {cast(value, "Utf8", types), result} end)}
    else
      {operand, whens}
    end
  end

  @spec family(SQLExprType.type()) :: SQLExprType.type()
  defp family("Dictionary(Int32, Utf8)"), do: "Utf8"
  defp family("Utf8View"), do: "Utf8"
  defp family(type), do: type

  @spec target([SQLExpr.t()], :case | :coalesce, %{binary() => binary()}) :: SQLExprType.type()
  defp target(results, mode, types),
    do: results |> Enum.map(&SQLExprType.type_of(&1, types)) |> SQLExprType.common(mode)

  # An `Int64` result of a `Float64` whole is cast to `Float64`, a number of a
  # `Utf8` one to text.
  @spec cast(SQLExpr.t(), SQLExprType.type(), %{binary() => binary()}) :: SQLExpr.t()
  defp cast(expr, "Float64", types) do
    if SQLExprType.type_of(expr, types) == "Int64", do: {:cast, expr, :float}, else: expr
  end

  defp cast(expr, text, types) when text in ["Utf8", "Utf8View", "Dictionary(Int32, Utf8)"] do
    if SQLExprType.type_of(expr, types) in @numbers,
      do: {:cast, expr, :string},
      else: expr
  end

  # An integer beside one of the other sign is a decimal.
  defp cast(expr, "Decimal128(?)", types) do
    if SQLExprType.type_of(expr, types) in ["Int64", "UInt64"],
      do: {:cast, expr, :decimal},
      else: expr
  end

  defp cast(expr, _target, _types), do: expr
end
