defmodule InfluxElixir.Client.Local.InfluxQLPlan do
  @moduledoc false
  # The planning errors the engine raises for a select list, after it has
  # planned the `WHERE` and before it checks `LIMIT` (verified), in the frame
  # it gives them (`gather information about select statement`):
  #
  #   * a constant, or a function of one: see
  #     `InfluxElixir.Client.Local.InfluxQLLiteral`
  #   * `distinct()` beside any other item
  #   * `GROUP BY time(...)` without an aggregate
  #   * a plain column (a field, a tag) beside an aggregate that is no selector
  #     (`mixing aggregate and non-aggregate columns is not supported`), or
  #     beside several selectors (`mixing multiple selector functions with tags
  #     or fields is not supported`); one selector, with its point's columns, is
  #     the one mix the engine answers

  alias InfluxElixir.Client.Local.{
    InfluxQL,
    InfluxQLAggregate,
    InfluxQLError,
    InfluxQLExpr,
    InfluxQLLiteral
  }

  @numeric ~w(mean sum median spread stddev)

  @doc """
  `:ok`, the engine's error as `{:error, {:engine, body}}` (or
  `{:error, {:engine, status, body}}`), or a refusal by name as
  `{:error, message}` for a mix the double does not answer. `types` is the
  type of each field of the measurement.
  """
  @spec check(InfluxQL.query(), %{binary() => InfluxQL.field_type()}, MapSet.t(binary())) ::
          :ok
          | {:error, {:engine, binary()} | {:engine, pos_integer(), binary()} | binary()}
  def check(%{items: items, group_time: group_time} = query, types, tags) do
    with :ok <- InfluxQLLiteral.constant_error(items),
         :ok <- distinct_alone(items),
         :ok <- group_needs_aggregate(items, group_time),
         :ok <- fill_needs_aggregate(query),
         :ok <- no_mix(items),
         :ok <- group_selector_columns(items, group_time),
         :ok <- text_aggregate(items, types),
         :ok <- expressions(items, types, tags) do
      fill_number_on_text(query, types)
    end
  end

  # The engine's planning error for the first operation of an expression it
  # cannot type; an expression of constants alone, and one that mixes
  # aggregates with fields, are the double's refusals.
  @spec expressions([InfluxQL.item()], map(), MapSet.t(binary())) ::
          :ok | {:error, {:engine, binary()} | binary()}
  defp expressions(items, types, tags) do
    Enum.find_value(items, :ok, fn
      {:expr, ast, _alias} -> expression(ast, types, tags)
      _item -> nil
    end)
  end

  defp expression(ast, types, tags) do
    cond do
      InfluxQLExpr.refs(ast) == [] and InfluxQLExpr.aggregates(ast) == [] ->
        {:error, "unsupported InfluxQL (an expression of constants)"}

      InfluxQLExpr.refs(ast) != [] and InfluxQLExpr.aggregates(ast) != [] ->
        {:error, "unsupported InfluxQL (an expression of aggregates and fields)"}

      true ->
        with :ok <- InfluxQLExpr.check(ast, types, tags), do: nil
    end
  end

  # The aggregates that need numbers, given a string field: the engine's
  # planning error, as its function library words it.
  @spec text_aggregate([InfluxQL.item()], map()) :: :ok | {:error, {:engine, binary()} | binary()}
  defp text_aggregate(items, types) do
    Enum.find_value(items, :ok, fn
      {:aggregate, fun, field, _alias} = item when is_binary(field) and fun in @numeric ->
        text_aggregate_error(item, Map.get(types, field))

      _item ->
        nil
    end)
  end

  defp text_aggregate_error({:aggregate, fun, _field, _alias}, :string) do
    {:error, {:engine, "Error during planning: " <> text_signature(fun)}}
  end

  defp text_aggregate_error({:aggregate, fun, _field, _alias}, :boolean),
    do: {:error, "unsupported InfluxQL (#{fun}() of a boolean field)"}

  defp text_aggregate_error(_item, _type), do: nil

  @candidates " No function matches the given name and argument types"
  @casts "You might need to add explicit type casts.\n\tCandidate functions:\n\t"

  defp text_signature("mean") do
    "Execution error: Function 'avg' user-defined coercion failed with " <>
      "\"Error during planning: Avg does not support inputs of type Utf8.\"" <>
      @candidates <> " 'avg(Utf8)'. " <> @casts <> "avg(UserDefined)"
  end

  defp text_signature("sum") do
    "Execution error: Function 'sum' user-defined coercion failed with " <>
      "\"Execution error: Sum not supported for Utf8\"" <>
      @candidates <> " 'sum(Utf8)'. " <> @casts <> "sum(UserDefined)"
  end

  defp text_signature(fun) when fun in ["median", "stddev"] do
    "Function '#{fun}' expects NativeType::Numeric but received NativeType::String" <>
      @candidates <> " '#{fun}(Utf8)'. " <> @casts <> "#{fun}(Numeric(1))"
  end

  defp text_signature("spread") do
    "Failed to coerce arguments to satisfy a call to 'spread' function: coercion from Utf8 to " <>
      "the signature OneOf([Exact([Int64]), Exact([UInt64]), Exact([Float64])]) failed" <>
      @candidates <>
      " 'spread(Utf8)'. " <>
      @casts <>
      "spread(Int64)\n\tspread(UInt64)\n\tspread(Float64)"
  end

  # A number given to `fill()` cannot become the value of a text column.
  @spec fill_number_on_text(InfluxQL.query(), map()) ::
          :ok | {:error, {:engine, 500, binary()} | binary()}
  defp fill_number_on_text(%{group_time: nil}, _types), do: :ok

  defp fill_number_on_text(%{fill: {:number, number}, items: items}, types) do
    case Enum.find(items, &(column_type(&1, types) in [:string, :boolean])) do
      nil -> :ok
      item -> text_fill_error(column_type(item, types), number)
    end
  end

  defp fill_number_on_text(_query, _types), do: :ok

  defp column_type({:aggregate, fun, field, _alias}, types) when is_binary(field) do
    if fun in ~w(first last min max), do: Map.get(types, field)
  end

  defp column_type(_item, _types), do: nil

  defp text_fill_error(:string, number) do
    case number_text(number) do
      nil ->
        {:error, "unsupported InfluxQL (fill() with that number on a string column)"}

      text ->
        {:error,
         {:engine, 500,
          "External error: InfluxQL internal error: no conversion from #{text} to Utf8"}}
    end
  end

  defp text_fill_error(:boolean, _number),
    do: {:error, "unsupported InfluxQL (fill() with a number on a boolean column)"}

  defp number_text(number) when is_integer(number), do: Integer.to_string(number)

  defp number_text(number) when is_float(number) do
    text = Float.to_string(number)
    if trunc(number) == number or String.contains?(text, "e"), do: nil, else: text
  end

  @spec distinct_alone([InfluxQL.item()]) :: :ok | {:error, {:engine, binary()}}
  defp distinct_alone(items) do
    if length(items) > 1 and
         Enum.any?(items, &match?({:aggregate, "distinct", _arg, _alias}, &1)),
       do:
         planning(
           "aggregate function distinct() cannot be combined with other functions or fields"
         ),
       else: :ok
  end

  @spec group_needs_aggregate([InfluxQL.item()], term()) :: :ok | {:error, {:engine, binary()}}
  defp group_needs_aggregate(_items, nil), do: :ok

  defp group_needs_aggregate(items, _group_time) do
    if Enum.any?(items, &aggregate?/1),
      do: :ok,
      else: planning("GROUP BY requires at least one aggregate function")
  end

  # `fill(none)` and `fill(linear)` need something to fill: an aggregate or a
  # selector. Any other option is ignored by a select of plain columns.
  @spec fill_needs_aggregate(InfluxQL.query()) :: :ok | {:error, {:engine, binary()}}
  defp fill_needs_aggregate(%{fill: fill, items: items, group_time: nil})
       when fill in [:none, :linear] do
    if Enum.any?(items, &aggregate?/1),
      do: :ok,
      else: planning("FILL(#{fill}) must be used with an aggregate or selector function")
  end

  defp fill_needs_aggregate(_query), do: :ok

  @spec no_mix([InfluxQL.item()]) :: :ok | {:error, {:engine, binary()}}
  defp no_mix(items) do
    aggregates = Enum.filter(items, &aggregate?/1)
    plain = Enum.reject(items, &(aggregate?(&1) or time?(&1)))

    cond do
      aggregates == [] or plain == [] ->
        :ok

      Enum.any?(aggregates, &(not selector?(&1))) ->
        planning("mixing aggregate and non-aggregate columns is not supported")

      length(aggregates) > 1 ->
        planning("mixing multiple selector functions with tags or fields is not supported")

      true ->
        :ok
    end
  end

  # One selector with columns beside it, per bucket, is answered by the engine
  # and not by the double.
  @spec group_selector_columns([InfluxQL.item()], term()) :: :ok | {:error, binary()}
  defp group_selector_columns(_items, nil), do: :ok

  defp group_selector_columns(items, _group_time) do
    if Enum.any?(items, &aggregate?/1) and Enum.any?(items, &(not (aggregate?(&1) or time?(&1)))),
      do: {:error, "unsupported InfluxQL (columns beside a selector in GROUP BY time)"},
      else: :ok
  end

  defp aggregate?({:aggregate, _fun, _arg, _alias}), do: true
  defp aggregate?({:expr, ast, _alias}), do: InfluxQLExpr.aggregates(ast) != []
  defp aggregate?(_item), do: false

  defp selector?({:aggregate, fun, arg, _alias}),
    do: InfluxQLAggregate.selector?(fun) and is_binary(arg)

  defp selector?(_item), do: false

  defp time?({:column, column, _name}), do: String.downcase(column) == "time"
  defp time?(_item), do: false

  defp planning(message), do: {:error, {:engine, InfluxQLError.select_error(message)}}
end
