defmodule InfluxElixir.Client.Local.SQLSchema do
  @moduledoc """
  The schema errors of a SQL query for `InfluxElixir.Client.Local`: a column
  the query names that no row has — in `SELECT`, an aggregate, `WHERE`,
  `GROUP BY`, `ORDER BY` or `DISTINCT` — is the engine's schema error ("No
  field named prod. Valid fields are ..."), not an empty or unsorted result.
  The usual cause is a typo or a forgotten pair of quotes around a string
  literal. With no rows the schema is unknown, so nothing is checked.

  A relation is one table or CTE of a `FROM`, with the name its columns are
  qualified by in the engine's "Valid fields" list.
  """

  alias InfluxElixir.Client.Local.{
    LineProtocolParser,
    SQLClauses,
    SQLError,
    SQLExpr,
    SQLLiteral,
    SQLParser
  }

  @typedoc "A stored point, as `InfluxElixir.Client.Local` keeps it."
  @type point :: LineProtocolParser.point()

  @typedoc """
  One relation of a `FROM`: the name its columns are qualified with, its
  points, and its columns in order when it is a CTE (a table's are its
  points', sorted).
  """
  @type relation :: %{qualifier: binary(), points: [point()], columns: [binary()] | nil}

  @doc "A source (its points and, for a CTE, its columns) as the relation known by `qualifier`."
  @spec relation(binary(), %{points: [point()], columns: [binary()] | nil}) :: relation()
  def relation(qualifier, source),
    do: %{qualifier: qualifier, points: source.points, columns: source.columns}

  # The clauses a reference stands in, in the order the engine plans them:
  # WHERE, the select list, ORDER BY, GROUP BY, DISTINCT ON. The select list
  # and WHERE see the table's fields; the later clauses see the select
  # list's output as well.
  @typedoc "The clause a reference stands in."
  @type clause :: :where | :select | :order | :group | :on

  @doc "Every tag and field name any of the points has."
  @spec point_columns([point()]) :: MapSet.t(binary())
  def point_columns(points) do
    Enum.reduce(points, MapSet.new(), fn point, acc ->
      MapSet.union(acc, point_columns_of(point))
    end)
  end

  @spec point_columns_of(point()) :: MapSet.t(binary())
  defp point_columns_of(point) do
    MapSet.new(Map.keys(point.tags) ++ Map.keys(point.fields))
  end

  # A column the query names that no row has — in SELECT, an aggregate,
  # WHERE, GROUP BY, ORDER BY or DISTINCT — is the engine's schema error
  # ("No field named prod"), not an empty or unsorted result. The usual
  # cause is a typo or a forgotten pair of quotes around a string literal.
  # With no rows the schema is unknown, so nothing is checked.
  @doc "`:ok`, or the engine's schema error for the first column the query names that is not there."
  @spec check([relation()], SQLParser.parsed_query()) :: :ok | {:error, term()}
  def check(relations, query) do
    refs = clause_refs(query)

    if refs == [] or Enum.any?(relations, &unknown_schema?/1) do
      :ok
    else
      # Almost every query names only columns the first row has, so that row
      # answers first; the full scan (every row's columns) runs only when a
      # name is missing there, which is also when the error message needs it.
      quick =
        relations
        |> Enum.map(&quick_columns/1)
        |> Enum.reduce(MapSet.new(), &MapSet.union/2)

      if Enum.all?(refs, fn {_clause, ref} -> known?(ref, quick) end),
        do: :ok,
        else: check_against_all_rows(relations, query, refs)
    end
  end

  @doc "Whether a relation's columns cannot be known: a table with no rows."
  @spec unknown_schema?(relation()) :: boolean()
  def unknown_schema?(%{columns: nil, points: []}), do: true
  def unknown_schema?(_relation), do: false

  @spec quick_columns(relation()) :: MapSet.t(binary())
  defp quick_columns(%{columns: columns}) when is_list(columns), do: MapSet.new(columns)

  defp quick_columns(%{points: [first | _rest]}),
    do: first |> point_columns_of() |> MapSet.put("time")

  # A reference to a relation the query does not have is never a column.
  @spec known?(SQLExpr.column_ref(), MapSet.t(binary())) :: boolean()
  defp known?(ref, columns) when is_binary(ref), do: MapSet.member?(columns, ref)
  defp known?(_qualified, _columns), do: false

  @spec check_against_all_rows([relation()], SQLParser.parsed_query(), [{clause(), term()}]) ::
          :ok | {:error, term()}
  defp check_against_all_rows(relations, query, refs) do
    listed = Enum.map(relations, &{&1.qualifier, full_columns(&1)})
    known = listed |> Enum.flat_map(&elem(&1, 1)) |> MapSet.new()

    case Enum.find(refs, fn {_clause, ref} -> not known?(ref, known) end) do
      nil -> :ok
      {clause, ref} -> {:error, no_field(ref, clause, query, listed)}
    end
  end

  # A CTE's columns are as it declared them; a table's are every column any
  # of its rows has, sorted as the engine's schema is (byte order).
  @spec full_columns(relation()) :: [binary()]
  defp full_columns(%{columns: columns}) when is_list(columns), do: columns

  defp full_columns(%{points: points}),
    do: points |> point_columns() |> MapSet.put("time") |> Enum.sort()

  @spec no_field(SQLExpr.column_ref(), clause(), SQLParser.parsed_query(), [
          {binary(), [binary()]}
        ]) :: map()
  defp no_field(ref, clause, query, listed) do
    fields = Enum.flat_map(listed, fn {qualifier, columns} -> qualify(qualifier, columns) end)

    # Under DISTINCT ON an ORDER BY term is resolved against the table, so
    # an output name there lists the table's fields alone (verified).
    output_name? = query.distinct_on != nil and ref in output_names(query)

    valid =
      if clause in [:order, :group, :on] and not output_name?,
        do: projection_fields(query, listed) ++ fields,
        else: fields

    printed = printed(ref, query.qualified)

    body =
      Enum.join(
        ["Schema error: No field named #{printed}." | case_hint(ref, printed, listed)] ++
          ["Valid fields are #{Enum.join(valid, ", ")}."],
        " "
      )

    %{status: 500, body: body}
  end

  # The name as the query wrote it: a column written with its relation
  # (`t.nosuch`) is named with it.
  @spec printed(SQLExpr.column_ref(), %{binary() => binary()}) :: binary()
  defp printed(ref, qualified) when is_binary(ref) do
    case Map.fetch(qualified, ref) do
      {:ok, relation} ->
        SQLLiteral.render_identifier(relation) <> "." <> SQLLiteral.render_identifier(ref)

      :error ->
        SQLExpr.ref_text(ref)
    end
  end

  defp printed(ref, _qualified), do: SQLExpr.ref_text(ref)

  # A qualified name that would resolve if its case were folded gets the
  # engine's pointer to quoting (verified).
  @spec case_hint(SQLExpr.column_ref(), binary(), [{binary(), [binary()]}]) :: [binary()]
  defp case_hint({:qualified, qualifier, column}, printed, listed) do
    {relation, name} = {unquoted(qualifier), unquoted(column)}

    folded? =
      Enum.any?(listed, fn {qualifier, columns} ->
        String.downcase(qualifier) == String.downcase(relation) and
          Enum.any?(columns, &(String.downcase(&1) == String.downcase(name)))
      end)

    if folded?,
      do: [
        "Column names are case sensitive. You can use double quotes to refer to the " <>
          "\"#{printed}\" column or set the datafusion.sql_parser.enable_ident_normalization " <>
          "configuration."
      ],
      else: []
  end

  defp case_hint(_name, _printed, _listed), do: []

  @spec unquoted(binary()) :: binary()
  defp unquoted(text) do
    if SQLLiteral.identifier?(text), do: SQLLiteral.identifier_name(text), else: text
  end

  @spec qualify(binary(), [binary()]) :: [binary()]
  defp qualify(qualifier, columns),
    do: Enum.map(columns, &field_text(qualifier, &1))

  @spec field_text(binary(), binary()) :: binary()
  defp field_text(qualifier, column),
    do: SQLLiteral.render_identifier(qualifier) <> "." <> SQLLiteral.render_identifier(column)

  # The select list's output fields as the engine lists them: a column
  # qualified by its relation, anything else (an alias, an expression, an
  # aggregate) by its name alone; `*` is every field.
  @spec projection_fields(SQLParser.parsed_query(), [{binary(), [binary()]}]) :: [binary()]
  defp projection_fields(query, listed) do
    cond do
      query.distinct_columns ->
        Enum.map(query.distinct_columns, &holder_field(&1, listed))

      query.select_columns ->
        Enum.map(query.select_columns, &select_field(&1, listed))

      query.projection_columns ->
        Enum.map(query.projection_columns, &projected_field(&1, listed))

      true ->
        Enum.flat_map(listed, fn {qualifier, columns} -> qualify(qualifier, columns) end)
    end
  end

  @spec select_field(SQLParser.select_column(), [{binary(), [binary()]}]) :: binary()
  defp select_field({:grouping_column, source, source}, listed), do: holder_field(source, listed)

  defp select_field(column, _listed),
    do: SQLLiteral.render_identifier(elem(column, tuple_size(column) - 1))

  @spec projected_field(SQLParser.projection(), [{binary(), [binary()]}]) :: binary()
  defp projected_field({source, source}, listed) when is_binary(source),
    do: holder_field(source, listed)

  defp projected_field({_source, output}, _listed), do: SQLLiteral.render_identifier(output)

  @spec holder_field(binary(), [{binary(), [binary()]}]) :: binary()
  defp holder_field(column, listed) do
    {qualifier, _columns} =
      Enum.find(listed, hd(listed), fn {_qualifier, columns} -> column in columns end)

    field_text(qualifier, column)
  end

  @doc """
  Every source column the query refers to, with the clause it stands in, in
  the order the engine resolves the clauses. ORDER BY may name an output
  alias instead, which is not a source column.
  """
  @spec clause_refs(SQLParser.parsed_query()) :: [{clause(), SQLExpr.column_ref()}]
  def clause_refs(query) do
    aliases = if query.distinct_on, do: [], else: output_names(query)

    order_by_refs =
      Enum.flat_map(query.order_by, fn
        {{:expr, expr}, _direction} ->
          expr_fields(expr)

        {column, _direction} ->
          if column in aliases or ordinal?(query, column), do: [], else: [column]
      end)

    select_refs =
      Enum.flat_map(query.projection_columns || [], &projection_refs/1) ++
        Enum.flat_map(query.select_columns || [], &select_column_refs/1) ++
        (query.distinct_columns || [])

    tagged(:where, where_refs(query.where)) ++
      tagged(:select, select_refs) ++
      tagged(:order, order_by_refs) ++
      tagged(:group, query.group_by_columns || []) ++
      tagged(:on, query.distinct_on || [])
  end

  # In a `SELECT *` a number in `ORDER BY` is a position among the columns.
  @spec ordinal?(SQLParser.parsed_query(), binary()) :: boolean()
  defp ordinal?(query, term),
    do: star?(query) and SQLClauses.order_position(term, 0) != :not_positional

  @doc "Whether the query selects `*`."
  @spec star?(SQLParser.parsed_query()) :: boolean()
  def star?(query) do
    is_nil(query.distinct_columns) and is_nil(query.select_columns) and
      is_nil(query.projection_columns)
  end

  @doc """
  The query with the positions in a `SELECT *`'s `ORDER BY` replaced by the
  columns they name, or the engine's planning error for a position outside
  them (`ORDER BY 0` and a position past the last column; verified).
  """
  @spec resolve_ordinals(SQLParser.parsed_query(), [relation()]) ::
          {:ok, SQLParser.parsed_query()} | {:error, map()}
  def resolve_ordinals(query, relations) do
    columns = output_columns(query, relations)

    if is_nil(columns) or not star?(query) do
      {:ok, query}
    else
      query.order_by
      |> Enum.reduce_while({:ok, []}, fn {target, direction}, {:ok, acc} ->
        case resolve_ordinal(target, columns) do
          {:ok, column} -> {:cont, {:ok, [{column, direction} | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> then(fn
        {:ok, terms} -> {:ok, %{query | order_by: Enum.reverse(terms)}}
        {:error, _reason} = error -> error
      end)
    end
  end

  @spec resolve_ordinal(term(), [binary()]) :: {:ok, term()} | {:error, map()}
  defp resolve_ordinal(target, columns) when is_binary(target) do
    case SQLClauses.order_position(target, length(columns)) do
      {:ok, position} -> {:ok, Enum.at(columns, position - 1)}
      :not_positional -> {:ok, target}
      {:error, _reason} = error -> error
    end
  end

  # A number with a fraction or an exponent reads as an expression, and is
  # taken for a position all the same (a sign makes it an expression).
  defp resolve_ordinal({:expr, {:lit, value}} = target, _columns) do
    if value == :inf or positive_float?(value),
      do: {:error, SQLError.planning("invalid digit found in string")},
      else: {:ok, target}
  end

  defp resolve_ordinal(target, _columns), do: {:ok, target}

  @spec positive_float?(term()) :: boolean()
  defp positive_float?(value),
    do: is_float(value) and match?(<<0::1, _rest::63>>, <<value::float>>)

  @spec tagged(clause(), [SQLExpr.column_ref()]) :: [{clause(), SQLExpr.column_ref()}]
  defp tagged(clause, refs), do: Enum.map(refs, &{clause, &1})

  @spec output_names(SQLParser.parsed_query()) :: [binary()]
  defp output_names(query) do
    Enum.map(query.projection_columns || [], fn {_source, output} -> output end) ++
      Enum.map(query.select_columns || [], &elem(&1, tuple_size(&1) - 1)) ++
      (query.distinct_columns || [])
  end

  @spec projection_refs(SQLParser.projection()) :: [SQLExpr.column_ref()]
  defp projection_refs({source, _output}) when is_binary(source), do: [source]
  defp projection_refs({expr, _output}), do: expr_fields(expr)

  @spec select_column_refs(SQLParser.select_column()) :: [SQLExpr.column_ref()]
  defp select_column_refs({:time_bucket, _alias}), do: ["time"]
  defp select_column_refs({:aggregate, _agg, expr, _alias}), do: expr_fields(expr)
  defp select_column_refs({:count_star, _alias}), do: []
  defp select_column_refs({:count_distinct, column, _alias}), do: [column]

  defp select_column_refs({:ordered_aggregate, _agg, field, ordering, _alias}),
    do: [field, ordering]

  defp select_column_refs({:selector, _kind, field, ordering, _access, _alias}),
    do: [field, ordering]

  defp select_column_refs({:grouping_column, source, _alias}), do: [source]
  defp select_column_refs({:constant, _value, _alias}), do: []

  @doc "The columns a `WHERE` reads."
  @spec where_refs([SQLParser.where_node()]) :: [SQLExpr.column_ref()]
  def where_refs(nodes) do
    Enum.flat_map(nodes, fn
      {:or, branches} ->
        Enum.flat_map(branches, &where_refs/1)

      {:not, conjunction} ->
        where_refs(conjunction)

      {op, left, {low, high}} when op in [:between, :not_between] ->
        operand_fields(left) ++ expr_fields([low, high])

      {_op, left, right} when is_binary(left) ->
        [left | expr_fields(right)]

      {_op, left, right} ->
        expr_fields(left) ++ expr_fields(right)
    end)
  end

  @spec operand_fields(SQLParser.operand()) :: [SQLExpr.column_ref()]
  defp operand_fields(column) when is_binary(column), do: [column]
  defp operand_fields(operand), do: expr_fields(operand)

  @doc "The columns an expression, or a plan item over expressions, reads."
  @spec expr_fields(term()) :: [SQLExpr.column_ref()]
  def expr_fields({:expr, expr}), do: expr_fields(expr)
  def expr_fields({:field, name}), do: [name]
  def expr_fields({:uint_col, name}), do: [name]
  def expr_fields({:op, _op, left, right}), do: expr_fields(left) ++ expr_fields(right)
  def expr_fields({:cast, inner, _type}), do: expr_fields(inner)
  def expr_fields({:call, _function, args}), do: expr_fields(args)
  def expr_fields(items) when is_list(items), do: Enum.flat_map(items, &expr_fields/1)
  def expr_fields({:neg, inner}), do: expr_fields(inner)
  def expr_fields({:aggregate, _agg, expr}), do: expr_fields(expr)
  def expr_fields({:cut, call}), do: expr_fields(call)
  def expr_fields({:pattern, _kind, expr, _rest}), do: expr_fields(expr)
  def expr_fields({:compare, _op, left, _right}), do: expr_fields(left)
  def expr_fields({:in_list, left, _values}), do: expr_fields(left)
  def expr_fields({:range, left, _low, _high}), do: expr_fields(left)
  def expr_fields(_other), do: []

  @doc """
  The columns a query's rows are made of, whether or not any row has a value
  for them: a column that is null in every row is still in the schema the
  next query reads. `nil` when a relation's columns are not known.
  """
  @spec output_columns(SQLParser.parsed_query(), [relation()]) :: [binary()] | nil
  def output_columns(%{distinct_columns: columns}, _relations) when is_list(columns),
    do: columns

  def output_columns(%{select_columns: columns}, _relations) when is_list(columns),
    do: Enum.map(columns, &elem(&1, tuple_size(&1) - 1))

  def output_columns(%{projection_columns: columns}, _relations) when is_list(columns),
    do: Enum.map(columns, fn {_source, output} -> output end)

  # `*` is every column of the relations in turn, or unknown when one of
  # them is a table with no rows.
  def output_columns(_select_star, relations) do
    if Enum.any?(relations, &unknown_schema?/1),
      do: nil,
      else: Enum.flat_map(relations, &full_columns/1)
  end
end
