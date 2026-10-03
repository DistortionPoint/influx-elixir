defmodule InfluxElixir.Client.Local.SQLJoin do
  @moduledoc false
  # `FROM a CROSS JOIN b` for `InfluxElixir.Client.Local`: every left point
  # paired with every right point, the right side's columns merged in as
  # fields. Rows are the left side's measurement and timestamp.
  #
  # Qualifiers are dropped at parse time, so a column present on both sides
  # cannot be told apart. The engine refuses an unqualified reference to such a
  # column (the first one its planner meets: WHERE, then the select list, then
  # the rest) and the double does too; a query that names none of them is fine
  # on the engine. When the text did qualify a shared column (`a.v`) the engine
  # resolves it to a side, which the double cannot, so that is refused by name;
  # so is `SELECT *`, which would return each shared column twice, which a row
  # map cannot hold. Both sides carry `time`.

  alias InfluxElixir.Client.Local.{SQLError, SQLParser, SQLSchema}

  @typedoc "What a query reads from: its points and, for a CTE, its columns."
  @type source :: %{points: [point()], columns: [binary()] | nil, pushdown: boolean()}

  @typedoc "Fetches a named table or CTE as a source, or the engine's error for it."
  @type fetch_source :: (binary() -> {:ok, source()} | {:error, term()})

  @typep point :: SQLSchema.point()

  @doc """
  The query's points after its `CROSS JOIN` (the source's own when it has
  none), with the relations they were read from.
  """
  @spec cross_join(source(), SQLParser.parsed_query(), fetch_source()) ::
          {:ok, [point()], [SQLSchema.relation()]} | {:error, term()}
  def cross_join(source, %{cross_join: nil} = query, _fetch_source),
    do: {:ok, source.points, [SQLSchema.relation(query.qualifier, source)]}

  def cross_join(source, %{cross_join: {right_name, names}} = query, fetch_source) do
    with {:ok, right} <- fetch_source.(right_name),
         :ok <- check_collisions(source.points, right.points, query) do
      joined =
        for left <- source.points, right_point <- right.points do
          %{
            left
            | tags: Map.merge(left.tags, right_point.tags),
              fields: Map.merge(left.fields, right_point.fields)
          }
        end

      relations = [
        SQLSchema.relation(query.qualifier, source),
        SQLSchema.relation(List.last(names), right)
      ]

      {:ok, joined, relations}
    end
  end

  @spec check_collisions([point()], [point()], SQLParser.parsed_query()) ::
          :ok | {:error, term()}
  defp check_collisions(left, right, query) do
    shared = MapSet.intersection(columns_with_time(left), columns_with_time(right))
    references = Enum.map(SQLSchema.clause_refs(query), &elem(&1, 1))

    cond do
      MapSet.size(shared) == 0 ->
        :ok

      ambiguous = Enum.find(references, &MapSet.member?(shared, &1)) ->
        {:error, ambiguous_error(ambiguous, query)}

      SQLSchema.star?(query) ->
        {:error,
         SQLError.refusal(
           "SELECT * over a CROSS JOIN whose sides share #{Enum.join(Enum.sort(shared), ", ")} " <>
             "returns each twice, which a row map cannot hold; name the columns"
         )}

      true ->
        :ok
    end
  end

  # The engine's error for a reference to a column both sides have, when no
  # reference to it was qualified; when one was, which side the engine reads
  # it from is not known here.
  @spec ambiguous_error(binary(), SQLParser.parsed_query()) :: SQLError.t()
  defp ambiguous_error(column, query) do
    if is_map_key(query.qualified, column) do
      SQLError.refusal(
        "a column both sides of a CROSS JOIN have (#{column}), written with a qualifier: " <>
          "the double reads a column by its name alone, so the side a qualifier picks is " <>
          "not modelled"
      )
    else
      %{status: 500, body: "Schema error: Ambiguous reference to unqualified field #{column}"}
    end
  end

  @spec columns_with_time([point()]) :: MapSet.t(binary())
  defp columns_with_time(points) do
    columns = SQLSchema.point_columns(points)

    if Enum.any?(points, &(not is_nil(&1.timestamp))),
      do: MapSet.put(columns, "time"),
      else: columns
  end
end
