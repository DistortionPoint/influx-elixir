defmodule InfluxElixir.Client.Local.SQLParser do
  @moduledoc """
  SQL parser for `InfluxElixir.Client.Local`.

  Recognises the SQL subset documented on `InfluxElixir.Client.Local` and
  produces a `t:parsed_query/0` for the executor. It is deliberately strict:
  anything the real InfluxDB v3 engine would reject — or that the double
  cannot execute faithfully — is refused with a `Client.Local:`-prefixed 400
  so a query cannot pass tests here and fail in production.

  Pure functions only: no ETS, no connection state.
  """

  alias InfluxElixir.Client.Local.LineProtocolParser

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
          | {:selector, :first | :last | :min | :max, binary(), binary(), :value | :time,
             binary()}
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
          group_by_interval: pos_integer() | nil,
          group_by_columns: [binary()] | nil,
          select_columns: [select_column()] | nil,
          distinct_columns: [binary()] | nil,
          projection_columns: [projection()] | nil,
          ctes: [{binary(), parsed_query()}],
          cross_join: {binary(), [binary()]} | nil
        }

  @typedoc """
  A `WHERE` operand: a column name, or an arithmetic expression over columns
  and literals (`price <= med * 3`).
  """
  @type operand :: binary() | {:expr, expr()}

  # Aggregate function names recognised by the parser (all verified against
  # InfluxDB 3 Core; VARIANCE is *not* one of them).
  @aggregate_functions ~w(AVG SUM COUNT MIN MAX MEDIAN STDDEV STDDEV_SAMP STDDEV_POP VAR_SAMP VAR_POP VAR FIRST_VALUE LAST_VALUE SELECTOR_FIRST SELECTOR_LAST SELECTOR_MIN SELECTOR_MAX)

  @aggregate_atoms %{
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

  # selector_first|last|min|max(field, time)['value'|'time'] AS alias
  @selector_pattern ~r/(?i)^\s*SELECTOR_(FIRST|LAST|MIN|MAX)\s*\(\s*(\w+)\s*,\s*(\w+)\s*\)\s*\[\s*'(value|time)'\s*\]\s+AS\s+(\w+)\s*$/

  # InfluxQL selector functions that InfluxDB v3 SQL does not provide. They are
  # routed into the aggregate parser only so the rejection can name the fix.
  @influxql_only_functions ~w(FIRST LAST)

  # first_value(field ORDER BY col [ASC|DESC]) AS alias  (and last_value).
  # The ORDER BY group is optional in the grammar so a missing one can be
  # reported specifically instead of as a generic parse failure.
  @ordered_agg_pattern ~r/(?i)^\s*(FIRST_VALUE|LAST_VALUE)\s*\(\s*(\w+)\s*(?:ORDER\s+BY\s+(\w+)(?:\s+(ASC|DESC))?\s*)?\)\s+AS\s+(\w+)\s*$/

  @doc """
  Parses a statement — an optional `WITH` list of non-recursive CTEs followed
  by one `SELECT` — into a `t:parsed_query/0`.
  """
  @spec parse_select(binary()) :: {:ok, parsed_query()} | {:error, term()}
  def parse_select(sql) do
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

  # Splits `str` at the parenthesis that closes the one already opened.
  @spec take_balanced(binary()) :: {:ok, binary(), binary()} | :error
  defp take_balanced(str), do: take_balanced(str, 1, [])

  defp take_balanced(<<>>, _depth, _acc), do: :error

  defp take_balanced(<<")", rest::binary>>, 1, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_balanced(<<")", rest::binary>>, depth, acc),
    do: take_balanced(rest, depth - 1, [")" | acc])

  defp take_balanced(<<"(", rest::binary>>, depth, acc),
    do: take_balanced(rest, depth + 1, ["(" | acc])

  defp take_balanced(<<c::utf8, rest::binary>>, depth, acc),
    do: take_balanced(rest, depth, [<<c::utf8>> | acc])

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

    with :ok <- check_clauses(normalised),
         {:ok, split} <- split_select(normalised),
         {:ok, split, normalised} <- resolve_references(split, normalised),
         {:ok, query} <- dispatch_select(split, normalised) do
      {:ok, %{query | cross_join: cross_join}}
    end
  end

  # `GROUP BY 1`, `ORDER BY 2 DESC` and `GROUP BY bucket` (a select alias)
  # are rewritten to the select items they name before anything else reads
  # the clauses, as DataFusion resolves them (verified): a position becomes
  # the item's expression in GROUP BY and its output name in ORDER BY, an
  # alias in GROUP BY becomes its expression. A position outside the
  # select list is the engine's planning error.
  @group_clause ~r/(?i)(\bGROUP\s+BY\s+)(.+?)(?=\s+ORDER\b|\s+LIMIT\s+\d|\s+OFFSET\s+\d|\s*$)/s
  @order_clause ~r/(?i)(\bORDER\s+BY\s+)(.+?)(?=\s+LIMIT\s+\d|\s+OFFSET\s+\d|\s*$)/s

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
    case Regex.run(~r/^(.+?)\s+AS\s+"?(\w+)"?$/is, item) do
      [_full, expr, alias_name] -> {String.trim(expr), alias_name}
      nil -> {item, item}
    end
  end

  @spec rewrite_clause(binary(), Regex.t(), (binary() -> {:ok, binary()} | {:error, map()})) ::
          {:ok, binary()} | {:error, map()}
  defp rewrite_clause(rest, pattern, rewrite_term) do
    case Regex.run(pattern, rest, return: :index) do
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
      case Regex.run(~r/^(.+?)\s+(ASC|DESC)$/is, term) do
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
    case Regex.named_captures(@select_pattern, sql) do
      %{
        "distinct" => distinct,
        "columns" => columns,
        "quoted" => quoted,
        "bare" => bare,
        "rest" => rest
      } ->
        table = if quoted != "", do: quoted, else: LineProtocolParser.unescape_measurement(bare)

        {:ok,
         %{distinct: distinct != "", columns: String.trim(columns), table: table, rest: rest}}

      nil ->
        unsupported(sql)
    end
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
    case Regex.run(@cross_join_pattern, sql) do
      [full, left, table] ->
        name = String.trim(table, "\"")
        {String.replace(sql, full, left), {name, [name]}}

      [full, left, table, alias_name] ->
        name = String.trim(table, "\"")
        {String.replace(sql, full, left), {name, [name, alias_name]}}

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
    scannable = blank_literals(sql)

    with :ok <- check_constructs(scannable, sql),
         :ok <- check_single_select(scannable, sql),
         :ok <- check_limit(scannable, sql),
         {:ok, %{rest: rest}} <- split_select(scannable) do
      [next] = Regex.run(~r/^\w*/, rest)
      if next == "" or String.upcase(next) in @clause_keywords, do: :ok, else: unsupported(sql)
    end
  end

  @spec blank_literals(binary()) :: binary()
  defp blank_literals(sql), do: Regex.replace(~r/'[^']*'/, sql, "''")

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
  # is the keyword followed by a number — a column called `offset` stays a
  # column. The engine plans a negative value as "LIMIT must be >= 0" /
  # "OFFSET must be >=0" and accepts 0 for both.
  @spec check_limit(binary(), binary()) :: :ok | {:error, term()}
  defp check_limit(scannable, sql) do
    cond do
      Regex.match?(~r/(?i)\bLIMIT\s+-\d+/, scannable) ->
        {:error, local_error("LIMIT must be >= 0: #{sql}")}

      Regex.match?(~r/(?i)\bOFFSET\s+-\d+/, scannable) ->
        {:error, local_error("OFFSET must be >=0: #{sql}")}

      Regex.match?(~r/(?i)\bLIMIT\s+(?!\d)\S/, scannable) ->
        {:error, local_error("unsupported LIMIT (a non-negative integer is required): #{sql}")}

      match = Regex.run(~r/(?i)\b((?:LIMIT|OFFSET)\s+\d+.*)$/s, scannable) ->
        [_full, tail] = match

        if Regex.match?(~r/(?i)^(?:(?:LIMIT|OFFSET)\s+\d+\s*){1,2}$/, tail),
          do: :ok,
          else:
            {:error,
             local_error(
               "unsupported LIMIT / OFFSET (non-negative integers are required): #{sql}"
             )}

      true ->
        :ok
    end
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

    case Regex.run(@from_alias_pattern, sql) do
      [_full, from_clause, table, alias_name] ->
        alias_pattern =
          ~r/(?i)(#{Regex.escape(from_clause)})\s+(?:AS\s+)?#{Regex.escape(alias_name)}\b/

        sql
        |> String.replace(alias_pattern, "\\1")
        |> drop_qualifiers([String.trim(table, "\""), alias_name | joined_names])

      [_full, _from_clause, table] ->
        drop_qualifiers(sql, [String.trim(table, "\"") | joined_names])

      nil ->
        sql
    end
  end

  @spec drop_qualifiers(binary(), [binary()]) :: binary()
  defp drop_qualifiers(sql, qualifiers) do
    names = qualifiers |> Enum.map(&Regex.escape/1) |> Enum.join("|")
    pattern = ~r/'[^']*'|(?<![\w."])(?:#{names})\.(?=\w)/

    Regex.replace(pattern, sql, fn
      "'" <> _rest = literal -> literal
      _qualifier -> ""
    end)
  end

  @spec aggregate_query?(binary()) :: boolean()
  # A GROUP BY without an aggregate (`SELECT host FROM p GROUP BY host`) is
  # still a grouped query: one row per group, the grouping columns projected.
  defp aggregate_query?(sql) do
    upper = String.upcase(sql)

    String.contains?(upper, "DATE_BIN") or
      Regex.match?(~r/\bGROUP\s+BY\b/, upper) or
      Enum.any?(
        @aggregate_functions ++ @influxql_only_functions,
        &String.contains?(upper, &1 <> "(")
      )
  end

  @spec parse_aggregate_select(split(), binary()) ::
          {:ok, parsed_query()} | {:error, term()}
  defp parse_aggregate_select(%{table: measurement, rest: rest} = split, sql) do
    with {:ok, columns} <- parse_select_list(split.columns),
         {:ok, interval_ns} <- resolve_aggregate_interval(sql),
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
    case Regex.run(@group_clause, sql) do
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
          {:ok, pos_integer() | nil} | {:error, term()}
  defp resolve_aggregate_interval(sql) do
    case Enum.find(group_by_items(sql), &date_bin_item?/1) do
      nil -> {:ok, nil}
      item -> parse_group_by_interval(item)
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

  # Split column list by commas, respecting parentheses nesting
  @spec split_top_level_commas(binary()) :: [binary()]
  defp split_top_level_commas(str) do
    {last, acc} =
      str
      |> String.graphemes()
      |> Enum.reduce({[], [], 0}, fn
        ",", {current, acc, 0} ->
          token = current |> Enum.reverse() |> Enum.join()
          {[], [token | acc], 0}

        "(", {current, acc, depth} ->
          {["(" | current], acc, depth + 1}

        ")", {current, acc, depth} ->
          {[")" | current], acc, max(depth - 1, 0)}

        char, {current, acc, depth} ->
          {[char | current], acc, depth}
      end)
      |> then(fn {current, acc, _depth} ->
        token = current |> Enum.reverse() |> Enum.join()
        {token, acc}
      end)

    Enum.reverse([last | acc])
  end

  # Parse a single SELECT column expression
  # A constant in the select list (`0.0 AS volume`, `'x' AS label`) needs an
  # alias: DataFusion names an unaliased one after its own rendering
  # (`Int64(1)`), which the double will not guess.
  @constant_column ~r/^\s*(-?\d+(?:\.\d+)?|'[^']*')\s+AS\s+(\w+)\s*$/i

  @spec parse_single_column(binary()) ::
          {:ok, select_column()} | {:error, term()}
  defp parse_single_column(col) do
    cond do
      String.match?(col, ~r/(?i)DATE_BIN\s*\(/) ->
        parse_date_bin_column(col)

      String.match?(col, ~r/(?i)\b(FIRST_VALUE|LAST_VALUE)\s*\(/) ->
        parse_ordered_agg_column(col)

      String.match?(col, ~r/(?i)\bSELECTOR_(FIRST|LAST|MIN|MAX)\s*\(/) ->
        parse_selector_column(col)

      String.match?(col, ~r/(?i)\b(FIRST|LAST)\s*\(/) ->
        {:error, influxql_selector_error(col)}

      String.match?(
        col,
        ~r/(?i)\b(AVG|SUM|COUNT|MIN|MAX|MEDIAN|STDDEV|STDDEV_SAMP|STDDEV_POP|VAR|VAR_SAMP|VAR_POP)\s*\(/
      ) ->
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

  # FIRST()/LAST() are InfluxQL selectors. Accepting them here would certify a
  # query the real engine rejects ("Invalid function 'last'"), so refuse and
  # point at the v3 SQL spelling.
  @spec influxql_selector_error(binary()) :: map()
  defp influxql_selector_error(col) do
    local_error(
      "FIRST()/LAST() are InfluxQL selector functions that InfluxDB v3 SQL " <>
        "does not provide (the real engine fails planning with " <>
        "\"Invalid function\"). Use first_value(field ORDER BY time) / " <>
        "last_value(field ORDER BY time) instead: #{col}"
    )
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
    one_arg =
      ~r/(?i)^\s*(AVG|SUM|COUNT|MIN|MAX|MEDIAN|STDDEV_SAMP|STDDEV_POP|STDDEV|VAR_SAMP|VAR_POP|VAR)\s*\((.+)\)\s+AS\s+(\w+)\s*$/s

    with [_full, func, expr_str, alias_name] <- Regex.run(one_arg, col),
         {:ok, expr} <- parse_expr(expr_str),
         agg = Map.fetch!(@aggregate_atoms, String.downcase(func)),
         :ok <- check_time_argument(agg, expr, col) do
      {:ok, {:aggregate, agg, expr, alias_name}}
    else
      {:error, %{status: 400}} = error -> error
      _no_match -> {:error, local_error("invalid aggregate: #{col}")}
    end
  end

  # `time` is a Timestamp column. DataFusion computes MIN, MAX and COUNT over
  # it but fails planning for AVG, SUM and the statistics ("does not support
  # inputs of type Timestamp(ns)") and for any arithmetic on it ("Cannot
  # coerce arithmetic expression Timestamp(ns) - Int64"), so the double
  # refuses those rather than certify a query the engine rejects.
  @spec check_time_argument(aggregate(), expr(), binary()) :: :ok | {:error, term()}
  defp check_time_argument(agg, {:field, "time"}, _col) when agg in [:min, :max, :count],
    do: :ok

  defp check_time_argument(_agg, expr, col) do
    if references_time?(expr) do
      {:error,
       local_error(
         "InfluxDB rejects this aggregate over `time` (Timestamp): only " <>
           "MIN(time), MAX(time) and COUNT(time) are valid: #{col}"
       )}
    else
      :ok
    end
  end

  @spec references_time?(expr()) :: boolean()
  defp references_time?({:field, "time"}), do: true

  defp references_time?({:op, _op, left, right}),
    do: references_time?(left) or references_time?(right)

  defp references_time?({:cast, inner, _type}), do: references_time?(inner)
  defp references_time?(_leaf), do: false

  # Parse: selector_first|last|min|max(field, time)['value' | 'time'] AS alias.
  # selector_first/last pick the row with the smallest/largest second
  # argument; selector_min/max pick the row with the smallest/largest field.
  @spec parse_selector_column(binary()) :: {:ok, select_column()} | {:error, term()}
  defp parse_selector_column(col) do
    case Regex.run(@selector_pattern, col) do
      [_full, kind, field, ordering, access, alias_name] ->
        selector = String.to_existing_atom(String.downcase(kind))
        {:ok, {:selector, selector, field, ordering, String.to_existing_atom(access), alias_name}}

      _no_match ->
        {:error,
         local_error(
           "selector functions are supported as " <>
             "selector_first|last|min|max(field, time)['value' | 'time'] AS alias: #{col}"
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
  # ---------------------------------------------------------------------------

  @expr_token ~r/\s*(?:(\d+\.\d+|\d+)|(\w+)|([()+\-*\/%]))/

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

  defp parse_factor([{:field, _name} = field | rest]), do: {:ok, field, rest}

  defp parse_factor([{:tok, "("} | rest]) do
    case parse_sum(rest) do
      {:ok, inner, [{:tok, ")"} | rest]} -> {:ok, inner, rest}
      {:ok, _inner, _rest} -> {:error, :unbalanced_parenthesis}
      {:error, _reason} = error -> error
    end
  end

  defp parse_factor(_tokens), do: {:error, :unexpected_token}

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
    if Regex.match?(~r/^\w+(\s*,\s*\w+)*$/, columns) do
      build_distinct_query(split_columns(columns), table, rest)
    else
      {:error, local_error("unsupported DISTINCT query: #{sql}")}
    end
  end

  @spec split_columns(binary()) :: [binary()]
  defp split_columns(columns), do: columns |> String.split(",") |> Enum.map(&String.trim/1)

  # DataFusion: "For SELECT DISTINCT, ORDER BY expressions must appear in
  # select list".
  @spec parse_distinct_order_by([binary()], binary()) :: {:ok, order_by()} | {:error, term()}
  defp parse_distinct_order_by(columns, rest) do
    order_by = parse_order_by(rest)

    case Enum.find(order_by, fn {target, _dir} ->
           not (is_binary(target) and target in columns)
         end) do
      nil ->
        {:ok, order_by}

      {target, _direction} ->
        {:error,
         local_error(
           "For SELECT DISTINCT, ORDER BY expressions must appear in select list: " <>
             order_target_text(target)
         )}
    end
  end

  @spec order_target_text(binary() | {:expr, expr()}) :: binary()
  defp order_target_text({:expr, _expr}), do: "expression"
  defp order_target_text(column), do: column

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
         {:ok, order_by} <- parse_distinct_order_by(columns, rest) do
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

      match = Regex.run(~r/^(\w+)(?:\s+AS\s+(\w+))?$/i, trimmed) ->
        case match do
          [_full, name] -> {:ok, {name, name}}
          [_full, name, alias_name] -> {:ok, {name, alias_name}}
        end

      match = Regex.run(~r/^(.+?)\s+AS\s+(\w+)$/is, trimmed) ->
        [_full, expr_str, alias_name] = match

        case parse_expr(expr_str) do
          {:ok, expr} -> {:ok, {expr, alias_name}}
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
    case Regex.run(
           ~r/(?i)WHERE\s+(.+?)(?:\s+GROUP\b|\s+ORDER\b|\s+LIMIT\s+\d|\s+OFFSET\s+\d|$)/s,
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

  defp scan_where(<<"'", rest::binary>>, state) do
    case String.split(rest, "'", parts: 2) do
      [literal, after_quote] -> scan_where(after_quote, append(state, "'" <> literal <> "'"))
      [_unterminated] -> {:error, local_error("unterminated string literal in WHERE: #{rest}")}
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

  defp where_factor([{:pred, text} | rest]) do
    with {:ok, clause} <- parse_single_where_clause(text), do: {:ok, [clause], rest}
  end

  defp where_factor(_tokens), do: {:error, local_error("unsupported WHERE clause")}

  # ---------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------

  # IN / NOT IN must be matched before binary operators because they don't
  # contain any of {=, <, >, !} characters that the binary-op scanner looks
  # for. Order: NOT IN before IN (NOT IN substring contains IN).
  @not_in_pattern ~r/^(\w+)\s+NOT\s+IN\s*\((.*)\)\s*$/is
  @in_pattern ~r/^(\w+)\s+IN\s*\((.*)\)\s*$/is
  @is_not_null_pattern ~r/^(\w+)\s+IS\s+NOT\s+NULL$/i
  @is_null_pattern ~r/^(\w+)\s+IS\s+NULL$/i
  @between_pattern ~r/^(.+?)\s+(NOT\s+)?BETWEEN\s+(.+?)\s+AND\s+(.+)$/is
  @like_pattern ~r/^(.+?)\s+(NOT\s+)?(I?LIKE)\s+'(.*)'$/is

  @spec parse_single_where_clause(binary()) ::
          {:ok, where_clause()} | {:error, map()}
  defp parse_single_where_clause(clause) do
    trimmed = String.trim(clause)

    cond do
      match = Regex.run(@is_not_null_pattern, trimmed) ->
        [_full, key] = match
        {:ok, {:is_not_null, key, nil}}

      match = Regex.run(@is_null_pattern, trimmed) ->
        [_full, key] = match
        {:ok, {:is_null, key, nil}}

      match = Regex.run(@not_in_pattern, trimmed) ->
        [_full, key, list_str] = match
        with {:ok, values} <- parse_in_values(key, list_str), do: {:ok, {:not_in, key, values}}

      match = Regex.run(@in_pattern, trimmed) ->
        [_full, key, list_str] = match
        with {:ok, values} <- parse_in_values(key, list_str), do: {:ok, {:in, key, values}}

      match = Regex.run(@between_pattern, trimmed) ->
        [_full, left, negated, low, high] = match

        with {:ok, operand} <- parse_operand(String.trim(left)),
             do: parse_between(operand, negated != "", String.trim(low), String.trim(high))

      match = Regex.run(@like_pattern, trimmed) ->
        [_full, left, negated, kind, pattern] = match

        with {:ok, operand} <- parse_operand(String.trim(left)),
             do:
               {:ok,
                {like_op(negated != ""), operand,
                 like_regex(pattern, String.upcase(kind) == "ILIKE")}}

      # A bare column is a boolean predicate (`WHERE b`, `NOT b`).
      Regex.match?(~r/^[A-Za-z_]\w*$/, trimmed) and
          String.upcase(trimmed) not in ~w(TRUE FALSE NULL) ->
        {:ok, {:truthy, trimmed, nil}}

      true ->
        parse_binary_where_clause(trimmed)
    end
  end

  @spec parse_between(operand(), boolean(), binary(), binary()) ::
          {:ok, where_clause()} | {:error, map()}
  defp parse_between(operand, negated, low, high) do
    op = if negated, do: :not_between, else: :between

    if operand == "time" do
      with {:ok, lo} <- parse_time_comparand(low),
           {:ok, hi} <- parse_time_comparand(high),
           do: {:ok, {op, "time", {lo, hi}}}
    else
      {:ok, {op, operand, {parse_where_value(low), parse_where_value(high)}}}
    end
  end

  @spec like_op(boolean()) :: :like | :not_like
  defp like_op(true), do: :not_like
  defp like_op(false), do: :like

  # SQL LIKE: `%` is any run, `_` any single character, `\` makes the next
  # character literal (`'al\%%'` matches "al%pha", verified); everything
  # else is literal. LIKE is case-sensitive on the engine, ILIKE is not.
  @spec like_regex(binary(), boolean()) :: Regex.t()
  defp like_regex(pattern, case_insensitive) do
    source = pattern |> String.graphemes() |> like_source([])

    Regex.compile!("\\A" <> source <> "\\z", if(case_insensitive, do: "is", else: "s"))
  end

  @spec like_source([binary()], [binary()]) :: binary()
  defp like_source([], acc), do: acc |> Enum.reverse() |> Enum.join()
  defp like_source(["\\", char | rest], acc), do: like_source(rest, [Regex.escape(char) | acc])
  defp like_source(["%" | rest], acc), do: like_source(rest, [".*" | acc])
  defp like_source(["_" | rest], acc), do: like_source(rest, ["." | acc])
  defp like_source([char | rest], acc), do: like_source(rest, [Regex.escape(char) | acc])

  @spec parse_binary_where_clause(binary()) ::
          {:ok, where_clause()} | {:error, map()}
  defp parse_binary_where_clause(trimmed) do
    # Multi-char operators must be tried before their single-char prefixes.
    operators = [
      {">=", :gte},
      {"<=", :lte},
      {"!=", :ne},
      {"<>", :ne},
      {">", :gt},
      {"<", :lt},
      {"=", :eq}
    ]

    split =
      Enum.find_value(operators, fn {op_str, op_atom} ->
        case String.split(trimmed, op_str, parts: 2) do
          [left, right] -> {op_atom, String.trim(left), String.trim(right)}
          _no_match -> nil
        end
      end)

    case split do
      nil ->
        {:error, local_error("unsupported WHERE clause: #{trimmed}")}

      {op, "time", right} ->
        with {:ok, value} <- parse_time_comparand(right), do: {:ok, {op, "time", value}}

      {op, key, right} ->
        with {:ok, left} <- parse_operand(key),
             {:ok, value} <- parse_comparand(right),
             do: {:ok, {op, left, value}}
    end
  end

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

    # Each item is a comparand: a literal, or — as in SQL — a column
    # reference or expression (`v IN (1, other)`). Source order is kept so
    # the schema check names the first unknown column, as the engine does.
    parse_item = if key == "time", do: &parse_time_comparand/1, else: &parse_comparand/1

    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case parse_item.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  # What the engine accepts as a `time` comparand: a quoted ISO-8601
  # datetime (zoned or not, optional fraction), a quoted date (midnight
  # UTC), or `now()` offset by `+`/`-` `INTERVAL 'N unit'` terms. DataFusion
  # fails planning for a bare integer ("Cannot infer common argument type
  # for comparison operation Timestamp(ns) > Int64") and fails execution for
  # any other string ("Error parsing timestamp"), so those are refused here
  # instead of silently matching no rows.
  @now_pattern ~r/^now\(\)((?:\s*[+-]\s*INTERVAL\s*'[^']*')*)$/i
  @interval_term ~r/([+-])\s*INTERVAL\s*'([^']*)'/i

  @spec parse_time_comparand(binary()) :: {:ok, time_value()} | {:error, map()}
  defp parse_time_comparand(str) do
    cond do
      quoted?(str) -> parse_time_literal(String.slice(str, 1..-2//1), str)
      match = Regex.run(@now_pattern, str) -> parse_now_offset(match)
      true -> {:error, invalid_time_error(str)}
    end
  end

  @spec quoted?(binary()) :: boolean()
  defp quoted?(str) do
    byte_size(str) >= 2 and
      ((String.starts_with?(str, "'") and String.ends_with?(str, "'")) or
         (String.starts_with?(str, "\"") and String.ends_with?(str, "\"")))
  end

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
        "ISO-8601 string or now() +/- INTERVAL 'N unit', never a bare integer): #{str}"
    )
  end

  # A quoted literal is a string, full stop — exactly as in InfluxDB v3.
  # Re-typing `'08338636'` as an integer would drop the leading zero and
  # change the type, so `WHERE repcode = '08338636'` could never match a
  # string tag (#12). Only bare literals are typed.
  @spec parse_where_value(binary()) :: term()
  defp parse_where_value(str) do
    cond do
      String.starts_with?(str, "'") and String.ends_with?(str, "'") ->
        String.slice(str, 1..-2//1)

      String.starts_with?(str, "\"") and String.ends_with?(str, "\"") ->
        String.slice(str, 1..-2//1)

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
    case Regex.run(~r/(?i)ORDER\s+BY\s+(.+?)\s*(?:\b(?:LIMIT|OFFSET)\s+\d.*)?$/s, rest) do
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
    case Regex.run(~r/^(.+?)(?:\s+(ASC|DESC))?(?:\s+NULLS\s+(FIRST|LAST))?$/is, term) do
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
  defp parse_limit(rest), do: clause_count(~r/(?i)\bLIMIT\s+(\d+)/s, rest)

  @spec parse_offset(binary()) :: non_neg_integer() | nil
  defp parse_offset(rest), do: clause_count(~r/(?i)\bOFFSET\s+(\d+)/s, rest)

  @spec clause_count(Regex.t(), binary()) :: non_neg_integer() | nil
  defp clause_count(pattern, rest) do
    case Regex.run(pattern, rest) do
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
    case Regex.run(~r/\$\w+/, blank_literals(sql)) do
      [name] -> name
      nil -> nil
    end
  end

  @doc "Substitutes `$name` placeholders with SQL literals built from `params`."
  @spec resolve_params(binary(), map()) :: binary()
  def resolve_params(sql, params) when map_size(params) == 0, do: sql

  # One pass over the SQL, whole placeholders only: a sequential
  # String.replace/3 per param rewrote `$a` inside `$ab` and could
  # re-substitute inside an already-substituted value.
  def resolve_params(sql, params) do
    lookup = Map.new(params, fn {key, value} -> {normalize_param_key(key), value} end)

    Regex.replace(~r/\$\w+/, sql, fn placeholder ->
      case Map.fetch(lookup, placeholder) do
        {:ok, value} -> to_sql_literal(value)
        :error -> placeholder
      end
    end)
  end

  @spec normalize_param_key(atom() | binary()) :: binary()
  defp normalize_param_key(key) when is_atom(key), do: "$#{key}"
  defp normalize_param_key("$" <> _rest = key), do: key
  defp normalize_param_key(key) when is_binary(key), do: "$#{key}"

  # Calendar params render as the ISO-8601 strings Jason sends over HTTP, so
  # `time >= $start` with a DateTime behaves the same on both clients.
  @spec to_sql_literal(term()) :: binary()
  defp to_sql_literal(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp to_sql_literal(%DateTime{} = value), do: "'#{DateTime.to_iso8601(value)}'"
  defp to_sql_literal(%NaiveDateTime{} = value), do: "'#{NaiveDateTime.to_iso8601(value)}'"
  defp to_sql_literal(%Date{} = value), do: "'#{Date.to_iso8601(value)}'"
  defp to_sql_literal(value) when is_binary(value), do: "'#{value}'"
  defp to_sql_literal(value) when is_integer(value), do: Integer.to_string(value)
  defp to_sql_literal(value) when is_float(value), do: Float.to_string(value)
  defp to_sql_literal(true), do: "true"
  defp to_sql_literal(false), do: "false"
  # Jason sends nil as JSON null; `col = NULL` is never true on the engine.
  defp to_sql_literal(nil), do: "NULL"
  defp to_sql_literal(value), do: inspect(value)

  # Every parser rejection carries this prefix so a consumer reading
  # "unsupported ..." knows the test double, not InfluxDB, refused the query.
  @spec local_error(binary()) :: %{status: 400, body: binary()}
  defp local_error(message), do: %{status: 400, body: "Client.Local: " <> message}
end
