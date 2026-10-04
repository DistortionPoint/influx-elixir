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
    InfluxQLLiteral,
    InfluxQLNames
  }

  @numeric ~w(mean sum median spread stddev)

  # The type as the library words it: `{in a coercion, as a native type, in a signature}`.
  @utf8 {"Utf8", "String", "Utf8"}
  @timestamp {"Timestamp(ns)", "Timestamp(Nanosecond, None)", "Timestamp(ns)"}

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
    with :ok <- early_error(query),
         :ok <- item_errors(items, types, tags),
         :ok <- distinct_alone(items),
         :ok <- multi_rules(items),
         :ok <- multi_schema(query, types, tags),
         :ok <- transforms(query),
         :ok <- group_needs_aggregate(query),
         :ok <- fill_needs_aggregate(query),
         :ok <- no_mix(items),
         :ok <- group_selector_columns(items, group_time),
         :ok <- text_aggregate(items, types),
         :ok <- time_aggregate(items, types, tags),
         :ok <- expressions(items, types, tags),
         :ok <- call_before_selector(query, types),
         :ok <- lone_selector_calls(items),
         :ok <- group_field_read(query, types, tags) do
      fill_number_on_text(query, types)
    end
  end

  # A field named in `GROUP BY` groups by its values. When the select list also
  # reads that field the engine answers oddly (the aggregate disappears, a
  # selected column comes twice as `f` and `f_1`): refused by name.
  @spec group_field_read(InfluxQL.query(), map(), MapSet.t(binary())) :: :ok | {:error, binary()}
  defp group_field_read(%{group_by: dimensions, items: items}, types, tags) do
    fields =
      for {:tag, name} <- dimensions,
          Map.has_key?(types, name),
          not MapSet.member?(tags, name),
          do: name

    if fields != [] and reads_any?(items, fields),
      do: {:error, "unsupported InfluxQL (GROUP BY a field that the select list reads)"},
      else: :ok
  end

  defp reads_any?(items, fields) do
    Enum.any?(items, fn item ->
      case item do
        :star -> true
        {:aggregate, _fun, :star, _alias} -> true
        _item -> Enum.any?(item_reads(item), &(&1 in fields))
      end
    end)
  end

  defp item_reads({:column, column, _name}), do: [column]
  defp item_reads({:aggregate, _fun, {:distinct, field}, _alias}), do: [field]
  defp item_reads({:aggregate, _fun, field, _alias}) when is_binary(field), do: [field]

  defp item_reads({:expr, ast, _name}),
    do:
      InfluxQLExpr.refs(ast) ++
        for({_fun, arg} <- InfluxQLExpr.aggregates(ast), is_binary(arg), do: arg)

  defp item_reads(_item), do: []

  # The engine's planning error for the first operation of an expression it
  # cannot type; an expression of constants alone, and one that mixes
  # aggregates with fields, are the double's refusals.
  @spec expressions([InfluxQL.item()], map(), MapSet.t(binary())) ::
          :ok | {:error, {:engine, binary()} | binary()}
  defp expressions(items, types, tags) do
    physical? =
      Enum.any?(items, &(field_aggregate?(&1, types, tags) or field_read?(&1, types, tags)))

    # The engine rewrites the whole list before it plans a function: its operand errors come
    # first, a function of a time after them.
    case first_expression_error(items, types, tags, false) do
      :ok when physical? -> first_expression_error(items, types, tags, true)
      result -> result
    end
  end

  defp first_expression_error(items, types, tags, physical?) do
    Enum.find_value(items, :ok, fn
      {:expr, ast, _alias} -> expression(ast, types, tags, physical?)
      _item -> nil
    end)
  end

  defp expression(ast, types, tags, physical?) do
    cond do
      InfluxQLExpr.refs(ast) == [] and InfluxQLExpr.aggregates(ast) == [] ->
        {:error, "unsupported InfluxQL (an expression of constants)"}

      InfluxQLExpr.refs(ast) != [] and InfluxQLExpr.aggregates(ast) != [] ->
        {:error, "unsupported InfluxQL (an expression of aggregates and fields)"}

      true ->
        with :ok <- InfluxQLExpr.check(ast, types, tags, physical?), do: nil
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
    {:error, {:engine, "Error during planning: " <> text_signature(fun, @utf8)}}
  end

  defp text_aggregate_error({:aggregate, fun, _field, _alias}, :boolean),
    do: {:error, "unsupported InfluxQL (#{fun}() of a boolean field)"}

  defp text_aggregate_error(_item, _type), do: nil

  @candidates " No function matches the given name and argument types"
  @casts "You might need to add explicit type casts.\n\tCandidate functions:\n\t"

  defp text_signature("mean", {type, _native, signature}) do
    "Execution error: Function 'avg' user-defined coercion failed with " <>
      "\"Error during planning: Avg does not support inputs of type #{type}.\"" <>
      @candidates <> " 'avg(#{signature})'. " <> @casts <> "avg(UserDefined)"
  end

  defp text_signature("sum", {type, _native, signature}) do
    "Execution error: Function 'sum' user-defined coercion failed with " <>
      "\"Execution error: Sum not supported for #{type}\"" <>
      @candidates <> " 'sum(#{signature})'. " <> @casts <> "sum(UserDefined)"
  end

  defp text_signature(fun, {_type, native, signature}) when fun in ["median", "stddev"] do
    "Function '#{fun}' expects NativeType::Numeric but received NativeType::#{native}" <>
      @candidates <> " '#{fun}(#{signature})'. " <> @casts <> "#{fun}(Numeric(1))"
  end

  defp text_signature("spread", {type, _native, signature}) do
    "Failed to coerce arguments to satisfy a call to 'spread' function: coercion from " <>
      "#{type} to the signature OneOf([Exact([Int64]), Exact([UInt64]), Exact([Float64])]) " <>
      "failed" <>
      @candidates <>
      " 'spread(#{signature})'. " <>
      @casts <>
      "spread(Int64)\n\tspread(UInt64)\n\tspread(Float64)"
  end

  # An aggregate of the `time` column that needs numbers is a planning error when a field is
  # aggregated beside it (verified; alone, or beside tags and other times, the engine answers
  # nothing, and the first such aggregate of the list is the one it names). `percentile()` and
  # `integral()` word it at length and are refused by name.
  @spec time_aggregate([InfluxQL.item()], map(), MapSet.t(binary())) ::
          :ok | {:error, {:engine, binary()} | binary()}
  defp time_aggregate(items, types, tags) do
    if Enum.any?(items, &field_aggregate?(&1, types, tags)) do
      Enum.find_value(items, :ok, &time_error/1)
    else
      :ok
    end
  end

  defp time_error({:aggregate, fun, "time", _alias}) when fun in @numeric,
    do: {:error, {:engine, "Error during planning: " <> text_signature(fun, @timestamp)}}

  defp time_error({:aggregate, "percentile:" <> _rest, "time", _alias}),
    do: {:error, "unsupported InfluxQL (percentile() of time beside a field)"}

  defp time_error({:aggregate, "integral:" <> _rest, "time", _alias}),
    do: {:error, "unsupported InfluxQL (integral() of time beside a field)"}

  defp time_error(_item), do: nil

  defp field_aggregate?({:aggregate, _fun, :star, _alias}, _types, _tags), do: true

  defp field_aggregate?({:aggregate, "count", {:distinct, field}, _alias}, types, tags),
    do: field?(field, types, tags)

  defp field_aggregate?({:aggregate, _fun, field, _alias}, types, tags) when is_binary(field),
    do: field?(field, types, tags)

  defp field_aggregate?({:expr, ast, _alias}, types, tags) do
    Enum.any?(InfluxQLExpr.aggregates(ast), fn {_fun, arg} ->
      is_binary(arg) and field?(arg, types, tags)
    end)
  end

  defp field_aggregate?(_item, _types, _tags), do: false

  # A plain field in the list (a column, or an expression of fields) makes the engine run the plan
  # of the row, which is where it rejects a math function of a time (verified: `abs(time), n`
  # is the error, `abs(time), host` answers nothing).
  defp field_read?({:column, column, _name}, types, tags), do: field?(column, types, tags)

  defp field_read?({:expr, ast, _alias}, types, tags),
    do: Enum.any?(InfluxQLExpr.refs(ast), &field?(&1, types, tags))

  defp field_read?(_item, _types, _tags), do: false

  defp field?(name, types, tags), do: Map.has_key?(types, name) and not MapSet.member?(tags, name)

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

  defp text_fill_error(:string, number), do: no_conversion(number, "Utf8")
  defp text_fill_error(:boolean, number), do: no_conversion(number, "Boolean")

  defp no_conversion(number, type) do
    {:error,
     {:engine, 500,
      "External error: InfluxQL internal error: no conversion from #{number_text(number)} to #{type}"}}
  end

  defp number_text(number) when is_integer(number), do: Integer.to_string(number)
  defp number_text(number) when is_float(number), do: InfluxQLLiteral.display(number)

  # What `top()` and `bottom()` read beside other columns (verified): a field the measurement
  # lacks, with a field beside it, and a `time` that is aliased, are the schema error that lists
  # the columns of the measurement (the field comes first, else the alias, unless that is a
  # column); beside a tag as the field, or an expression of columns, the double has no answer.
  @spec multi_schema(InfluxQL.query(), map(), MapSet.t(binary())) ::
          :ok | {:error, {:engine, 500, binary()} | binary()}
  defp multi_schema(%{items: items, measurement: table}, types, tags) do
    case Enum.find(items, &match?({:multi, _kind, _field, _tags, _limit, _alias}, &1)) do
      # a measurement the double knows no columns of is no schema to name
      {:multi, _kind, _field, _by, _limit, _alias} when map_size(types) == 0 ->
        :ok

      {:multi, kind, field, _by, _limit, _alias} ->
        columns = for {:column, column, name} = item <- items, do: {column, name, item}
        multi_columns(kind, field, columns, items, {table, types, tags})

      nil ->
        :ok
    end
  end

  # Arithmetic of the columns of the point `top()` chose is answered; one of aggregates or
  # transforms (they read the series, not the point) is not.
  defp aggregating_expression?({:expr, ast, _alias}),
    do: InfluxQLExpr.aggregates(ast) != [] or InfluxQLExpr.transforms(ast) != []

  defp aggregating_expression?(_item), do: false

  defp multi_columns(kind, field, columns, items, {table, types, tags}) do
    field_beside? =
      Enum.any?(columns, fn {column, _name, _item} -> field?(column, types, tags) end)

    aliased = Enum.find(columns, &aliased_time?/1)

    cond do
      Enum.any?(items, &aggregating_expression?/1) ->
        {:error, "unsupported InfluxQL (#{kind}() beside an expression)"}

      field_beside? and MapSet.member?(tags, field) ->
        {:error, "unsupported InfluxQL (#{kind}() of a tag beside a field)"}

      field_beside? and not Map.has_key?(types, field) and field != "time" ->
        schema_error(table, field, types, tags)

      aliased != nil ->
        {_column, name, _item} = aliased
        if known_column?(name, types, tags), do: :ok, else: schema_error(table, name, types, tags)

      true ->
        :ok
    end
  end

  defp known_column?(name, types, tags),
    do: name == "time" or Map.has_key?(types, name) or MapSet.member?(tags, name)

  defp aliased_time?({_column, name, item}),
    do: InfluxQLNames.time_item?(item) and name != "time"

  defp schema_error(table, name, types, tags) do
    valid =
      ["time" | Map.keys(types) ++ MapSet.to_list(tags)]
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map_join(", ", &"#{table}.#{&1}")

    {:error, {:engine, 500, "Schema error: No field named #{name}. Valid fields are #{valid}."}}
  end

  # `top()` and `bottom()` stand alone: any other function beside them, or a
  # second one, is the engine's planning error (verified); columns beside them
  # are fine. An error found while a call was read comes first.
  @spec multi_rules([InfluxQL.item()]) :: :ok | {:error, {:engine, binary()}}
  defp multi_rules(items) do
    multis = for {:multi, kind, _field, _tags, _limit, _alias} <- items, do: kind

    others =
      Enum.filter(items, fn item ->
        aggregate?(item) and not match?({:multi, _k, _f, _t, _n, _a}, item)
      end)

    cond do
      multis == [] ->
        :ok

      others != [] ->
        planning("selector functions top and bottom cannot be combined with other functions")

      length(multis) > 1 ->
        planning(
          "selector function #{Enum.at(multis, 1)}() cannot be combined with other functions"
        )

      true ->
        :ok
    end
  end

  @doc """
  The errors the engine raises while it rewrites the statement, before it looks
  at the `WHERE` (verified): one found while the projection is expanded, then
  the offset of the `GROUP BY time()`.
  """
  @spec early_error(InfluxQL.query()) :: :ok | {:error, {:engine, binary()}}
  def early_error(%{items: items} = query) do
    case Enum.find(items, &match?({:expand_error, _message}, &1)) do
      {:expand_error, message} -> {:error, {:engine, InfluxQLError.expand_error(message)}}
      nil -> offset_error(Map.get(query, :rewrite_error))
    end
  end

  defp offset_error(nil), do: :ok
  defp offset_error(body), do: {:error, {:engine, body}}

  # The operands an expression of the list cannot be typed from (`incompatible operands`) are
  # found while the projection is expanded, for the whole list, before the engine splits the
  # condition and before it gathers what the statement selects (verified: `-f + time, -0.0`
  # and `top(f, 2), top(g, 2), f + time` are the operand error, not `field must contain at
  # least one variable` or the selectors that cannot be combined). A column the measurement
  # lacks is no operand it types (`nosuch + max(time)` answers nothing).
  @spec expand_errors([InfluxQL.item()], map(), MapSet.t(binary())) ::
          :ok | {:error, {:engine, binary()}}
  def expand_errors(items, types, tags) do
    Enum.find_value(items, :ok, fn
      {:expr, ast, _alias} ->
        with {:error, {:engine, body}} = error <- InfluxQLExpr.check_expanding(ast, types, tags),
             true <- String.contains?(body, "\nexpand projection\n"),
             false <- String.contains?(body, "unknown") do
          error
        else
          _other -> nil
        end

      _item ->
        nil
    end)
  end

  # The first item, in order, that is a constant or a call the engine refuses; a second
  # `top()` or `bottom()` is the error of the selectors that cannot be combined at the
  # second one, so before a constant that stands after it and not before (verified:
  # `top(f, 2), top(g, 2), 1` and `1, top(f, 2), top(g, 2)`).
  @spec item_errors([InfluxQL.item()], map(), MapSet.t(binary())) ::
          :ok | {:error, {:engine, binary()} | binary()}
  defp item_errors(items, types, tags), do: item_errors(items, types, tags, 0)

  defp item_errors([], _types, _tags, _multis), do: :ok

  defp item_errors([{:multi, kind, _f, _t, _n, _a} | _rest], _types, _tags, multis)
       when multis > 0,
       do: planning("selector function #{kind}() cannot be combined with other functions")

  defp item_errors([item | rest], types, tags, multis) do
    case item_error(item, types, tags) do
      nil ->
        count = if match?({:multi, _k, _f, _t, _n, _a}, item), do: 1, else: 0
        item_errors(rest, types, tags, multis + count)

      error ->
        error
    end
  end

  defp item_error({:planning_error, message}, _types, _tags), do: planning(message)

  defp item_error({:argument_error, name, argument}, types, tags),
    do: InfluxQLExpr.argument_error(name, argument, types, tags)

  defp item_error(item, _types, _tags) do
    case InfluxQLLiteral.constant_error([item]) do
      :ok -> nil
      error -> error
    end
  end

  # A math function written before the only selector of the list is the engine's internal
  # error, which names the first function of the list (verified: `abs(n), top(n, 2)`,
  # `n + abs(n), max(n)`, `sqrt(abs(n)), min(n)` are `unexpected selector function: sqrt`
  # and the like; after the selector, or beside an aggregate that is no selector, it is not).
  # `top()` and `bottom()` do it in every shape, the other selectors but in a `GROUP BY
  # time`, where the double refuses columns beside them. A measurement the double knows no
  # columns of is no plan.
  @spec call_before_selector(InfluxQL.query(), map()) ::
          :ok | {:error, {:engine, 500, binary()}}
  defp call_before_selector(%{items: items, group_time: group_time}, types) do
    selectors = Enum.filter(items, &selector?/1)

    with [selector] <- selectors,
         true <- map_size(types) > 0,
         true <- multi?(selector) or group_time == nil,
         false <- Enum.any?(items, &(aggregate?(&1) and not selector?(&1))),
         [_first | _rest] = before <- Enum.take_while(items, &(&1 != selector)),
         name when is_binary(name) <- Enum.find_value(before, &plain_call/1) do
      {:error,
       {:engine, 500,
        "External error: InfluxQL internal error: unexpected selector function: " <> name}}
    else
      _other -> :ok
    end
  end

  defp plain_call({:expr, ast, _alias}) do
    if InfluxQLExpr.refs(ast) != [] and InfluxQLExpr.aggregates(ast) == [] and
         InfluxQLExpr.transforms(ast) == [],
       do: InfluxQLExpr.first_call(ast)
  end

  defp plain_call(_item), do: nil

  # A math function over the only selector of the list is the engine's internal
  # error; over it in a deeper shape, or an arithmetic on a `percentile()` the
  # engine does not compute (it answers the percentile itself), the double
  # refuses.
  @spec lone_selector_calls([InfluxQL.item()]) ::
          :ok | {:error, {:engine, 500, binary()} | binary()}
  defp lone_selector_calls(items) do
    calls = for item <- items, call <- item_aggregates(item), do: call

    case calls do
      [{_fun, "time"}] ->
        :ok

      [{fun, _field}] ->
        if selector_name?(fun), do: lone_selector_expression(items, fun), else: :ok

      _several ->
        :ok
    end
  end

  defp item_aggregates({:aggregate, fun, arg, _alias}) when is_binary(arg), do: [{fun, arg}]
  defp item_aggregates({:expr, ast, _alias}), do: InfluxQLExpr.aggregates(ast)
  defp item_aggregates(_item), do: []

  defp selector_name?(fun), do: InfluxQLAggregate.selector?(fun)

  defp lone_selector_expression(items, fun) do
    case Enum.find(items, &match?({:expr, _ast, _alias}, &1)) do
      nil -> :ok
      {:expr, ast, _alias} -> selector_in(ast, fun)
    end
  end

  defp selector_in({:fn, name, [{:agg, _call, _field} | _rest]}, _fun),
    do:
      {:error,
       {:engine, 500,
        "External error: InfluxQL internal error: unexpected selector function: " <> name}}

  defp selector_in({:fn, _name, _arguments}, _fun),
    do: {:error, "unsupported InfluxQL (a function over a selector in that shape)"}

  defp selector_in({:bin, _op, _left, _right} = ast, "percentile:" <> _percent),
    do:
      if(InfluxQLExpr.aggregates(ast) != [],
        do: {:error, "unsupported InfluxQL (arithmetic on percentile())"},
        else: :ok
      )

  defp selector_in({:neg, _operand}, "percentile:" <> _percent),
    do: {:error, "unsupported InfluxQL (arithmetic on percentile())"}

  defp selector_in({:bin, _op, left, right}, fun) do
    with :ok <- selector_in(left, fun), do: selector_in(right, fun)
  end

  defp selector_in(_ast, _fun), do: :ok

  # A transform of an aggregate needs the buckets of a `GROUP BY time`, a
  # transform of a field the points of a series (verified); beside an aggregate
  # a transform of a field is the engine's schema error, which the double
  # refuses.
  @spec transforms(InfluxQL.query()) :: :ok | {:error, {:engine, binary()} | binary()}
  defp transforms(%{items: items, group_time: group_time}) do
    calls = for {:expr, ast, _alias} <- items, call <- InfluxQLExpr.transforms(ast), do: call
    {of_aggregates, of_fields} = Enum.split_with(calls, &of_aggregate?/1)
    aggregate_items? = Enum.any?(items, &match?({:aggregate, _fun, _arg, _alias}, &1))

    cond do
      calls == [] ->
        :ok

      Enum.any?(of_aggregates, &match?({:transform, "elapsed", _inner, _parameter}, &1)) ->
        {:error, "unsupported InfluxQL (elapsed() of an aggregate)"}

      group_time == nil and of_aggregates != [] ->
        {:transform, name, _inner, _parameter} = hd(of_aggregates)
        planning("#{name} aggregate requires a GROUP BY interval")

      group_time != nil and of_fields != [] ->
        {:error, "unsupported InfluxQL (a transform of a field in GROUP BY time)"}

      aggregate_items? and of_fields != [] ->
        {:error, "unsupported InfluxQL (a transform of a field beside an aggregate)"}

      true ->
        :ok
    end
  end

  defp of_aggregate?({:transform, _name, inner, _parameter}),
    do: InfluxQLExpr.aggregates(inner) != []

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

  # A `GROUP BY time()` of a list with nothing to aggregate; when the statement also fills with
  # `none` or `linear`, which need something to fill, that is the error it words first
  # (verified).
  @spec group_needs_aggregate(InfluxQL.query()) :: :ok | {:error, {:engine, binary()}}
  defp group_needs_aggregate(%{group_time: nil}), do: :ok

  defp group_needs_aggregate(%{items: items, fill: fill} = query) do
    cond do
      Enum.any?(items, &aggregate?/1) -> :ok
      fill in [:none, :linear] -> fill_needs_aggregate(%{query | group_time: nil})
      true -> planning("GROUP BY requires at least one aggregate function")
    end
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

  @spec no_mix([InfluxQL.item()]) :: :ok | {:error, {:engine, binary()} | binary()}
  defp no_mix(items) do
    aggregates = Enum.filter(items, &aggregate?/1)
    plain = Enum.reject(items, &(aggregate?(&1) or time?(&1)))

    cond do
      aggregates == [] or plain == [] ->
        :ok

      refusal = mix_refusal(aggregates, plain) ->
        refusal

      Enum.any?(aggregates, &(not selector?(&1))) ->
        planning("mixing aggregate and non-aggregate columns is not supported")

      length(aggregates) > 1 ->
        planning("mixing multiple selector functions with tags or fields is not supported")

      true ->
        :ok
    end
  end

  # An expression over fields that reads the time column (the engine's own schema error).
  defp time_expression?({:expr, ast, _alias}),
    do: Enum.any?(InfluxQLExpr.refs(ast), &(String.downcase(&1) == "time"))

  defp time_expression?(_item), do: false

  # Columns beside an expression that reads the time, or beside arithmetic over a selector (the
  # engine takes that for a selector, and answers): the double does not word what it does.
  @spec mix_refusal([InfluxQL.item()], [InfluxQL.item()]) :: {:error, binary()} | nil
  defp mix_refusal(aggregates, plain) do
    cond do
      Enum.any?(plain, &time_expression?/1) ->
        {:error, "unsupported InfluxQL (a function of time beside an aggregate)"}

      Enum.any?(aggregates, &selector_expression?/1) ->
        {:error, "unsupported InfluxQL (arithmetic on a selector beside columns)"}

      true ->
        nil
    end
  end

  defp selector_expression?({:expr, ast, _alias}) do
    case InfluxQLExpr.aggregates(ast) do
      [{fun, _arg}] -> InfluxQLAggregate.selector?(fun)
      _several -> false
    end
  end

  defp selector_expression?(_item), do: false

  # One selector with columns beside it, per bucket, is answered by the engine
  # and not by the double.
  @spec group_selector_columns([InfluxQL.item()], term()) :: :ok | {:error, binary()}
  defp group_selector_columns(_items, nil), do: :ok

  defp group_selector_columns(items, _group_time) do
    if Enum.any?(items, &aggregate?/1) and not Enum.any?(items, &multi?/1) and
         Enum.any?(items, &(not (aggregate?(&1) or time?(&1)))),
       do: {:error, "unsupported InfluxQL (columns beside a selector in GROUP BY time)"},
       else: :ok
  end

  defp multi?({:multi, _kind, _field, _tags, _limit, _alias}), do: true
  defp multi?(_item), do: false

  defp aggregate?({:aggregate, _fun, _arg, _alias}), do: true
  defp aggregate?({:multi, _kind, _field, _tags, _limit, _alias}), do: true

  defp aggregate?({:expr, ast, _alias}),
    do: InfluxQLExpr.aggregates(ast) != [] or InfluxQLExpr.transforms(ast) != []

  defp aggregate?(_item), do: false

  defp selector?({:aggregate, fun, arg, _alias}),
    do: InfluxQLAggregate.selector?(fun) and is_binary(arg)

  defp selector?({:multi, _kind, _field, _tags, _limit, _alias}), do: true
  defp selector?(_item), do: false

  defp time?({:column, column, _name}), do: String.downcase(column) == "time"
  defp time?(_item), do: false

  defp planning(message), do: {:error, {:engine, InfluxQLError.select_error(message)}}
end
