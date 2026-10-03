defmodule InfluxElixir.Client.Local.InfluxQLRun do
  @moduledoc false
  # Shapes the rows a statement's `WHERE` kept into the engine's answer: the
  # series of a `GROUP BY`, the rows of a plain select, the aggregates, and the
  # `LIMIT` and `OFFSET` of each series.

  alias InfluxElixir.Client.Local.{
    InfluxQL,
    InfluxQLAggregate,
    InfluxQLBuckets,
    InfluxQLExpr,
    InfluxQLGroup,
    InfluxQLNames,
    InfluxQLRegex,
    InfluxQLTransform
  }

  @epoch DateTime.from_unix!(0, :microsecond)

  @doc """
  Shapes `rows` — the measurement's points already filtered by the
  statement's `WHERE`, as SQL row maps with `"time"`, **in time order** —
  into the engine's answer. `tags` names the measurement's tag columns;
  everything else but `time` is a field.

  Options:

    * `:lower` - the lower bound (nanoseconds) the `WHERE` gives `time`;
      an aggregate row is stamped with it, and with the epoch without one
      (verified: `WHERE time >= 2` answers `mean` at 2 ns, `WHERE time < 3`
      at the epoch; with `GROUP BY` every series carries it)
    * `:fields` - the measurement's field names, when `LIMIT` or `OFFSET`
      need them (they are read from the rows otherwise)
    * `:types` - the type of each field (`:integer`, `:unsigned`, `:float`,
      ...): a `SUM` wraps at the range of its type, as it does there
  """
  @spec run(InfluxQL.query(), [map()], MapSet.t(binary()), keyword()) :: [map()]
  def run(query, rows, tags, opts \\ []) do
    context = %{
      query: query,
      tags: tags,
      time: lower_time(Keyword.get(opts, :lower)),
      fields: Keyword.get(opts, :fields),
      types: Keyword.get(opts, :types, %{}),
      expr_refs: for({:expr, ast, _name} <- query.items, ref <- InfluxQLExpr.refs(ast), do: ref),
      lower_ns: Keyword.get(opts, :lower),
      upper_ns: Keyword.get(opts, :upper),
      now: Keyword.get_lazy(opts, :now, fn -> System.os_time(:nanosecond) end),
      sources: Map.new(for({:column, column, name} <- query.items, do: {name, column})),
      body: query.items |> leading_time_off() |> Enum.map(&compile_item/1),
      star?: query.items == [:star]
    }

    query
    |> series_groups(rows, tags)
    |> Enum.flat_map(fn {key, group} ->
      group
      |> series(context, key)
      |> window(context)
    end)
  end

  # `LIMIT` and `OFFSET` of one series. A row of an aggregate is one row;
  # for plain columns the engine counts per selected field, not per row
  # (verified): `SELECT v, x FROM m LIMIT 1` is the first row with a `v` and
  # the first with an `x`, which may be two rows, each with its own field
  # only. A row that keeps no field is dropped.
  @spec window(Enumerable.t(), map()) :: [map()]
  defp window(rows, %{query: %{limit: nil, offset: 0}}), do: bounded(rows)

  defp window(rows, %{query: query} = context) do
    if Enum.any?(query.items, &(aggregate_item?(&1) or raw_transform_item?(&1))),
      do: rows |> Stream.drop(query.offset) |> take(query.limit) |> bounded(),
      else: window_per_field(rows, context)
  end

  defp window_per_field(rows, %{query: query} = context) do
    fields = window_fields(rows, context)

    # row index => the fields of it inside their windows
    kept =
      Enum.reduce(fields, %{}, fn field, kept ->
        field
        |> window_indices(rows, query)
        |> Enum.reduce(kept, fn index, kept -> Map.update(kept, index, [field], &[field | &1]) end)
      end)

    last = kept |> Map.keys() |> Enum.max(fn -> -1 end)

    for {row, index} <- rows |> Enum.take(last + 1) |> Enum.with_index(),
        {:ok, keep} <- [Map.fetch(kept, index)] do
      Map.drop(row, fields -- keep)
    end
  end

  # The fields a window counts, as the rows name them: the selected
  # columns that are fields, `*` being the measurement's (or, when the
  # caller did not say, those the rows hold).
  @spec window_fields([map()], map()) :: [binary()]
  defp window_fields(rows, %{query: query} = context) do
    query.items
    |> Enum.flat_map(fn
      :star ->
        star_fields(rows, context)

      {:column, _column, name} ->
        if field?(name, context), do: [name], else: []

      {:expr, _ast, name} ->
        [name]
    end)
    |> Enum.uniq()
  end

  defp star_fields(rows, %{fields: nil} = context) do
    rows
    |> Enum.flat_map(fn row ->
      for {name, _value} <- row,
          name not in ["iox::measurement", "time"],
          field?(name, context),
          do: name
    end)
    |> Enum.uniq()
  end

  defp star_fields(_rows, %{fields: fields}), do: fields

  # The indices of the rows that hold `field` inside its window, stopping
  # at the end of it.
  @spec window_indices(binary(), [map()], InfluxQL.query()) :: [non_neg_integer()]
  defp window_indices(field, rows, query) do
    wanted = if query.limit, do: query.offset + query.limit, else: :all
    rows |> field_indices(field, 0, wanted, []) |> Enum.drop(query.offset)
  end

  defp field_indices(_rows, _field, _index, 0, acc), do: Enum.reverse(acc)
  defp field_indices([], _field, _index, _wanted, acc), do: Enum.reverse(acc)

  defp field_indices([row | rows], field, index, wanted, acc) do
    if Map.has_key?(row, field),
      do: field_indices(rows, field, index + 1, decrement(wanted), [index | acc]),
      else: field_indices(rows, field, index + 1, wanted, acc)
  end

  defp decrement(:all), do: :all
  defp decrement(n), do: n - 1

  # The rows of each `GROUP BY` series, in order of the tag values by tag
  # key (verified: `GROUP BY r, h` orders as `GROUP BY h, r`); the
  # rows keep the time order they came in (the grouping is stable). Without
  # a `GROUP BY` there is one series and no pass to group it.
  @spec series_groups(InfluxQL.query(), [map()], MapSet.t(binary())) :: [{map(), [map()]}]
  defp series_groups(_query, [], _tags), do: []
  defp series_groups(%{group_by: []}, rows, _tags), do: [{%{}, rows}]

  defp series_groups(%{group_by: group_by}, rows, tags) do
    keys = group_by |> Enum.flat_map(&dimension_keys(&1, tags)) |> Enum.uniq() |> Enum.sort()
    check_group_keys(keys)

    rows
    |> Enum.group_by(&Map.take(&1, keys))
    |> Enum.sort_by(fn {key, _rows} -> Enum.map(keys, &series_sort_key(key, &1)) end)
  end

  # A column called `time` is a dimension of its own beside the time column,
  # in an order that is the engine's hash order (verified): refused.
  @spec check_group_keys([binary()]) :: :ok
  defp check_group_keys(keys) do
    if Enum.any?(keys, &(String.downcase(&1) == "time")),
      do: throw({:refused, "unsupported InfluxQL (GROUP BY a tag named time)"}),
      else: :ok
  end

  # The columns a dimension groups by: a name, every tag (`*`), the tags a
  # regular expression matches.
  @spec dimension_keys(InfluxQLGroup.dimension(), MapSet.t(binary())) :: [binary()]
  defp dimension_keys({:tag, name}, _tags), do: [name]
  defp dimension_keys(:wildcard, tags), do: MapSet.to_list(tags)

  defp dimension_keys({:regex, source}, tags) do
    regex = InfluxQLRegex.compile(source)
    Enum.filter(tags, &Regex.match?(regex, &1))
  end

  # The series that lacks the tag comes after every tag value, as the engine lists it.
  @spec series_sort_key(map(), binary()) :: {boolean(), term()}
  defp series_sort_key(key, tag) do
    value = Map.get(key, tag)
    {is_nil(value), value}
  end

  @spec lower_time(integer() | nil) :: DateTime.t()
  defp lower_time(nil), do: @epoch
  defp lower_time(ns), do: DateTime.from_unix!(Integer.floor_div(ns, 1_000), :microsecond)

  # ---------------------------------------------------------------------------
  # One series (one GROUP BY key)
  # ---------------------------------------------------------------------------

  @spec series([map()], map(), map()) :: Enumerable.t()
  defp series(rows, %{query: query} = context, key) do
    base = Map.put(key, "iox::measurement", query.measurement)

    cond do
      Enum.any?(query.items, &match?({:multi, _k, _f, _t, _n, _a}, &1)) ->
        multi_selector(rows, context, base)

      Enum.any?(query.items, &raw_transform_item?/1) ->
        transformed_raw(rows, context, base)

      not Enum.any?(query.items, &aggregate_item?/1) ->
        project(rows, context, base)

      query.group_time != nil ->
        bucketed(rows, context, base)

      true ->
        aggregate(rows, query.items, context, base)
    end
  end

  # The time column leads every row, named `time` unless the first `time`
  # that is selected renames it; a row with no field value is dropped.
  @spec project([map()], map(), map()) :: [map()]
  defp project(rows, %{query: query, body: body} = context, base) do
    rows = if query.descending, do: Enum.reverse(rows), else: rows
    time_name = InfluxQLNames.time_name(query.items)

    star? = context.star?

    for row <- rows,
        projected =
          if(star?, do: Map.delete(row, "time"), else: projection(body, row, context.types)),
        row_kept?(projected, row, context) do
      base |> Map.put(time_name, row["time"]) |> Map.merge(projected)
    end
  end

  # The items without the first `time` column, which is the leading one.
  @spec leading_time_off([InfluxQL.item()]) :: [InfluxQL.item()]
  defp leading_time_off(items) do
    case Enum.split_while(items, &(not InfluxQLNames.time_item?(&1))) do
      {before, [_time | after_time]} -> before ++ after_time
      {before, []} -> before
    end
  end

  # What the time test costs is paid once per statement, not once per row.
  @spec compile_item(InfluxQL.item()) :: term()
  defp compile_item(:star), do: :star

  defp compile_item({:column, _column, name} = item) do
    if InfluxQLNames.time_item?(item), do: {:time, name}, else: item
  end

  defp compile_item(item), do: item

  # A row is kept when it holds a field the list selects: a column's value, or
  # a field an expression reads, whatever the expression comes to.
  @spec row_kept?(map(), map(), map()) :: boolean()
  defp row_kept?(projected, row, %{expr_refs: refs} = context) do
    Enum.any?(projected, fn {name, _value} -> field?(name, context) end) or
      Enum.any?(refs, &(Map.get(row, &1) != nil and field?(&1, context)))
  end

  @spec projection([term()], map(), map()) :: map()
  defp projection(items, row, types),
    do: Enum.reduce(items, %{}, &put_item(&1, row, &2, types))

  @spec put_item(term(), map(), map(), map()) :: map()
  defp put_item(:star, row, acc, _types), do: Map.merge(acc, Map.delete(row, "time"))
  defp put_item({:time, name}, row, acc, _types), do: Map.put(acc, name, row["time"])

  defp put_item({:expr, ast, name}, row, acc, types) do
    case InfluxQLExpr.eval(ast, row, types) do
      nil -> acc
      :nan -> Map.put(acc, name, nil)
      value -> Map.put(acc, name, value)
    end
  end

  defp put_item({:column, column, name}, row, acc, _types) do
    case Map.fetch(row, column) do
      {:ok, value} -> Map.put(acc, name, value)
      :error -> acc
    end
  end

  # A projected key counts as a field value unless it is a tag or the time
  # (under its own name or an alias; `sources` maps an alias to its column).
  @spec field?(binary(), map()) :: boolean()
  defp field?(name, %{sources: sources, tags: tags}) do
    column = Map.get(sources, name, name)
    not (MapSet.member?(tags, column) or time_column?(column))
  end

  defp time_column?(column), do: byte_size(column) == 4 and String.downcase(column) == "time"

  @spec aggregate([map()], [InfluxQL.item()], map(), map()) :: [map()]
  defp aggregate(rows, items, %{tags: tags, time: time, types: types}, base) do
    plan = expression_plan(items, types, tags)
    fields = if count_star?(plan.aggregates), do: field_names(rows, tags), else: []
    named = InfluxQLAggregate.columns(plan.aggregates, rows, fields, tags, types)

    values = for {name, {:value, value, _point}, _spec} <- named, into: %{}, do: {name, value}

    cond do
      Enum.all?(named, fn {_name, result, _spec} -> result == :none end) ->
        []

      lone_selector?(for({:aggregate, _fun, _arg, _alias} = item <- items, do: item)) and
          plan.exprs == [] ->
        lone_selector_row(named, items, base, values)

      lone_selector_expression?(plan) ->
        expression_row(named, base, finish(values, plan), time)

      true ->
        [base |> Map.put("time", time) |> Map.merge(finish(values, plan))]
    end
  end

  # The only selector of the list inside arithmetic still returns its point's
  # time (verified: `max(v) * 2`).
  @spec lone_selector_expression?(map()) :: boolean()
  defp lone_selector_expression?(%{
         aggregates: [{:aggregate, fun, arg, _alias}],
         exprs: [_first | _more]
       }),
       do: InfluxQLAggregate.selector?(fun) and is_binary(arg)

  defp lone_selector_expression?(_plan), do: false

  defp expression_row([{_name, {:value, _value, point}, _spec}], base, values, _time),
    do: [base |> Map.put("time", point["time"]) |> Map.merge(values)]

  defp expression_row(_named, _base, _values, _time), do: []

  # The point a lone selector chose, with its time and the columns beside it;
  # a selector with no result there answers nothing.
  @spec lone_selector_row([tuple()], [InfluxQL.item()], map(), map()) :: [map()]
  defp lone_selector_row([{_name, {:value, _value, point}, _spec}], items, base, values) do
    columns =
      for {:column, column, name} <- items,
          Map.has_key?(point, column),
          into: %{},
          do: {name, point[column]}

    [base |> Map.put("time", point["time"]) |> Map.merge(columns) |> Map.merge(values)]
  end

  defp lone_selector_row(_named, _items, _base, _values), do: []

  # `GROUP BY time(...)`: a row for every bucket, as `InfluxQLBuckets` fills them.
  @spec bucketed([map()], map(), map()) :: Enumerable.t()
  defp bucketed(rows, %{query: query, tags: tags, types: types} = context, base) do
    plan = expression_plan(query.items, types, tags)
    fields = if count_star?(plan.aggregates), do: field_names(rows, tags), else: []

    bucket_aggregates = Enum.map(plan.aggregates, &mark_bucket/1)

    compute = fn bucket_rows ->
      InfluxQLAggregate.columns(bucket_aggregates, bucket_rows, fields, tags, types)
    end

    opts = [
      lower: scan_lower(context, rows, query, plan),
      upper: context.upper_ns,
      now: context.now,
      descending: query.descending,
      window: if(plan.transforms == [], do: query.limit && query.limit + query.offset)
    ]

    buckets = InfluxQLBuckets.series(rows, query.group_time, query.fill, opts, compute)

    # A list of transforms alone answers only the buckets they have a result for
    drop_empty? = Enum.all?(query.items, &transform_item?/1)

    if plan.transforms == [] do
      Stream.map(buckets, fn {start, values} ->
        base |> Map.put("time", ns_time(start)) |> Map.merge(finish(values, plan))
      end)
    else
      buckets
      |> Enum.to_list()
      |> transform_buckets(plan, query)
      |> Enum.flat_map(fn {start, values} ->
        case finish(values, plan) do
          visible when map_size(visible) == 0 and drop_empty? -> []
          visible -> [base |> Map.put("time", ns_time(start)) |> Map.merge(visible)]
        end
      end)
    end
  end

  # A percentile in a bucket reads its rank one further than over a series.
  defp mark_bucket({:aggregate, "percentile:" <> rest = fun, field, alias}) do
    if String.ends_with?(rest, ":bucket"),
      do: {:aggregate, fun, field, alias},
      else: {:aggregate, fun <> ":bucket", field, alias}
  end

  defp mark_bucket({:aggregate, "integral:" <> _flags = fun, field, alias}),
    do: {:aggregate, fun <> ":bucket", field, alias}

  defp mark_bucket(aggregate), do: aggregate

  # Where the buckets of a series start: at the bucket the range begins in, one
  # more back for the transforms that look back.
  @spec scan_lower(map(), [map()], InfluxQL.query(), map()) :: integer() | nil
  defp scan_lower(context, _rows, _query, %{transforms: []}), do: context.lower_ns

  defp scan_lower(context, rows, %{group_time: {every, _offset}}, plan) do
    cond do
      not lookback?(plan) -> context.lower_ns
      context.lower_ns != nil -> context.lower_ns - every
      rows == [] -> nil
      true -> time_ns(hd(rows)) - every
    end
  end

  # The transforms over the buckets of a series, whose first bucket is the one
  # before the range, which the transforms that look back scan (verified): it is
  # computed as any bucket, from the points in the scan and the `fill()`, and
  # is no row of the answer.
  @spec transform_buckets([{integer(), map()}], map(), InfluxQL.query()) :: [{integer(), map()}]
  defp transform_buckets(buckets, plan, query) do
    {every, _offset} = query.group_time
    lookback? = lookback?(plan)

    if lookback? and query.descending and phantom_value?(List.last(buckets)),
      do: throw({:refused, "unsupported InfluxQL (a transform in descending order after data)"})

    results =
      Enum.reduce(plan.transforms, buckets, fn transform, buckets ->
        inputs =
          Enum.map(buckets, fn {start, values} -> {start, Map.get(values, transform.source)} end)

        outputs = InfluxQLTransform.run(transform.name, transform.parameter || every, inputs)

        buckets
        |> Enum.zip(outputs)
        |> Enum.map(fn {{start, values}, output} ->
          {start, if(output == nil, do: values, else: Map.put(values, transform.key, output))}
        end)
      end)

    cond do
      not lookback? -> results
      query.descending -> Enum.drop(results, -1)
      true -> tl(results)
    end
  end

  # Whether the bucket scanned before the range holds a value.
  defp phantom_value?({_start, values}), do: map_size(values) > 0

  @lookback ~w(derivative non_negative_derivative difference non_negative_difference
               moving_average)

  @doc false
  @spec lookback?(map()) :: boolean()
  def lookback?(%{transforms: transforms}), do: Enum.any?(transforms, &(&1.name in @lookback))

  @doc """
  How far before the range the scan of a `GROUP BY time` goes, in nanoseconds:
  the transforms that compare with the bucket before read one more bucket (the
  answer, the first bucket whole, comes of the points in it), the others none.
  """
  @spec lookback(InfluxQL.query()) :: {:ok, non_neg_integer()} | {:error, binary()}
  def lookback(%{group_time: {every, _offset}, items: items}) do
    names =
      for {:expr, ast, _alias} <- items,
          {:transform, name, _inner, _parameter} <- InfluxQLExpr.transforms(ast),
          do: name

    looks_back? = Enum.any?(names, &(&1 in @lookback))

    cond do
      looks_back? and "cumulative_sum" in names ->
        {:error, "unsupported InfluxQL (cumulative_sum() beside a transform that looks back)"}

      looks_back? ->
        {:ok, every}

      true ->
        {:ok, 0}
    end
  end

  def lookback(_query), do: {:ok, 0}

  # The transforms over the points of a series: the values of a field in time
  # order, one result per point after the first. Points that share a time (of
  # several series that `GROUP BY` does not tell apart) are in an order the
  # double does not reproduce.
  @spec transformed_raw([map()], map(), map()) :: [map()]
  defp transformed_raw(rows, %{query: query, types: types, tags: tags}, base) do
    plan = expression_plan(query.items, types, tags)
    rows = if query.descending, do: Enum.reverse(rows), else: rows

    if query.descending and Enum.any?(plan.transforms, &(&1.name == "elapsed")),
      do: throw({:refused, "unsupported InfluxQL (elapsed() in descending order)"})

    if length(Enum.uniq_by(rows, & &1["time"])) != length(rows),
      do: throw({:refused, "unsupported InfluxQL (a transform over points that share a time)"})

    time_name = InfluxQLNames.time_name(query.items)

    results =
      Map.new(plan.transforms, fn transform ->
        inputs =
          for row <- rows, is_number(row[transform.source]) do
            {time_ns(row), row[transform.source]}
          end

        {transform.key, inputs |> raw_results(transform) |> Map.new()}
      end)

    for row <- rows,
        values = row_values(plan.transforms, results, time_ns(row)),
        values != %{},
        visible = finish(values, plan),
        visible != %{} do
      base |> Map.put(time_name, row["time"]) |> Map.merge(visible)
    end
  end

  defp raw_results(inputs, transform) do
    unit = transform.parameter || if(transform.name == "elapsed", do: 1, else: 1_000_000_000)
    results = InfluxQLTransform.run(transform.name, unit, inputs)
    for {{time, _value}, result} <- Enum.zip(inputs, results), result != nil, do: {time, result}
  end

  defp row_values(transforms, results, time) do
    for transform <- transforms,
        {:ok, result} <- [Map.fetch(results[transform.key], time)],
        into: %{},
        do: {transform.key, result}
  end

  @spec time_ns(map()) :: integer()
  defp time_ns(%{"time" => time}), do: DateTime.to_unix(time, :microsecond) * 1000

  # The aggregates to compute for a select list: its own, and those inside
  # expressions (named apart, `"\0agg0"`...), with the expressions rewritten to
  # read them, the types of those columns, and their names. The transforms of
  # the expressions are named apart too (`"\0tr0"`...), each with the column it
  # reads.
  @spec expression_plan([InfluxQL.item()], map(), MapSet.t(binary())) :: map()
  defp expression_plan(items, types, tags) do
    plain = for {:aggregate, _fn, _arg, _alias} = item <- items, do: item
    exprs = for {:expr, ast, name} <- items, do: {name, ast}

    keyed =
      exprs
      |> Enum.flat_map(fn {_name, ast} -> InfluxQLExpr.aggregates(ast) end)
      |> Enum.uniq()
      |> Enum.with_index()
      |> Map.new(fn {call, index} -> {call, "\0agg#{index}"} end)

    calls =
      exprs
      |> Enum.flat_map(fn {_name, ast} -> InfluxQLExpr.transforms(ast) end)
      |> Enum.uniq()
      |> Enum.with_index()
      |> Map.new(fn {call, index} -> {call, "\0tr#{index}"} end)

    transforms =
      for {{:transform, name, inner, parameter} = call, key} <- calls do
        {:ref, source} = InfluxQLExpr.hoist(inner, &Map.fetch!(keyed, &1))
        %{key: key, name: name, parameter: parameter, source: source, call: call}
      end

    %{
      aggregates: plain ++ for({{fun, arg}, key} <- keyed, do: {:aggregate, fun, arg, key}),
      exprs:
        for(
          {name, ast} <- exprs,
          do:
            {name,
             ast
             |> InfluxQLExpr.hoist_transforms(&Map.fetch!(calls, &1))
             |> InfluxQLExpr.hoist(&Map.fetch!(keyed, &1))}
        ),
      transforms: transforms,
      types:
        types
        |> Map.merge(
          for({{fun, arg}, key} <- keyed, into: %{}, do: {key, aggregate_type(fun, arg, types)})
        )
        |> Map.merge(
          for(
            {call, key} <- calls,
            into: %{},
            do: {key, InfluxQLExpr.result_type(call, types, tags)}
          )
        ),
      kinds:
        for({{fun, _arg}, key} <- keyed, into: %{}, do: {key, if(fun == "count", do: :count)}),
      hidden: Map.values(keyed) ++ Map.values(calls)
    }
  end

  defp aggregate_type(fun, arg, types), do: InfluxQLAggregate.result_type(fun, arg, types)

  # The values of a row of aggregates with the expressions computed from them.
  @spec finish(map(), map()) :: map()
  defp finish(values, %{exprs: [], hidden: []}), do: values

  defp finish(values, plan) do
    computed =
      Enum.flat_map(plan.exprs, fn {name, ast} ->
        case InfluxQLExpr.eval(ast, values, plan.types) do
          nil -> []
          :nan -> [{name, nil}]
          value -> [{name, value}]
        end
      end)

    values |> Map.drop(plan.hidden) |> Map.merge(Map.new(computed))
  end

  # The rows of a series as a list, as many as the double will hold: more is
  # refused, never read.
  @spec bounded(Enumerable.t()) :: [map()]
  defp bounded(rows) when is_list(rows), do: rows

  defp bounded(rows) do
    max = InfluxQLBuckets.max_rows()

    case Enum.take(rows, max + 1) do
      kept when length(kept) > max ->
        throw({:refused, "unsupported InfluxQL (more than #{max} rows in a series)"})

      kept ->
        kept
    end
  end

  @spec aggregate_item?(InfluxQL.item()) :: boolean()
  defp aggregate_item?({:aggregate, _fun, _arg, _alias}), do: true
  defp aggregate_item?({:multi, _kind, _field, _tags, _limit, _alias}), do: true
  defp aggregate_item?({:expr, ast, _name}), do: InfluxQLExpr.aggregates(ast) != []
  defp aggregate_item?(_item), do: false

  defp transform_item?({:expr, ast, _name}), do: InfluxQLExpr.transforms(ast) != []
  defp transform_item?(_item), do: false

  # `top(f, n)` and `bottom(f, n)` answer the points they chose, with their own
  # times and the columns beside them (verified): the `n` largest (smallest)
  # values of a series, of each bucket of a `GROUP BY time` (`fill()` adds no
  # row), the earlier point winning a tie; with tags, the best point of each
  # value of the tags. The points come in time order, a tie in time in the
  # order of their ranks.
  @spec multi_selector([map()], map(), map()) :: [map()]
  defp multi_selector(rows, %{query: query} = context, base) do
    {:multi, kind, field, tags, limit, alias} =
      Enum.find(query.items, &match?({:multi, _k, _f, _t, _n, _a}, &1))

    groups =
      case query.group_time do
        nil -> [rows]
        {every, offset} -> bucket_rows(rows, every, offset)
      end

    time_name = InfluxQLNames.time_name(query.items)

    if rows != [] and Enum.any?(tags, &(not MapSet.member?(context.tags, &1))),
      do:
        throw(
          {:refused, "unsupported InfluxQL (#{kind}() by a tag the measurement does not have)"}
        )

    columns =
      for {:column, column, name} = item <- query.items,
          not InfluxQLNames.time_item?(item),
          do: {column, name}

    tag_columns = Enum.map(tags, &{&1, &1})

    points =
      Enum.flat_map(groups, fn group ->
        group
        |> choose(kind, field, tags, limit)
        |> Enum.sort_by(fn {rank, point} -> {time_ns(point), rank} end)
        |> Enum.map(&elem(&1, 1))
      end)

    points = if query.descending, do: Enum.reverse(points), else: points

    for point <- points do
      beside =
        for {column, name} <- tag_columns ++ columns,
            Map.has_key?(point, column),
            into: %{},
            do: {name, point[column]}

      base
      |> Map.put(time_name, point["time"])
      |> Map.merge(beside)
      |> Map.put(alias || kind, point[field])
    end
  end

  defp bucket_rows(rows, every, offset) do
    rows
    |> Enum.group_by(&InfluxQLBuckets.bucket_start(time_ns(&1), every, offset))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # The chosen points of a group of rows, as `{rank, point}`.
  defp choose(rows, kind, field, tags, limit) do
    points = Enum.filter(rows, &orderable?(&1[field]))

    points =
      if tags == [] do
        points
      else
        points
        |> Enum.group_by(fn point -> Enum.map(tags, &point[&1]) end)
        |> best_of_each(kind, field)
      end

    points
    |> Enum.sort_by(& &1[field], if(kind == "top", do: :desc, else: :asc))
    |> Enum.take(limit)
    |> Enum.with_index()
    |> Enum.map(fn {point, rank} -> {rank, point} end)
  end

  # The first point with the best value of each group, in the order the groups
  # first appear.
  defp best_of_each(groups, kind, field) do
    groups
    |> Map.values()
    |> Enum.sort_by(&time_ns(hd(&1)))
    |> Enum.map(fn points ->
      Enum.reduce(points, fn point, best ->
        better? =
          if kind == "top", do: point[field] > best[field], else: point[field] < best[field]

        if better?, do: point, else: best
      end)
    end)
  end

  defp orderable?(value), do: is_number(value) or is_binary(value) or is_boolean(value)

  # A transform of a field reads the points, not buckets.
  @spec raw_transform_item?(InfluxQL.item()) :: boolean()
  defp raw_transform_item?({:expr, ast, _name}),
    do: InfluxQLExpr.transforms(ast) != [] and InfluxQLExpr.aggregates(ast) == []

  defp raw_transform_item?(_item), do: false

  @spec ns_time(integer()) :: DateTime.t()
  defp ns_time(ns), do: DateTime.from_unix!(Integer.floor_div(ns, 1_000), :microsecond)

  @spec count_star?([InfluxQL.item()]) :: boolean()
  defp count_star?(aggregates),
    do: Enum.any?(aggregates, &match?({:aggregate, "count", :star, _alias}, &1))

  # The field names the rows hold, sorted: only `COUNT(*)` needs them.
  @spec field_names([map()], MapSet.t(binary())) :: [binary()]
  defp field_names(rows, tags) do
    rows
    |> Enum.reduce(MapSet.new(), fn row, names ->
      row |> Map.keys() |> MapSet.new() |> MapSet.union(names)
    end)
    |> Enum.reject(&(&1 == "time" or MapSet.member?(tags, &1)))
    |> Enum.sort()
  end

  @spec lone_selector?([InfluxQL.item()]) :: boolean()
  defp lone_selector?([{:aggregate, fun, arg, _alias}]),
    do: InfluxQLAggregate.selector?(fun) and is_binary(arg)

  defp lone_selector?(_aggregates), do: false

  @spec take(Enumerable.t(), non_neg_integer() | nil) :: Enumerable.t()
  defp take(rows, nil), do: rows
  defp take(rows, limit), do: Stream.take(rows, limit)
end
