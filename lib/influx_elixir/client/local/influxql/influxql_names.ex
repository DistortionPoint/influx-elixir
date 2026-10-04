defmodule InfluxElixir.Client.Local.InfluxQLNames do
  @moduledoc false
  # The names the engine gives the columns of a select list (verified).
  #
  # A name taken twice becomes `name_1`, then `name_2`, in the order of the
  # list, skipping a name already taken (`i AS i_1, i, i` is `i_1, i, i_2`).
  # Every answer leads with the time column, named `time`: a select item that
  # would take that name becomes `time_1`, and two that end up with the same
  # name are the planning error. A `time` column that is selected takes the
  # place of the leading one (and its alias names it); a second one is a
  # column of its own.

  alias InfluxElixir.Client.Local.{InfluxQLExpr, InfluxQLLiteral}

  @type item :: InfluxElixir.Client.Local.InfluxQL.item()

  @doc """
  The items with the names the engine gives them, or the refusal of a list
  the double does not name as the engine does.
  """
  @spec resolve([item()]) :: {:ok, [item()]} | {:error, binary()}
  def resolve(items) do
    # a list with a constant in it is the engine's planning error, whatever its names; a `*`
    # that is written out beside other columns names them all once it is (`InfluxQLWild`)
    if Enum.any?(items, &InfluxQLLiteral.literal_item?/1) or star_written_out?(items),
      do: {:ok, items},
      else: resolve_names(items)
  end

  @doc """
  Whether a `*` of the list is written out as columns: beside another `*`, or beside a column or a
  wildcard (alone, or beside an aggregate, it is left to the rows).
  """
  @spec star_written_out?([item()]) :: boolean()
  def star_written_out?(items) do
    stars = Enum.count(items, &(&1 == :star))

    stars > 1 or
      (stars == 1 and
         Enum.any?(items, fn
           {:column, _column, _name} = item -> not time_item?(item)
           {:wild_column, _target} -> true
           _item -> false
         end))
  end

  @spec resolve_names([item()]) :: {:ok, [item()]} | {:error, binary()}
  defp resolve_names(items) do
    explicit_time? = Enum.any?(items, &time_item?/1)

    {named, _taken} =
      Enum.map_reduce(items, MapSet.new(), fn item, taken ->
        case name(item) do
          nil ->
            {item, taken}

          name ->
            {unique, taken} = take(name, taken)
            {rename(item, unique), taken}
        end
      end)

    named = if explicit_time?, do: named, else: Enum.map(named, &lead_time/1)
    check(named, explicit_time?)
  end

  @doc "Whether an item is the `time` column (in any case)."
  @spec time_item?(item()) :: boolean()
  def time_item?({:column, column, _name}), do: String.downcase(column) == "time"
  def time_item?(_item), do: false

  @doc "The name the time column leads the answer with."
  @spec time_name([item()]) :: binary()
  def time_name(items) do
    case Enum.find(items, &time_item?/1) do
      {:column, _column, name} -> name
      nil -> "time"
    end
  end

  # `nil` for what is named only once the rows are known (`*`, `COUNT(*)`).
  @spec name(item()) :: binary() | nil
  defp name({:column, _column, name}), do: name
  defp name({:aggregate, _fun, :star, _alias}), do: nil
  defp name({:aggregate, fun, _arg, alias}), do: alias || InfluxQLExpr.function_name(fun)
  defp name({:expr, ast, alias}), do: alias || InfluxQLExpr.name(ast)
  defp name({:multi, kind, _field, _tags, _limit, alias}), do: alias || kind
  defp name(_item), do: nil

  @spec rename(item(), binary()) :: item()
  defp rename({:column, column, _name}, name), do: {:column, column, name}
  defp rename({:aggregate, fun, arg, _alias}, name), do: {:aggregate, fun, arg, name}
  defp rename({:expr, ast, _alias}, name), do: {:expr, ast, name}

  defp rename({:multi, kind, field, tags, limit, _alias}, name),
    do: {:multi, kind, field, tags, limit, name}

  @doc "The name `name` becomes among those `taken`: itself, else `name_1`, `name_2`..."
  @spec unique(binary(), MapSet.t(binary())) :: {binary(), MapSet.t(binary())}
  def unique(name, taken), do: take(name, taken)

  @spec take(binary(), MapSet.t(binary())) :: {binary(), MapSet.t(binary())}
  defp take(name, taken), do: take(name, name, 0, taken)

  defp take(base, candidate, count, taken) do
    if MapSet.member?(taken, candidate),
      do: take(base, "#{base}_#{count + 1}", count + 1, taken),
      else: {candidate, MapSet.put(taken, candidate)}
  end

  # With no `time` column selected, the leading one is named `time`, and the
  # engine renames an item of that name.
  @spec lead_time(item()) :: item()
  defp lead_time({:column, column, "time"}), do: {:column, column, "time_1"}

  defp lead_time({:aggregate, fun, arg, "time"}) when arg != :star,
    do: {:aggregate, fun, arg, "time_1"}

  defp lead_time({:expr, ast, "time"}), do: {:expr, ast, "time_1"}

  defp lead_time({:multi, kind, field, tags, limit, "time"}),
    do: {:multi, kind, field, tags, limit, "time_1"}

  defp lead_time(item), do: item

  # What may stand beside a `*`: other columns and wildcards, which are written out beside it
  # (see `InfluxQLWild`), and the time.
  defp star_companion?(:star), do: true
  defp star_companion?({:column, _column, _name}), do: true
  defp star_companion?({:wild_column, _target}), do: true
  defp star_companion?(_item), do: false

  @spec check([item()], boolean()) :: {:ok, [item()]} | {:error, binary()}
  defp check(items, explicit_time?) do
    names = items |> Enum.map(&name/1) |> Enum.reject(&is_nil/1)

    cond do
      :star in items and Enum.any?(items, &(not star_companion?(&1))) ->
        {:error, "unsupported InfluxQL (* beside other select items)"}

      length(names) != length(Enum.uniq(names)) ->
        {:error, "unsupported InfluxQL (select items that end up with the same name)"}

      explicit_time? and time_name(items) != "time" and
          Enum.any?(items, &match?({:aggregate, _fun, _arg, _alias}, &1)) ->
        {:error, "unsupported InfluxQL (a renamed time column beside an aggregate)"}

      true ->
        {:ok, items}
    end
  end
end
