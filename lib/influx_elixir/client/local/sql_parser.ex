defmodule InfluxElixir.Client.Local.SQLParser do
  @moduledoc """
  SQL parser for `InfluxElixir.Client.Local`.

  Recognises the SQL subset documented on `InfluxElixir.Client.Local` and
  produces a `t:parsed_query/0` for the executor. It is deliberately strict:
  anything the real InfluxDB v3 engine would reject — or that the double
  cannot execute faithfully — is refused with a `Client.Local:`-prefixed 400
  so a query cannot pass tests here and fail in production.

  This module cuts a statement into its parts and hands each to the module
  that reads it:

    * `InfluxElixir.Client.Local.SQLLexer` — comments, statements and
      unterminated literals, before anything else
    * `InfluxElixir.Client.Local.SQLIdentifiers` — case folding
    * `InfluxElixir.Client.Local.SQLSelect` — an aggregate select list
    * `InfluxElixir.Client.Local.SQLExpr` — arithmetic expressions
    * `InfluxElixir.Client.Local.SQLWhere` — the `WHERE` clause
    * `InfluxElixir.Client.Local.SQLClauses` — `GROUP BY` and `ORDER BY`
    * `InfluxElixir.Client.Local.SQLLimit` — `LIMIT` and `OFFSET`
    * `InfluxElixir.Client.Local.SQLTime` — `time` comparands

  A `$name` placeholder is read as a value wherever a value may stand and is
  kept as a node; `InfluxElixir.Client.Local.SQLBind` replaces the nodes with
  the values the engine would read for them, so a parameter is data and never
  SQL text.

  Pure functions only: no ETS, no connection state.
  """

  alias InfluxElixir.Client.Local.{
    LineProtocolParser,
    SQLBind,
    SQLClauses,
    SQLError,
    SQLExpr,
    SQLIdentifiers,
    SQLLexer,
    SQLLimit,
    SQLLiteral,
    SQLMask,
    SQLSelect,
    SQLTime,
    SQLWhere
  }

  # The one place a SELECT is cut into its parts. A measurement name is
  # quoted, or bare with escaped spaces ("my\ measurement") — everything up
  # to the first unescaped space. `rest` is whatever follows the table.
  @select_pattern ~r/(?i)^\s*SELECT\s+(?<distinct>DISTINCT\s+)?(?<columns>.+?)\s+FROM\s+(?:"(?<quoted>[^"]+)"|(?<bare>(?:[^\s\\]|\\.)+))\s*(?<rest>.*)$/su

  @typedoc false
  @typep split :: %{distinct: boolean(), columns: binary(), table: binary(), rest: binary()}

  @typedoc "An arithmetic expression; see `t:InfluxElixir.Client.Local.SQLExpr.t/0`."
  @type expr :: SQLExpr.t()

  @typedoc "`CAST(expr AS INTEGER | DOUBLE | VARCHAR)` targets (and their synonyms)."
  @type cast_type :: SQLExpr.cast_type()

  @typedoc "Plain aggregates; `:stddev`/`:var` are the sample forms, as in InfluxDB."
  @type aggregate :: SQLSelect.aggregate()

  @typedoc "One column of an aggregate or grouped select list."
  @type select_column :: SQLSelect.column()

  @typedoc "The comparison, set and pattern operators of a predicate."
  @type where_op :: SQLWhere.op()

  @typedoc "A predicate: operator, left operand, right side."
  @type where_clause :: SQLWhere.clause()

  @typedoc """
  A WHERE conjunction is a list of nodes: a predicate, an `{:or, branches}`
  node whose branches are conjunctions, or a `{:not, conjunction}` node.
  """
  @type where_node :: SQLWhere.node_t()

  @typedoc """
  A `time` comparand: nanoseconds since the epoch, `now()` plus an offset in
  nanoseconds (resolved when the query runs), null, or a string the optimizer
  cannot read (raised once the type checks have passed).
  """
  @type time_value :: integer() | {:now, integer()} | nil | {:invalid_time, SQLError.t()}

  @typedoc "`:asc` / `:desc` (nulls last / first), or a direction with explicit NULLS placement."
  @type direction :: SQLClauses.direction()

  @typedoc "`ORDER BY` terms in order; a target is `time`, a column, an output alias or an expression."
  @type order_by :: SQLClauses.order_by()

  @typedoc """
  A projected column: `{source, output}` where `source` is a column name or
  an arithmetic `t:expr/0` (`(bid + ask) / 2 AS mid`).
  """
  @type projection :: {binary() | expr(), binary()}

  @typedoc """
  One `SELECT`. `ctes` holds the `WITH name AS (...)` queries that precede
  it, in order; `measurement` may name one of them.
  """
  @type parsed_query :: %{
          measurement: binary(),
          where: [where_node()],
          order_by: order_by(),
          limit: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          group_by_interval: non_neg_integer() | nil,
          group_by_columns: [binary()] | nil,
          select_columns: [select_column()] | nil,
          distinct_columns: [binary()] | nil,
          distinct_on: [binary()] | nil,
          projection_columns: [projection()] | nil,
          ctes: [{binary(), parsed_query()}],
          cross_join: {binary(), [binary()]} | nil
        }

  @typedoc """
  A `WHERE` operand: a column name, or an arithmetic expression over columns
  and literals (`price <= med * 3`).
  """
  @type operand :: SQLWhere.operand()

  @doc """
  Parses a statement — an optional `WITH` list of non-recursive CTEs followed
  by one `SELECT` — into a `t:parsed_query/0`.

  Identifiers follow DataFusion's rules (see
  `InfluxElixir.Client.Local.SQLIdentifiers`) unless `identifiers: :exact`
  is given — for SQL the double writes itself, from InfluxQL, whose
  identifiers are case-sensitive.
  """
  @spec parse_select(binary(), keyword()) :: {:ok, parsed_query()} | {:error, term()}
  def parse_select(sql, opts \\ []) do
    with {:ok, text} <- SQLLexer.scrub(sql),
         {:ok, cte_sources, main_sql} <- split_ctes(String.trim(fold_identifiers(text, opts))),
         {:ok, ctes} <- parse_ctes(cte_sources),
         {:ok, main} <- parse_single_select(main_sql) do
      {:ok, %{main | ctes: ctes}}
    end
  end

  @spec fold_identifiers(binary(), keyword()) :: binary()
  defp fold_identifiers(sql, opts) do
    if Keyword.get(opts, :identifiers, :fold) == :exact,
      do: sql,
      else: SQLIdentifiers.normalize(sql)
  end

  # ---------------------------------------------------------------------------
  # WITH name AS (<select>)[, name AS (<select>)] <select>
  #
  # Each body is a query in the same subset, run in order over the store or
  # an earlier CTE; the main query may read from any of them. Joins, and a
  # body that is not a SELECT, are outside the subset.
  # ---------------------------------------------------------------------------

  @spec split_ctes(binary()) :: {:ok, [{binary(), binary()}], binary()} | {:error, term()}
  defp split_ctes(sql) do
    case Regex.run(~r/^WITH\s+(.*)$/isu, sql) do
      [_full, rest] -> take_ctes(rest, [], sql)
      nil -> {:ok, [], sql}
    end
  end

  @spec take_ctes(binary(), [{binary(), binary()}], binary()) ::
          {:ok, [{binary(), binary()}], binary()} | {:error, term()}
  defp take_ctes(str, acc, sql) do
    with [_full, name, after_open] <- Regex.run(~r/^\s*(\w+)\s+AS\s*\((.*)$/isu, str),
         {:ok, body, after_close} <- SQLMask.balanced(after_open) do
      cte = {name, String.trim(body)}

      case Regex.run(~r/^\s*,(.*)$/su, after_close) do
        [_full, more] -> take_ctes(more, [cte | acc], sql)
        nil -> {:ok, Enum.reverse([cte | acc]), String.trim(after_close)}
      end
    else
      _no_match -> {:error, SQLError.refusal("unsupported WITH clause: #{sql}")}
    end
  end

  @spec parse_ctes([{binary(), binary()}]) ::
          {:ok, [{binary(), parsed_query()}]} | {:error, term()}
  defp parse_ctes(sources) do
    sources
    |> Enum.reduce_while({:ok, []}, fn {name, body}, {:ok, acc} ->
      case parse_single_select(body) do
        {:ok, query} -> {:cont, {:ok, [{name, query} | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ctes} -> {:ok, Enum.reverse(ctes)}
      {:error, _reason} = error -> error
    end
  end

  @spec parse_single_select(binary()) :: {:ok, parsed_query()} | {:error, term()}
  defp parse_single_select(sql) do
    {sql, cross_join} = sql |> String.trim() |> split_cross_join()
    normalised = strip_table_qualifiers(sql, cross_join)

    {normalised, on} = split_distinct_on(normalised)

    with :ok <- check_clauses(normalised),
         :ok <- check_distinct_on_grouping(on, normalised),
         {:ok, split} <- split_select(normalised),
         {:ok, split, normalised} <- resolve_references(split, normalised),
         {:ok, query} <- dispatch_select(split, normalised),
         {:ok, query} <- apply_distinct_on(query, on) do
      {:ok, %{query | cross_join: cross_join}}
    end
  end

  # `SELECT DISTINCT ON (a[, b]) ...` is an ordinary select whose rows are
  # then cut to the first per distinct (a, b) after ORDER BY, before LIMIT
  # and OFFSET (verified against InfluxDB 3). The ON list is taken out of
  # the text so the rest parses as that ordinary select.
  @distinct_on ~r/^(\s*SELECT\s+)DISTINCT\s+ON\s*\((.*)$/isu

  @spec split_distinct_on(binary()) :: {binary(), binary() | nil}
  defp split_distinct_on(sql) do
    with [_full, select, after_open] <- Regex.run(@distinct_on, sql),
         {:ok, on, rest} <- SQLMask.balanced(after_open) do
      {select <> String.trim_leading(rest), on}
    else
      _no_distinct_on -> {sql, nil}
    end
  end

  # DISTINCT ON with an aggregate in the select list, or a GROUP BY, is the
  # engine's 405, answered before the select list is read (verified). A
  # DATE_BIN in ORDER BY is neither.
  @spec check_distinct_on_grouping(binary() | nil, binary()) :: :ok | {:error, map()}
  defp check_distinct_on_grouping(nil, _sql), do: :ok

  defp check_distinct_on_grouping(_on, sql) do
    masked = SQLMask.mask(sql)

    select_list =
      case split_select(masked) do
        {:ok, %{columns: columns}} -> columns
        {:error, _reason} -> ""
      end

    if SQLSelect.aggregate_call?(select_list) or Regex.match?(~r/\bGROUP\s+BY\b/iu, masked) do
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

  # The engine's other rules for DISTINCT ON, each verified: at least one
  # expression, and an ORDER BY, if any, must start with the ON expressions
  # in their order (400). The double takes plain columns only and refuses
  # an expression by name.
  @spec apply_distinct_on(parsed_query(), binary() | nil) ::
          {:ok, parsed_query()} | {:error, map()}
  defp apply_distinct_on(query, nil), do: {:ok, query}

  defp apply_distinct_on(query, on) do
    columns = on |> SQLMask.split_commas() |> Enum.map(&String.trim/1)

    cond do
      columns == [""] ->
        {:error, %{status: 400, body: "Error during planning: No `ON` expressions provided"}}

      not Enum.all?(columns, &Regex.match?(~r/^(?:\w+|"[^"]+")$/u, &1)) ->
        {:error, SQLError.refusal("DISTINCT ON takes column names only: (#{on})")}

      true ->
        columns = Enum.map(columns, &String.trim(&1, "\""))
        check_distinct_on_order(%{query | distinct_on: columns}, columns)
    end
  end

  @spec check_distinct_on_order(parsed_query(), [binary()]) ::
          {:ok, parsed_query()} | {:error, map()}
  defp check_distinct_on_order(%{order_by: []} = query, _columns), do: {:ok, query}

  # Under DISTINCT ON the engine resolves ORDER BY against the table: a
  # select alias there is its schema error, which it reports before this
  # rule, so an aliased term is left to the executor's column check.
  defp check_distinct_on_order(%{order_by: order_by} = query, columns) do
    leading = order_by |> Enum.take(length(columns)) |> Enum.map(&elem(&1, 0))

    aliases =
      for {source, output} <- query.projection_columns || [], source != output, do: output

    if leading == columns or Enum.any?(leading, &(&1 in aliases)),
      do: {:ok, query},
      else:
        {:error,
         %{
           status: 400,
           body:
             "Error during planning: SELECT DISTINCT ON expressions must match initial " <>
               "ORDER BY expressions"
         }}
  end

  # `GROUP BY 1`, `ORDER BY 2 DESC` and `GROUP BY bucket` (a select alias)
  # name select items; the clauses are rewritten to them before anything
  # else reads the text.
  @spec resolve_references(split(), binary()) :: {:ok, split(), binary()} | {:error, map()}
  defp resolve_references(%{columns: "*"} = split, sql), do: {:ok, split, sql}

  defp resolve_references(%{rest: rest} = split, sql) do
    with {:ok, rewritten} <- SQLClauses.resolve_references(split.columns, rest) do
      {:ok, %{split | rest: rewritten}, String.replace_suffix(sql, rest, rewritten)}
    end
  end

  @spec split_select(binary()) :: {:ok, split()} | {:error, term()}
  defp split_select(sql) do
    case Regex.named_captures(@select_pattern, SQLMask.mask(sql), return: :index) do
      nil ->
        unsupported(sql)

      indexes ->
        part = fn name -> SQLMask.cut(sql, Map.fetch!(indexes, name)) end
        table = part.("quoted")

        table =
          if table != "", do: table, else: LineProtocolParser.unescape_measurement(part.("bare"))

        {:ok, select_parts(part.("distinct") != "", String.trim(part.("columns")), table, part)}
    end
  end

  # `SELECT DISTINCT FROM t` has no column: the pattern reads DISTINCT as the
  # (only) column, and the engine reads it as a DISTINCT over nothing.
  @spec select_parts(boolean(), binary(), binary(), (binary() -> binary())) :: split()
  defp select_parts(distinct, columns, table, part) do
    if not distinct and String.upcase(columns) == "DISTINCT",
      do: %{distinct: true, columns: "", table: table, rest: part.("rest")},
      else: %{distinct: distinct, columns: columns, table: table, rest: part.("rest")}
  end

  @spec dispatch_select(split(), binary()) :: {:ok, parsed_query()} | {:error, term()}
  defp dispatch_select(%{distinct: true} = split, sql), do: parse_distinct_select(split, sql)

  defp dispatch_select(split, sql) do
    cond do
      SQLSelect.aggregate_query?(sql) -> parse_aggregate_select(split, sql)
      split.columns == "*" -> build_star_query(split.table, split.rest)
      true -> build_columns_query(split.columns, split.table, split.rest)
    end
  end

  # `FROM w CROSS JOIN ref [AS r]`: the right side is taken out of the text
  # (the rest of the parser sees one table) and recorded with its alias so
  # its qualifiers can be dropped like the left side's.
  # Keywords that can follow a table name are clauses (or constructs), never an alias.
  @not_an_alias ~w(WHERE GROUP ORDER LIMIT JOIN CROSS INNER LEFT RIGHT FULL OUTER NATURAL UNION EXCEPT INTERSECT HAVING OFFSET ON USING)

  @cross_join_pattern ~r/(?i)(\bFROM\s+(?:"[^"]+"|(?:[^\s\\]|\\.)+)(?:\s+(?:AS\s+)?(?!CROSS\b)\w+)?)\s+CROSS\s+JOIN\s+("[^"]+"|(?:[^\s\\]|\\.)+)(?:\s+(?:AS\s+)?(?!(?:#{Enum.join(@not_an_alias, "|")})\b)(\w+))?/u

  @spec split_cross_join(binary()) :: {binary(), {binary(), [binary()]} | nil}
  defp split_cross_join(sql) do
    case Regex.run(@cross_join_pattern, SQLMask.mask(sql), return: :index) do
      [{start, length}, left, table | alias_name] ->
        name = sql |> SQLMask.cut(table) |> String.trim("\"")
        names = [name | Enum.map(alias_name, &SQLMask.cut(sql, &1))]
        tail = binary_part(sql, start + length, byte_size(sql) - start - length)
        {binary_part(sql, 0, start) <> SQLMask.cut(sql, left) <> tail, {name, names}}

      nil ->
        {sql, nil}
    end
  end

  # One table, then only WHERE / GROUP BY / ORDER BY / LIMIT. A join, set
  # operation or window would otherwise be ignored and the query answered
  # from the first table alone, which is a wrong result, not a refusal.
  # Keywords are matched by the shape only a clause can have, so a column
  # called `offset` or `over` (both fine on the engine) is not mistaken for
  # one; string literals are blanked first so `note = 'select from join'`
  # is not either.
  @unsupported_construct ~r/(?i)\b(JOIN|UNION|EXCEPT|INTERSECT|HAVING)\b|\b(OVER)\s*\(/u
  @clause_keywords ~w(WHERE GROUP ORDER LIMIT OFFSET)

  @spec check_clauses(binary()) :: :ok | {:error, term()}
  defp check_clauses(sql) do
    scannable = SQLMask.mask(sql)

    with :ok <- check_constructs(scannable, sql),
         :ok <- check_single_select(scannable, sql),
         {:ok, %{rest: rest}} <- split_select(scannable),
         :ok <- SQLLimit.check(rest, sql) do
      [next] = Regex.run(~r/^\w*/u, rest)
      if next == "" or String.upcase(next) in @clause_keywords, do: :ok, else: unsupported(sql)
    end
  end

  @spec check_constructs(binary(), binary()) :: :ok | {:error, term()}
  defp check_constructs(scannable, sql) do
    case Regex.run(@unsupported_construct, scannable) do
      nil ->
        :ok

      [_full | groups] ->
        construct = groups |> Enum.reject(&(&1 == "")) |> List.first() |> String.upcase()
        {:error, SQLError.refusal("unsupported SQL construct #{construct}: #{sql}")}
    end
  end

  # After the CTEs are split off, one query holds exactly one SELECT; a
  # second one is a subquery (`WHERE x IN (SELECT ...)`), which would
  # otherwise be read as a string literal.
  @spec check_single_select(binary(), binary()) :: :ok | {:error, term()}
  defp check_single_select(scannable, sql) do
    if length(Regex.scan(~r/(?i)\bSELECT\b/u, scannable)) > 1,
      do: {:error, SQLError.refusal("unsupported SQL construct SUBQUERY: #{sql}")},
      else: :ok
  end

  @spec unsupported(binary()) :: {:error, term()}
  defp unsupported(sql), do: {:error, SQLError.refusal("unsupported SQL: #{sql}")}

  # `SELECT w.bid FROM q AS w WHERE w.provider = 'a'` — one table per query,
  # so a qualifier (the table name or its alias) adds nothing: drop the
  # alias from FROM and the `qualifier.` prefixes outside string literals.
  # A keyword after the table is a clause (or an unsupported construct that
  # `check_clauses/1` will name), never an alias.
  @from_alias_pattern ~r/(?i)(FROM\s+("[^"]+"|(?:[^\s\\]|\\.)+))(?:\s+(?:AS\s+)?(?!(?:#{Enum.join(@not_an_alias, "|")})\b)(\w+))?/u

  @spec strip_table_qualifiers(binary(), {binary(), [binary()]} | nil) :: binary()
  defp strip_table_qualifiers(sql, cross_join) do
    joined_names =
      case cross_join do
        {_table, names} -> names
        nil -> []
      end

    case Regex.run(@from_alias_pattern, SQLMask.mask(sql), return: :index) do
      [{start, length}, from_clause, table, alias_name] ->
        # The alias (with its `AS`) is whatever follows the table in the match.
        {from_start, from_length} = from_clause
        after_match = start + length

        without_alias =
          binary_part(sql, 0, from_start + from_length) <>
            binary_part(sql, after_match, byte_size(sql) - after_match)

        drop_qualifiers(without_alias, [
          sql |> SQLMask.cut(table) |> String.trim("\""),
          SQLMask.cut(sql, alias_name) | joined_names
        ])

      [_full, _from_clause, table] ->
        drop_qualifiers(sql, [sql |> SQLMask.cut(table) |> String.trim("\"") | joined_names])

      nil ->
        sql
    end
  end

  @spec drop_qualifiers(binary(), [binary()]) :: binary()
  defp drop_qualifiers(sql, qualifiers) do
    names = qualifiers |> Enum.map(&Regex.escape/1) |> Enum.join("|")
    pattern = ~r/'(?:[^']|'')*'|"[^"]*"|(?<![\w."])(?:#{names})\.(?=\w)/u

    Regex.replace(pattern, sql, fn
      "'" <> _rest = literal -> literal
      "\"" <> _rest = identifier -> identifier
      _qualifier -> ""
    end)
  end

  @spec parse_aggregate_select(split(), binary()) ::
          {:ok, parsed_query()} | {:error, term()}
  defp parse_aggregate_select(%{table: measurement, rest: rest} = split, sql) do
    with {:ok, columns} <- SQLSelect.parse_list(split.columns),
         {:ok, interval_ns} <- SQLClauses.interval(sql),
         :ok <- SQLClauses.check_date_bins(split.columns, interval_ns),
         {:ok, where} <- SQLWhere.nodes(rest),
         :ok <- reject_expr_order(SQLClauses.order_by(rest)) do
      {:ok,
       new_query(measurement, where, rest,
         group_by_interval: interval_ns,
         group_by_columns: SQLClauses.group_columns(sql),
         select_columns: columns
       )}
    end
  end

  # Every query shape shares this skeleton; `ORDER BY` and `LIMIT` come from
  # the text after the table unless the caller overrides them.
  @spec new_query(binary(), [where_node()], binary(), keyword()) :: parsed_query()
  defp new_query(measurement, where, rest, overrides) do
    Map.merge(
      %{
        measurement: measurement,
        where: where,
        order_by: SQLClauses.order_by(rest),
        limit: SQLLimit.limit(rest),
        offset: SQLLimit.offset(rest),
        group_by_interval: nil,
        group_by_columns: nil,
        select_columns: nil,
        distinct_columns: nil,
        distinct_on: nil,
        projection_columns: nil,
        ctes: [],
        cross_join: nil
      },
      Map.new(overrides)
    )
  end

  # SELECT DISTINCT col[, col ...] FROM measurement ...
  # SELECT DISTINCT a[, b ...]: plain column names only.
  @spec parse_distinct_select(split(), binary()) ::
          {:ok, parsed_query()} | {:error, term()}
  defp parse_distinct_select(%{columns: columns, table: table, rest: rest}, sql) do
    cond do
      # A DISTINCT over no columns: one empty row if any row qualifies.
      columns == "" ->
        build_distinct_query([], table, rest)

      Regex.match?(~r/^\w+(\s*,\s*\w+)*$/u, columns) ->
        build_distinct_query(split_columns(columns), table, rest)

      true ->
        {:error, SQLError.refusal("unsupported DISTINCT query: #{sql}")}
    end
  end

  @spec split_columns(binary()) :: [binary()]
  defp split_columns(columns), do: columns |> String.split(",") |> Enum.map(&String.trim/1)

  # DataFusion: "For SELECT DISTINCT, ORDER BY expressions <table>.<column>
  # must appear in select list" (verified). Several missing columns are
  # listed run together, with no separator (`pp.pricepp.name`), and an
  # expression is listed as the columns it reads.
  @spec parse_distinct_order_by([binary()], binary(), binary()) ::
          {:ok, order_by()} | {:error, term()}
  defp parse_distinct_order_by(columns, table, rest) do
    order_by = SQLClauses.order_by(rest)

    case Enum.flat_map(order_by, &unselected_columns(&1, columns)) do
      [] ->
        {:ok, order_by}

      missing ->
        {:error,
         %{
           status: 400,
           body:
             "Error during planning: For SELECT DISTINCT, ORDER BY expressions " <>
               Enum.map_join(missing, &"#{table}.#{&1}") <> " must appear in select list"
         }}
    end
  end

  @spec unselected_columns({binary() | {:expr, expr()}, direction()}, [binary()]) :: [binary()]
  defp unselected_columns({target, _direction}, columns) when is_binary(target),
    do: if(target in columns, do: [], else: [target])

  defp unselected_columns({{:expr, expr}, _direction}, columns),
    do: expr |> SQLExpr.columns() |> Enum.reject(&(&1 in columns))

  # Grouped rows have no source point to evaluate an expression against.
  @spec reject_expr_order(order_by()) :: :ok | {:error, term()}
  defp reject_expr_order(order_by) do
    if Enum.any?(order_by, &match?({{:expr, _expr}, _direction}, &1)),
      do:
        {:error,
         SQLError.refusal("ORDER BY an expression is not supported in an aggregate query")},
      else: :ok
  end

  @spec build_distinct_query([binary()], binary(), binary()) ::
          {:ok, parsed_query()} | {:error, map()}
  defp build_distinct_query(columns, measurement, rest) do
    with {:ok, where} <- SQLWhere.nodes(rest),
         {:ok, order_by} <- parse_distinct_order_by(columns, measurement, rest) do
      {:ok, new_query(measurement, where, rest, order_by: order_by, distinct_columns: columns)}
    end
  end

  @spec build_star_query(binary(), binary()) ::
          {:ok, parsed_query()} | {:error, map()}
  defp build_star_query(measurement, rest) do
    with {:ok, where} <- SQLWhere.nodes(rest) do
      {:ok, new_query(measurement, where, rest, [])}
    end
  end

  @spec build_columns_query(binary(), binary(), binary()) ::
          {:ok, parsed_query()} | {:error, term()}
  defp build_columns_query(columns_str, measurement, rest) do
    with {:ok, projection} <- parse_projection_columns(columns_str),
         {:ok, where} <- SQLWhere.nodes(rest) do
      {:ok, new_query(measurement, where, rest, projection_columns: projection)}
    end
  end

  @spec parse_projection_columns(binary()) ::
          {:ok, [projection()]} | {:error, term()}
  defp parse_projection_columns(columns_str) do
    columns =
      columns_str
      |> SQLMask.split_commas()
      |> Enum.map(&String.trim/1)
      |> Enum.map(&parse_projection_column/1)

    if Enum.any?(columns, &match?({:error, _}, &1)) do
      Enum.find(columns, &match?({:error, _}, &1))
    else
      {:ok, Enum.map(columns, fn {:ok, col} -> col end)}
    end
  end

  # A constant in a select list as an expression: a literal, or a `$name`.
  @spec literal_expr(binary()) :: expr()
  defp literal_expr(text) do
    case SQLLiteral.value(text) do
      {:param, _name} = param -> param
      value -> {:lit, value}
    end
  end

  # Parse `name`, `name AS alias` or `<arithmetic> AS alias`, returning
  # `{source, output}`. An expression needs an alias: DataFusion names an
  # unaliased one after its own rendering (`q.bid * Int64(2)`), which the
  # double will not guess.
  @spec parse_projection_column(binary()) :: {:ok, projection()} | {:error, term()}
  defp parse_projection_column(col) do
    trimmed = String.trim(col)

    cond do
      match = SQLSelect.constant_column(trimmed) ->
        [_full, literal, alias_name] = match
        {:ok, {literal_expr(literal), alias_name}}

      Regex.match?(~r/^(?:-?[0-9]+(?:\.[0-9]+)?|'[^']*'|\$\w+)$/u, trimmed) ->
        {:error, SQLError.refusal("unsupported column (a constant needs AS alias): #{col}")}

      # A quoted alias keeps a name that needs its quotes (`AS "The Host"`).
      match = Regex.run(~r/^(\w+)(?:\s+AS\s+(\w+|"[^"]+"))?$/iu, trimmed) ->
        case match do
          [_full, name] -> {:ok, {name, name}}
          [_full, name, alias_name] -> {:ok, {name, String.trim(alias_name, "\"")}}
        end

      match = Regex.run(~r/^(.+?)\s+AS\s+(\w+|"[^"]+")$/isu, trimmed) ->
        [_full, expr_str, alias_name] = match

        case SQLExpr.parse(expr_str) do
          {:ok, expr} -> {:ok, {expr, String.trim(alias_name, "\"")}}
          {:error, _reason} -> {:error, SQLError.refusal("unsupported column: #{col}")}
        end

      true ->
        {:error, SQLError.refusal("unsupported column (an expression needs AS alias): #{col}")}
    end
  end

  @doc """
  Parses the `WHERE ...` clause (if any) out of the text after `FROM <table>`,
  for a statement that binds no parameters (`DELETE`, InfluxQL). A `$name`
  in it is the engine's unbound-placeholder error, and so is a `time` string
  the optimizer cannot read.
  """
  @spec parse_where(binary()) :: {:ok, [where_node()]} | {:error, map()}
  def parse_where(rest) do
    if String.trim(rest) == "" do
      {:ok, []}
    else
      with {:ok, text} <- SQLLexer.scrub(rest),
           {:ok, nodes} <- SQLWhere.nodes(text),
           :ok <- SQLBind.reject_placeholders(nodes),
           :ok <- SQLTime.first_invalid(nodes) do
        {:ok, nodes}
      end
    end
  end

  @doc """
  Binds a parsed query's `$name` placeholders to `params`; see
  `InfluxElixir.Client.Local.SQLBind.bind/2`.
  """
  @spec bind(parsed_query(), %{binary() => term()}) :: {:ok, parsed_query()} | {:error, map()}
  defdelegate bind(query, params), to: SQLBind
end
