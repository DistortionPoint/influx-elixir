defmodule InfluxElixir.Client.Local.SQLSort do
  @moduledoc false
  # The ordering of values and rows for `InfluxElixir.Client.Local`'s SQL, as
  # the engine orders them (verified against InfluxDB 3 Core): `DateTime`s
  # chronologically, numbers by `InfluxElixir.Client.Local.SQLNumber` (a
  # `UInt64` or a decimal by its value, an infinity beyond every finite float),
  # nulls last when ascending and first when descending unless the query says
  # `NULLS FIRST` / `NULLS LAST`; it is not term order, which puts a nil before
  # every string and between `false` and `true`.

  alias InfluxElixir.Client.Local.{SQLClauses, SQLNumber}

  @typedoc "A key's direction and where its nulls go."
  @type placement :: {:asc | :desc, :nulls_first | :nulls_last}

  @typedoc "How one `ORDER BY` key reads a value from an item."
  @type key :: {(term() -> term()), SQLClauses.direction()}

  @doc """
  Stable multi-key sort with a direction per key.

  Each item's key values are read once, not on every comparison, so the cost
  of a sort is its keys over the items and not over the comparisons.
  """
  @spec sort_by_keys([term()], [key()]) :: [term()]
  # One key, the common case (`ORDER BY time`): its key functions are cheap
  # field reads, and building a decorated list costs more than it saves.
  def sort_by_keys(items, [{key_fn, direction}]) do
    placement = null_placement(direction)
    Enum.sort(items, fn a, b -> value_before?(key_fn.(a), key_fn.(b), placement) != :after end)
  end

  def sort_by_keys(items, keys) do
    placements = Enum.map(keys, fn {_key_fn, direction} -> null_placement(direction) end)

    items
    |> Enum.map(fn item ->
      {Enum.map(keys, fn {key_fn, _direction} -> key_fn.(item) end), item}
    end)
    |> Enum.sort(fn {a, _item_a}, {b, _item_b} -> values_before?(a, b, placements) end)
    |> Enum.map(fn {_values, item} -> item end)
  end

  @spec values_before?([term()], [term()], [placement()]) :: boolean()
  defp values_before?([], [], []), do: true

  defp values_before?([x | xs], [y | ys], [placement | rest]) do
    case value_before?(x, y, placement) do
      :tie -> values_before?(xs, ys, rest)
      order -> order == :before
    end
  end

  @doc "One key's order: `:before`, `:after` or `:tie`."
  @spec value_before?(term(), term(), placement()) :: :before | :after | :tie
  def value_before?(x, y, {dir, nulls}) do
    cond do
      is_nil(x) and is_nil(y) -> :tie
      is_nil(x) -> if nulls == :nulls_first, do: :before, else: :after
      is_nil(y) -> if nulls == :nulls_last, do: :before, else: :after
      value_order(x, y) and value_order(y, x) -> :tie
      value_order(x, y) == (dir == :asc) -> :before
      true -> :after
    end
  end

  # Where a direction puts nulls when the query does not say.
  @spec null_placement(SQLClauses.direction()) :: placement()
  defp null_placement(:asc), do: {:asc, :nulls_last}
  defp null_placement(:desc), do: {:desc, :nulls_first}
  defp null_placement({dir, nulls}), do: {dir, nulls}

  @doc "Whether `a` sorts at or before `b`, ascending."
  @spec value_order(term(), term()) :: boolean()
  def value_order(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) != :gt

  # Integers of one type, and floats that are not zero (the engine orders -0.0
  # before 0.0), order as Erlang orders them.
  def value_order(a, b) when is_integer(a) and is_integer(b), do: a <= b

  def value_order(a, b) when is_float(a) and is_float(b) and a != 0.0 and b != 0.0,
    do: a <= b

  def value_order(a, b) do
    if SQLNumber.numeric?(a) and SQLNumber.numeric?(b),
      do: SQLNumber.compare(a, b) != :gt,
      else: a <= b
  end
end
