defmodule InfluxElixir.Client.Local.InfluxQLWild do
  @moduledoc false
  # Wildcards in the select list of an InfluxQL `SELECT`, written out for one
  # measurement the way the engine does (verified):
  #
  #   * `*::field` is every field, `*::tag` every tag (alone, no field to answer:
  #     nothing), `/re/` every field or tag whose name matches it (unanchored,
  #     case-sensitive; an alias is ignored). A column twice is `name_1`
  #   * `F(*)` and `F(/re/)` are `F` of every field the wildcard stands for that
  #     the function takes (a regular expression only names fields), each
  #     column named `F_field` (`alias_field` after `AS`): the numeric fields
  #     for `mean sum median spread stddev percentile abs round floor ceil sqrt
  #     `ln log pow` and the transforms except `elapsed`, the numeric and boolean
  #     ones for `min` and `max`, every field for `count`, `mode`, `elapsed`,
  #     `first` and `last`
  #   * `*::tag` is the planning error `unable to use tag as wildcard in F()`
  #   * a measurement with none of them answers nothing; a function the double
  #     does not know is refused by name, never answered with nothing

  alias InfluxElixir.Client.Local.{InfluxQL, InfluxQLExpr, InfluxQLNames, InfluxQLRegex}

  @numeric ~w(integer unsigned float)a
  @numeric_functions ~w(mean sum median spread stddev percentile integral abs round floor ceil sqrt ln
                        log pow derivative non_negative_derivative difference
                        non_negative_difference cumulative_sum moving_average top bottom)
  @every_type ~w(first last count mode elapsed)
  @aggregates ~w(mean sum median spread stddev min max first last count mode)
  @known @every_type ++ ~w(min max) ++ @numeric_functions

  @doc """
  The query with its wildcards written out for a measurement with the given
  field `types` and `tags`: `{:ok, query}`, `:empty` when nothing is left to
  select, `{:error, message}` for a list the double does not name as the engine
  does. A query without wildcards is returned as it is.
  """
  @spec expand(InfluxQL.query(), %{binary() => atom()}, MapSet.t(binary())) ::
          {:ok, InfluxQL.query()} | :empty | {:error, binary()}
  def expand(%{items: items} = query, types, tags) do
    cond do
      not Enum.any?(items, &wild?/1) ->
        {:ok, query}

      unknown = Enum.find(items, &unknown_call?/1) ->
        {:wild_call, name, _extra, _target, _alias} = unknown
        {:error, "unsupported InfluxQL (#{name}() of a wildcard)"}

      true ->
        case Enum.flat_map(items, &expand_item(&1, types, tags)) do
          [] ->
            :empty

          expanded ->
            with {:ok, named} <- InfluxQLNames.resolve(expanded),
                 do: {:ok, %{query | items: named}}
        end
    end
  end

  defp unknown_call?({:wild_call, name, _extra, _target, _alias}), do: name not in @known
  defp unknown_call?(_item), do: false

  defp wild?({:wild_column, _target}), do: true
  defp wild?({:wild_call, _name, _extra, _target, _alias}), do: true
  defp wild?(_item), do: false

  defp expand_item({:wild_column, {:star, "field"}}, types, _tags),
    do: for(field <- sorted(Map.keys(types)), do: {:column, field, field})

  defp expand_item({:wild_column, {:star, "tag"}}, _types, tags),
    do: for(tag <- sorted(tags), do: {:column, tag, tag})

  defp expand_item({:wild_column, {:regex, source}}, types, tags) do
    regex = InfluxQLRegex.compile(source)
    names = Enum.uniq(sorted(Map.keys(types)) ++ sorted(tags))
    for name <- names, Regex.match?(regex, name), do: {:column, name, name}
  end

  defp expand_item({:wild_call, name, extra, target, alias}, types, _tags) do
    for {field, type} <- fields_of(target, types),
        takes?(name, type),
        item = call_item(name, extra, field, "#{alias || name}_#{field}"),
        do: item
  end

  defp expand_item(item, _types, _tags), do: [item]

  defp fields_of({:star, _kind}, types), do: types |> Enum.sort() |> Enum.to_list()

  defp fields_of({:regex, source}, types) do
    regex = InfluxQLRegex.compile(source)
    types |> Enum.sort() |> Enum.filter(fn {field, _type} -> Regex.match?(regex, field) end)
  end

  defp takes?(name, type) when name in @every_type,
    do: type in (@numeric ++ [:string, :boolean])

  defp takes?(name, type) when name in ["min", "max"], do: type in (@numeric ++ [:boolean])
  defp takes?(name, type) when name in @numeric_functions, do: type in @numeric

  # `F(field)` as the item the engine reads it as; the engine counts the
  # arguments first (the wildcard is one).
  defp call_item(name, extra, field, column) do
    case arity_error(name, 1 + length(extra)) do
      nil -> call_item_of(name, extra, field, column)
      message -> {:planning_error, message}
    end
  end

  @one_argument @aggregates ++
                  ~w(difference non_negative_difference cumulative_sum abs round floor ceil sqrt ln)
  @two_arguments ~w(percentile moving_average pow log)
  @one_or_two ~w(derivative non_negative_derivative elapsed integral)
  @selectors ~w(top bottom)

  @spec arity_error(binary(), pos_integer()) :: binary() | nil
  defp arity_error(name, count) when name in @one_argument and count != 1,
    do: "invalid number of arguments for #{name}, expected 1, got #{count}"

  defp arity_error(name, count) when name in @two_arguments and count != 2,
    do: "invalid number of arguments for #{name}, expected 2, got #{count}"

  defp arity_error(name, count) when name in @selectors and count < 2,
    do: "invalid number of arguments for #{name}, expected at least 2, got #{count}"

  defp arity_error(name, count) when name in @one_or_two and count > 2,
    do:
      "invalid number of arguments for #{name}, expected at least 1 but no more than 2, " <>
        "got #{count}"

  defp arity_error(_name, _count), do: nil

  defp call_item_of(name, _extra, field, column) when name in @aggregates,
    do: {:aggregate, name, field, column}

  defp call_item_of("integral", extra, field, column) do
    case InfluxQLExpr.integral_unit(extra) do
      {:ok, unit} -> {:aggregate, "integral:" <> Integer.to_string(unit), field, column}
      {:planning, message} -> {:planning_error, message}
      :error -> refuse("integral")
    end
  end

  defp call_item_of("percentile", [{:str, content}], _field, _column) do
    {:planning_error,
     "expected number for percentile(), got Literal(String(#{inspect(content)}))"}
  end

  defp call_item_of("percentile", [{:lit, {_kind, percent}}], field, column),
    do: {:aggregate, "percentile:" <> InfluxQLExpr.number_text(percent), field, column}

  defp call_item_of(name, extra, field, column) do
    arguments =
      Enum.map_join([~s("#{field}") | Enum.map(extra, &argument_text(name, &1))], ", ", & &1)

    case InfluxQLExpr.parse("#{name}(#{arguments})") do
      {:ok, ast} -> {:expr, ast, column}
      {:planning, message} -> {:planning_error, message}
      _other -> refuse(name)
    end
  end

  defp argument_text(_name, {:lit, {_kind, number}}), do: InfluxQLExpr.number_text(number)
  defp argument_text(_name, {:dur, ns}), do: "#{ns}ns"
  defp argument_text(_name, {:neg, {:dur, ns}}), do: "-#{ns}ns"
  defp argument_text(name, _other), do: refuse(name)

  @spec refuse(binary()) :: no_return()
  defp refuse(name),
    do: throw({:refused, "unsupported InfluxQL (#{name}() of a wildcard with those arguments)"})

  defp sorted(names), do: names |> Enum.to_list() |> Enum.sort()
end
