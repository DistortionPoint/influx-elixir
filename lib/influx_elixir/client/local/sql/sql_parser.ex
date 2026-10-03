defmodule InfluxElixir.Client.Local.SQLParser do
  @moduledoc false
  # SQL parser for `InfluxElixir.Client.Local`.
  #
  # Recognises the SQL subset documented on `InfluxElixir.Client.Local` and
  # produces a `t:parsed_query/0` for the executor. It is deliberately strict:
  # anything the real InfluxDB v3 engine would reject — or that the double
  # cannot execute faithfully — is refused with a `Client.Local:`-prefixed 400
  # so a query cannot pass tests here and fail in production.
  #
  # This module cuts a statement into its parts and hands each to the module
  # that reads it:
  #
  #   * `InfluxElixir.Client.Local.SQLLexer` — comments, statements and
  #     unterminated literals, before anything else
  #   * `InfluxElixir.Client.Local.SQLIdentifiers` — case folding
  #   * `InfluxElixir.Client.Local.SQLSelect` — an aggregate select list
  #   * `InfluxElixir.Client.Local.SQLExpr` — arithmetic expressions
  #   * `InfluxElixir.Client.Local.SQLWhere` — the `WHERE` clause
  #   * `InfluxElixir.Client.Local.SQLClauses` — `GROUP BY` and `ORDER BY`
  #   * `InfluxElixir.Client.Local.SQLLimit` — `LIMIT` and `OFFSET`
  #   * `InfluxElixir.Client.Local.SQLTime` — `time` comparands
  #
  # A `$name` placeholder is read as a value wherever a value may stand and is
  # kept as a node; `InfluxElixir.Client.Local.SQLBind` replaces the nodes with
  # the values the engine would read for them, so a parameter is data and never
  # SQL text.
  #
  # Pure functions only: no ETS, no connection state.

  alias InfluxElixir.Client.Local.{
    LineProtocolParser,
    SQLAggExpr,
    SQLBind,
    SQLClauses,
    SQLDistinctOn,
    SQLError,
    SQLExpr,
    SQLIdentifiers,
    SQLLexer,
    SQLLimit,
    SQLMask,
    SQLNoFrom,
    SQLPredicate,
    SQLQualifier,
    SQLSelect,
    SQLSyntax,
    SQLTable,
    SQLTime,
    SQLWhere
  }

  # The one place a SELECT is cut into its parts. A measurement name is
  # quoted, or bare with escaped spaces ("my\ measurement") — everything up
  # to the first unescaped space. `rest` is whatever follows the table.
  @select_pattern ~r/(?i)^\s*SELECT\s+(?<distinct>DISTINCT\s+)?(?<columns>.+?)\s+FROM\s+(?:"(?<quoted>[^"]+)"|(?<bare>(?:[^\s\\]|\\.)+))\s*(?<rest>.*)$/su

  @typedoc false
  @typep split :: %{
           distinct: boolean(),
           columns: binary(),
           table: binary(),
           table_error: SQLError.t() | nil,
           rest: binary()
         }

  @typedoc "An arithmetic expression; see `t:InfluxElixir.Client.Local.SQLExpr.t/0`."
  @type expr :: SQLExpr.t()

  @typedoc "`CAST(expr AS type)` targets: an integer width, `DOUBLE` or text."
  @type cast_type :: SQLExpr.cast_type()

  @typedoc "Plain aggregates; `:stddev`/`:var` are the sample forms, as in InfluxDB."
  @type aggregate :: SQLSelect.aggregate()

  @typedoc "One column of an aggregate or grouped select list."
  @type select_column :: SQLSelect.column() | SQLAggExpr.column()

  @typedoc "The comparison, set and pattern operators of a predicate."
  @type where_op :: SQLPredicate.op()

  @typedoc "A predicate: operator, left operand, right side."
  @type where_clause :: SQLPredicate.clause()

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
          where_tree: SQLWhere.tree() | nil,
          order_by: order_by(),
          limit: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          group_by_interval: non_neg_integer() | nil,
          group_by_columns: [binary() | {:expr, SQLExpr.t()}] | nil,
          select_columns: [select_column()] | nil,
          distinct_columns: [binary()] | nil,
          distinct_on: [binary()] | nil,
          projection_columns: [projection()] | nil,
          ctes: [{binary(), parsed_query()}],
          cross_join: {binary(), [binary()]} | nil,
          qualifier: binary(),
          qualified: %{binary() => binary()},
          plan_error: SQLError.t() | nil,
          limit_error: SQLError.t() | nil,
          table_error: SQLError.t() | nil,
          having: SQLAggExpr.having_t() | nil
        }

  @typedoc """
  A `WHERE` operand: a column name, or an arithmetic expression over columns
  and literals (`price <= med * 3`).
  """
  @type operand :: SQLPredicate.operand()

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
    with {:ok, scrubbed} <- SQLLexer.scrub(sql),
         :ok <- syntax(sql, opts),
         {:ok, text} <- unwrap(scrubbed),
         {:ok, cte_sources, main_sql} <- split_ctes(String.trim(fold_identifiers(text, opts))),
         {:ok, ctes} <- parse_ctes(cte_sources),
         {:ok, main} <- parse_single_select(main_sql) do
      {:ok, %{main | ctes: ctes}}
    else
      {:error, %{body: body} = error} -> {:error, %{error | body: SQLNoFrom.restore(body)}}
      other -> other
    end
  end

  # The text the double writes itself (from InfluxQL) is well formed; any
  # other is read as the engine's parser reads it.
  @spec syntax(binary(), keyword()) :: :ok | {:error, SQLError.t()}
  defp syntax(sql, opts) do
    if Keyword.get(opts, :identifiers, :fold) == :exact, do: :ok, else: SQLSyntax.check(sql)
  end

  # A query in parentheses is the query (`(SELECT ...)`, `((SELECT ...))`). An
  # `ORDER BY`, `LIMIT` or `OFFSET` after the parentheses orders or cuts what
  # the query in them returned, which the double does not read; anything else
  # after them is not a query it knows.
  @spec unwrap(binary()) :: {:ok, binary()} | {:error, term()}
  defp unwrap(text) do
    with "(" <> inner <- String.trim(text),
         {:ok, body, rest} <- SQLMask.balanced(inner) do
      unwrap_rest(body, String.trim(rest), text)
    else
      _not_wrapped -> {:ok, text}
    end
  end

  @spec unwrap_rest(binary(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  defp unwrap_rest(body, "", _text), do: unwrap(body)

  defp unwrap_rest(_body, rest, text) do
    if Regex.match?(~r/\A(?:ORDER|LIMIT|OFFSET|FETCH)\b/iu, rest),
      do:
        {:error,
         SQLError.refusal(
           "a parenthesized query followed by ORDER BY, LIMIT or OFFSET: #{String.trim(text)}"
         )},
      else: {:ok, text}
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
    {sql, cross_join} =
      sql |> String.trim() |> SQLNoFrom.add_table() |> SQLQualifier.split_cross_join()

    {normalised, qualifier, qualified} = SQLQualifier.strip(sql, cross_join)

    {normalised, on} = SQLDistinctOn.split(normalised)

    # A column of a joined table is qualified by the side that holds it,
    # which a text cannot tell: no name is written for it.
    naming = if cross_join, do: nil, else: qualifier

    with :ok <- check_clauses(normalised),
         :ok <- SQLDistinctOn.check_grouping(on, normalised, &select_list/1),
         {:ok, split} <- split_select(normalised),
         {:ok, split, normalised} <- resolve_references(split, normalised, naming),
         {:ok, query} <- dispatch_select(split, normalised, naming),
         {:ok, query} <- SQLDistinctOn.apply(query, on) do
      {:ok,
       %{
         query
         | cross_join: cross_join,
           qualifier: qualifier,
           qualified: qualified,
           table_error: split.table_error
       }}
    end
  end

  # `GROUP BY 1`, `ORDER BY 2 DESC` and `GROUP BY bucket` (a select alias)
  # name select items; the clauses are rewritten to them before anything
  # else reads the text.
  @spec resolve_references(split(), binary(), binary() | nil) ::
          {:ok, split(), binary()} | {:error, map()}
  defp resolve_references(%{columns: "*"} = split, sql, _qualifier), do: {:ok, split, sql}

  defp resolve_references(%{rest: rest} = split, sql, qualifier) do
    with :ok <- reject_mixed_star(split.columns),
         {:ok, rewritten} <-
           SQLClauses.resolve_references(split.columns, rest, &item_name(&1, qualifier)) do
      {:ok, %{split | rest: rewritten}, String.replace_suffix(sql, rest, rewritten)}
    end
  end

  # A `*` beside other items stands for every column in its place, so the
  # positions of the items after it are not the ones written; the double
  # does not read it, whatever the clauses name.
  @spec reject_mixed_star(binary()) :: :ok | {:error, map()}
  defp reject_mixed_star(columns) do
    items = columns |> SQLMask.split_commas() |> Enum.map(&String.trim/1)

    if match?([_, _ | _], items) and
         Enum.any?(items, &(&1 == "*" or String.ends_with?(&1, ".*"))),
       do: {:error, SQLError.refusal("unsupported column: *")},
       else: :ok
  end

  # The name the engine gives a select item with no alias, for `ORDER BY 2`
  # to name it; `nil` when the double cannot write it.
  @spec item_name(binary(), binary() | nil) :: binary() | nil
  defp item_name(item, qualifier) do
    parsed =
      if SQLSelect.aggregate_query?(item),
        do: SQLAggExpr.parse_list(item, qualifier),
        else: parse_projection_column(item, qualifier)

    case parsed do
      {:ok, [column]} -> elem(column, tuple_size(column) - 1)
      {:ok, {_source, output}} -> output
      {:error, _reason} -> nil
    end
  end

  # The select list of a masked statement, or nothing when it has none.
  @spec select_list(binary()) :: binary()
  defp select_list(masked) do
    case split_select(masked) do
      {:ok, %{columns: columns}} -> columns
      {:error, _reason} -> ""
    end
  end

  @spec split_select(binary()) :: {:ok, split()} | {:error, term()}
  defp split_select(sql) do
    masked = sql |> SQLMask.mask() |> SQLMask.hide_inner_from()

    case Regex.named_captures(@select_pattern, masked, return: :index) do
      nil ->
        unsupported(sql)

      indexes ->
        part = fn name -> SQLMask.cut(sql, Map.fetch!(indexes, name)) end

        {table, table_error} = table_reference(part.("quoted"), part.("bare"))

        {:ok,
         select_parts(
           part.("distinct") != "",
           String.trim(part.("columns")),
           {table, table_error},
           part
         )}
    end
  end

  # `SELECT DISTINCT FROM t` has no column: the pattern reads DISTINCT as the
  # (only) column, and the engine reads it as a DISTINCT over nothing.
  @spec select_parts(
          boolean(),
          binary(),
          {binary(), SQLError.t() | nil},
          (binary() -> binary())
        ) :: split()
  defp select_parts(distinct, columns, {table, table_error}, part) do
    # The engine reads a comma that ends the select list as nothing.
    columns = Regex.replace(~r/,\s*\z/u, columns, "")

    {distinct, columns} =
      if not distinct and String.upcase(columns) == "DISTINCT",
        do: {true, ""},
        else: {distinct, columns}

    %{
      distinct: distinct,
      columns: columns,
      table: table,
      table_error: table_error,
      rest: part.("rest")
    }
  end

  # The table a `FROM` names: a quoted one is a measurement of that name, a
  # bare one with dots is a qualified reference (see `SQLTable`), any other
  # a measurement.
  @spec table_reference(binary(), binary()) :: {binary(), SQLError.t() | nil}
  defp table_reference("", bare) do
    if Regex.match?(~r/\A[\p{L}\p{N}_$]+(?:\.[\p{L}\p{N}_$]+)+\z/u, bare) do
      case SQLTable.resolve(bare) do
        {:ok, %{measurement: measurement}} -> {measurement, nil}
        {:error, error} -> {bare, error}
      end
    else
      {LineProtocolParser.unescape_measurement(bare), nil}
    end
  end

  defp table_reference(quoted, _bare), do: {String.replace(quoted, ~s(""), ~s(")), nil}

  @spec dispatch_select(split(), binary(), binary() | nil) ::
          {:ok, parsed_query()} | {:error, term()}
  defp dispatch_select(%{distinct: true} = split, sql, qualifier),
    do: parse_distinct_select(split, sql, qualifier)

  defp dispatch_select(split, sql, qualifier) do
    cond do
      split.columns == "*" and SQLClauses.empty_tuple_error(split.rest) ->
        build_star_query(split.table, split.rest)

      SQLSelect.aggregate_query?(sql) ->
        parse_aggregate_select(split, sql, qualifier)

      split.columns == "*" ->
        build_star_query(split.table, split.rest)

      true ->
        build_columns_query(split.columns, split.table, split.rest, qualifier)
    end
  end

  # One table, then only WHERE / GROUP BY / ORDER BY / LIMIT. A join, set
  # operation or window would otherwise be ignored and the query answered
  # from the first table alone, which is a wrong result, not a refusal.
  # Keywords are matched by the shape only a clause can have, so a column
  # called `offset` or `over` (both fine on the engine) is not mistaken for
  # one; string literals are blanked first so `note = 'select from join'`
  # is not either.
  @unsupported_construct ~r/(?i)\b(JOIN|UNION|EXCEPT|INTERSECT)\b|\b(OVER)\s*\(|\b(ROLLUP|CUBE)\s*\(|\b(GROUPING)\s+SETS\b|\bFROM\s*\(\s*(VALUES)\b/u
  @clause_keywords ~w(WHERE GROUP HAVING ORDER LIMIT OFFSET)

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

  @spec parse_aggregate_select(split(), binary(), binary() | nil) ::
          {:ok, parsed_query()} | {:error, term()}
  defp parse_aggregate_select(%{table: measurement, rest: rest} = split, sql, qualifier) do
    with {:ok, columns} <- SQLAggExpr.parse_list(split.columns, qualifier),
         :ok <- check_unique(Enum.map(columns, &elem(&1, tuple_size(&1) - 1))),
         :ok <- SQLClauses.check_group_items(rest),
         {:ok, interval_ns} <- SQLClauses.interval(sql),
         :ok <- SQLClauses.check_date_bins(split.columns, interval_ns),
         {:ok, groups} <- SQLClauses.group_columns(sql),
         {:ok, where} <- SQLWhere.nodes(rest),
         {:ok, having} <- SQLAggExpr.having(rest, qualifier, groups, columns),
         :ok <- reject_expr_order(SQLClauses.order_by(rest)) do
      {:ok,
       new_query(measurement, where, rest,
         group_by_interval: interval_ns,
         group_by_columns: groups,
         select_columns: columns,
         having: having
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
        where_tree: SQLWhere.tree(rest),
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
        cross_join: nil,
        qualifier: measurement,
        qualified: %{},
        plan_error: SQLClauses.empty_tuple_error(rest) || SQLLimit.planning_error(rest),
        limit_error: SQLLimit.deferred(rest),
        table_error: nil,
        having: nil
      },
      Map.new(overrides)
    )
  end

  # SELECT DISTINCT col[, col ...] FROM measurement ...
  # SELECT DISTINCT a[, b ...]: plain column names only.
  @spec parse_distinct_select(split(), binary(), binary() | nil) ::
          {:ok, parsed_query()} | {:error, term()}
  defp parse_distinct_select(%{columns: columns, table: table, rest: rest}, sql, qualifier) do
    cond do
      # A DISTINCT over no columns: one empty row if any row qualifies.
      columns == "" ->
        build_distinct_query([], table, rest, qualifier)

      Regex.match?(~r/^[\p{L}_]\w*(\s*,\s*[\p{L}_]\w*)*$/u, columns) ->
        build_distinct_query(split_columns(columns), table, rest, qualifier)

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
          {order_by(), SQLError.t() | nil}
  defp parse_distinct_order_by(columns, table, rest) do
    order_by = SQLClauses.order_by(rest)

    case Enum.flat_map(order_by, &unselected_columns(&1, columns)) do
      [] ->
        {order_by, nil}

      missing ->
        {order_by,
         SQLError.planning(
           "For SELECT DISTINCT, ORDER BY expressions " <>
             Enum.map_join(missing, &"#{table}.#{SQLExpr.ref_text(&1)}") <>
             " must appear in select list"
         )}
    end
  end

  @spec unselected_columns({binary() | {:expr, expr()}, direction()}, [binary()]) ::
          [SQLExpr.column_ref()]
  defp unselected_columns({target, _direction}, columns) when is_binary(target),
    do: if(target in columns, do: [], else: [target])

  defp unselected_columns({{:expr, expr}, _direction}, columns),
    do: expr |> SQLExpr.columns() |> Enum.reject(&(&1 in columns))

  @spec readable_expression?({binary() | {:expr, expr()}, direction()}) :: boolean()
  defp readable_expression?({{:expr, {:unreadable, _text}}, _direction}), do: false
  defp readable_expression?({{:expr, _expr}, _direction}), do: true
  defp readable_expression?({_column, _direction}), do: false

  # Grouped rows have no source point to evaluate an expression against.
  @spec reject_expr_order(order_by()) :: :ok | {:error, term()}
  defp reject_expr_order(order_by) do
    if Enum.any?(order_by, &readable_expression?/1),
      do:
        {:error,
         SQLError.refusal("ORDER BY an expression is not supported in an aggregate query")},
      else: :ok
  end

  # An ORDER BY outside the selected columns is the planner's error, raised
  # once the executor has found the columns (a name that is no column is the
  # schema error first).
  @spec build_distinct_query([binary()], binary(), binary(), binary() | nil) ::
          {:ok, parsed_query()} | {:error, map()}
  defp build_distinct_query(columns, measurement, rest, qualifier) do
    with {:ok, where} <- SQLWhere.nodes(rest) do
      {order_by, error} = parse_distinct_order_by(columns, qualifier || measurement, rest)

      {:ok,
       new_query(measurement, where, rest,
         order_by: order_by,
         distinct_columns: columns,
         plan_error: error || SQLLimit.planning_error(rest)
       )}
    end
  end

  @spec build_star_query(binary(), binary()) ::
          {:ok, parsed_query()} | {:error, map()}
  defp build_star_query(measurement, rest) do
    with {:ok, where} <- SQLWhere.nodes(rest) do
      {:ok, new_query(measurement, where, rest, [])}
    end
  end

  @spec build_columns_query(binary(), binary(), binary(), binary() | nil) ::
          {:ok, parsed_query()} | {:error, term()}
  defp build_columns_query(columns_str, measurement, rest, qualifier) do
    with {:ok, projection} <- parse_projection_columns(columns_str, qualifier),
         :ok <- check_unique(Enum.map(projection, fn {_source, output} -> output end)),
         {:ok, where} <- SQLWhere.nodes(rest) do
      {:ok, new_query(measurement, where, rest, projection_columns: projection)}
    end
  end

  # The engine refuses a select list that names two columns alike
  # ("Projections require unique expression names"), in words that print its
  # planner's rendering of each expression, which the double does not
  # reproduce: it refuses the list by name.
  @spec check_unique([binary()]) :: :ok | {:error, map()}
  defp check_unique(outputs) do
    case outputs -- Enum.uniq(outputs) do
      [] ->
        :ok

      [name | _more] ->
        {:error,
         SQLError.refusal(
           "two select items are both named #{inspect(name)}, which the engine refuses " <>
             "(\"Projections require unique expression names\"); alias one of them"
         )}
    end
  end

  @spec parse_projection_columns(binary(), binary() | nil) ::
          {:ok, [projection()]} | {:error, term()}
  defp parse_projection_columns(columns_str, qualifier) do
    columns =
      columns_str
      |> SQLMask.split_commas()
      |> Enum.map(&String.trim/1)
      |> Enum.map(&parse_projection_column(&1, qualifier))

    if Enum.any?(columns, &match?({:error, _}, &1)) do
      Enum.find(columns, &match?({:error, _}, &1))
    else
      {:ok, Enum.map(columns, fn {:ok, col} -> col end)}
    end
  end

  # Parse a select item: a column (`name`, or a quoted `"a b"`), a constant,
  # or an arithmetic expression, with or without `AS alias`, returning
  # `{source, output}`. An item with no alias is named as the engine names it
  # (`rvt.v * Int64(2)`, `Int64(1)`; see `InfluxElixir.Client.Local.SQLSelect`).
  @spec parse_projection_column(binary(), binary() | nil) ::
          {:ok, projection()} | {:error, term()}
  defp parse_projection_column(col, qualifier) do
    trimmed = String.trim(col)
    {body, alias_name} = SQLSelect.split_alias(trimmed)

    cond do
      constant = SQLSelect.constant(body) ->
        {expr, default} = constant

        with {:ok, output} <-
               SQLSelect.output_name(trimmed, alias_name, fn ->
                 default || throw(:unrenderable)
               end) do
          {:ok, {expr, output}}
        end

      source = plain_column(body) ->
        {:ok, {source, alias_name || source}}

      true ->
        expression_projection(trimmed, body, alias_name, qualifier)
    end
  end

  # A column the select item names, however many pairs of parentheses wrap it
  # (`(v)` is named `v`, as the engine names it); `nil` for anything else,
  # a wrapped constant (`(1)`) included.
  @wrapped_column ~r/\A((?:\(\s*)*)(\w+|"(?:[^"]|"")*")((?:\s*\))*)\z/u

  @spec plain_column(binary()) :: binary() | nil
  defp plain_column(body) do
    with [_full, opens, name, closes] <- Regex.run(@wrapped_column, body),
         true <-
           String.length(opens |> String.replace(~r/\s/, "")) ==
             String.length(String.replace(closes, ~r/\s/, "")),
         nil <- SQLSelect.constant(name) do
      SQLSelect.name(name)
    else
      _not_a_column -> nil
    end
  end

  @spec expression_projection(binary(), binary(), binary() | nil, binary() | nil) ::
          {:ok, projection()} | {:error, term()}
  defp expression_projection(col, body, alias_name, qualifier) do
    case SQLExpr.parse(body) do
      {:ok, expr} ->
        with {:ok, output} <-
               SQLSelect.output_name(col, alias_name, fn ->
                 SQLExpr.render(expr, qualifier, :drop)
               end) do
          {:ok, {expr, output}}
        end

      {:error, _reason} ->
        {:error, SQLError.refusal("unsupported column: #{col}")}
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
           :ok <- SQLTime.first_type_error(nodes),
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
