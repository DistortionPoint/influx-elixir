defmodule InfluxElixir.Client.Local.InfluxQLRun do
  @moduledoc """
  Shapes the rows a statement's `WHERE` kept into the engine's answer: the
  series of a `GROUP BY`, the rows of a plain select, the aggregates, and the
  `LIMIT` and `OFFSET` of each series.
  """

  alias InfluxElixir.Client.Local.{InfluxQL, InfluxQLArithmetic, InfluxQLNames}

  @epoch DateTime.from_unix!(0, :microsecond)

  @selectors ~w(min max first last)

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
      sources: Map.new(for({:column, column, name} <- query.items, do: {name, column})),
      body: query.items |> leading_time_off() |> Enum.map(&compile_item/1),
      star?: query.items == [:star]
    }

    query
    |> series_groups(rows)
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
  @spec window([map()], map()) :: [map()]
  defp window(rows, %{query: %{limit: nil, offset: 0}}), do: rows

  defp window(rows, %{query: query} = context) do
    if Enum.any?(query.items, &match?({:aggregate, _fn, _arg, _alias}, &1)),
      do: rows |> Enum.drop(query.offset) |> take(query.limit),
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
      :star -> star_fields(rows, context)
      {:column, _column, name} -> if field?(name, context), do: [name], else: []
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
  @spec series_groups(InfluxQL.query(), [map()]) :: [{map(), [map()]}]
  defp series_groups(%{group_by: []}, []), do: []
  defp series_groups(%{group_by: []}, rows), do: [{%{}, rows}]

  defp series_groups(%{group_by: group_by}, rows) do
    keys = Enum.sort(group_by)

    rows
    |> Enum.group_by(&Map.take(&1, keys))
    |> Enum.sort_by(fn {key, _rows} -> Enum.map(keys, &series_sort_key(key, &1)) end)
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

  @spec series([map()], map(), map()) :: [map()]
  defp series(rows, %{query: query} = context, key) do
    base = Map.put(key, "iox::measurement", query.measurement)

    if Enum.any?(query.items, &match?({:aggregate, _fn, _arg, _alias}, &1)),
      do: aggregate(rows, query.items, context, base),
      else: project(rows, context, base)
  end

  # The time column leads every row, named `time` unless the first `time`
  # that is selected renames it; a row with no field value is dropped.
  @spec project([map()], map(), map()) :: [map()]
  defp project(rows, %{query: query, body: body} = context, base) do
    rows = if query.descending, do: Enum.reverse(rows), else: rows
    time_name = InfluxQLNames.time_name(query.items)

    star? = context.star?

    for row <- rows,
        projected = if(star?, do: Map.delete(row, "time"), else: projection(body, row)),
        Enum.any?(projected, fn {name, _value} -> field?(name, context) end) do
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

  @spec projection([term()], map()) :: map()
  defp projection(items, row), do: Enum.reduce(items, %{}, &put_item(&1, row, &2))

  @spec put_item(term(), map(), map()) :: map()
  defp put_item(:star, row, acc), do: Map.merge(acc, Map.delete(row, "time"))
  defp put_item({:time, name}, row, acc), do: Map.put(acc, name, row["time"])

  defp put_item({:column, column, name}, row, acc) do
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
    aggregates = for {:aggregate, _fn, _arg, _alias} = item <- items, do: item
    fields = if count_star?(aggregates), do: field_names(rows, tags), else: []

    {values, _names} =
      Enum.flat_map_reduce(aggregates, %{}, fn item, names ->
        item
        |> compute(rows, fields, types)
        |> Enum.map_reduce(names, fn {name, value}, names ->
          {unique, names} = unique_name(name, names)
          {{unique, value}, names}
        end)
      end)

    values = for {name, {:value, value, _point}} <- values, into: %{}, do: {name, value}

    cond do
      values == %{} ->
        []

      lone_selector?(aggregates) ->
        [{:aggregate, fun, field, _alias}] = aggregates
        {:value, _value, point} = select(fun, rows, field)

        columns =
          for {:column, column, name} <- items,
              Map.has_key?(point, column),
              into: %{},
              do: {name, point[column]}

        [base |> Map.put("time", point["time"]) |> Map.merge(columns) |> Map.merge(values)]

      true ->
        [base |> Map.put("time", time) |> Map.merge(values)]
    end
  end

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
  defp lone_selector?([{:aggregate, fun, arg, _alias}]), do: fun in @selectors and arg != :star
  defp lone_selector?(_aggregates), do: false
  # [{output_name, {:value, value, point} | :none}]
  @spec compute(InfluxQL.item(), [map()], [binary()], map()) :: [
          {binary(), {:value, term(), map()} | :none}
        ]
  defp compute({:aggregate, "count", :star, alias}, rows, fields, _types) do
    for field <- fields, do: {"#{alias || "count"}_" <> field, count(rows, field)}
  end

  defp compute({:aggregate, fun, field, alias}, rows, _fields, types) do
    [{alias || fun, apply_function(fun, rows, field, types)}]
  end

  @spec apply_function(binary(), [map()], binary(), map()) ::
          {:value, term(), map() | nil} | :none
  defp apply_function("count", rows, field, _types), do: count(rows, field)

  defp apply_function(fun, rows, field, _types) when fun in @selectors,
    do: select(fun, rows, field)

  defp apply_function(fun, rows, field, types) do
    case numbers(rows, field) do
      [] -> :none
      values -> {:value, InfluxQLArithmetic.fold(fun, values, Map.get(types, field)), nil}
    end
  end

  @spec count([map()], binary()) :: {:value, non_neg_integer(), nil} | :none
  defp count(rows, field) do
    case Enum.count(rows, &Map.has_key?(&1, field)) do
      0 -> :none
      n -> {:value, n, nil}
    end
  end

  # Rows arrive in time order, so the first extreme wins a tie, as on the
  # engine.
  @spec select(binary(), [map()], binary()) :: {:value, term(), map()} | :none
  defp select(fun, rows, field) do
    candidates =
      if fun in ["first", "last"],
        do: Enum.filter(rows, &Map.has_key?(&1, field)),
        else: Enum.filter(rows, &is_number(&1[field]))

    case candidates do
      [] -> :none
      points -> pick(fun, points, field)
    end
  end

  @spec pick(binary(), [map(), ...], binary()) :: {:value, term(), map()}
  defp pick("first", [point | _rest], field), do: {:value, point[field], point}
  defp pick("last", points, field), do: pick("first", Enum.reverse(points), field)

  defp pick("max", points, field) do
    point = Enum.reduce(points, fn p, best -> if p[field] > best[field], do: p, else: best end)
    {:value, point[field], point}
  end

  defp pick("min", points, field) do
    point = Enum.reduce(points, fn p, best -> if p[field] < best[field], do: p, else: best end)
    {:value, point[field], point}
  end

  @spec numbers([map()], binary()) :: [number()]
  defp numbers(rows, field), do: for(%{^field => v} <- rows, is_number(v), do: v)

  # The engine names a second `min` `min_1`, a third `min_2`.
  @spec unique_name(binary(), map()) :: {binary(), map()}
  defp unique_name(name, names) do
    case Map.fetch(names, name) do
      :error -> {name, Map.put(names, name, 1)}
      {:ok, n} -> {"#{name}_#{n}", Map.put(names, name, n + 1)}
    end
  end

  @spec take([map()], non_neg_integer() | nil) :: [map()]
  defp take(rows, nil), do: rows
  defp take(rows, limit), do: Enum.take(rows, limit)
end
