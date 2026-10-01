defmodule InfluxElixir.Client.Local.SQLParser do
  @compile {:no_warn_undefined, Decimal}

  @moduledoc """
  SQL parser for `InfluxElixir.Client.Local`.

  Recognises the SQL subset documented on `InfluxElixir.Client.Local` and
  produces a `t:parsed_query/0` for the executor. It is deliberately strict:
  anything the real InfluxDB v3 engine would reject — or that the double
  cannot execute faithfully — is refused with a `Client.Local:`-prefixed 400
  so a query cannot pass tests here and fail in production.

  Pure functions only: no ETS, no connection state.
  """

  alias InfluxElixir.Client.Local.{LineProtocolParser, SQLFunctions, SQLIdentifiers}

  # The one place a SELECT is cut into its parts. A measurement name is
  # quoted, or bare with escaped spaces ("my\ measurement") — everything up
  # to the first unescaped space. `rest` is whatever follows the table.
  @select_pattern ~r/(?i)^\s*SELECT\s+(?<distinct>DISTINCT\s+)?(?<columns>.+?)\s+FROM\s+(?:"(?<quoted>[^"]+)"|(?<bare>(?:[^\s\\]|\\.)+))\s*(?<rest>.*)$/s

  @typedoc false
  @typep split :: %{distinct: boolean(), columns: binary(), table: binary(), rest: binary()}

  @typedoc """
  An arithmetic expression inside an aggregate: a field reference, a numeric
  literal, or a binary operation over two expressions.
  """
  @type expr ::
          {:field, binary()}
          | {:lit, number() | binary()}
          | {:op, :+ | :- | :* | :/ | :rem, expr(), expr()}
          | {:neg, expr()}
          | {:cast, expr(), cast_type()}
          | {:call, InfluxElixir.Client.Local.SQLFunctions.name(), [expr()]}

  @typedoc "`CAST(expr AS INTEGER | DOUBLE | VARCHAR)` targets (and their synonyms)."
  @type cast_type :: :integer | :float | :string

  @typedoc "Plain aggregates; `:stddev`/`:var` are the sample forms, as in InfluxDB."
  @type aggregate ::
          :avg | :sum | :count | :min | :max | :median | :stddev | :stddev_pop | :var | :var_pop

  @type select_column ::
          {:time_bucket, binary()}
          | {:aggregate, aggregate(), expr(), binary()}
          | {:count_star, binary()}
          | {:count_distinct, binary(), binary()}
          | {:ordered_aggregate, :first | :last, binary(), binary(), binary()}
          | {:selector, :first | :last | :min | :max, binary(), binary(),
             :value | :time | :struct, binary()}
          | {:grouping_column, binary(), binary()}
          | {:constant, term(), binary()}

  @type where_op ::
          :eq
          | :gt
          | :lt
          | :gte
          | :lte
          | :ne
          | :in
          | :not_in
          | :is_null
          | :is_not_null
          | :between
          | :not_between
          | :like
          | :not_like
          | :regex
          | :not_regex
  @type where_clause :: {where_op(), binary(), term()}

  @typedoc """
  A WHERE conjunction is a list of nodes: a predicate, an `{:or, branches}`
  node whose branches are conjunctions, or a `{:not, conjunction}` node.
  """
  @type where_node :: where_clause() | {:or, [[where_node()]]} | {:not, [where_node()]}

  @typedoc """
  A `time` comparand: nanoseconds since the epoch, or `now()` plus an offset
  in nanoseconds, resolved when the query runs.
  """
  @type time_value :: integer() | {:now, integer()}

  @typedoc "`:asc` / `:desc` (nulls last / first), or a direction with explicit NULLS placement."
  @type direction :: :asc | :desc | {:asc | :desc, :nulls_first | :nulls_last}

  @typedoc "`ORDER BY` terms in order; a target is `time`, a column, an output alias or an expression."
  @type order_by :: [{binary() | {:expr, expr()}, direction()}]

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
  @type operand :: binary() | {:expr, expr()}

  # The aggregate functions, in one place (all verified against InfluxDB 3
  # Core; VARIANCE is *not* one of them). The plain ones take one expression
  # and map to the executor's atoms; `:stddev`/`:var` are the sample forms.
  @plain_aggregates %{
    "avg" => :avg,
    "sum" => :sum,
    "count" => :count,
    "min" => :min,
    "max" => :max,
    "stddev" => :stddev,
    "stddev_samp" => :stddev,
    "stddev_pop" => :stddev_pop,
    "var" => :var,
    "var_samp" => :var,
    "var_pop" => :var_pop,
    "median" => :median
  }

  @ordered_aggregates ~w(first_value last_value)
  @selector_aggregates ~w(selector_first selector_last selector_min selector_max)

  # InfluxQL selector functions that InfluxDB v3 SQL does not provide. They
  # are recognised only so the rejection can be the engine's own, which
  # suggests a (different, arbitrary) function name; the double picks one.
  @influxql_only_functions %{"first" => "cbrt", "last" => "least"}

  @plain_alternation @plain_aggregates
                     |> Map.keys()
                     |> Enum.sort_by(&(-byte_size(&1)))
                     |> Enum.join("|")

  @aggregate_alternation Enum.join(
                           Map.keys(@plain_aggregates) ++
                             @ordered_aggregates ++ @selector_aggregates,
                           "|"
                         )

  # A call to an aggregate, or to an InfluxQL-only selector.
  @aggregate_call ~r/(?i)(?:#{@aggregate_alternation})\s*\(/
  @influxql_call ~r/(?i)\b(?:#{Enum.join(Map.keys(@influxql_only_functions), "|")})\s*\(/

  # selector_first|last|min|max(field, time)[['value'|'time']] AS alias
  @selector_pattern ~r/(?i)^\s*SELECTOR_(FIRST|LAST|MIN|MAX)\s*\(\s*(\w+)\s*,\s*(\w+)\s*\)\s*(?:\[\s*'(value|time)'\s*\])?\s+AS\s+(\w+)\s*$/

  # first_value(field ORDER BY col [ASC|DESC]) AS alias  (and last_value).
  # The ORDER BY group is optional in the grammar so a missing one can be
  # reported specifically instead of as a generic parse failure.
  @ordered_agg_pattern ~r/(?i)^\s*(FIRST_VALUE|LAST_VALUE)\s*\(\s*(\w+)\s*(?:ORDER\s+BY\s+(\w+)(?:\s+(ASC|DESC))?\s*)?\)\s+AS\s+(\w+)\s*$/

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
    sql =
      if Keyword.get(opts, :identifiers, :fold) == :exact,
        do: sql,
        else: SQLIdentifiers.normalize(sql)

    with {:ok, cte_sources, main_sql} <- split_ctes(String.trim(sql)),
         {:ok, ctes} <- parse_ctes(cte_sources),
         {:ok, main} <- parse_single_select(main_sql) do
      {:ok, %{main | ctes: ctes}}
    end
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
    case Regex.run(~r/^WITH\s+(.*)$/is, sql) do
      [_full, rest] -> take_ctes(rest, [], sql)
      nil -> {:ok, [], sql}
    end
  end

  @spec take_ctes(binary(), [{binary(), binary()}], binary()) ::
          {:ok, [{binary(), binary()}], binary()} | {:error, term()}
  defp take_ctes(str, acc, sql) do
    with [_full, name, after_open] <- Regex.run(~r/^\s*(\w+)\s+AS\s*\((.*)$/is, str),
         {:ok, body, after_close} <- take_balanced(after_open) do
      cte = {name, String.trim(body)}

      case Regex.run(~r/^\s*,(.*)$/s, after_close) do
        [_full, more] -> take_ctes(more, [cte | acc], sql)
        nil -> {:ok, Enum.reverse([cte | acc]), String.trim(after_close)}
      end
    else
      _no_match -> {:error, local_error("unsupported WITH clause: #{sql}")}
    end
  end

  # Splits `str` at the parenthesis that closes the one already opened;
  # parentheses inside a quoted literal do not count.
  @spec take_balanced(binary()) :: {:ok, binary(), binary()} | :error
  defp take_balanced(str) do
    case closing_paren(mask(str), 1, 0) do
      nil -> :error
      at -> {:ok, binary_part(str, 0, at), binary_part(str, at + 1, byte_size(str) - at - 1)}
    end
  end

  @spec closing_paren(binary(), pos_integer(), non_neg_integer()) :: non_neg_integer() | nil
  defp closing_paren(<<>>, _depth, _at), do: nil
  defp closing_paren(<<?), _rest::binary>>, 1, at), do: at
  defp closing_paren(<<?), rest::binary>>, depth, at), do: closing_paren(rest, depth - 1, at + 1)
  defp closing_paren(<<?(, rest::binary>>, depth, at), do: closing_paren(rest, depth + 1, at + 1)
  defp closing_paren(<<_byte, rest::binary>>, depth, at), do: closing_paren(rest, depth, at + 1)

  # ---------------------------------------------------------------------------
  # Quoted text
  #
  # Every clause is located by a regular expression, and a string literal can
  # hold anything: a comma, `>`, `limit 5`, `from t`. So the text is masked
  # first — the body of each '...' or "..." becomes `x`s, byte for byte, the
  # quotes stay — the expression runs over the mask, and what it found is cut
  # out of the original at the same offsets. A doubled quote (`'O''Brien'`)
  # is one quote inside the literal.
  # ---------------------------------------------------------------------------

  @spec mask(binary()) :: binary()
  defp mask(sql), do: sql |> mask_scan([]) |> IO.iodata_to_binary()

  @spec mask_scan(binary(), iodata()) :: iodata()
  defp mask_scan(<<>>, acc), do: Enum.reverse(acc)

  defp mask_scan(<<q, rest::binary>>, acc) when q in [?', ?"] do
    {width, closer, rest} = mask_quoted(rest, q, 0)
    mask_scan(rest, [[q, String.duplicate("x", width), closer] | acc])
  end

  defp mask_scan(<<byte, rest::binary>>, acc), do: mask_scan(rest, [byte | acc])

  @spec mask_quoted(binary(), char(), non_neg_integer()) ::
          {non_neg_integer(), binary(), binary()}
  defp mask_quoted(<<q, q, rest::binary>>, q, width), do: mask_quoted(rest, q, width + 2)
  defp mask_quoted(<<q, rest::binary>>, q, width), do: {width, <<q>>, rest}
  defp mask_quoted(<<_byte, rest::binary>>, q, width), do: mask_quoted(rest, q, width + 1)
  defp mask_quoted(<<>>, _q, width), do: {width, "", ""}

  # `Regex.run/2` over the masked text, with the captures cut from `text`
  # (an unmatched optional group is `""`).
  @spec run_masked(Regex.t(), binary()) :: [binary()] | nil
  defp run_masked(pattern, text) do
    case Regex.run(pattern, mask(text), return: :index) do
      nil -> nil
      indexes -> Enum.map(indexes, &cut(text, &1))
    end
  end

  @spec cut(binary(), {integer(), non_neg_integer()}) :: binary()
  defp cut(_text, {-1, _length}), do: ""
  defp cut(text, {start, length}), do: binary_part(text, start, length)

  # `'it''s'` is the text `it's`.
  @spec unescape_literal(binary()) :: binary()
  defp unescape_literal(body), do: String.replace(body, "''", "'")

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
  @distinct_on ~r/^(\s*SELECT\s+)DISTINCT\s+ON\s*\((.*)$/is

  @spec split_distinct_on(binary()) :: {binary(), binary() | nil}
  defp split_distinct_on(sql) do
    with [_full, select, after_open] <- Regex.run(@distinct_on, sql),
         {:ok, on, rest} <- take_balanced(after_open) do
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
    masked = mask(sql)

    select_list =
      case split_select(masked) do
        {:ok, %{columns: columns}} -> columns
        {:error, _reason} -> ""
      end

    if Regex.match?(@aggregate_call, select_list) or Regex.match?(~r/\bGROUP\s+BY\b/i, masked) do
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
    columns = on |> split_top_level_commas() |> Enum.map(&String.trim/1)

    cond do
      columns == [""] ->
        {:error, %{status: 400, body: "Error during planning: No `ON` expressions provided"}}

      not Enum.all?(columns, &Regex.match?(~r/^(?:\w+|"[^"]+")$/, &1)) ->
        {:error, local_error("DISTINCT ON takes column names only: (#{on})")}

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
  # are rewritten to the select items they name before anything else reads
  # the clauses, as DataFusion resolves them (verified): a position becomes
  # the item's expression in GROUP BY and its output name in ORDER BY, an
  # alias in GROUP BY becomes its expression. A position outside the
  # select list is the engine's planning error.
  # What starts a LIMIT or OFFSET clause (rather than a column of that name):
  # a number, or NULL. A name after them is the engine's schema error, a
  # negative or fractional number its own, all answered by `check_limit/2`.
  @limit_start "(?:LIMIT|OFFSET)\\s+(?:-?\\.?\\d|NULL\\b)"

  @group_clause ~r/(?i)(\bGROUP\s+BY\s+)(.+?)(?=\s+ORDER\b|\s+#{@limit_start}|\s*$)/s
  @order_clause ~r/(?i)(\bORDER\s+BY\s+)(.+?)(?=\s+#{@limit_start}|\s*$)/s

  @spec resolve_references(split(), binary()) ::
          {:ok, split(), binary()} | {:error, map()}
  defp resolve_references(%{columns: "*"} = split, sql), do: {:ok, split, sql}

  defp resolve_references(%{rest: rest} = split, sql) do
    items =
      split.columns
      |> split_top_level_commas()
      |> Enum.map(&(&1 |> String.trim() |> select_item()))

    with {:ok, rest} <- rewrite_clause(rest, @group_clause, &group_term(&1, items)),
         {:ok, rest} <- rewrite_clause(rest, @order_clause, &order_term(&1, items)) do
      {:ok, %{split | rest: rest}, String.replace_suffix(sql, split.rest, rest)}
    end
  end

  # {expression, output name} of one select item.
  @spec select_item(binary()) :: {binary(), binary()}
  defp select_item(item) do
    case run_masked(~r/^(.+?)\s+AS\s+"?(\w+)"?$/is, item) do
      [_full, expr, alias_name] -> {String.trim(expr), alias_name}
      nil -> {item, item}
    end
  end

  @spec rewrite_clause(binary(), Regex.t(), (binary() -> {:ok, binary()} | {:error, map()})) ::
          {:ok, binary()} | {:error, map()}
  defp rewrite_clause(rest, pattern, rewrite_term) do
    case Regex.run(pattern, mask(rest), return: :index) do
      [{start, len}, {_kw_start, kw_len}, {_list_start, _list_len}] ->
        clause = binary_part(rest, start, len)
        keyword = binary_part(clause, 0, kw_len)
        list = binary_part(clause, kw_len, len - kw_len)

        list
        |> split_top_level_commas()
        |> Enum.reduce_while({:ok, []}, fn term, {:ok, acc} ->
          case rewrite_term.(String.trim(term)) do
            {:ok, term} -> {:cont, {:ok, [term | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, terms} ->
            new_clause = keyword <> (terms |> Enum.reverse() |> Enum.join(", "))

            {:ok,
             binary_part(rest, 0, start) <>
               new_clause <> binary_part(rest, start + len, byte_size(rest) - start - len)}

          error ->
            error
        end

      nil ->
        {:ok, rest}
    end
  end

  @spec group_term(binary(), [{binary(), binary()}]) :: {:ok, binary()} | {:error, map()}
  defp group_term(term, items) do
    case positional(term, items) do
      {:ok, {expr, _name}} ->
        {:ok, expr}

      :not_positional ->
        case Enum.find(items, fn {expr, name} -> name == term and expr != term end) do
          {expr, _name} -> {:ok, expr}
          nil -> {:ok, term}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec order_term(binary(), [{binary(), binary()}]) :: {:ok, binary()} | {:error, map()}
  defp order_term(term, items) do
    {target, direction} =
      case run_masked(~r/^(.+?)\s+(ASC|DESC)$/is, term) do
        [_full, target, direction] -> {target, " " <> direction}
        nil -> {term, ""}
      end

    case positional(target, items) do
      {:ok, {_expr, name}} -> {:ok, name <> direction}
      :not_positional -> {:ok, term}
      error -> error
    end
  end

  @spec positional(binary(), [{binary(), binary()}]) ::
          {:ok, {binary(), binary()}} | :not_positional | {:error, map()}
  defp positional(term, items) do
    case Integer.parse(term) do
      {n, ""} when n >= 1 and n <= length(items) ->
        {:ok, Enum.at(items, n - 1)}

      {n, ""} ->
        {:error,
         %{
           status: 400,
           body:
             "Error during planning: Cannot find column with position #{n} in SELECT clause. " <>
               "Valid columns: 1 to #{length(items)}"
         }}

      _not_integer ->
        :not_positional
    end
  end

  @spec split_select(binary()) :: {:ok, split()} | {:error, term()}
  defp split_select(sql) do
    case Regex.named_captures(@select_pattern, mask(sql), return: :index) do
      nil ->
        unsupported(sql)

      indexes ->
        part = fn name -> cut(sql, Map.fetch!(indexes, name)) end
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
      aggregate_query?(sql) -> parse_aggregate_select(split, sql)
      split.columns == "*" -> build_star_query(split.table, split.rest)
      true -> build_columns_query(split.columns, split.table, split.rest)
    end
  end

  # `FROM w CROSS JOIN ref [AS r]`: the right side is taken out of the text
  # (the rest of the parser sees one table) and recorded with its alias so
  # its qualifiers can be dropped like the left side's.
  # Keywords that can follow a table name are clauses (or constructs), never an alias.
  @not_an_alias ~w(WHERE GROUP ORDER LIMIT JOIN CROSS INNER LEFT RIGHT FULL OUTER NATURAL UNION EXCEPT INTERSECT HAVING OFFSET ON USING)

  @cross_join_pattern ~r/(?i)(\bFROM\s+(?:"[^"]+"|(?:[^\s\\]|\\.)+)(?:\s+(?:AS\s+)?(?!CROSS\b)\w+)?)\s+CROSS\s+JOIN\s+("[^"]+"|(?:[^\s\\]|\\.)+)(?:\s+(?:AS\s+)?(?!(?:#{Enum.join(@not_an_alias, "|")})\b)(\w+))?/

  @spec split_cross_join(binary()) :: {binary(), {binary(), [binary()]} | nil}
  defp split_cross_join(sql) do
    case Regex.run(@cross_join_pattern, mask(sql), return: :index) do
      [{start, length}, left, table | alias_name] ->
        name = sql |> cut(table) |> String.trim("\"")
        names = [name | Enum.map(alias_name, &cut(sql, &1))]
        tail = binary_part(sql, start + length, byte_size(sql) - start - length)
        {binary_part(sql, 0, start) <> cut(sql, left) <> tail, {name, names}}

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
  @unsupported_construct ~r/(?i)\b(JOIN|UNION|EXCEPT|INTERSECT|HAVING)\b|\b(OVER)\s*\(/
  @clause_keywords ~w(WHERE GROUP ORDER LIMIT OFFSET)

  @spec check_clauses(binary()) :: :ok | {:error, term()}
  defp check_clauses(sql) do
    scannable = mask(sql)

    with :ok <- check_constructs(scannable, sql),
         :ok <- check_single_select(scannable, sql),
         {:ok, %{rest: rest}} <- split_select(scannable),
         :ok <- check_limit(rest, sql) do
      [next] = Regex.run(~r/^\w*/, rest)
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
        {:error, local_error("unsupported SQL construct #{construct}: #{sql}")}
    end
  end

  # After the CTEs are split off, one query holds exactly one SELECT; a
  # second one is a subquery (`WHERE x IN (SELECT ...)`), which would
  # otherwise be read as a string literal.
  @spec check_single_select(binary(), binary()) :: :ok | {:error, term()}
  defp check_single_select(scannable, sql) do
    if length(Regex.scan(~r/(?i)\bSELECT\b/, scannable)) > 1,
      do: {:error, local_error("unsupported SQL construct SUBQUERY: #{sql}")},
      else: :ok
  end

  # `LIMIT n` and `OFFSET m`, in either order, end the statement. A clause
  # is the keyword followed by a value, so a column called `offset` (an
  # operator or keyword follows it) stays a column. The engine's answers
  # (verified): a name is its schema error (500), a fractional number the
  # type_coercion error naming the clause, a negative number the optimizer's
  # error, 0 and NULL are fine. Planning comes before optimizing, and LIMIT
  # before OFFSET; a negative OFFSET is reported by `push_down_limit` when a
  # LIMIT is present and by `eliminate_limit` when it is not.
  @limit_keywords ~w(ASC DESC NULLS LIMIT OFFSET AND OR NOT IS IN LIKE ILIKE BETWEEN AS)

  @spec check_limit(binary(), binary()) :: :ok | {:error, term()}
  defp check_limit(rest, sql) do
    found =
      ~r/(?i)(?<![\w.])(LIMIT|OFFSET)\s+(\S+)/
      |> Regex.scan(rest, return: :index)
      |> Enum.map(fn [{start, _len}, keyword, token] ->
        {start, {cut(rest, keyword) |> String.upcase(), limit_token(cut(rest, token))}}
      end)
      |> Enum.reject(&match?({_start, {_keyword, :not_a_clause}}, &1))

    clauses = Enum.map(found, &elem(&1, 1))

    with :ok <- limit_refusal(clauses, trailing_garbage?(found, rest), sql),
         :ok <- limit_planning(clauses) do
      limit_optimizer(clauses)
    end
  end

  @spec limit_token(binary()) ::
          {:count, non_neg_integer()}
          | {:negative, binary()}
          | {:name, binary()}
          | :fractional
          | :null
          | :other
          | :not_a_clause
  defp limit_token(token) do
    upper = String.upcase(token)

    cond do
      Regex.match?(~r/^\d+$/, token) -> {:count, String.to_integer(token)}
      Regex.match?(~r/^-\d+$/, token) -> {:negative, token}
      Regex.match?(~r/^(?:\d+\.\d*|\.\d+)$/, token) -> :fractional
      upper == "NULL" -> :null
      upper in @limit_keywords or Regex.match?(~r/^[=<>!,)~]/, token) -> :not_a_clause
      Regex.match?(~r/^[A-Za-z_]\w*$/, token) -> {:name, token}
      true -> :other
    end
  end

  # Whatever follows the first clause must be clauses and nothing else.
  @spec trailing_garbage?([{non_neg_integer(), term()}], binary()) :: boolean()
  defp trailing_garbage?([], _rest), do: false

  defp trailing_garbage?([{start, _clause} | _more], rest) do
    tail = binary_part(rest, start, byte_size(rest) - start)
    not Regex.match?(~r/(?i)^(?:(?:LIMIT|OFFSET)\s+\S+\s*)+$/, tail)
  end

  @spec limit_refusal([{binary(), term()}], boolean(), binary()) :: :ok | {:error, term()}
  defp limit_refusal(clauses, garbage?, sql) do
    cond do
      Enum.any?(clauses, &match?({"LIMIT", :other}, &1)) ->
        {:error, local_error("unsupported LIMIT (a non-negative integer is required): #{sql}")}

      Enum.any?(clauses, &match?({"OFFSET", :other}, &1)) ->
        {:error,
         local_error("unsupported LIMIT / OFFSET (non-negative integers are required): #{sql}")}

      garbage? or too_many_clauses?(clauses) ->
        {:error,
         local_error("unsupported LIMIT / OFFSET (non-negative integers are required): #{sql}")}

      true ->
        :ok
    end
  end

  # One LIMIT and one OFFSET at most.
  @spec too_many_clauses?([{binary(), term()}]) :: boolean()
  defp too_many_clauses?(clauses),
    do:
      Enum.count(clauses, &(elem(&1, 0) == "LIMIT")) > 1 or
        Enum.count(clauses, &(elem(&1, 0) == "OFFSET")) > 1

  @spec limit_planning([{binary(), term()}]) :: :ok | {:error, map()}
  defp limit_planning(clauses) do
    case Enum.find(clauses, &match?({_keyword, {:name, _name}}, &1)) do
      {_keyword, {:name, name}} ->
        {:error, %{status: 500, body: "Schema error: No field named #{name}."}}

      nil ->
        case Enum.find(clauses, &match?({_keyword, :fractional}, &1)) do
          {keyword, :fractional} ->
            {:error,
             %{
               status: 400,
               body:
                 "type_coercion\ncaused by\nError during planning: Expected #{keyword} to be " <>
                   "an integer or null, but got Float64"
             }}

          nil ->
            :ok
        end
    end
  end

  @spec limit_optimizer([{binary(), term()}]) :: :ok | {:error, map()}
  defp limit_optimizer(clauses) do
    limit = Enum.find(clauses, &match?({"LIMIT", _clause}, &1))
    offset = Enum.find(clauses, &match?({"OFFSET", _clause}, &1))

    case {limit, offset} do
      {{"LIMIT", {:negative, n}}, _offset} ->
        {:error, optimizer_error("eliminate_limit", "LIMIT must be >= 0, '#{n}' was provided")}

      {_limit, {"OFFSET", {:negative, n}}} ->
        rule =
          if match?({"LIMIT", {:count, _n}}, limit),
            do: "push_down_limit",
            else: "eliminate_limit"

        {:error, optimizer_error(rule, "OFFSET must be >=0, '#{n}' was provided")}

      _valid ->
        :ok
    end
  end

  @spec optimizer_error(binary(), binary()) :: map()
  defp optimizer_error(rule, message) do
    %{
      status: 400,
      body: "Optimizer rule '#{rule}' failed\ncaused by\nError during planning: #{message}"
    }
  end

  @spec unsupported(binary()) :: {:error, term()}
  defp unsupported(sql), do: {:error, local_error("unsupported SQL: #{sql}")}

  # `SELECT w.bid FROM q AS w WHERE w.provider = 'a'` — one table per query,
  # so a qualifier (the table name or its alias) adds nothing: drop the
  # alias from FROM and the `qualifier.` prefixes outside string literals.
  # A keyword after the table is a clause (or an unsupported construct that
  # `check_clauses/1` will name), never an alias.
  @from_alias_pattern ~r/(?i)(FROM\s+("[^"]+"|(?:[^\s\\]|\\.)+))(?:\s+(?:AS\s+)?(?!(?:#{Enum.join(@not_an_alias, "|")})\b)(\w+))?/

  @spec strip_table_qualifiers(binary(), {binary(), [binary()]} | nil) :: binary()
  defp strip_table_qualifiers(sql, cross_join) do
    joined_names =
      case cross_join do
        {_table, names} -> names
        nil -> []
      end

    case Regex.run(@from_alias_pattern, mask(sql), return: :index) do
      [{start, length}, from_clause, table, alias_name] ->
        # The alias (with its `AS`) is whatever follows the table in the match.
        {from_start, from_length} = from_clause
        after_match = start + length

        without_alias =
          binary_part(sql, 0, from_start + from_length) <>
            binary_part(sql, after_match, byte_size(sql) - after_match)

        drop_qualifiers(without_alias, [
          sql |> cut(table) |> String.trim("\""),
          cut(sql, alias_name) | joined_names
        ])

      [_full, _from_clause, table] ->
        drop_qualifiers(sql, [sql |> cut(table) |> String.trim("\"") | joined_names])

      nil ->
        sql
    end
  end

  @spec drop_qualifiers(binary(), [binary()]) :: binary()
  defp drop_qualifiers(sql, qualifiers) do
    names = qualifiers |> Enum.map(&Regex.escape/1) |> Enum.join("|")
    pattern = ~r/'(?:[^']|'')*'|"[^"]*"|(?<![\w."])(?:#{names})\.(?=\w)/

    Regex.replace(pattern, sql, fn
      "'" <> _rest = literal -> literal
      "\"" <> _rest = identifier -> identifier
      _qualifier -> ""
    end)
  end

  @spec aggregate_query?(binary()) :: boolean()
  # A GROUP BY without an aggregate (`SELECT host FROM p GROUP BY host`) is
  # still a grouped query: one row per group, the grouping columns projected.
  defp aggregate_query?(sql) do
    masked = mask(sql)

    Regex.match?(~r/(?i)DATE_BIN|\bGROUP\s+BY\b/, masked) or
      Regex.match?(@aggregate_call, masked) or Regex.match?(@influxql_call, masked)
  end

  @spec parse_aggregate_select(split(), binary()) ::
          {:ok, parsed_query()} | {:error, term()}
  defp parse_aggregate_select(%{table: measurement, rest: rest} = split, sql) do
    with {:ok, columns} <- parse_select_list(split.columns),
         {:ok, interval_ns} <- resolve_aggregate_interval(sql),
         :ok <- check_select_date_bins(split.columns, interval_ns),
         {:ok, where} <- parse_where(rest),
         :ok <- reject_expr_order(parse_order_by(rest)) do
      {:ok,
       new_query(measurement, where, rest,
         group_by_interval: interval_ns,
         group_by_columns: parse_group_by_columns(sql),
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
        order_by: parse_order_by(rest),
        limit: parse_limit(rest),
        offset: parse_offset(rest),
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

  # The GROUP BY items, after positions and aliases were resolved. A
  # `DATE_BIN(...)` item sets the bucket interval; the others are grouping
  # columns, and the two combine (`GROUP BY DATE_BIN(...), host`: one row
  # per bucket per host, verified).
  @spec group_by_items(binary()) :: [binary()]
  defp group_by_items(sql) do
    case run_masked(@group_clause, sql) do
      [_full, _keyword, list] ->
        list |> split_top_level_commas() |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      nil ->
        []
    end
  end

  @spec date_bin_item?(binary()) :: boolean()
  defp date_bin_item?(item), do: Regex.match?(~r/^DATE_BIN\s*\(/i, item)

  # The bare-column GROUP BY items, or nil when there are none.
  @spec parse_group_by_columns(binary()) :: [binary()] | nil
  defp parse_group_by_columns(sql) do
    case sql |> group_by_items() |> Enum.reject(&date_bin_item?/1) do
      [] -> nil
      columns -> columns
    end
  end

  # GROUP BY DATE_BIN is optional. Without it the executor groups by columns
  # or produces a single scalar row; a malformed interval still surfaces.
  @spec resolve_aggregate_interval(binary()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  defp resolve_aggregate_interval(sql) do
    case Enum.find(group_by_items(sql), &date_bin_item?/1) do
      nil -> {:ok, nil}
      item -> parse_group_by_interval(item)
    end
  end

  # A DATE_BIN in the select list must be the GROUP BY's (the engine compares
  # the intervals, not their spelling: `'60 seconds'` is `'1 minute'`).
  # Anything else fails its planning with "Column in SELECT must be in GROUP
  # BY or an aggregate function" and a rendering of the interval that the
  # double does not reproduce; and without a GROUP BY the engine reads the
  # call as an ordinary projection, which the double does not model. Both
  # are refused by name.
  @date_bin_mismatch "a DATE_BIN in the select list needs a GROUP BY DATE_BIN with the " <>
                       "same interval (InfluxDB otherwise fails planning with \"Column in " <>
                       "SELECT must be in GROUP BY or an aggregate function\", or answers a " <>
                       "plain projection, which this double does not model): "

  @spec check_select_date_bins(binary(), non_neg_integer() | nil) :: :ok | {:error, map()}
  defp check_select_date_bins(columns, group_interval) do
    columns
    |> split_top_level_commas()
    |> Enum.flat_map(&date_bin_interval/1)
    |> Enum.reduce_while(:ok, fn interval, :ok ->
      case parse_interval(interval) do
        {:ok, ns} when ns == group_interval -> {:cont, :ok}
        {:ok, _ns} -> {:halt, {:error, local_error(@date_bin_mismatch <> columns)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec date_bin_interval(binary()) :: [binary()]
  defp date_bin_interval(column) do
    case run_masked(~r/(?i)DATE_BIN\s*\(\s*INTERVAL\s+'([^']+)'/, column) do
      [_full, interval] -> [interval]
      nil -> []
    end
  end

  # The aggregate SELECT list: DATE_BIN(...) AS alias, AGG(expr) AS alias,
  # selectors, grouping columns.
  @spec parse_select_list(binary()) :: {:ok, [select_column()]} | {:error, term()}
  defp parse_select_list(columns_str) do
    columns =
      columns_str
      |> split_top_level_commas()
      |> Enum.map(&String.trim/1)
      |> Enum.map(&parse_single_column/1)

    case Enum.find(columns, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(columns, fn {:ok, col} -> col end)}
      error -> error
    end
  end

  # Splits at the commas outside parentheses and string literals.
  @spec split_top_level_commas(binary()) :: [binary()]
  defp split_top_level_commas(str) do
    commas = str |> mask() |> comma_positions(0, 0, [])
    {last, parts} = Enum.reduce(commas, {0, []}, &cut_before(&1, &2, str))
    Enum.reverse([binary_part(str, last, byte_size(str) - last) | parts])
  end

  @spec cut_before(non_neg_integer(), {non_neg_integer(), [binary()]}, binary()) ::
          {non_neg_integer(), [binary()]}
  defp cut_before(at, {from, parts}, str),
    do: {at + 1, [binary_part(str, from, at - from) | parts]}

  @spec comma_positions(binary(), non_neg_integer(), non_neg_integer(), [non_neg_integer()]) ::
          [non_neg_integer()]
  defp comma_positions(<<>>, _at, _depth, acc), do: Enum.reverse(acc)

  defp comma_positions(<<?,, rest::binary>>, at, 0, acc),
    do: comma_positions(rest, at + 1, 0, [at | acc])

  defp comma_positions(<<?(, rest::binary>>, at, depth, acc),
    do: comma_positions(rest, at + 1, depth + 1, acc)

  defp comma_positions(<<?), rest::binary>>, at, depth, acc),
    do: comma_positions(rest, at + 1, max(depth - 1, 0), acc)

  defp comma_positions(<<_byte, rest::binary>>, at, depth, acc),
    do: comma_positions(rest, at + 1, depth, acc)

  # Parse a single SELECT column expression
  # A constant in the select list (`0.0 AS volume`, `'x' AS label`) needs an
  # alias: DataFusion names an unaliased one after its own rendering
  # (`Int64(1)`), which the double will not guess.
  @constant_column ~r/^\s*(-?\d+(?:\.\d+)?|'(?:[^']|'')*')\s+AS\s+(\w+)\s*$/i

  @spec parse_single_column(binary()) ::
          {:ok, select_column()} | {:error, term()}
  defp parse_single_column(col) do
    masked = mask(col)

    cond do
      String.match?(masked, ~r/(?i)DATE_BIN\s*\(/) ->
        parse_date_bin_column(col)

      String.match?(masked, ~r/(?i)\b(FIRST_VALUE|LAST_VALUE)\s*\(/) ->
        parse_ordered_agg_column(col)

      String.match?(masked, ~r/(?i)\bSELECTOR_(FIRST|LAST|MIN|MAX)\s*\(/) ->
        parse_selector_column(col)

      match = Regex.run(@influxql_call, masked) ->
        {:error, invalid_function(hd(match))}

      String.match?(masked, ~r/(?i)\b(?:#{@plain_alternation})\s*\(/) ->
        parse_agg_column(col)

      match = Regex.run(@constant_column, col) ->
        [_full, literal, alias_name] = match
        {:ok, {:constant, parse_where_value(literal), alias_name}}

      String.match?(col, ~r/^\s*\w+(\s+AS\s+\w+)?\s*$/i) ->
        parse_grouping_column(col)

      true ->
        {:error, local_error("unsupported column expression: #{col}")}
    end
  end

  # FIRST()/LAST() are InfluxQL selectors, not SQL functions: the engine
  # fails planning, suggesting some other function by edit distance. The
  # double names one, always the same.
  @spec invalid_function(binary()) :: map()
  defp invalid_function(call) do
    name = call |> String.replace(~r/\s*\($/, "") |> String.downcase()

    %{
      status: 400,
      body:
        "Error during planning: Invalid function '#{name}'.\nDid you mean " <>
          "'#{Map.fetch!(@influxql_only_functions, name)}'?"
    }
  end

  # Parse: first_value(field ORDER BY col [ASC|DESC]) AS alias  (and last_value).
  #
  # Direction is folded into the aggregate atom at parse time: `:first` always
  # means "the point with the smallest ordering value" and `:last` the largest,
  # so first_value(... DESC) and last_value(... ASC) share one executor.
  #
  # ORDER BY is mandatory. DataFusion returns an arbitrary group member when it
  # is omitted, which the double cannot reproduce — accepting the query would
  # certify a non-deterministic result.
  @spec parse_ordered_agg_column(binary()) ::
          {:ok, select_column()} | {:error, term()}
  defp parse_ordered_agg_column(col) do
    case Regex.run(@ordered_agg_pattern, col) do
      [_full, func, field, ordering, direction, alias_name] when ordering != "" ->
        agg = ordered_agg_end(func, direction)
        {:ok, {:ordered_aggregate, agg, field, ordering, alias_name}}

      [_full, func, _field, "", _direction, _alias] ->
        {:error,
         local_error(
           "#{func}() needs ORDER BY inside the call: InfluxDB v3 returns an " <>
             "arbitrary row from the group without one, which this test double " <>
             "cannot reproduce. Write #{func}(field ORDER BY time): #{col}"
         )}

      _no_match ->
        {:error, local_error("invalid aggregate: #{col}")}
    end
  end

  @spec ordered_agg_end(binary(), binary()) :: :first | :last
  defp ordered_agg_end(func, direction) do
    case {String.downcase(func), String.upcase(direction)} do
      {"first_value", "DESC"} -> :last
      {"first_value", _asc} -> :first
      {"last_value", "DESC"} -> :first
      {"last_value", _asc} -> :last
    end
  end

  # Parse a bare grouping column: `name` or `name AS alias`.
  @spec parse_grouping_column(binary()) ::
          {:ok, select_column()} | {:error, term()}
  defp parse_grouping_column(col) do
    case Regex.run(~r/^(\w+)(?:\s+AS\s+(\w+))?$/i, String.trim(col)) do
      [_full, name] -> {:ok, {:grouping_column, name, name}}
      [_full, name, alias_name] -> {:ok, {:grouping_column, name, alias_name}}
      _no_match -> {:error, local_error("invalid column: #{col}")}
    end
  end

  # Parse: DATE_BIN(INTERVAL 'N unit', time) AS alias
  @spec parse_date_bin_column(binary()) ::
          {:ok, select_column()} | {:error, term()}
  defp parse_date_bin_column(col) do
    pattern =
      ~r/(?i)DATE_BIN\s*\(\s*INTERVAL\s+'([^']+)'\s*,\s*time\s*\)\s+AS\s+(\w+)/

    case Regex.run(pattern, col) do
      [_full, _interval, alias_name] ->
        {:ok, {:time_bucket, alias_name}}

      _no_match ->
        {:error, local_error("invalid DATE_BIN: #{col}")}
    end
  end

  # Parse: AGG(field) AS alias.
  # COUNT(*) is special-cased — it counts rows regardless of field nullity
  # (matching real InfluxDB v3 / SQL semantics), so it doesn't fit the
  # `\w+`-inside-parens shape used for the other aggregates.
  @spec parse_agg_column(binary()) ::
          {:ok, select_column()} | {:error, term()}
  defp parse_agg_column(col) do
    count_star =
      ~r/(?i)^\s*COUNT\s*\(\s*\*\s*\)\s+AS\s+(\w+)\s*$/

    count_distinct =
      ~r/(?i)^\s*COUNT\s*\(\s*DISTINCT\s+(\w+)\s*\)\s+AS\s+(\w+)\s*$/

    cond do
      error = time_aggregate_error(col) ->
        {:error, error}

      match = Regex.run(count_star, col) ->
        [_full, alias_name] = match
        {:ok, {:count_star, alias_name}}

      match = Regex.run(count_distinct, col) ->
        [_full, column, alias_name] = match
        {:ok, {:count_distinct, column, alias_name}}

      true ->
        parse_agg_column_arg(col)
    end
  end

  # One argument, which may be an arithmetic expression over fields and
  # numeric literals (`SUM(value * value)`), as the real engine allows.
  # `AVG(field, other)` is not SQL: the expression parser rejects the comma.
  @spec parse_agg_column_arg(binary()) ::
          {:ok, select_column()} | {:error, term()}
  defp parse_agg_column_arg(col) do
    one_arg = ~r/(?i)^\s*(#{@plain_alternation})\s*\((.+)\)\s+AS\s+(\w+)\s*$/s

    with [_full, func, expr_str, alias_name] <- Regex.run(one_arg, col),
         {:ok, expr} <- parse_expr(expr_str),
         agg = Map.fetch!(@plain_aggregates, String.downcase(func)),
         :ok <- check_time_argument(agg, expr, col) do
      {:ok, {:aggregate, agg, expr, alias_name}}
    else
      {:error, %{status: 400}} = error -> error
      _no_match -> {:error, local_error("invalid aggregate: #{col}")}
    end
  end

  # `time` is a Timestamp column. DataFusion computes MIN, MAX and COUNT over
  # it but fails planning for AVG, SUM and the statistics, in the words
  # `time_aggregate_error/1` reproduces. Arithmetic on it
  # (`MAX(time - 1)`: "Cannot coerce arithmetic expression Timestamp(ns) -
  # Int64 to valid types") is the executor's plan-time type check, in the
  # engine's words.
  @spec check_time_argument(aggregate(), expr(), binary()) :: :ok | {:error, term()}
  defp check_time_argument(agg, {:field, "time"}, _col) when agg in [:min, :max, :count],
    do: :ok

  defp check_time_argument(_agg, expr, col) do
    if expr == {:field, "time"} do
      {:error,
       local_error(
         "InfluxDB rejects this aggregate over `time` (Timestamp): only " <>
           "MIN(time), MAX(time) and COUNT(time) are valid: #{col}"
       )}
    else
      :ok
    end
  end

  # The engine's planning error for `AVG(time)` and the like (verified, and
  # the same with or without an alias). Each function words it its own way,
  # and names itself canonically: `stddev_samp` is `stddev`, `var_samp` is
  # `var`.
  @spec time_aggregate_error(binary()) :: map() | nil
  defp time_aggregate_error(col) do
    with [_full, func] <-
           Regex.run(~r/(?i)^\s*(#{@plain_alternation})\s*\(\s*time\s*\)/, col),
         agg when agg not in [:min, :max, :count] <-
           Map.fetch!(@plain_aggregates, String.downcase(func)) do
      name = Atom.to_string(agg)
      call = "'#{name}(Timestamp(ns))'. You might need to add explicit type casts.\n\tCandidate "

      %{
        status: 400,
        body:
          "Error during planning: " <>
            time_aggregate_head(agg, name) <>
            call <> "functions:\n\t#{name}(#{time_aggregate_candidate(agg)})"
      }
    else
      _no_error -> nil
    end
  end

  @spec time_aggregate_head(aggregate(), binary()) :: binary()
  defp time_aggregate_head(:avg, _name) do
    "Execution error: Function 'avg' user-defined coercion failed with \"Error during " <>
      "planning: Avg does not support inputs of type Timestamp(ns).\" No function matches " <>
      "the given name and argument types "
  end

  defp time_aggregate_head(:sum, _name) do
    "Execution error: Function 'sum' user-defined coercion failed with \"Execution error: " <>
      "Sum not supported for Timestamp(ns)\" No function matches the given name and " <>
      "argument types "
  end

  defp time_aggregate_head(_statistic, name) do
    "Function '#{name}' expects NativeType::Numeric but received " <>
      "NativeType::Timestamp(Nanosecond, None) No function matches the given name and " <>
      "argument types "
  end

  @spec time_aggregate_candidate(aggregate()) :: binary()
  defp time_aggregate_candidate(agg) when agg in [:avg, :sum], do: "UserDefined"
  defp time_aggregate_candidate(_statistic), do: "Numeric(1)"

  # Parse: selector_first|last|min|max(field, time)[['value' | 'time']] AS alias.
  # selector_first/last pick the row with the smallest/largest second
  # argument; selector_min/max pick the row with the smallest/largest field.
  @spec parse_selector_column(binary()) :: {:ok, select_column()} | {:error, term()}
  defp parse_selector_column(col) do
    case Regex.run(@selector_pattern, col) do
      [_full, kind, field, ordering, access, alias_name] ->
        selector = String.to_existing_atom(String.downcase(kind))
        # Without a subscript the engine returns the whole struct.
        access = if access == "", do: :struct, else: String.to_existing_atom(access)
        {:ok, {:selector, selector, field, ordering, access, alias_name}}

      _no_match ->
        {:error,
         local_error(
           "selector functions are supported as " <>
             "selector_first|last|min|max(field, time)[['value' | 'time']] AS alias: #{col}"
         )}
    end
  end

  # ---------------------------------------------------------------------------
  # Arithmetic expressions inside aggregates
  #
  # Grammar (recursive descent, standard precedence):
  #   expr   := term   (('+' | '-') term)*
  #   term   := factor (('*' | '/' | '%') factor)*
  #   factor := '-' factor | number | identifier | '(' expr ')'
  #           | function '(' [expr (',' expr)*] ')'
  #
  # `function` is one of `InfluxElixir.Client.Local.SQLFunctions`; any
  # number of arguments parses, and the executor answers a wrong count or
  # type as the engine's planner does.
  # ---------------------------------------------------------------------------

  @expr_token ~r/\s*(?:(\d+\.\d+|\d+)|(\w+)|([()+\-*\/%,]))/

  # `col::INTEGER` is DataFusion's shorthand for `CAST(col AS INTEGER)`.
  @shorthand_cast ~r/(\w+)::(\w+)/

  @doc false
  @spec parse_expr(binary()) :: {:ok, expr()} | {:error, term()}
  def parse_expr(str) do
    with {:ok, tokens} <- tokenize_expr(str),
         {:ok, ast, []} <- parse_sum(tokens) do
      {:ok, ast}
    else
      {:ok, _ast, _leftover} -> {:error, :trailing_tokens}
      {:error, _reason} = error -> error
    end
  end

  # Every non-blank byte must belong to a token; anything the scanner skipped
  # (a comma, a quote) makes the expression invalid.
  @spec tokenize_expr(binary()) :: {:ok, [term()]} | {:error, term()}
  defp tokenize_expr(str) do
    str = Regex.replace(@shorthand_cast, str, "CAST(\\1 AS \\2)")
    matches = Regex.scan(@expr_token, str)

    consumed =
      matches |> Enum.map(fn [full | _groups] -> byte_size(String.trim(full)) end) |> Enum.sum()

    if consumed == byte_size(String.replace(str, ~r/\s/, "")) do
      {:ok, Enum.map(matches, &expr_token/1)}
    else
      {:error, :unexpected_character}
    end
  end

  @spec expr_token([binary()]) :: term()
  defp expr_token([_full, num, "", ""]), do: {:lit, coerce_value(num)}
  defp expr_token([_full, "", ident, ""]), do: {:field, ident}
  defp expr_token([_full, "", "", op]), do: {:tok, op}
  defp expr_token([_full, "", ident]), do: {:field, ident}
  defp expr_token([_full, num]), do: {:lit, coerce_value(num)}

  @spec parse_sum([term()]) :: {:ok, expr(), [term()]} | {:error, term()}
  defp parse_sum(tokens) do
    with {:ok, left, rest} <- parse_product(tokens) do
      parse_sum_tail(left, rest)
    end
  end

  defp parse_sum_tail(left, [{:tok, op} | rest]) when op in ["+", "-"] do
    with {:ok, right, rest} <- parse_product(rest) do
      parse_sum_tail({:op, operator(op), left, right}, rest)
    end
  end

  defp parse_sum_tail(left, rest), do: {:ok, left, rest}

  @spec parse_product([term()]) :: {:ok, expr(), [term()]} | {:error, term()}
  defp parse_product(tokens) do
    with {:ok, left, rest} <- parse_factor(tokens) do
      parse_product_tail(left, rest)
    end
  end

  defp parse_product_tail(left, [{:tok, op} | rest]) when op in ["*", "/", "%"] do
    with {:ok, right, rest} <- parse_factor(rest) do
      parse_product_tail({:op, operator(op), left, right}, rest)
    end
  end

  defp parse_product_tail(left, rest), do: {:ok, left, rest}

  @spec operator(binary()) :: :+ | :- | :* | :/ | :rem
  defp operator("+"), do: :+
  defp operator("-"), do: :-
  defp operator("*"), do: :*
  defp operator("/"), do: :/
  defp operator("%"), do: :rem

  @spec parse_factor([term()]) :: {:ok, expr(), [term()]} | {:error, term()}
  # Unary minus (`-n`, `-(a + b)`), as DataFusion reads it (verified).
  defp parse_factor([{:tok, "-"} | rest]) do
    with {:ok, inner, rest} <- parse_factor(rest), do: {:ok, {:neg, inner}, rest}
  end

  defp parse_factor([{:lit, _value} = lit | rest]), do: {:ok, lit, rest}

  # CAST(expr AS type): the tokens are `CAST`, `(`, the expression, `AS`,
  # the type name and `)`.
  defp parse_factor([{:field, cast}, {:tok, "("} | rest]) when cast in ["CAST", "cast", "Cast"] do
    with {:ok, inner, [{:field, as_kw}, {:field, type}, {:tok, ")"} | rest]}
         when as_kw in ["AS", "as", "As"] <- parse_sum(rest),
         {:ok, target} <- cast_type(type) do
      {:ok, {:cast, inner, target}, rest}
    else
      {:error, _reason} = error -> error
      _shape -> {:error, :invalid_cast}
    end
  end

  defp parse_factor([{:field, name} = field, {:tok, "("} | args] = tokens) do
    case SQLFunctions.lookup(name) do
      nil -> {:ok, field, tl(tokens)}
      function -> parse_call(function, args)
    end
  end

  defp parse_factor([{:field, _name} = field | rest]), do: {:ok, field, rest}

  defp parse_factor([{:tok, "("} | rest]) do
    case parse_sum(rest) do
      {:ok, inner, [{:tok, ")"} | rest]} -> {:ok, inner, rest}
      {:ok, _inner, _rest} -> {:error, :unbalanced_parenthesis}
      {:error, _reason} = error -> error
    end
  end

  defp parse_factor(_tokens), do: {:error, :unexpected_token}

  @spec parse_call(SQLFunctions.name(), [term()]) :: {:ok, expr(), [term()]} | {:error, term()}
  defp parse_call(function, [{:tok, ")"} | rest]), do: {:ok, {:call, function, []}, rest}
  defp parse_call(function, tokens), do: parse_call_args(function, tokens, [])

  defp parse_call_args(function, tokens, args) do
    case parse_sum(tokens) do
      {:ok, arg, [{:tok, ","} | rest]} ->
        parse_call_args(function, rest, [arg | args])

      {:ok, arg, [{:tok, ")"} | rest]} ->
        {:ok, {:call, function, Enum.reverse([arg | args])}, rest}

      {:ok, _arg, _rest} ->
        {:error, :unbalanced_parenthesis}

      {:error, _reason} = error ->
        error
    end
  end

  # The SQL type names DataFusion accepts for the three casts the double
  # performs; anything else (BOOLEAN, TIMESTAMP, ...) is outside the subset.
  @spec cast_type(binary()) :: {:ok, cast_type()} | {:error, term()}
  defp cast_type(type) do
    case String.upcase(type) do
      t when t in ~w(INTEGER INT BIGINT SMALLINT TINYINT) -> {:ok, :integer}
      t when t in ~w(DOUBLE FLOAT REAL) -> {:ok, :float}
      t when t in ~w(VARCHAR STRING TEXT CHAR) -> {:ok, :string}
      _other -> {:error, {:unsupported_cast_type, type}}
    end
  end

  # DATE_BIN(INTERVAL 'N unit', time) → the interval in nanoseconds
  @spec parse_group_by_interval(binary()) ::
          {:ok, pos_integer()} | {:error, term()}
  defp parse_group_by_interval(item) do
    pattern =
      ~r/(?i)^DATE_BIN\s*\(\s*INTERVAL\s+'([^']+)'\s*,\s*time\s*\)$/

    case Regex.run(pattern, item) do
      [_full, interval_str] -> parse_interval(interval_str)
      _no_match -> {:error, local_error("missing GROUP BY DATE_BIN")}
    end
  end

  # Convert "N unit" → nanoseconds
  @spec parse_interval(binary()) :: {:ok, pos_integer()} | {:error, term()}
  defp parse_interval(interval_str) do
    case Regex.run(~r/^\s*(\d+)\s+(\w+)\s*$/, interval_str) do
      [_full, n_str, unit] ->
        {n, ""} = Integer.parse(n_str)
        multiplier = interval_unit_to_ns(String.downcase(unit))

        if multiplier do
          {:ok, n * multiplier}
        else
          {:error, local_error("unknown interval unit: #{unit}")}
        end

      _no_match ->
        {:error, local_error("invalid interval: #{interval_str}")}
    end
  end

  @spec interval_unit_to_ns(binary()) :: pos_integer() | nil
  defp interval_unit_to_ns(unit) when unit in ["second", "seconds"],
    do: 1_000_000_000

  defp interval_unit_to_ns(unit) when unit in ["minute", "minutes"],
    do: 60_000_000_000

  defp interval_unit_to_ns(unit) when unit in ["hour", "hours"],
    do: 3_600_000_000_000

  defp interval_unit_to_ns(unit) when unit in ["day", "days"],
    do: 86_400_000_000_000

  defp interval_unit_to_ns(_unknown), do: nil

  # SELECT DISTINCT col[, col ...] FROM measurement ...
  # SELECT DISTINCT a[, b ...]: plain column names only.
  @spec parse_distinct_select(split(), binary()) ::
          {:ok, parsed_query()} | {:error, term()}
  defp parse_distinct_select(%{columns: columns, table: table, rest: rest}, sql) do
    cond do
      # A DISTINCT over no columns: one empty row if any row qualifies.
      columns == "" ->
        build_distinct_query([], table, rest)

      Regex.match?(~r/^\w+(\s*,\s*\w+)*$/, columns) ->
        build_distinct_query(split_columns(columns), table, rest)

      true ->
        {:error, local_error("unsupported DISTINCT query: #{sql}")}
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
    order_by = parse_order_by(rest)

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
    do: expr |> expr_columns() |> Enum.reject(&(&1 in columns))

  @spec expr_columns(expr()) :: [binary()]
  defp expr_columns({:field, name}), do: [name]
  defp expr_columns({:lit, _value}), do: []
  defp expr_columns({:neg, inner}), do: expr_columns(inner)
  defp expr_columns({:cast, inner, _type}), do: expr_columns(inner)
  defp expr_columns({:op, _op, left, right}), do: expr_columns(left) ++ expr_columns(right)
  defp expr_columns({:call, _name, args}), do: Enum.flat_map(args, &expr_columns/1)

  # Grouped rows have no source point to evaluate an expression against.
  @spec reject_expr_order(order_by()) :: :ok | {:error, term()}
  defp reject_expr_order(order_by) do
    if Enum.any?(order_by, &match?({{:expr, _expr}, _direction}, &1)),
      do: {:error, local_error("ORDER BY an expression is not supported in an aggregate query")},
      else: :ok
  end

  @spec build_distinct_query([binary()], binary(), binary()) ::
          {:ok, parsed_query()} | {:error, map()}
  defp build_distinct_query(columns, measurement, rest) do
    with {:ok, where} <- parse_where(rest),
         {:ok, order_by} <- parse_distinct_order_by(columns, measurement, rest) do
      {:ok, new_query(measurement, where, rest, order_by: order_by, distinct_columns: columns)}
    end
  end

  @spec build_star_query(binary(), binary()) ::
          {:ok, parsed_query()} | {:error, map()}
  defp build_star_query(measurement, rest) do
    with {:ok, where} <- parse_where(rest) do
      {:ok, new_query(measurement, where, rest, [])}
    end
  end

  @spec build_columns_query(binary(), binary(), binary()) ::
          {:ok, parsed_query()} | {:error, term()}
  defp build_columns_query(columns_str, measurement, rest) do
    with {:ok, projection} <- parse_projection_columns(columns_str),
         {:ok, where} <- parse_where(rest) do
      {:ok, new_query(measurement, where, rest, projection_columns: projection)}
    end
  end

  @spec parse_projection_columns(binary()) ::
          {:ok, [projection()]} | {:error, term()}
  defp parse_projection_columns(columns_str) do
    columns =
      columns_str
      |> split_top_level_commas()
      |> Enum.map(&String.trim/1)
      |> Enum.map(&parse_projection_column/1)

    if Enum.any?(columns, &match?({:error, _}, &1)) do
      Enum.find(columns, &match?({:error, _}, &1))
    else
      {:ok, Enum.map(columns, fn {:ok, col} -> col end)}
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
      match = Regex.run(@constant_column, trimmed) ->
        [_full, literal, alias_name] = match
        {:ok, {{:lit, parse_where_value(literal)}, alias_name}}

      Regex.match?(~r/^(?:-?\d+(?:\.\d+)?|'[^']*')$/, trimmed) ->
        {:error, local_error("unsupported column (a constant needs AS alias): #{col}")}

      # A quoted alias keeps a name that needs its quotes (`AS "The Host"`).
      match = Regex.run(~r/^(\w+)(?:\s+AS\s+(\w+|"[^"]+"))?$/i, trimmed) ->
        case match do
          [_full, name] -> {:ok, {name, name}}
          [_full, name, alias_name] -> {:ok, {name, String.trim(alias_name, "\"")}}
        end

      match = Regex.run(~r/^(.+?)\s+AS\s+(\w+|"[^"]+")$/is, trimmed) ->
        [_full, expr_str, alias_name] = match

        case parse_expr(expr_str) do
          {:ok, expr} -> {:ok, {expr, String.trim(alias_name, "\"")}}
          {:error, _reason} -> {:error, local_error("unsupported column: #{col}")}
        end

      true ->
        {:error, local_error("unsupported column (an expression needs AS alias): #{col}")}
    end
  end

  @doc "Parses the `WHERE ...` clause (if any) out of the text after `FROM <table>`."
  @spec parse_where(binary()) ::
          {:ok, [where_node()]} | {:error, map()}
  def parse_where(rest) do
    case run_masked(
           ~r/(?i)WHERE\s+(.+?)(?:\s+GROUP\b|\s+ORDER\b|\s+#{@limit_start}|$)/s,
           rest
         ) do
      [_full_match, clauses_str] -> parse_where_clauses(clauses_str)
      _no_match -> {:ok, []}
    end
  end

  # ---------------------------------------------------------------------------
  # WHERE: a boolean expression over predicates
  #
  #   expr   := term (OR term)*
  #   term   := factor (AND factor)*
  #   factor := NOT factor | '(' expr ')' | predicate
  #
  # AND binds tighter than OR, as in SQL. The result is a conjunction list;
  # OR and NOT appear as nodes inside it, so a plain `a AND b` is still the
  # flat list every executor path already understands.
  # ---------------------------------------------------------------------------

  @spec parse_where_clauses(binary()) :: {:ok, [where_node()]} | {:error, map()}
  defp parse_where_clauses(str) do
    with {:ok, tokens} <- tokenize_where(str),
         {:ok, conj, []} <- where_or(tokens) do
      {:ok, conj}
    else
      {:ok, _conj, _leftover} -> {:error, local_error("unsupported WHERE clause: #{str}")}
      {:error, _reason} = error -> error
    end
  end

  @typep where_token :: :lparen | :rparen | :and | :or | :not | {:pred, binary()}

  # Scans the clause text into grouping parentheses, the three keywords and
  # predicate text. Parentheses that belong to a predicate (`IN (...)`,
  # `now()`) and keywords that belong to one (`NOT IN`, `NOT LIKE`, the AND of
  # `BETWEEN a AND b`) stay inside its text; string literals are opaque.
  @spec tokenize_where(binary()) :: {:ok, [where_token()]} | {:error, map()}
  defp tokenize_where(str) do
    scan_where(str, %{buf: "", depth: 0, between: false, tokens: []})
  end

  @spec scan_where(binary(), map()) :: {:ok, [where_token()]} | {:error, map()}
  defp scan_where(<<>>, state),
    do: {:ok, state |> flush_pred() |> Map.fetch!(:tokens) |> Enum.reverse()}

  defp scan_where(<<q, rest::binary>>, state) when q in [?', ?"] do
    case take_literal(rest, q, []) do
      {:ok, literal, after_quote} -> scan_where(after_quote, append(state, <<q>> <> literal))
      :error -> {:error, local_error("unterminated string literal in WHERE: #{rest}")}
    end
  end

  defp scan_where(<<"(", rest::binary>>, %{depth: 0} = state) do
    if String.trim(state.buf) == "",
      do: scan_where(rest, emit(state, :lparen)),
      else: scan_where(rest, %{append(state, "(") | depth: 1})
  end

  defp scan_where(<<"(", rest::binary>>, state),
    do: scan_where(rest, %{append(state, "(") | depth: state.depth + 1})

  defp scan_where(<<")", rest::binary>>, %{depth: 0} = state),
    do: scan_where(rest, state |> flush_pred() |> emit(:rparen))

  defp scan_where(<<")", rest::binary>>, state),
    do: scan_where(rest, %{append(state, ")") | depth: state.depth - 1})

  defp scan_where(str, %{depth: 0} = state) do
    case {word_boundary?(state.buf), Regex.run(~r/^(AND|OR|NOT)(?=\s|\(|$)/i, str)} do
      {true, [keyword, _word]} ->
        rest = binary_part(str, byte_size(keyword), byte_size(str) - byte_size(keyword))
        scan_keyword(String.upcase(keyword), rest, state)

      _not_a_keyword ->
        <<c::utf8, rest::binary>> = str
        scan_where(rest, append(state, <<c::utf8>>))
    end
  end

  defp scan_where(<<c::utf8, rest::binary>>, state),
    do: scan_where(rest, append(state, <<c::utf8>>))

  # The rest of a quoted literal, through its closing quote; a doubled quote
  # does not close it.
  @spec take_literal(binary(), char(), iodata()) :: {:ok, binary(), binary()} | :error
  defp take_literal(<<q, q, rest::binary>>, q, acc), do: take_literal(rest, q, [q, q | acc])

  defp take_literal(<<q, rest::binary>>, q, acc),
    do: {:ok, [q | acc] |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_literal(<<byte, rest::binary>>, q, acc), do: take_literal(rest, q, [byte | acc])
  defp take_literal(<<>>, _q, _acc), do: :error

  @spec scan_keyword(binary(), binary(), map()) :: {:ok, [where_token()]} | {:error, map()}
  defp scan_keyword("AND", rest, %{between: true} = state),
    do: scan_where(rest, %{append(state, "AND") | between: false})

  defp scan_keyword("AND", rest, state), do: scan_where(rest, state |> flush_pred() |> emit(:and))
  defp scan_keyword("OR", rest, state), do: scan_where(rest, state |> flush_pred() |> emit(:or))

  # A leading NOT negates; one inside a predicate is `NOT IN` / `NOT LIKE` /
  # `NOT BETWEEN`.
  defp scan_keyword("NOT", rest, state) do
    if String.trim(state.buf) == "",
      do: scan_where(rest, emit(state, :not)),
      else: scan_where(rest, append(state, "NOT"))
  end

  @spec word_boundary?(binary()) :: boolean()
  defp word_boundary?(""), do: true
  defp word_boundary?(buf), do: String.ends_with?(buf, [" ", "\n", "\t", "("])

  @spec append(map(), binary()) :: map()
  defp append(state, text) do
    buf = state.buf <> text
    between = state.between or Regex.match?(~r/\bBETWEEN\s*$/i, buf)
    %{state | buf: buf, between: between}
  end

  @spec emit(map(), where_token()) :: map()
  defp emit(state, token), do: %{state | tokens: [token | state.tokens]}

  @spec flush_pred(map()) :: map()
  defp flush_pred(state) do
    case String.trim(state.buf) do
      "" -> %{state | buf: "", between: false}
      text -> %{state | buf: "", between: false, tokens: [{:pred, text} | state.tokens]}
    end
  end

  @spec where_or([where_token()]) :: {:ok, [where_node()], [where_token()]} | {:error, map()}
  defp where_or(tokens) do
    with {:ok, first, rest} <- where_and(tokens) do
      where_collect_or(rest, [first])
    end
  end

  defp where_collect_or([:or | rest], branches) do
    with {:ok, branch, rest} <- where_and(rest), do: where_collect_or(rest, [branch | branches])
  end

  defp where_collect_or(rest, [single]), do: {:ok, single, rest}
  defp where_collect_or(rest, branches), do: {:ok, [{:or, Enum.reverse(branches)}], rest}

  @spec where_and([where_token()]) :: {:ok, [where_node()], [where_token()]} | {:error, map()}
  defp where_and(tokens) do
    with {:ok, first, rest} <- where_factor(tokens) do
      where_collect_and(rest, first)
    end
  end

  defp where_collect_and([:and | rest], conj) do
    with {:ok, next, rest} <- where_factor(rest), do: where_collect_and(rest, conj ++ next)
  end

  defp where_collect_and(rest, conj), do: {:ok, conj, rest}

  @spec where_factor([where_token()]) :: {:ok, [where_node()], [where_token()]} | {:error, map()}
  defp where_factor([:not | rest]) do
    with {:ok, conj, rest} <- where_factor(rest), do: {:ok, [{:not, conj}], rest}
  end

  defp where_factor([:lparen | rest]) do
    case where_or(rest) do
      {:ok, conj, [:rparen | rest]} -> {:ok, conj, rest}
      {:ok, _conj, _rest} -> {:error, local_error("unbalanced parenthesis in WHERE")}
      {:error, _reason} = error -> error
    end
  end

  # A constant predicate is no condition (`[]`, true for every row) or one no
  # row meets (an OR of nothing).
  defp where_factor([{:pred, text} | rest]) do
    case parse_single_where_clause(text) do
      {:ok, :always} -> {:ok, [], rest}
      {:ok, :never} -> {:ok, [{:or, []}], rest}
      {:ok, clause} -> {:ok, [clause], rest}
      {:error, _reason} = error -> error
    end
  end

  defp where_factor(_tokens), do: {:error, local_error("unsupported WHERE clause")}

  # ---------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------

  # IN / NOT IN must be matched before binary operators because they don't
  # contain any of {=, <, >, !} characters that the binary-op scanner looks
  # for. Order: NOT IN before IN (NOT IN substring contains IN).
  # The left side of these is a column or an expression (`abs(x) IS NULL`,
  # `price * 2 IN (...)`); a match whose left side is neither (the words
  # inside a string literal, say) is not one of them.
  @not_in_pattern ~r/^(.+?)\s+NOT\s+IN\s*\((.*)\)\s*$/is
  @in_pattern ~r/^(.+?)\s+IN\s*\((.*)\)\s*$/is
  @is_not_null_pattern ~r/^(.+?)\s+IS\s+NOT\s+NULL$/is
  @is_null_pattern ~r/^(.+?)\s+IS\s+NULL$/is
  @between_pattern ~r/^(.+?)\s+(NOT\s+)?BETWEEN\s+(.+?)\s+AND\s+(.+)$/is
  @like_pattern ~r/^(.+?)\s+(NOT\s+)?(I?LIKE)\s+'(.*)'$/is
  @regex_pattern ~r/^(.+?)\s*(!?~\*?)\s*'(.*)'$/s

  @spec parse_single_where_clause(binary()) ::
          {:ok, where_clause() | :always | :never} | {:error, map()}
  defp parse_single_where_clause(clause) do
    trimmed = String.trim(clause)

    cond do
      match = operand_match(@is_not_null_pattern, trimmed) ->
        [key] = match
        {:ok, {:is_not_null, key, nil}}

      match = operand_match(@is_null_pattern, trimmed) ->
        [key] = match
        {:ok, {:is_null, key, nil}}

      match = operand_match(@not_in_pattern, trimmed) ->
        [key, list_str] = match
        with {:ok, values} <- parse_in_values(key, list_str), do: {:ok, {:not_in, key, values}}

      match = operand_match(@in_pattern, trimmed) ->
        [key, list_str] = match
        with {:ok, values} <- parse_in_values(key, list_str), do: {:ok, {:in, key, values}}

      match = run_masked(@between_pattern, trimmed) ->
        [_full, left, negated, low, high] = match

        with {:ok, operand} <- parse_operand(String.trim(left)),
             do: parse_between(operand, negated != "", String.trim(low), String.trim(high))

      match = run_masked(@like_pattern, trimmed) ->
        [_full, left, negated, kind, pattern] = match

        with {:ok, operand} <- parse_operand(String.trim(left)),
             do:
               {:ok,
                {like_op(negated != ""), operand,
                 like_regex(unescape_literal(pattern), String.upcase(kind) == "ILIKE")}}

      match = run_masked(@regex_pattern, trimmed) ->
        [_full, left, op, pattern] = match

        with {:ok, operand} <- parse_operand(String.trim(left)),
             {:ok, regex} <- compile_sql_regex(unescape_literal(pattern), op) do
          {:ok, {regex_op(op), operand, {regex, op}}}
        end

      constant = constant_predicate(trimmed) ->
        constant

      # A bare column is a boolean predicate (`WHERE b`, `NOT b`).
      Regex.match?(~r/^[A-Za-z_]\w*$/, trimmed) and
          String.upcase(trimmed) not in ~w(TRUE FALSE NULL) ->
        {:ok, {:truthy, trimmed, nil}}

      true ->
        parse_binary_where_clause(trimmed)
    end
  end

  # `WHERE true` and `WHERE false` are conditions that hold for every row or
  # none. Any other lone literal is not a boolean, which the engine's
  # planner refuses (verified), naming the literal in its own rendering.
  @spec constant_predicate(binary()) :: {:ok, :always | :never} | {:error, map()} | nil
  defp constant_predicate(text) do
    cond do
      String.upcase(text) == "TRUE" -> {:ok, :always}
      String.upcase(text) == "FALSE" -> {:ok, :never}
      Regex.match?(~r/^-?\d+$/, text) -> non_boolean_filter("Int64(#{text})", "Int64")
      match?({_float, ""}, parse_float(text)) -> float_filter(text)
      quoted?(text) -> non_boolean_filter(~s|Utf8("#{literal_body(text)}")|, "Utf8")
      true -> nil
    end
  end

  @spec parse_float(binary()) :: {float(), binary()} | :error
  defp parse_float(text) do
    if Regex.match?(~r/^-?(?:\d+\.\d*|\.\d+|\d+(?:\.\d*)?[eE][+-]?\d+)$/, text),
      do: text |> String.replace(~r/^(-?)\./, "\\g{1}0.") |> Float.parse(),
      else: :error
  end

  @spec float_filter(binary()) :: {:error, map()}
  defp float_filter(text) do
    {value, ""} = parse_float(text)

    rendered =
      if value == Float.round(value) and abs(value) < 1.0e15,
        do: Integer.to_string(trunc(value)),
        else: Float.to_string(value)

    non_boolean_filter("Float64(#{rendered})", "Float64")
  end

  @spec non_boolean_filter(binary(), binary()) :: {:error, map()}
  defp non_boolean_filter(expression, type) do
    {:error,
     %{
       status: 400,
       body:
         "Error during planning: Cannot create filter with non-boolean predicate " <>
           "'#{expression}' returning #{type}"
     }}
  end

  # The pattern's captures, cut from the unmasked text, with the first parsed
  # as an operand; nil when the pattern does not match or its left side is not
  # an operand.
  @spec operand_match(Regex.t(), binary()) :: [term()] | nil
  defp operand_match(pattern, text) do
    with [_full, left | rest] <- run_masked(pattern, text),
         {:ok, operand} <- parse_operand(String.trim(left)) do
      [operand | rest]
    else
      _no_match -> nil
    end
  end

  @spec parse_between(operand(), boolean(), binary(), binary()) ::
          {:ok, where_clause()} | {:error, map()}
  defp parse_between(operand, negated, low, high) do
    op = if negated, do: :not_between, else: :between

    if operand == "time" do
      case {parse_time_comparand(low), parse_time_comparand(high)} do
        {{:ok, lo}, {:ok, hi}} -> {:ok, {op, "time", {lo, hi}}}
        {{:error, {:number, type}}, _high} -> {:error, between_type_error(type)}
        {_low, {:error, {:number, type}}} -> {:error, between_type_error(type)}
        {{:error, error}, _high} -> {:error, error}
        {_low, {:error, error}} -> {:error, error}
      end
    else
      {:ok, {op, operand, {between_bound(low), between_bound(high)}}}
    end
  end

  # A NULL bound is null (the comparison is unknown), not the string "null".
  @spec between_bound(binary()) :: term()
  defp between_bound(text) do
    if String.upcase(text) == "NULL", do: nil, else: parse_where_value(text)
  end

  # `~` / `~*` match and `!~` / `!~*` do not match a regular expression,
  # anywhere in the value (unanchored); `*` ignores case. As on the engine
  # (verified): a null is unknown and an invalid pattern fails the query.
  # The engine's regexes are Rust's; the double compiles with Erlang's PCRE,
  # which also accepts backreferences and lookaround the engine refuses.
  @spec regex_op(binary()) :: :regex | :not_regex
  defp regex_op("!" <> _rest), do: :not_regex
  defp regex_op(_match), do: :regex

  @spec compile_sql_regex(binary(), binary()) :: {:ok, Regex.t()} | {:error, map()}
  defp compile_sql_regex(pattern, op) do
    case Regex.compile(pattern, if(String.ends_with?(op, "*"), do: "iu", else: "u")) do
      {:ok, regex} ->
        {:ok, regex}

      {:error, {reason, _position}} ->
        {:error,
         %{
           status: 500,
           body:
             "Optimizer rule 'simplify_expressions' failed\ncaused by\nInvalid regex\n" <>
               "caused by\nExternal error: regex parse error: #{reason}"
         }}
    end
  end

  @spec like_op(boolean()) :: :like | :not_like
  defp like_op(true), do: :not_like
  defp like_op(false), do: :like

  # SQL LIKE: `%` is any run, `_` any single character (a code point:
  # `'caf_'` matches "café", and `ILIKE 'éa'` matches "Éa", verified), `\`
  # makes the next character literal (`'al\%%'` matches "al%pha"); everything
  # else is literal. LIKE is case-sensitive on the engine, ILIKE is not.
  @spec like_regex(binary(), boolean()) :: Regex.t()
  defp like_regex(pattern, case_insensitive) do
    source = pattern |> String.codepoints() |> like_source([])

    Regex.compile!("\\A" <> source <> "\\z", if(case_insensitive, do: "isu", else: "su"))
  end

  @spec like_source([binary()], [binary()]) :: binary()
  defp like_source([], acc), do: acc |> Enum.reverse() |> Enum.join()
  defp like_source(["\\", char | rest], acc), do: like_source(rest, [Regex.escape(char) | acc])
  defp like_source(["%" | rest], acc), do: like_source(rest, [".*" | acc])
  defp like_source(["_" | rest], acc), do: like_source(rest, ["." | acc])
  defp like_source([char | rest], acc), do: like_source(rest, [Regex.escape(char) | acc])

  @comparison_operators %{
    ">=" => :gte,
    "<=" => :lte,
    "!=" => :ne,
    "<>" => :ne,
    ">" => :gt,
    "<" => :lt,
    "=" => :eq
  }

  @spec parse_binary_where_clause(binary()) ::
          {:ok, where_clause() | :always | :never} | {:error, map()}
  defp parse_binary_where_clause(trimmed) do
    # The first operator outside a string literal, the two-character ones
    # before their one-character prefixes.
    case Regex.run(~r/>=|<=|!=|<>|>|<|=/, mask(trimmed), return: :index) do
      nil ->
        {:error, local_error("unsupported WHERE clause: #{trimmed}")}

      [{start, length}] ->
        text = binary_part(trimmed, start, length)
        left = trimmed |> binary_part(0, start) |> String.trim()

        right =
          trimmed
          |> binary_part(start + length, byte_size(trimmed) - start - length)
          |> String.trim()

        comparison_clause(text, left, right, trimmed)
    end
  end

  @spec comparison_clause(binary(), binary(), binary(), binary()) ::
          {:ok, where_clause() | :always | :never} | {:error, map()}
  defp comparison_clause(text, "time", right, _trimmed) do
    op = Map.fetch!(@comparison_operators, text)

    case parse_time_comparand(right) do
      {:ok, value} -> {:ok, {op, "time", value}}
      {:error, {:number, type}} -> {:error, comparison_type_error("Timestamp(ns)", text, type)}
      {:error, _reason} = error -> error
    end
  end

  # A literal on the left (`1 < abs(x)`, `'2024-01-01' <= time`) is the
  # same comparison turned around. It was read as a column named `1`:
  # the engine's schema error, for a query the engine answers.
  defp comparison_clause(text, left, "time", trimmed) do
    op = Map.fetch!(@comparison_operators, text)

    with true <- literal?(left),
         {:ok, value} <- parse_time_comparand(left) do
      {:ok, {mirror(op), "time", value}}
    else
      {:error, {:number, type}} -> {:error, comparison_type_error(type, text, "Timestamp(ns)")}
      false -> {:error, local_error("unsupported WHERE clause: #{trimmed}")}
      {:error, _reason} = error -> error
    end
  end

  defp comparison_clause(text, left, right, trimmed) do
    op = Map.fetch!(@comparison_operators, text)

    cond do
      literal?(left) and literal?(right) -> constant_comparison(op, left, right, trimmed)
      literal?(left) -> comparison(mirror(op), right, left)
      true -> comparison(op, left, right)
    end
  end

  # Two literals compare to a constant: every row or none. Numbers compare as
  # numbers, strings as text; the engine casts across the two, which the
  # double does not.
  @spec constant_comparison(where_op(), binary(), binary(), binary()) ::
          {:ok, :always | :never} | {:error, map()}
  defp constant_comparison(op, left, right, trimmed) do
    {l, r} = {parse_where_value(strip_unsigned(left)), parse_where_value(strip_unsigned(right))}

    if (is_number(l) and is_number(r)) or (is_binary(l) and is_binary(r)) or
         (is_boolean(l) and is_boolean(r)),
       do: {:ok, if(compare_constants(op, l, r), do: :always, else: :never)},
       else: {:error, local_error("unsupported WHERE clause: #{trimmed}")}
  end

  @spec compare_constants(where_op(), term(), term()) :: boolean()
  defp compare_constants(:eq, l, r), do: l == r
  defp compare_constants(:ne, l, r), do: l != r
  defp compare_constants(:gt, l, r), do: l > r
  defp compare_constants(:lt, l, r), do: l < r
  defp compare_constants(:gte, l, r), do: l >= r
  defp compare_constants(:lte, l, r), do: l <= r

  @spec comparison(where_op(), binary(), binary()) :: {:ok, where_clause()} | {:error, map()}
  defp comparison(op, operand, comparand) do
    with {:ok, left} <- parse_operand(operand),
         {:ok, value} <- parse_comparand(comparand),
         do: {:ok, {op, left, value}}
  end

  @spec literal?(binary()) :: boolean()
  defp literal?(text) do
    text = strip_unsigned(text)
    quoted?(text) or text in ["true", "false"] or is_number(coerce_value(text))
  end

  @spec mirror(where_op()) :: where_op()
  defp mirror(:gt), do: :lt
  defp mirror(:lt), do: :gt
  defp mirror(:gte), do: :lte
  defp mirror(:lte), do: :gte
  defp mirror(op), do: op

  # The left side is a column, or an arithmetic expression over columns
  # (`2 * price > volume`).
  @spec parse_operand(binary()) :: {:ok, operand()} | {:error, map()}
  defp parse_operand(text) do
    cond do
      Regex.match?(~r/^\w+$/, text) ->
        {:ok, text}

      match?({:ok, _expr}, parse_expr(text)) ->
        {:ok, expr} = parse_expr(text)
        {:ok, {:expr, expr}}

      true ->
        {:error, local_error("unsupported WHERE clause: #{text}")}
    end
  end

  # The right side is a literal, or an expression over columns and literals.
  # A bare word is a column reference, as in SQL — never a string.
  @spec parse_comparand(binary()) :: {:ok, term()} | {:error, map()}
  defp parse_comparand(text) do
    cond do
      quoted?(text) or text in ["true", "false"] ->
        {:ok, parse_where_value(text)}

      String.upcase(text) == "NULL" ->
        {:ok, nil}

      is_number(coerce_value(text)) ->
        {:ok, coerce_value(text)}

      match?({:ok, _expr}, parse_expr(text)) ->
        {:ok, expr} = parse_expr(text)
        {:ok, {:expr, expr}}

      true ->
        {:error, local_error("unsupported WHERE clause: #{text}")}
    end
  end

  @spec parse_in_values(binary(), binary()) :: {:ok, [term()]} | {:error, map()}
  defp parse_in_values(key, str) do
    items =
      str
      |> split_top_level_commas()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if key == "time", do: parse_time_set(items), else: parse_value_set(items)
  end

  # Each item is a comparand: a literal, or — as in SQL — a column
  # reference or expression (`v IN (1, other)`). Source order is kept so
  # the schema check names the first unknown column, as the engine does.
  @spec parse_value_set([binary()]) :: {:ok, [term()]} | {:error, map()}
  defp parse_value_set(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case parse_comparand(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  # A bare number among the items fails the whole list, which the engine
  # words with every item's type, a string being `Utf8`.
  @spec parse_time_set([binary()]) :: {:ok, [term()]} | {:error, map()}
  defp parse_time_set(items) do
    parsed = Enum.map(items, &parse_time_comparand/1)

    if Enum.any?(parsed, &match?({:error, {:number, _type}}, &1)) do
      types =
        Enum.map(parsed, fn
          {:error, {:number, type}} -> type
          _other -> "Utf8"
        end)

      {:error,
       coercion_error(
         "Can not find compatible types to compare Timestamp(ns) with [#{Enum.join(types, ", ")}]"
       )}
    else
      parsed
      |> Enum.find(&match?({:error, _reason}, &1))
      |> case do
        nil -> {:ok, Enum.map(parsed, fn {:ok, value} -> value end)}
        {:error, _reason} = error -> error
      end
    end
  end

  # What the engine accepts as a `time` comparand: a quoted ISO-8601
  # datetime (zoned or not, optional fraction), a quoted date (midnight
  # UTC), or `now()` offset by `+`/`-` `INTERVAL 'N unit'` terms. DataFusion
  # fails planning for a bare number (`{:error, {:number, type}}` here, for
  # the caller to word as its clause does) and fails execution for any
  # other string ("Error parsing timestamp"), so those are refused here
  # instead of silently matching no rows.
  @now_pattern ~r/^now\(\)((?:\s*[+-]\s*INTERVAL\s*'[^']*')*)$/i
  @interval_term ~r/([+-])\s*INTERVAL\s*'([^']*)'/i

  @spec parse_time_comparand(binary()) ::
          {:ok, time_value()} | {:error, map() | {:number, binary()}}
  defp parse_time_comparand(str) do
    cond do
      quoted?(str) -> parse_time_literal(literal_body(str), str)
      match = Regex.run(@now_pattern, str) -> parse_now_offset(match)
      type = number_type(str) -> {:error, {:number, type}}
      true -> {:error, invalid_time_error(str)}
    end
  end

  # A parameter's integer is `UInt64` to the engine when it is not negative
  # (it arrives as JSON), a literal's `Int64`. `resolve_params/2` marks the
  # former where it stands beside `time`, and this is the one place that
  # reads the mark.
  @unsigned "\u{E000}"

  @spec strip_unsigned(binary()) :: binary()
  defp strip_unsigned(@unsigned <> text), do: text
  defp strip_unsigned(text), do: text

  @spec number_type(binary()) :: binary() | nil
  defp number_type(str) do
    text = strip_unsigned(str)

    cond do
      Regex.match?(~r/^-?\d+$/, text) -> if str == text, do: "Int64", else: "UInt64"
      Regex.match?(~r/^-?(?:\d+\.\d*|\.\d+|\d+(?:\.\d*)?[eE][+-]?\d+)$/, text) -> "Float64"
      true -> nil
    end
  end

  @spec comparison_type_error(binary(), binary(), binary()) :: map()
  defp comparison_type_error(left, operator, right) do
    operator = if operator == "<>", do: "!=", else: operator

    coercion_error(
      "Cannot infer common argument type for comparison operation #{left} #{operator} #{right}"
    )
  end

  @spec between_type_error(binary()) :: map()
  defp between_type_error(type) do
    %{
      status: 500,
      body:
        "type_coercion\ncaused by\nInternal error: Failed to coerce types Timestamp(ns) and " <>
          "#{type} in BETWEEN expression.\nThis issue was likely caused by a bug in " <>
          "DataFusion's code. Please help us to resolve this by filing a bug report in our " <>
          "issue tracker: https://github.com/apache/datafusion/issues"
    }
  end

  @spec coercion_error(binary()) :: map()
  defp coercion_error(message),
    do: %{status: 400, body: "type_coercion\ncaused by\nError during planning: " <> message}

  # One literal, not two joined by an operator: `'a'`, `"a"`, and not `'a' = 'b'`.
  @spec quoted?(binary()) :: boolean()
  defp quoted?(str), do: Regex.match?(~r/\A(?:'x*'|"x*")\z/, mask(str))

  # The text between a literal's quotes, with a doubled quote one quote.
  @spec literal_body(binary()) :: binary()
  defp literal_body(str), do: str |> String.slice(1..-2//1) |> unescape_literal()

  @spec parse_time_literal(binary(), binary()) :: {:ok, integer()} | {:error, map()}
  # Elixir's calendar types stop at microseconds, so fraction digits seven
  # to nine are split off and added back as nanoseconds: the engine compares
  # '...:20.0000002Z' exactly (verified), and so must the double.
  defp parse_time_literal(literal, original) do
    {literal, extra_ns} = split_sub_microseconds(literal)

    with :error <- zoned_to_ns(literal),
         :error <- naive_to_ns(literal),
         :error <- date_to_ns(literal) do
      {:error, invalid_time_error(original)}
    else
      {:ok, ns} -> {:ok, ns + extra_ns}
    end
  end

  @sub_microsecond ~r/^(?<head>.*T\d{2}:\d{2}:\d{2}\.\d{6})(?<sub>\d{1,3})\d*(?<zone>Z|[+-]\d{2}:?\d{2})?$/

  @spec split_sub_microseconds(binary()) :: {binary(), non_neg_integer()}
  defp split_sub_microseconds(literal) do
    case Regex.named_captures(@sub_microsecond, literal) do
      %{"head" => head, "sub" => sub, "zone" => zone} ->
        {head <> zone, sub |> String.pad_trailing(3, "0") |> String.to_integer()}

      nil ->
        {literal, 0}
    end
  end

  @spec zoned_to_ns(binary()) :: {:ok, integer()} | :error
  defp zoned_to_ns(literal) do
    case DateTime.from_iso8601(literal) do
      {:ok, dt, _offset} -> {:ok, DateTime.to_unix(dt, :nanosecond)}
      {:error, _reason} -> :error
    end
  end

  @spec naive_to_ns(binary()) :: {:ok, integer()} | :error
  defp naive_to_ns(literal) do
    case NaiveDateTime.from_iso8601(literal) do
      {:ok, naive} ->
        {:ok, naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:nanosecond)}

      {:error, _reason} ->
        :error
    end
  end

  @spec date_to_ns(binary()) :: {:ok, integer()} | :error
  defp date_to_ns(literal) do
    case Date.from_iso8601(literal) do
      {:ok, date} ->
        {:ok, date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix(:nanosecond)}

      {:error, _reason} ->
        :error
    end
  end

  @spec parse_now_offset([binary()]) :: {:ok, {:now, integer()}} | {:error, map()}
  defp parse_now_offset([_full, terms]) do
    @interval_term
    |> Regex.scan(terms)
    |> Enum.reduce_while({:ok, {:now, 0}}, fn [_term, sign, interval], {:ok, {:now, acc}} ->
      case parse_interval(interval) do
        {:ok, ns} when sign == "-" -> {:cont, {:ok, {:now, acc - ns}}}
        {:ok, ns} -> {:cont, {:ok, {:now, acc + ns}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec invalid_time_error(binary()) :: %{status: 400, body: binary()}
  defp invalid_time_error(str) do
    local_error(
      "InfluxDB rejects this `time` comparand (a Timestamp compares only with an " <>
        "ISO-8601 string or now() +/- INTERVAL 'N unit', never a bare integer): " <>
        strip_unsigned(str)
    )
  end

  # A quoted literal is a string, full stop — exactly as in InfluxDB v3.
  # Re-typing `'08338636'` as an integer would drop the leading zero and
  # change the type, so `WHERE repcode = '08338636'` could never match a
  # string tag (#12). Only bare literals are typed.
  @spec parse_where_value(binary()) :: term()
  defp parse_where_value(str) do
    cond do
      quoted?(str) ->
        literal_body(str)

      str == "true" ->
        true

      str == "false" ->
        false

      true ->
        coerce_value(str)
    end
  end

  # Type a bare literal: integer, then float, else leave it as a string.
  @spec coerce_value(binary()) :: term()
  defp coerce_value(str) do
    case Integer.parse(str) do
      {n, ""} ->
        n

      _no_int ->
        case Float.parse(str) do
          {f, ""} -> f
          _no_parse -> str
        end
    end
  end

  # ORDER BY <column> [ASC|DESC]. The column is `time` or an output alias
  # (e.g. the DATE_BIN alias); direction defaults to ASC as in SQL.
  @spec parse_order_by(binary()) :: order_by()
  # `ORDER BY a [ASC|DESC][, b [ASC|DESC] ...]`; a target may be a column,
  # an output alias or an expression (`CAST(level AS INTEGER) DESC`). A
  # target the expression parser cannot read is left as a column name so
  # the schema check names it.
  defp parse_order_by(rest) do
    case run_masked(~r/(?i)ORDER\s+BY\s+(.+?)\s*(?:\b#{@limit_start}.*)?$/s, rest) do
      [_full_match, list] ->
        list
        |> split_top_level_commas()
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&parse_order_term/1)

      _no_match ->
        []
    end
  end

  @spec parse_order_term(binary()) :: {binary() | {:expr, expr()}, :asc | :desc}
  # `[ASC|DESC] [NULLS FIRST|LAST]`. Without NULLS, DataFusion puts nulls
  # last ascending and first descending (verified); the direction then
  # stays a bare atom and the executor applies that default.
  defp parse_order_term(term) do
    case run_masked(~r/^(.+?)(?:\s+(ASC|DESC))?(?:\s+NULLS\s+(FIRST|LAST))?$/is, term) do
      [_full, target] ->
        {order_target(String.trim(target)), :asc}

      [_full, target, direction] ->
        {order_target(String.trim(target)), direction_atom(direction)}

      [_full, target, direction, nulls] ->
        dir = if direction == "", do: :asc, else: direction_atom(direction)
        nulls = if String.upcase(nulls) == "FIRST", do: :nulls_first, else: :nulls_last
        {order_target(String.trim(target)), {dir, nulls}}
    end
  end

  @spec order_target(binary()) :: binary() | {:expr, expr()}
  defp order_target(target) do
    if Regex.match?(~r/^\w+$/, target) do
      target
    else
      case parse_expr(target) do
        {:ok, expr} -> {:expr, expr}
        {:error, _reason} -> target
      end
    end
  end

  @spec direction_atom(binary()) :: :asc | :desc
  defp direction_atom(direction) do
    if String.upcase(direction) == "DESC", do: :desc, else: :asc
  end

  @spec parse_limit(binary()) :: non_neg_integer() | nil
  defp parse_limit(rest), do: clause_count(~r/(?i)(?<![\w.])LIMIT\s+(\d+)/s, rest)

  @spec parse_offset(binary()) :: non_neg_integer() | nil
  defp parse_offset(rest), do: clause_count(~r/(?i)(?<![\w.])OFFSET\s+(\d+)/s, rest)

  @spec clause_count(Regex.t(), binary()) :: non_neg_integer() | nil
  defp clause_count(pattern, rest) do
    case Regex.run(pattern, mask(rest)) do
      [_full_match, n_str] -> String.to_integer(n_str)
      _no_match -> nil
    end
  end

  @doc """
  The first `$name` placeholder left in `sql` after substitution, or `nil`.
  String literals are ignored: a substituted value that happens to contain
  `$` is text.
  """
  @spec unbound_placeholder(binary()) :: binary() | nil
  def unbound_placeholder(sql) do
    case Regex.run(~r/\$\w+/, mask(sql)) do
      [name] -> name
      nil -> nil
    end
  end

  @doc """
  Substitutes `$name` placeholders with SQL literals built from `params`.

  A value is only ever data: a string becomes one quoted literal, its own
  quotes doubled, so `"x' OR 1 = 1 OR name = 'y"` is a (never matching)
  string and not a condition. Placeholders inside the query's own string
  literals are left as they are.
  """
  @spec resolve_params(binary(), map()) :: binary()
  def resolve_params(sql, params) when map_size(params) == 0, do: sql

  # One pass over the SQL, whole placeholders only: a sequential
  # String.replace/3 per param rewrote `$a` inside `$ab` and could
  # re-substitute inside an already-substituted value.
  def resolve_params(sql, params) do
    lookup = Map.new(params, fn {key, value} -> {normalize_param_key(key), value} end)

    ~r/'(?:[^']|'')*'|"[^"]*"|\$\w+/
    |> Regex.scan(sql, return: :index)
    |> Enum.reduce({0, []}, fn [{start, length}], {from, acc} ->
      kept = binary_part(sql, from, start - from)
      token = binary_part(sql, start, length)
      {start + length, [substitute(token, lookup, sql, start, length), kept | acc]}
    end)
    |> then(fn {from, acc} ->
      [binary_part(sql, from, byte_size(sql) - from) | acc]
      |> Enum.reverse()
      |> IO.iodata_to_binary()
    end)
  end

  @spec substitute(binary(), map(), binary(), non_neg_integer(), non_neg_integer()) :: binary()
  defp substitute("$" <> _name = placeholder, lookup, sql, start, length) do
    case Map.fetch(lookup, placeholder) do
      {:ok, value} -> param_literal(value, sql, start, length)
      :error -> placeholder
    end
  end

  defp substitute(quoted, _lookup, _sql, _start, _length), do: quoted

  @spec normalize_param_key(atom() | binary()) :: binary()
  defp normalize_param_key(key) when is_atom(key), do: "$#{key}"
  defp normalize_param_key("$" <> _rest = key), do: key
  defp normalize_param_key(key) when is_binary(key), do: "$#{key}"

  # A non-negative integer standing in a comparison with `time` is marked
  # `UInt64` (see `number_type/1`); everywhere else it is a plain literal.
  @spec param_literal(term(), binary(), non_neg_integer(), non_neg_integer()) :: binary()
  defp param_literal(value, sql, start, length) when is_integer(value) and value >= 0 do
    before = binary_part(sql, 0, start)
    after_text = binary_part(sql, start + length, byte_size(sql) - start - length)
    literal = Integer.to_string(value)
    if beside_time?(before, after_text), do: @unsigned <> literal, else: literal
  end

  defp param_literal(value, _sql, _start, _length), do: to_sql_literal(value)

  @spec beside_time?(binary(), binary()) :: boolean()
  defp beside_time?(before, after_text) do
    Regex.match?(~r/(?i)\btime\s*(?:<=|>=|<>|!=|=|<|>)\s*\z/, before) or
      Regex.match?(~r/(?i)\btime\s+(?:NOT\s+)?IN\s*\((?:[^()]*,)?\s*\z/, before) or
      Regex.match?(~r/(?i)\btime\s+(?:NOT\s+)?BETWEEN\s+(?:\S+\s+AND\s+)?\z/, before) or
      Regex.match?(~r/(?i)\A\s*(?:<=|>=|<>|!=|=|<|>)\s*time\b/, after_text)
  end

  # Calendar params render as the ISO-8601 strings Jason sends over HTTP, so
  # `time >= $start` with a DateTime behaves the same on both clients.
  @spec to_sql_literal(term()) :: binary()
  # `decimal` is an optional dependency: matching `%Decimal{}` would need
  # the struct at compile time, and the library failed to compile in a
  # project without it (verified). A Decimal is bound as the JSON number
  # Client.HTTP sends.
  defp to_sql_literal(%{__struct__: Decimal} = value), do: Decimal.to_string(value, :normal)
  defp to_sql_literal(%DateTime{} = value), do: quote_text(DateTime.to_iso8601(value))
  defp to_sql_literal(%NaiveDateTime{} = value), do: quote_text(NaiveDateTime.to_iso8601(value))
  defp to_sql_literal(%Date{} = value), do: quote_text(Date.to_iso8601(value))
  defp to_sql_literal(value) when is_binary(value), do: quote_text(value)
  defp to_sql_literal(value) when is_integer(value), do: Integer.to_string(value)
  defp to_sql_literal(value) when is_float(value), do: Float.to_string(value)
  defp to_sql_literal(true), do: "true"
  defp to_sql_literal(false), do: "false"
  # Jason sends nil as JSON null; `col = NULL` is never true on the engine.
  defp to_sql_literal(nil), do: "NULL"
  defp to_sql_literal(value), do: value |> inspect() |> quote_text()

  @spec quote_text(binary()) :: binary()
  defp quote_text(text), do: "'" <> String.replace(text, "'", "''") <> "'"

  # Every parser rejection carries this prefix so a consumer reading
  # "unsupported ..." knows the test double, not InfluxDB, refused the query.
  @spec local_error(binary()) :: %{status: 400, body: binary()}
  defp local_error(message), do: %{status: 400, body: "Client.Local: " <> message}
end
