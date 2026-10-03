defmodule InfluxElixir.Client.Local.SQLNoFrom do
  @moduledoc false
  # A `SELECT` with no `FROM` (`SELECT 1`, `SELECT now()`), for
  # `InfluxElixir.Client.Local` (verified against InfluxDB 3 Core): it reads one
  # row with no column, so a constant or a call answers one row, an aggregate
  # (`count(*)`) counts it, `WHERE false` and `LIMIT 0` leave none, and a name
  # of a column is "No field named n.". The statement is read as one over
  # that row: the table is added to the text, where the first clause stands.

  alias InfluxElixir.Client.Local.{SQLInformation, SQLMask}

  @clauses ~w(WHERE GROUP HAVING ORDER LIMIT OFFSET UNION EXCEPT INTERSECT)

  @doc """
  The statement with a `FROM` of the one-row table when it has none, as it
  was otherwise.
  """
  @spec add_table(binary()) :: binary()
  def add_table(sql) do
    masked = sql |> SQLMask.mask() |> SQLMask.hide_inner_from()

    if Regex.match?(~r/\A\s*SELECT\b/iu, masked) do
      case scan(masked, 0, 0, nil, nil) do
        :from -> sql
        {:clause, at} -> insert(sql, at)
        :end -> insert(sql, byte_size(sql))
      end
    else
      sql
    end
  end

  @doc "A message that quotes the statement, with the table `add_table/1` put in it taken out."
  @spec restore(binary()) :: binary()
  def restore(message) do
    message
    |> String.replace(~s( FROM "#{SQLInformation.dual()}" ), " ")
    |> String.replace(~s( FROM "#{SQLInformation.dual()}"), "")
  end

  @spec insert(binary(), non_neg_integer()) :: binary()
  defp insert(sql, at) do
    before = binary_part(sql, 0, at)
    rest = binary_part(sql, at, byte_size(sql) - at)
    String.trim_trailing(before) <> ~s( FROM "#{SQLInformation.dual()}" ) <> rest
  end

  # The top-level words of the text: `:from` when one is `FROM`, else where
  # the first clause starts. `depth` counts the parentheses open; `word` is
  # where the word being read starts.
  @spec scan(binary(), non_neg_integer(), non_neg_integer(), integer() | nil, term()) ::
          :from | {:clause, non_neg_integer()} | :end
  defp scan(masked, at, depth, word, clause) when at >= byte_size(masked) do
    case word_end(masked, word, at, depth, clause) do
      {:done, result} -> result
      {:continue, nil} -> :end
      {:continue, found} -> found
    end
  end

  defp scan(masked, at, depth, word, clause) do
    <<byte>> = binary_part(masked, at, 1)

    if word_byte?(byte) do
      scan(masked, at + 1, depth, word || at, clause)
    else
      case word_end(masked, word, at, depth, clause) do
        {:done, result} -> result
        {:continue, clause} -> scan(masked, at + 1, next_depth(byte, depth), nil, clause)
      end
    end
  end

  @spec word_byte?(byte()) :: boolean()
  defp word_byte?(byte), do: byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte == ?_

  @spec word_end(binary(), integer() | nil, non_neg_integer(), non_neg_integer(), term()) ::
          {:done, :from} | {:continue, term()}
  defp word_end(_masked, nil, _at, _depth, clause), do: {:continue, clause}

  defp word_end(masked, start, at, 0, clause) do
    word = masked |> binary_part(start, at - start) |> String.upcase()

    cond do
      word == "FROM" -> {:done, :from}
      is_nil(clause) and word in @clauses -> {:continue, {:clause, start}}
      true -> {:continue, clause}
    end
  end

  defp word_end(_masked, _start, _at, _depth, clause), do: {:continue, clause}

  @spec next_depth(byte(), non_neg_integer()) :: non_neg_integer()
  defp next_depth(?(, depth), do: depth + 1
  defp next_depth(?), depth), do: max(depth - 1, 0)
  defp next_depth(_byte, depth), do: depth
end
