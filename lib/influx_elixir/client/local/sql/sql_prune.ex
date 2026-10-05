defmodule InfluxElixir.Client.Local.SQLPrune do
  @moduledoc false
  # The negations the engine never meets, so that the error it has for them is dropped
  # (verified against InfluxDB 3 Core).
  #
  # The negation of a type it does not support (`-u` for an unsigned integer) is found only when
  # the physical plan is built. By then the optimizer has replaced the plan of a query that
  # answers no row with an empty relation (`InfluxElixir.Client.Local.SQLSimplify.empty?/2`),
  # and has removed from the `WHERE` and the select list what its simplifier proves is not
  # needed (`-u > 1 OR true`; `-u + NULL`). The simplifier is read as the optimizer reads it,
  # not as the rows do: `n = 1 AND NULL` is not an empty relation and keeps its negations.
  #
  # Whether two equalities contradict depends on the engine's coercion of their literals
  # (`InfluxElixir.Client.Local.SQLContradict`); for the ones not modelled the answer is not
  # known, and the verdict says so, so that the caller refuses instead of guessing.
  #
  # A common table expression is planned with the query that reads it, and the optimizer drops
  # the columns nothing reads (verified: `WITH t AS (SELECT -u AS q FROM m) SELECT count(*) FROM
  # t` is the count of the rows, where `SELECT q FROM t` is the negation's error), and an `ORDER
  # BY` that nothing above needs. `dead/2` finds the negations of those.

  alias InfluxElixir.Client.Local.{
    SQLContradict,
    SQLExpr,
    SQLParser,
    SQLSchema,
    SQLSimplify
  }

  @typedoc "Whether the error of a negation stands, is dropped, or is not known."
  @type verdict :: :keep | :drop | :unknown

  @typedoc "The Arrow types of the named columns."
  @type types :: (names :: [binary()] -> %{binary() => binary()})

  @typep reads :: MapSet.t(binary()) | :all

  @doc """
  The verdict on the error of the negation `item` of `query`. `types` gives the Arrow types of
  the columns it is asked for, `unused` the outputs of the query nothing reads (see `unused/2`),
  or `nil` for the query that answers.
  """
  @spec verdict(term(), SQLParser.parsed_query(), types(), [binary()] | nil) :: verdict()
  def verdict({:neg, _inner} = item, query, types, unused) do
    if is_list(unused) and item in negations(unused_terms(query, unused), []) do
      :drop
    else
      columns = types.(equality_columns(query.where, []))

      cond do
        SQLSimplify.empty?(query, columns) -> :drop
        SQLContradict.unknown?(predicates(query.where, []), columns) -> :unknown
        item in removed(query, columns) -> :drop
        true -> :keep
      end
    end
  end

  def verdict(_item, _query, _types, _dead), do: :keep

  @doc """
  Whether the optimizer proves the filter of a query that negates something false, so that its
  plan is empty and no row is read, and an expression no row could evaluate cannot fail (a
  negation of an unsigned integer is a refusal when a row meets it). A query that negates
  nothing is not asked.
  """
  @spec empty?(SQLParser.parsed_query(), types()) :: boolean()
  def empty?(query, types) do
    negations([query.where, query.projection_columns, query.order_by, query.having], []) != [] and
      SQLSimplify.empty?(query, types.(equality_columns(query.where, [])))
  end

  @doc """
  The outputs of the common table expressions that no query after them reads, by the name of
  the expression. The optimizer plans neither these nor the `ORDER BY` of an expression with no
  limit (a sort changes nothing above it that reads no order).
  """
  @spec unused([{binary(), SQLParser.parsed_query()}], SQLParser.parsed_query()) :: %{
          binary() => [binary()]
        }
  def unused(ctes, main) do
    if Enum.any?(ctes, fn {_name, query} -> negations(terms(query), []) != [] end) do
      {found, _read} =
        ctes
        |> Enum.reverse()
        |> Enum.reduce({%{}, reads(main, [], :final)}, fn {name, query}, {found, read} ->
          unused = unused_outputs(query, read)
          {Map.put(found, name, unused), merge(read, reads(query, unused, {:cte, read}))}
        end)

      found
    else
      %{}
    end
  end

  @doc """
  The query with the outputs nothing reads computed as the null: the engine does not plan them,
  so no row evaluates them (and an `ORDER BY` that holds a negation, which nothing needs, is
  left out).
  """
  @spec nullify(SQLParser.parsed_query(), [binary()] | nil) :: SQLParser.parsed_query()
  def nullify(query, nil), do: query
  def nullify(query, []), do: query

  def nullify(query, unused) do
    columns =
      Enum.map(query.projection_columns || [], fn {expr, output} = column ->
        if output in unused and is_tuple(expr), do: {{:lit, nil}, output}, else: column
      end)

    order_by =
      if sort_dead?(query) and negations(query.order_by, []) != [], do: [], else: query.order_by

    %{query | projection_columns: if(query.projection_columns, do: columns), order_by: order_by}
  end

  # The columns a query reads, leaving out the outputs nothing reads (and the `ORDER BY` of an
  # expression with no limit, which nothing above it needs), or `:all` for a query that selects
  # `*` and has an output read. A query nothing reads at all reads only what its other clauses do.
  @spec reads(SQLParser.parsed_query(), [binary()], :final | {:cte, reads()}) :: reads()
  defp reads(query, unused, mode) do
    cond do
      SQLSchema.star?(query) and nothing_read?(mode) ->
        refs(%{query | projection_columns: [], order_by: live_sort(query, mode)})

      SQLSchema.star?(query) ->
        :all

      true ->
        refs(%{
          query
          | projection_columns: live_columns(query.projection_columns, unused),
            order_by: live_sort(query, mode)
        })
    end
  end

  @spec nothing_read?(:final | {:cte, reads()}) :: boolean()
  defp nothing_read?({:cte, :all}), do: false
  defp nothing_read?({:cte, read}), do: MapSet.size(read) == 0
  defp nothing_read?(:final), do: false

  @spec live_sort(SQLParser.parsed_query(), :final | {:cte, reads()}) :: list()
  defp live_sort(query, :final), do: query.order_by
  defp live_sort(query, {:cte, _read}), do: if(sort_dead?(query), do: [], else: query.order_by)

  @spec refs(SQLParser.parsed_query()) :: reads()
  defp refs(query) do
    query
    |> SQLSchema.clause_refs()
    |> Enum.map(fn {_clause, ref} -> ref_name(ref) end)
    |> MapSet.new()
  end

  @spec ref_name(term()) :: binary()
  defp ref_name({:qualified, _relation, name}), do: name
  defp ref_name(name) when is_binary(name), do: name
  defp ref_name(other), do: inspect(other)

  @spec live_columns([SQLParser.projection()] | nil, [binary()]) ::
          [SQLParser.projection()] | nil
  defp live_columns(nil, _unused), do: nil
  defp live_columns(columns, unused), do: Enum.reject(columns, &(elem(&1, 1) in unused))

  @spec merge(reads(), reads()) :: reads()
  defp merge(:all, _other), do: :all
  defp merge(_read, :all), do: :all
  defp merge(read, other), do: MapSet.union(read, other)

  # The computed outputs of a query that keeps its rows as they are, which no query after it
  # reads.
  @spec unused_outputs(SQLParser.parsed_query(), reads()) :: [binary()]
  defp unused_outputs(query, read) do
    if is_list(query.projection_columns) and read != :all and plain?(query) do
      for {expr, output} <- query.projection_columns,
          is_binary(output),
          output not in read,
          not is_nil(expr),
          do: output
    else
      []
    end
  end

  @spec plain?(SQLParser.parsed_query()) :: boolean()
  defp plain?(query) do
    not query.distinct_rows and is_nil(query.distinct_columns) and
      is_nil(query.select_columns) and is_nil(query.distinct_on)
  end

  # What of a query is never planned: its unused outputs and, with no limit, its `ORDER BY`.
  @spec unused_terms(SQLParser.parsed_query(), [binary()]) :: [term()]
  defp unused_terms(query, unused) do
    columns = for {expr, output} <- query.projection_columns || [], output in unused, do: expr
    [columns, if(sort_dead?(query), do: query.order_by, else: [])]
  end

  @spec sort_dead?(SQLParser.parsed_query()) :: boolean()
  defp sort_dead?(query), do: is_nil(query.limit) and is_nil(query.offset)

  @spec terms(SQLParser.parsed_query()) :: [term()]
  defp terms(query), do: [query.projection_columns, query.order_by]

  # The negations the simplified query no longer holds.
  @spec removed(SQLParser.parsed_query(), %{binary() => binary()}) :: [term()]
  defp removed(query, columns) do
    simplified = SQLSimplify.apply_strict(query, columns)

    negations([query.where, query.projection_columns], []) --
      negations([simplified.where, simplified.projection_columns], [])
  end

  @spec negations(term(), [term()]) :: [term()]
  defp negations({:neg, inner} = node, found), do: negations(inner, [node | found])
  defp negations(tuple, found) when is_tuple(tuple), do: negations(Tuple.to_list(tuple), found)
  defp negations(list, found) when is_list(list), do: Enum.reduce(list, found, &negations/2)
  defp negations(_leaf, found), do: found

  # The predicates of a `WHERE`, wherever they stand in it.
  @spec predicates(term(), [tuple()]) :: [tuple()]
  defp predicates({:or, branches}, found), do: predicates(branches, found)
  defp predicates({:not, nodes}, found) when is_list(nodes), do: predicates(nodes, found)
  defp predicates(nodes, found) when is_list(nodes), do: Enum.reduce(nodes, found, &predicates/2)

  defp predicates({op, _operand, _rest} = clause, found) when op in [:eq, :in],
    do: [clause | found]

  defp predicates(_other, found), do: found

  # The columns the equalities of a `WHERE` read.
  @spec equality_columns(term(), [binary()]) :: [binary()]
  defp equality_columns(where, found) do
    where
    |> predicates([])
    |> Enum.reduce(found, fn {_op, operand, _rest}, columns ->
      operand_columns(operand) ++ columns
    end)
    |> Enum.uniq()
  end

  @spec operand_columns(binary() | {:expr, SQLExpr.t()}) :: [binary()]
  defp operand_columns({:expr, expr}), do: Enum.filter(SQLExpr.columns(expr), &is_binary/1)
  defp operand_columns(column) when is_binary(column), do: [column]
  defp operand_columns(_other), do: []
end
