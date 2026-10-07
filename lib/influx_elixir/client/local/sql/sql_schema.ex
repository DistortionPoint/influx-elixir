defmodule InfluxElixir.Client.Local.SQLSchema do
  @moduledoc false
  # The schema errors of a SQL query for `InfluxElixir.Client.Local`: a column
  # the query names that no row has — in `SELECT`, an aggregate, `WHERE`,
  # `GROUP BY`, `ORDER BY` or `DISTINCT` — is the engine's schema error ("No
  # field named prod. Valid fields are ..."), not an empty or unsorted result.
  # The usual cause is a typo or a forgotten pair of quotes around a string
  # literal. With no rows the schema is unknown, so nothing is checked.
  #
  # A relation is one table or CTE of a `FROM`, with the name its columns are
  # qualified by in the engine's "Valid fields" list.

  alias InfluxElixir.Client.Local.{
    LineProtocolParser,
    SQLAggExpr,
    SQLAggType,
    SQLClauses,
    SQLError,
    SQLExpr,
    SQLInformation,
    SQLLiteral,
    SQLParser,
    SQLWhere
  }

  @typedoc "A stored point, as `InfluxElixir.Client.Local` keeps it."
  @type point :: LineProtocolParser.point()

  # How near a name must be to another, in edits per character of the longer one, for the
  # engine to suggest it: a field within half, a select item within three fifths (verified).
  @field_ratio {1, 2}
  @item_ratio {3, 5}

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
  @type clause :: :where | :select | :having | :order | :group | :on

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
  @doc """
  `:ok`, or the engine's schema error for the first column the query names that is not there.
  `never?` says that the `WHERE` is false for every row (see
  `InfluxElixir.Client.Local.SQLSimplify.never?/1`).
  """
  @spec check([relation()], SQLParser.parsed_query(), boolean()) :: :ok | {:error, term()}
  def check(relations, query, never? \\ false) do
    with :ok <- no_table_star(relations, query),
         :ok <- check_columns(relations, query, never?),
         do: check_order_ambiguous(relations, query)
  end

  # `SELECT *` with no `FROM` has no table to expand.
  @spec no_table_star([relation()], SQLParser.parsed_query()) :: :ok | {:error, term()}
  defp no_table_star(relations, query) do
    if star?(query) and Enum.any?(relations, &(&1.qualifier == SQLInformation.dual())),
      do: {:error, SQLError.planning("SELECT * with no tables specified is not valid")},
      else: :ok
  end

  @spec check_columns([relation()], SQLParser.parsed_query(), boolean()) ::
          :ok | {:error, term()}
  defp check_columns(relations, query, never?) do
    refs = query |> clause_refs() |> reached(query, never?)

    # A selector's constant second argument is the planner's error once the `WHERE` and the
    # select list are resolved, and before the other clauses are (verified).
    case Map.get(query, :selector_error) do
      nil ->
        check_refs(relations, query, refs)

      error ->
        early = Enum.filter(refs, fn {clause, _ref} -> clause in [:where, :select] end)
        with :ok <- check_refs(relations, query, early), do: {:error, error}
    end
  end

  # A `WHERE` that is false for every row leaves the engine's plan empty before the `ORDER BY`
  # term that is a column written with its relation is resolved (verified: `WHERE false ORDER
  # BY m.host` is `[]` whatever `m` is, where `ORDER BY zzz` and `ORDER BY m.host + 1` are
  # errors).
  # An aggregate query without a `GROUP BY` resolves it all the same.
  @spec reached([{clause(), term()}], SQLParser.parsed_query(), boolean()) ::
          [{clause(), term()}]
  defp reached(refs, query, never?) do
    if never? and
         (query.select_columns == nil or query.group_by_columns != nil) do
      written = written_in(query, :order)

      skipped =
        for term <- query.order_by, ref = bare_qualified(term, written), do: {:order, ref}

      Enum.reduce(skipped, refs, &List.delete(&2, &1))
    else
      refs
    end
  end

  # An `ORDER BY` term that is one column written with its relation (`m.host`, or `t.host` of
  # the table `t` itself, which the parser has read as `host`).
  @spec bare_qualified({term(), term()}, MapSet.t(binary())) :: SQLExpr.column_ref() | nil
  defp bare_qualified({{:expr, {:field, {:qualified, _rel, _col} = ref}}, _direction}, _written),
    do: ref

  defp bare_qualified({ref, _direction}, written) when is_binary(ref),
    do: if(MapSet.member?(written, ref), do: ref)

  defp bare_qualified(_term, _written), do: nil

  @spec check_refs([relation()], SQLParser.parsed_query(), [{clause(), term()}]) ::
          :ok | {:error, term()}
  defp check_refs(relations, query, refs) do
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

  # Whether a relation's columns cannot be known: a table with no rows.
  @spec unknown_schema?(relation()) :: boolean()
  defp unknown_schema?(%{columns: nil, points: []}), do: true
  defp unknown_schema?(_relation), do: false

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
    listed = listed_columns(relations)
    known = listed |> Enum.flat_map(&elem(&1, 1)) |> MapSet.new()

    case Enum.find(refs, fn {_clause, ref} -> not known?(ref, known) end) do
      nil ->
        :ok

      {clause, ref} ->
        {:error, query |> then(&no_field(ref, clause, &1, listed)) |> coerced(ref, clause, query)}
    end
  end

  # A column written with its relation inside an `ORDER BY` expression is found missing by the
  # type coercion, which says so (verified: `ORDER BY m.host + 1`, `ORDER BY abs(m.n)`).
  @spec coerced(map(), SQLExpr.column_ref(), clause(), SQLParser.parsed_query()) :: map()
  defp coerced(
         %{body: "Schema error: " <> _rest} = error,
         {:qualified, _rel, _col} = ref,
         :order,
         query
       ) do
    if Enum.any?(query.order_by, &match?({{:expr, {:field, ^ref}}, _direction}, &1)),
      do: error,
      else: %{error | body: "type_coercion\ncaused by\n" <> error.body}
  end

  defp coerced(error, _ref, _clause, _query), do: error

  @doc "Every column the relations have, a table's from its rows and a CTE's as it declared them."
  @spec table_columns([relation()]) :: MapSet.t(binary())
  def table_columns(relations), do: relations |> Enum.flat_map(&full_columns/1) |> MapSet.new()

  # The relations with their columns, as the engine's error text lists them.
  @spec listed_columns([relation()]) :: [{binary(), [binary()]}]
  defp listed_columns(relations), do: Enum.map(relations, &{&1.qualifier, full_columns(&1)})

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
    if clause != :group and column_as_relation?(ref, query, listed),
      do:
        SQLError.refusal(
          "a column used as the relation of another (the engine reads it as a field of that " <>
            "column and fails by the column's type and the clause)"
        ),
      else: unknown_field(ref, clause, query, listed)
  end

  # `n.y` where `n` is no relation of the query but a column of one: the engine does not look
  # for a field `y` of a relation `n`, it reads `n` as a column to take a field of.
  @spec column_as_relation?(SQLExpr.column_ref(), SQLParser.parsed_query(), [
          {binary(), [binary()]}
        ]) :: boolean()
  defp column_as_relation?({:qualified, relation, _name}, _query, listed) do
    name = SQLLiteral.unquoted(relation)

    not Enum.any?(listed, fn {qualifier, _columns} -> qualifier == name end) and
      Enum.any?(listed, fn {_qualifier, columns} -> name in columns end)
  end

  defp column_as_relation?(_ref, _query, _listed), do: false

  @spec unknown_field(SQLExpr.column_ref(), clause(), SQLParser.parsed_query(), [
          {binary(), [binary()]}
        ]) :: map()
  defp unknown_field(ref, clause, query, listed) do
    fields = Enum.flat_map(listed, fn {qualifier, columns} -> qualify(qualifier, columns) end)

    # Under DISTINCT ON an ORDER BY term is resolved against the table, so
    # an output name there lists the table's fields alone (verified).
    output_name? = query.distinct_on != nil and ref in output_names(query)

    # A name written with its relation is looked up in the select list alone (verified).
    written_with_relation? =
      clause in [:order, :group] and written_with_relation?(ref, query, clause)

    # A name written with its relation in an aggregate of a `HAVING` is looked up in the
    # table alone (verified), where one written bare also sees the select list.
    valid =
      if clause == :having and written_with_relation?(ref, query, :having),
        do: fields,
        else: valid_fields(clause, written_with_relation?, output_name?, fields, query, listed)

    printed = printed(ref, query.qualified)

    case suggestion(clause, ref, query, listed) do
      {:refuse, why} ->
        SQLError.refusal(why)

      {:suggest, field} ->
        %{status: 500, body: "Schema error: No field named #{printed}. Did you mean '#{field}'?."}

      nil ->
        known = known_fields(ref, valid)

        # A clause that reads the select list's names also folds the case of those.
        outputs =
          if clause in [:order, :group, :on, :having] and not written_with_relation? and
               not output_name?,
             do: output_names(query),
             else: []

        body =
          Enum.join(
            [
              "Schema error: No field named #{printed}."
              | case_hint(ref, printed, listed, query.qualified, outputs)
            ] ++
              known,
            " "
          )

        %{status: 500, body: body}
    end
  end

  # What the engine says of the fields it knows: the first listed field that is within half
  # its length in edits of the name written, without its relation, as "Did you mean"
  # (verified: `x.host` over `cpu` suggests `cpu.host`, `x.cpu` suggests `cpu.h`, while
  # `x.n` over `cpu.n` and `x.hos` over `cpu.host` do not come within half), else all of them.
  @spec known_fields(SQLExpr.column_ref(), [binary()]) :: [binary()]
  defp known_fields(_ref, []), do: []

  defp known_fields(ref, valid) do
    name = bare_name(ref)

    case Enum.find(valid, &close?(name, &1, @field_ratio)) do
      nil -> ["Valid fields are #{Enum.join(valid, ", ")}."]
      field -> ["Did you mean '#{field}'?."]
    end
  end

  # The fields the engine lists: the table's, the select list's before them in a clause that
  # reads it, or the select list's alone for a name written with its relation.
  @spec valid_fields(clause(), boolean(), boolean(), [binary()], SQLParser.parsed_query(), [
          {binary(), [binary()]}
        ]) :: [binary()]
  defp valid_fields(:group, true, _output_name?, fields, _query, _listed), do: fields

  defp valid_fields(_clause, true, _output_name?, _fields, query, listed),
    do: projection_fields(query, listed)

  defp valid_fields(clause, false, false, fields, query, listed)
       when clause in [:order, :group, :on, :having],
       do: projection_fields(query, listed) ++ fields

  defp valid_fields(_clause, false, _output_name?, fields, _query, _listed), do: fields

  @spec written_with_relation?(SQLExpr.column_ref(), SQLParser.parsed_query(), clause()) ::
          boolean()
  defp written_with_relation?({:qualified, _relation, _name}, _query, _clause), do: true

  defp written_with_relation?(ref, query, clause),
    do: MapSet.member?(written_in(query, clause), ref)

  # The select item an unknown `ORDER BY` name is taken for (verified): one with the same
  # name is the engine's suggestion. A name that is merely close to an item is one the engine
  # suggests by a measure the double does not hold, so it is refused.
  @spec suggestion(clause(), SQLExpr.column_ref(), SQLParser.parsed_query(), [
          {binary(), [binary()]}
        ]) :: {:suggest, binary()} | {:refuse, binary()} | nil
  defp suggestion(:group, ref, query, listed) do
    if written_with_relation?(ref, query, :group) and
         Enum.any?(listed, fn {_relation, columns} -> bare_name(ref) in columns end),
       do:
         {:refuse,
          "a GROUP BY name with a relation that is not the column's: the engine may suggest " <>
            "the column"},
       else: nil
  end

  # Under DISTINCT ON the terms are resolved against the table alone.
  defp suggestion(:order, _ref, %{distinct_on: on}, _listed) when on != nil, do: nil

  defp suggestion(:order, ref, query, listed) do
    name = bare_name(ref)

    # Of a plain query the engine suggests a name that stands alone in its select list, not
    # a column it prints with its relation (verified); of an aggregate query, any item.
    outputs =
      for {output, field} <- Enum.zip(output_names(query), projection_fields(query, listed)),
          query.select_columns != nil or not relation_field?(field),
          do: {output, field}

    case Enum.filter(outputs, fn {output, _field} -> output == name end) do
      [{_output, field}] ->
        {:suggest, field}

      [] ->
        if Enum.any?(outputs, fn {output, _field} -> close?(output, name, @item_ratio) end),
          do:
            {:refuse,
             "an ORDER BY name close to a select item: the engine suggests the item by a " <>
               "measure of closeness the double does not hold"},
          else: nil

      _several ->
        {:refuse, "an ORDER BY name that several select items are called"}
    end
  end

  defp suggestion(_clause, _ref, _query, _listed), do: nil

  # Whether two names are within a share of the longer one's length of each other in edits.
  @spec close?(binary(), binary(), {pos_integer(), pos_integer()}) :: boolean()
  defp close?(left, right, {numerator, denominator}) do
    longest = max(String.length(left), String.length(right))
    longest > 0 and edit_distance(left, right) * denominator <= longest * numerator
  end

  @spec edit_distance(binary(), binary()) :: non_neg_integer()
  defp edit_distance(left, right) do
    initial = Enum.to_list(0..String.length(right))

    left
    |> String.graphemes()
    |> Enum.with_index(1)
    |> Enum.reduce(initial, fn {a, row}, previous ->
      right
      |> String.graphemes()
      |> Enum.zip(Enum.zip(previous, tl(previous)))
      |> Enum.reduce([row], fn {b, {diagonal, above}}, [left_cell | _older] = acc ->
        cost = if a == b, do: 0, else: 1
        [min(min(above + 1, left_cell + 1), diagonal + cost) | acc]
      end)
      |> Enum.reverse()
    end)
    |> List.last()
  end

  @spec relation_field?(binary()) :: boolean()
  defp relation_field?(field),
    do: not String.starts_with?(field, "\"") and String.contains?(field, ".")

  @spec bare_name(SQLExpr.column_ref()) :: binary()
  defp bare_name({:qualified, _relation, name}), do: SQLLiteral.unquoted(name)
  defp bare_name(name), do: name

  # `ORDER BY t.x` beside a select item called `x` that is no column of `t` is ambiguous to
  # the engine: the select list holds the unqualified field `x`.
  @spec check_order_ambiguous([relation()], SQLParser.parsed_query()) :: :ok | {:error, map()}
  defp check_order_ambiguous(relations, query) do
    written = written_in(query, :order)

    if MapSet.size(written) == 0 or Enum.any?(relations, &unknown_schema?/1) or
         query.distinct_on != nil do
      :ok
    else
      listed = listed_columns(relations)
      outputs = Enum.zip(output_names(query), projection_fields(query, listed))

      ambiguous =
        Enum.find(MapSet.to_list(written), fn name ->
          Enum.any?(outputs, fn {output, field} ->
            output == name and not relation_field?(field)
          end)
        end)

      if ambiguous do
        printed = written_name(ambiguous, query.qualified)

        {:error,
         %{
           status: 500,
           body:
             "Schema error: Schema contains qualified field name #{printed} and unqualified " <>
               "field name #{ambiguous} which would be ambiguous"
         }}
      else
        :ok
      end
    end
  end

  # In an aggregate query a table column in `ORDER BY` is one of the `GROUP BY` terms or an
  # output of the select list; any other is the engine's schema error, which lists the
  # outputs alone and names the column with its relation.
  @doc """
  `:ok`, or the engine's schema error for an `ORDER BY` column of an aggregate query that is
  neither grouped nor an output. The engine finds a select list that is not grouped first.
  """
  @spec check_order_available([relation()], SQLParser.parsed_query()) :: :ok | {:error, map()}
  def check_order_available(_relations, %{select_columns: nil}), do: :ok
  def check_order_available(_relations, %{distinct_on: on}) when on != nil, do: :ok

  def check_order_available(_relations, %{order_by: []}), do: :ok

  def check_order_available(relations, query) do
    if Enum.any?(relations, &unknown_schema?/1) do
      :ok
    else
      grouped = for item <- query.group_by_columns || [], is_binary(item), do: item
      outputs = output_names(query)

      unavailable =
        query.order_by
        |> Enum.flat_map(&order_refs(&1, query))
        |> Enum.find(fn ref ->
          is_binary(ref) and
            not (alias_ref?(ref, outputs, query, :order) or ref in grouped or
                   SQLAggExpr.placeholder?(ref))
        end)

      case unavailable do
        nil -> :ok
        ref -> {:error, unavailable_order(ref, query, listed_columns(relations))}
      end
    end
  end

  @spec order_refs({term(), term()}, SQLParser.parsed_query()) :: [SQLExpr.column_ref()]
  defp order_refs({{:expr, expr}, _direction}, _query), do: expr_fields(expr)

  defp order_refs({column, _direction}, query),
    do: if(ordinal?(query, column), do: [], else: [column])

  defp unavailable_order(ref, query, listed) do
    known = ref |> known_fields(projection_fields(query, listed)) |> Enum.map(&(" " <> &1))

    hint =
      ref
      |> case_hint(holder_field(ref, listed), [], query.qualified, output_names(query))
      |> Enum.map(&(" " <> &1))

    %{
      status: 500,
      body:
        "Schema error: No field named #{holder_field(ref, listed)}.#{Enum.join(hint)}" <>
          Enum.join(known)
    }
  end

  # The name as the query wrote it: a column written with its relation
  # (`t.nosuch`) is named with it.
  @spec printed(SQLExpr.column_ref(), %{binary() => binary()}) :: binary()
  defp printed(ref, qualified), do: written_name(ref, qualified)

  @doc "The name of a column as the query wrote it: with its relation when it had one."
  @spec written_name(SQLExpr.column_ref(), %{binary() => binary()}) :: binary()
  def written_name(ref, qualified) when is_binary(ref) do
    case Map.fetch(qualified, ref) do
      {:ok, relation} ->
        SQLLiteral.render_qualifier(relation) <> "." <> SQLLiteral.render_identifier(ref)

      :error ->
        SQLExpr.ref_text(ref)
    end
  end

  def written_name(ref, _qualified), do: SQLExpr.ref_text(ref)

  # A qualified name that would resolve if its case were folded gets the
  # engine's pointer to quoting (verified).
  @spec case_hint(
          SQLExpr.column_ref(),
          binary(),
          [{binary(), [binary()]}],
          %{binary() => binary()},
          [binary()]
        ) :: [binary()]
  defp case_hint(ref, printed, listed, qualified, outputs) when is_binary(ref) do
    flat = String.downcase(join_flat(Map.get(qualified, ref), ref))

    folded? =
      Enum.any?(listed, fn {qualifier, columns} ->
        Enum.any?(columns, &(String.downcase(join_flat(qualifier, &1)) == flat))
      end) or Enum.any?(outputs, &(String.downcase(&1) == flat))

    if folded?, do: [case_sensitive_hint(printed)], else: []
  end

  defp case_hint({:qualified, qualifier, column}, printed, listed, _qualified, _outputs) do
    {relation, name} = {SQLLiteral.unquoted(qualifier), SQLLiteral.unquoted(column)}

    folded? =
      Enum.any?(listed, fn {qualifier, columns} ->
        String.downcase(qualifier) == String.downcase(relation) and
          Enum.any?(columns, &(String.downcase(&1) == String.downcase(name)))
      end)

    if folded?, do: [case_sensitive_hint(printed)], else: []
  end

  defp join_flat(nil, name), do: name
  defp join_flat(qualifier, name), do: qualifier <> "." <> name

  defp case_sensitive_hint(printed) do
    "Column names are case sensitive. You can use double quotes to refer to the " <>
      "\"#{printed}\" column or set the datafusion.sql_parser.enable_ident_normalization " <>
      "configuration."
  end

  @spec qualify(binary(), [binary()]) :: [binary()]
  defp qualify(qualifier, columns),
    do: Enum.map(columns, &field_text(qualifier, &1))

  @spec field_text(binary(), binary()) :: binary()
  defp field_text(qualifier, column),
    do: SQLLiteral.render_qualifier(qualifier) <> "." <> SQLLiteral.render_identifier(column)

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
    alias? = &alias_ref?(&1, aliases, query, :order)

    order_by_refs =
      Enum.flat_map(query.order_by, fn
        {{:expr, expr}, _direction} ->
          Enum.reject(expr_fields(expr), alias?)

        {column, _direction} ->
          if alias?.(column) or ordinal?(query, column), do: [], else: [column]
      end)

    select_refs =
      Enum.flat_map(query.projection_columns || [], &projection_refs/1) ++
        Enum.flat_map(query.select_columns || [], &select_column_refs/1) ++
        (query.distinct_columns || [])

    tagged(:where, where_refs(query.where)) ++
      tagged(:select, select_refs) ++
      tagged(:having, having_refs(query.having, aliases, written_in(query, :having))) ++
      tagged(:order, order_by_refs) ++
      tagged(:group, group_refs(query.group_by_columns)) ++
      tagged(:on, query.distinct_on || [])
  end

  # Whether a reference is the name of a select item: only a name written without a relation
  # is (`ORDER BY t.alias` is a column of `t`).
  @spec alias_ref?(SQLExpr.column_ref(), [binary()], SQLParser.parsed_query(), atom()) ::
          boolean()
  defp alias_ref?(ref, aliases, query, clause),
    do: is_binary(ref) and ref in aliases and not MapSet.member?(written_in(query, clause), ref)

  # The columns the query wrote with a relation in a clause (see `SQLQualifier.strip/2`).
  @spec written_in(SQLParser.parsed_query(), :group | :having | :order) :: MapSet.t(binary())
  defp written_in(query, clause), do: Map.get(query.qualified_in, clause, MapSet.new())

  # The columns a `HAVING` reads that are neither an aggregate's name nor a
  # name of the select list, and those its aggregates read. A name written with a relation
  # is read by `InfluxElixir.Client.Local.SQLGrouping`, which the engine's `HAVING` check
  # precedes the schema with.
  @spec having_refs(SQLAggExpr.having_t() | nil, [binary()], MapSet.t(binary())) ::
          [SQLExpr.column_ref()]
  defp having_refs(nil, _aliases, _qualified), do: []

  defp having_refs(%{nodes: nodes, aggs: aggs}, aliases, qualified) do
    plain =
      for ref <- where_refs(nodes),
          not (is_binary(ref) and
                 (SQLAggExpr.placeholder?(ref) or ref in aliases or
                    MapSet.member?(qualified, ref))),
          not match?({:qualified, _relation, _name}, ref),
          do: ref

    plain ++ Enum.flat_map(aggs, fn {_name, column} -> select_column_refs(column) end)
  end

  @spec group_refs([binary() | {:expr, SQLExpr.t()}] | nil) :: [SQLExpr.column_ref()]
  defp group_refs(nil), do: []

  defp group_refs(items) do
    Enum.flat_map(items, fn
      {:expr, expr} -> expr_fields(expr)
      column -> [column]
    end)
  end

  # A number in `ORDER BY` is a position among the columns: in a `SELECT *` it is resolved with
  # the columns, and in another select the parser has replaced the positions that name an item,
  # so one that is left names none (the error of the plan, not of a column).
  @spec ordinal?(SQLParser.parsed_query(), binary()) :: boolean()
  defp ordinal?(_query, term), do: SQLClauses.order_position(term, 0) != :not_positional

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
    if star?(query) and Enum.any?(query.order_by, &positional?/1),
      do: resolve_positions(query, output_columns(query, relations)),
      else: {:ok, query}
  end

  @spec positional?({term(), term()}) :: boolean()
  defp positional?({target, _direction}) when is_binary(target),
    do: SQLClauses.order_position(target, 0) != :not_positional

  defp positional?({{:expr, {:lit, _value}}, _direction}), do: true
  defp positional?(_term), do: false

  @spec resolve_positions(SQLParser.parsed_query(), [binary()] | nil) ::
          {:ok, SQLParser.parsed_query()} | {:error, map()}
  defp resolve_positions(query, nil), do: {:ok, query}

  defp resolve_positions(query, columns) do
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

  defp select_column_refs({:expression, expr, aggs, _alias}) do
    SQLAggExpr.plain_columns(expr) ++
      Enum.flat_map(aggs, fn {_name, column} -> select_column_refs(column) end)
  end

  defp select_column_refs({:constant, _value, _alias}), do: []

  @doc "The columns a `WHERE` reads."
  @spec where_refs([SQLParser.where_node()]) :: [SQLExpr.column_ref()]
  def where_refs(nodes) do
    Enum.flat_map(nodes, fn
      {:or, branches} ->
        Enum.flat_map(branches, &where_refs/1)

      {:not, conjunction} ->
        where_refs(conjunction)

      {:eq, :null, nil} ->
        []

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

  # The values of an IN list or a BETWEEN that are expressions (the others are literals).
  @spec operand_exprs([term()]) :: [term()]
  defp operand_exprs(values), do: for({:expr, _expr} = value <- values, do: value)

  @doc "The columns an expression, or a plan item over expressions, reads."
  @spec expr_fields(term()) :: [SQLExpr.column_ref()]
  def expr_fields({:expr, expr}), do: expr_fields(expr)
  def expr_fields({:field, name}), do: [name]
  def expr_fields({:uint_col, name}), do: [name]
  def expr_fields(items) when is_list(items), do: Enum.flat_map(items, &expr_fields/1)
  def expr_fields({:aggregate, _agg, expr}), do: expr_fields(expr)

  def expr_fields({:aggs, aggs, item}),
    do: Enum.flat_map(SQLAggType.arguments(aggs), &expr_fields/1) ++ expr_fields(item)

  def expr_fields({:agg_ref, _name}), do: []
  def expr_fields({:selector_check, _selector, field, ordering, _grouped}), do: [field, ordering]
  def expr_fields({:constant, _call, _ancestors}), do: []
  def expr_fields({:cut, call}), do: expr_fields(call)
  def expr_fields({:lazy_cut, call}), do: expr_fields(call)
  def expr_fields({:null_cut, call}), do: expr_fields(call)
  def expr_fields({:case_cut, call}), do: expr_fields(call)
  def expr_fields({:expr_check, node}), do: expr_fields(node)
  def expr_fields({:logical, tree}), do: SQLWhere.truthy_columns(tree)
  def expr_fields({:logical_ops, tree}), do: SQLWhere.truthy_columns(tree)
  def expr_fields({:pattern, _kind, expr, _rest}), do: expr_fields(expr)
  def expr_fields({:compare, _op, left, right}), do: expr_fields([left | operand_exprs([right])])
  def expr_fields({:in_list, left, values}), do: expr_fields([left | operand_exprs(values)])

  def expr_fields({:range, left, low, high}),
    do: expr_fields([left | operand_exprs([low, high])])

  def expr_fields(expr), do: Enum.flat_map(SQLExpr.children(expr), &expr_fields/1)

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
