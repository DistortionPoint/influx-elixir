defmodule InfluxElixir.Client.Local.InfluxQLAggregate do
  @moduledoc false
  # The aggregates of an InfluxQL select list over the rows of a series (or of
  # one bucket of it), as the engine computes them (verified):
  #
  #   * `mean`, `sum` (wrapping at the range of its field's type), `count`,
  #     `min`, `max`, `first`, `last`; `median` (the middle of the sorted
  #     values, the average of the two middle ones for an even count, an integer
  #     for an integer field), `spread` (`max - min`), `stddev` (the sample
  #     standard deviation, null for one value) and `count(distinct(f))`
  #   * a result is `{:value, v, point}` (`point` is the row a selector chose),
  #     `:none` when no row held a value of the field (no row in the answer
  #     comes of it alone) and `:null` when rows held values and the result is
  #     null (a `stddev` of one value); `v` is `nil` for a float that
  #     overflowed, which the engine writes as `null`
  #   * `distinct(f)` lists values in an order the engine's hash gives: only a
  #     tag or a field no row holds, which it answers with nothing, is read
  #   * the columns are named after the function, a name taken twice is
  #     `name_1`, `name_2`

  alias InfluxElixir.Client.Local.{InfluxQL, InfluxQLArithmetic, InfluxQLExpr, SQLLimits}

  require SQLLimits

  @selectors ~w(min max first last)
  @root_of_float_max :math.sqrt(SQLLimits.float_max())

  @typedoc "What an aggregate comes to over some rows."
  @type result :: {:value, term(), map() | nil} | :none | :null

  @typedoc """
  How an aggregate fills an empty bucket: `:count` columns are zero (not null)
  there, and `type` is what a number given to `fill()` is cast to.
  """
  @type spec :: {:count | :other, InfluxQL.field_type()}

  @doc "Whether `fun` is an aggregate the double computes."
  @spec function?(binary()) :: boolean()
  def function?(fun),
    do:
      fun in ~w(mean sum count min max first last median spread stddev distinct mode) or
        String.starts_with?(fun, "percentile:") or String.starts_with?(fun, "integral:")

  @doc "Whether `fun` is a selector: it returns the point it chose, with its time and columns."
  @spec selector?(binary()) :: boolean()
  def selector?(fun), do: fun in @selectors or String.starts_with?(fun, "percentile:")

  @doc """
  The named results of `aggregates` over `rows`, with the `spec` of each
  column. `fields` names the fields `COUNT(*)` counts, `tags` the tag columns
  and `types` the type of each field.
  """
  @spec columns([InfluxQL.item()], [map()], [binary()], MapSet.t(binary()), map()) ::
          [{binary(), result(), spec()}]
  def columns(aggregates, rows, fields, tags, types) do
    tagged = Enum.filter(aggregates, &tag_argument?(&1, tags))

    cond do
      tagged == [] -> name_columns(aggregates, rows, fields, tags, types)
      length(tagged) == length(aggregates) -> name_columns(aggregates, [], fields, tags, types)
      true -> throw({:refused, "unsupported InfluxQL (an aggregate of a tag beside others)"})
    end
  end

  @spec name_columns([InfluxQL.item()], [map()], [binary()], MapSet.t(binary()), map()) ::
          [{binary(), result(), spec()}]
  defp name_columns(aggregates, rows, fields, tags, types) do
    beside? = length(aggregates) > 1

    {named, _names} =
      Enum.flat_map_reduce(aggregates, %{}, fn item, names ->
        item
        |> beside(beside?)
        |> compute(rows, fields, tags, types)
        |> tap(&check_null(item, &1, beside?, types))
        |> Enum.map_reduce(names, fn {name, result, spec}, names ->
          {unique, names} = unique_name(name, names)
          {{unique, result, spec}, names}
        end)
      end)

    named
  end

  # A `percentile()` that is not alone in the select list reads its rank as in a
  # bucket of a `GROUP BY time`: the last value is the one of rank `n` (verified;
  # alone, the engine answers nothing for it).
  @spec beside(InfluxQL.item(), boolean()) :: InfluxQL.item()
  defp beside({:aggregate, "percentile:" <> rest = fun, field, alias} = item, true) do
    if String.ends_with?(rest, ":bucket"),
      do: item,
      else: {:aggregate, fun <> ":bucket", field, alias}
  end

  defp beside(item, _beside?), do: item

  # A `percentile()` of an integer field that comes to null (a rank past its
  # values) breaks the engine's connection when another column is beside it
  # or the buckets of a `GROUP BY time` carry it (verified); alone over a
  # series it answers nothing. A float one answers the row of the others.
  @spec check_null(InfluxQL.item(), [{binary(), result(), spec()}], boolean(), map()) :: :ok
  defp check_null(
         {:aggregate, "percentile:" <> rest, field, _alias},
         [{_name, :null, _spec}],
         beside?,
         types
       ) do
    null_percentile(Map.get(types, field), beside? or String.ends_with?(rest, ":bucket"))
  end

  defp check_null(_item, _results, _beside, _types), do: :ok

  defp null_percentile(:integer, true), do: throw(:closed_connection)

  defp null_percentile(:unsigned, true),
    do:
      throw({:refused, "unsupported InfluxQL (percentile() of an unsigned field with no value)"})

  defp null_percentile(_type, _beside), do: :ok

  # An aggregate of a tag column answers nothing, alone: a query must select
  # a field to answer.
  @spec tag_argument?(InfluxQL.item(), MapSet.t(binary())) :: boolean()
  defp tag_argument?({:aggregate, _fun, field, _alias}, tags) when is_binary(field),
    do: MapSet.member?(tags, field)

  defp tag_argument?({:aggregate, "count", {:distinct, field}, _alias}, tags),
    do: MapSet.member?(tags, field)

  defp tag_argument?(_item, _tags), do: false

  # [{output_name, result, spec}]
  @spec compute(InfluxQL.item(), [map()], [binary()], MapSet.t(binary()), map()) ::
          [{binary(), result(), spec()}]
  defp compute({:aggregate, "count", :star, alias}, rows, fields, _tags, _types) do
    for field <- fields,
        do: {"#{alias || "count"}_" <> field, count(rows, field), {:count, :integer}}
  end

  defp compute({:aggregate, "count", {:distinct, field}, alias}, rows, _fields, _tags, _types) do
    [{alias || "count", count_distinct(rows, field), {:count, :integer}}]
  end

  defp compute({:aggregate, "distinct", field, alias}, rows, _fields, tags, _types) do
    [{alias || "distinct", distinct(rows, field, tags), {:other, :float}}]
  end

  defp compute({:aggregate, fun, field, alias}, rows, _fields, _tags, types) do
    [
      {alias || InfluxQLExpr.function_name(fun), apply_function(fun, rows, field, types),
       spec(fun, field, types)}
    ]
  end

  @doc "The type of the values an aggregate of `field` comes to."
  @spec result_type(binary(), binary(), map()) :: InfluxQL.field_type()
  def result_type(fun, field, types), do: fun |> spec(field, types) |> elem(1)

  @spec spec(binary(), binary(), map()) :: spec()
  defp spec("count", _field, _types), do: {:count, :integer}
  defp spec("integral:" <> _flags, _field, _types), do: {:other, :float}
  defp spec(fun, _field, _types) when fun in ["mean", "stddev"], do: {:other, :float}
  defp spec(_fun, field, types), do: {:other, Map.get(types, field, :float)}

  @spec apply_function(binary(), [map()], binary(), map()) :: result()
  defp apply_function("count", rows, field, _types), do: count(rows, field)

  defp apply_function(fun, rows, field, _types) when fun in @selectors,
    do: select(fun, rows, field)

  defp apply_function("percentile:" <> rest, rows, field, _types) do
    [percent | flags] = String.split(rest, ":")
    percentile(rows, field, percent |> Float.parse() |> elem(0), flags == ["bucket"])
  end

  defp apply_function("mode", rows, field, _types), do: mode(rows, field)

  defp apply_function("integral:" <> flags, rows, field, types),
    do: integral(rows, field, flags, types)

  defp apply_function("median", rows, field, _types), do: median(rows, field)
  defp apply_function("spread", rows, field, types), do: spread(rows, field, types)
  defp apply_function("stddev", rows, field, _types), do: stddev(rows, field)

  defp apply_function(fun, rows, field, types) do
    case numbers(rows, field) do
      [] -> :none
      values -> {:value, InfluxQLArithmetic.fold(fun, values, Map.get(types, field)), nil}
    end
  end

  # The value at rank `trunc(n * p / 100 + 0.5)` of the sorted points (equal
  # values keep their time order), a selector: it returns that point. A rank
  # below 1 has no value, nor has one of `n` and over, except in a bucket of a
  # `GROUP BY time`, where `n` is the largest (verified).
  @spec percentile([map()], binary(), number(), boolean()) :: result()
  defp percentile(rows, field, percent, bucket?) do
    points = Enum.filter(rows, &orderable?(&1[field]))
    count = length(points)
    rank = trunc(count * percent / 100.0 + 0.5)

    cond do
      points == [] ->
        :none

      rank >= 1 and (rank < count or (bucket? and rank == count)) ->
        point = points |> Enum.sort_by(& &1[field]) |> Enum.at(rank - 1)
        {:value, point[field], point}

      true ->
        :null
    end
  end

  # The area under the points of a series by the trapezoid rule, in `unit`
  # (verified: the time is the range's, as for any aggregate; one point has an
  # area of zero; each pair adds the mean of its two values, as floats, times
  # the time between them in the unit, which is what the engine's floats come
  # to; an area that overflows is null). Over the buckets of a `GROUP BY time`
  # the engine carries the line across the bucket edges and the gaps, which the
  # double does not.
  @spec integral([map()], binary(), binary(), map()) :: result()
  defp integral(rows, field, flags, types) do
    cond do
      Map.get(types, field) in [:string, :boolean] ->
        throw({:refused, "unsupported InfluxQL (integral() of a #{Map.get(types, field)} field)"})

      flags |> String.split(":") |> tl() == ["bucket"] ->
        throw({:refused, "unsupported InfluxQL (integral() in a GROUP BY time)"})

      true ->
        unit = flags |> String.split(":") |> hd() |> String.to_integer()

        case for(%{^field => value, "time" => time} <- rows, is_number(value), do: {time, value}) do
          [] -> :none
          points -> {:value, area(points, unit), nil}
        end
    end
  end

  defp area([_one], _unit), do: 0.0

  defp area(points, unit) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [{t0, y0}, {t1, y1}], total ->
      span = DateTime.diff(t1, t0, :microsecond) * 1000
      total + (y0 * 1.0 + y1 * 1.0) / 2 * (span / unit)
    end)
  rescue
    ArithmeticError -> nil
  end

  # The value that is most often there; of several the engine's choice is in an
  # order the double does not reproduce (verified), so it refuses.
  @spec mode([map()], binary()) :: result()
  defp mode(rows, field) do
    values = for %{^field => value} <- rows, orderable?(value), do: value

    case values do
      [] ->
        :none

      _values ->
        counts = Enum.frequencies(values)
        top = counts |> Map.values() |> Enum.max()

        case for({value, ^top} <- counts, do: value) do
          [best] ->
            {:value, best, nil}

          _tied ->
            throw({:refused, "unsupported InfluxQL (mode() of values equally often there)"})
        end
    end
  end

  @spec count([map()], binary()) :: result()
  defp count(rows, field) do
    case Enum.count(rows, &Map.has_key?(&1, field)) do
      0 -> :none
      n -> {:value, n, nil}
    end
  end

  @spec count_distinct([map()], binary()) :: result()
  defp count_distinct(rows, field) do
    case for(%{^field => value} <- rows, do: value) |> Enum.uniq() do
      [] -> :none
      values -> {:value, length(values), nil}
    end
  end

  # A tag, or a field no row holds, is answered with nothing; the values of
  # a field come in the engine's order, which the double does not reproduce.
  @spec distinct([map()], binary(), MapSet.t(binary())) :: result()
  defp distinct(rows, field, tags) do
    if MapSet.member?(tags, field) or not Enum.any?(rows, &Map.has_key?(&1, field)),
      do: :none,
      else:
        throw(
          {:refused, "unsupported InfluxQL (distinct(): the values come in the engine's order)"}
        )
  end

  @spec median([map()], binary()) :: result()
  defp median(rows, field) do
    case rows |> numbers(field) |> Enum.sort() do
      [] -> :none
      sorted -> {:value, middle(sorted), nil}
    end
  end

  @spec middle([number(), ...]) :: number() | nil
  defp middle(sorted) do
    count = length(sorted)
    upper = Enum.at(sorted, div(count, 2))

    if rem(count, 2) == 1,
      do: upper,
      else: average(Enum.at(sorted, div(count, 2) - 1), upper)
  end

  # Integers average as integers, the sum wrapped at 64 bits and the quotient
  # truncated toward zero; floats that overflow average to null.
  @spec average(number(), number()) :: number() | nil
  defp average(low, high) when is_integer(low) and is_integer(high),
    do: div(SQLLimits.wrap_int64(low + high), 2)

  defp average(low, high) do
    (low + high) / 2
  rescue
    ArithmeticError -> nil
  end

  @spec spread([map()], binary(), map()) :: result()
  defp spread(rows, field, types) do
    case numbers(rows, field) do
      [] ->
        :none

      values ->
        {:value, spread_of(values, Map.get(types, field)), nil}
    end
  end

  # `max - min`, but for integers the engine's maximum starts at zero
  # (verified: a lone `-9` has a spread of 9, `1` and `2` one of 1, `2` and `-9`
  # one of 11); what that makes of several negative values, or of negative
  # floats, is not known.
  @spec spread_of([number(), ...], atom()) :: number()
  defp spread_of(values, :integer) do
    if length(values) > 1 and Enum.all?(values, &(&1 < 0)),
      do: throw({:refused, "unsupported InfluxQL (the spread of several negative integers)"})

    spread = max(Enum.max(values), 0) - Enum.min(values)

    if spread > SQLLimits.int64_max(),
      do: throw({:refused, "unsupported InfluxQL (a spread beyond 64-bit integers)"}),
      else: spread
  end

  defp spread_of(values, _type) do
    if Enum.any?(values, &(&1 < 0)),
      do: throw({:refused, "unsupported InfluxQL (the spread of negative floats)"}),
      else: Enum.max(values) - Enum.min(values)
  end

  # The sample standard deviation, by Welford's streaming update as the
  # engine accumulates it; null for a single value, and for values whose
  # squares overflow (verified: two equal values of 1.7e308 are null).
  @spec stddev([map()], binary()) :: result()
  defp stddev(rows, field) do
    case numbers(rows, field) do
      [] -> :none
      [_one] -> :null
      values -> {:value, if(squares_fit?(values), do: welford(values)), nil}
    end
  end

  defp squares_fit?(values), do: Enum.all?(values, &(abs(&1) <= @root_of_float_max))

  @spec welford([number(), ...]) :: float() | nil
  defp welford(values) do
    {count, _mean, m2} =
      Enum.reduce(values, {0, 0.0, 0.0}, fn value, {count, mean, m2} ->
        count = count + 1
        delta = value - mean
        mean = delta / count + mean
        {count, mean, m2 + delta * (value - mean)}
      end)

    :math.sqrt(m2 / (count - 1))
  rescue
    ArithmeticError -> nil
  end

  # Rows arrive in time order, so the first extreme wins a tie, as on the
  # engine.
  @spec select(binary(), [map()], binary()) :: result()
  defp select(fun, rows, field) do
    candidates =
      if fun in ["first", "last"],
        do: Enum.filter(rows, &Map.has_key?(&1, field)),
        else: Enum.filter(rows, &orderable?(&1[field]))

    case candidates do
      [] -> :none
      points -> pick(fun, points, field)
    end
  end

  # `min` and `max` take numbers and strings (by bytes).
  @spec orderable?(term()) :: boolean()
  defp orderable?(value), do: is_number(value) or is_binary(value) or is_boolean(value)

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
end
