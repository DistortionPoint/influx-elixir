defmodule InfluxElixir.Client.Local.SQLDistinctOn do
  @moduledoc false
  # `SELECT DISTINCT ON (a[, b]) ...` for `InfluxElixir.Client.Local.SQLParser`
  # (verified against InfluxDB 3 Core): an ordinary select whose rows are then
  # cut to the first per distinct (a, b), after `ORDER BY` and before `LIMIT`
  # and `OFFSET`. The `ON` list is taken out of the text so the rest parses as
  # that ordinary select, and put back on the parsed query.

  alias InfluxElixir.Client.Local.{SQLError, SQLMask, SQLParser, SQLSelect}

  @distinct_on ~r/^(\s*SELECT\s+)DISTINCT\s+ON\s*\((.*)$/isu

  @doc "The text without its `DISTINCT ON (...)` list, and that list, or `nil`."
  @spec split(binary()) :: {binary(), binary() | nil}
  def split(sql) do
    with [_full, select, after_open] <- Regex.run(@distinct_on, sql),
         {:ok, on, rest} <- SQLMask.balanced(after_open) do
      {select <> String.trim_leading(rest), on}
    else
      _no_distinct_on -> {sql, nil}
    end
  end

  @doc """
  The engine's 405 for a `DISTINCT ON` with an aggregate in the select list or
  a `GROUP BY`, answered before the select list is read (verified). A
  `DATE_BIN` in `ORDER BY` is neither. `select_list` reads the select list out
  of the masked text.
  """
  @spec check_grouping(binary() | nil, binary(), (binary() -> binary())) ::
          :ok | {:error, map()}
  def check_grouping(nil, _sql, _select_list), do: :ok

  def check_grouping(_on, sql, select_list) do
    masked = SQLMask.mask(sql)

    if SQLSelect.aggregate_call?(select_list.(masked)) or
         Regex.match?(~r/\bGROUP\s+BY\b/iu, masked) do
      {:error,
       %{
         status: 405,
         body:
           "This feature is not implemented: DISTINCT ON expressions with GROUP BY, " <>
             "aggregation or window functions are not supported "
       }}
    else
      :ok
    end
  end

  @doc """
  Puts the `ON` list on the parsed query and applies the engine's other rules
  for it, each verified: at least one expression, and an `ORDER BY`, if any,
  must start with the `ON` expressions in their order (400, raised once the
  executor has found the columns). The double takes plain columns only and
  refuses an expression by name.
  """
  @spec apply(SQLParser.parsed_query(), binary() | nil) ::
          {:ok, SQLParser.parsed_query()} | {:error, map()}
  def apply(query, nil), do: {:ok, query}

  def apply(query, on) do
    columns = on |> SQLMask.split_commas() |> Enum.map(&String.trim/1)

    cond do
      columns == [""] ->
        {:error, %{status: 400, body: "Error during planning: No `ON` expressions provided"}}

      not Enum.all?(columns, &Regex.match?(~r/^(?:\w+|"[^"]+")$/u, &1)) ->
        {:error, SQLError.refusal("DISTINCT ON takes column names only: (#{on})")}

      true ->
        columns = Enum.map(columns, &String.trim(&1, "\""))
        {:ok, check_order(%{query | distinct_on: columns}, columns)}
    end
  end

  @spec check_order(SQLParser.parsed_query(), [binary()]) :: SQLParser.parsed_query()
  defp check_order(%{order_by: []} = query, _columns), do: query

  # Under DISTINCT ON the engine resolves ORDER BY against the table: a
  # select alias there is its schema error, which it reports before this
  # rule, so an aliased term is left to the executor's column check.
  defp check_order(%{order_by: order_by} = query, columns) do
    leading = order_by |> Enum.take(length(columns)) |> Enum.map(&elem(&1, 0))

    aliases =
      for {source, output} <- query.projection_columns || [], source != output, do: output

    if leading == columns or Enum.any?(leading, &(&1 in aliases)),
      do: query,
      else: %{
        query
        | plan_error:
            query.plan_error ||
              SQLError.planning(
                "SELECT DISTINCT ON expressions must match initial ORDER BY expressions"
              )
      }
  end
end
