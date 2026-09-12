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

  # Measurement names may contain escaped spaces (e.g. "my\ measurement").
  # This captures everything up to the first unescaped space or end-of-line.
  @measurement_pattern ~r/(?i)SELECT\s+\*\s+FROM\s+(?:"([^"]+)"|((?:[^\s\\]|\\.)+))(.*)/s

  @type select_column ::
          {:time_bucket, binary()}
          | {:aggregate, :avg | :sum | :count | :min | :max, binary(), binary()}
          | {:count_star, binary()}
          | {:ordered_aggregate, :first | :last, binary(), binary(), binary()}
          | {:grouping_column, binary(), binary()}

  @type where_op :: :eq | :gt | :lt | :gte | :lte | :ne | :in | :not_in
  @type where_clause :: {where_op(), binary(), term()}

  @type parsed_query :: %{
          measurement: binary(),
          where: [where_clause()],
          order_by: {:time, :asc | :desc} | nil,
          limit: pos_integer() | nil,
          group_by_interval: pos_integer() | nil,
          group_by_columns: [binary()] | nil,
          select_columns: [select_column()] | nil,
          distinct_column: binary() | nil,
          projection_columns: [{binary(), binary()}] | nil
        }

  # Aggregate function names recognised by the parser.
  @aggregate_functions ~w(AVG SUM COUNT MIN MAX FIRST_VALUE LAST_VALUE)

  # InfluxQL selector functions that InfluxDB v3 SQL does not provide. They are
  # routed into the aggregate parser only so the rejection can name the fix.
  @influxql_only_functions ~w(FIRST LAST)

  # first_value(field ORDER BY col [ASC|DESC]) AS alias  (and last_value).
  # The ORDER BY group is optional in the grammar so a missing one can be
  # reported specifically instead of as a generic parse failure.
  @ordered_agg_pattern ~r/(?i)^\s*(FIRST_VALUE|LAST_VALUE)\s*\(\s*(\w+)\s*(?:ORDER\s+BY\s+(\w+)(?:\s+(ASC|DESC))?\s*)?\)\s+AS\s+(\w+)\s*$/

  @doc "Parses a SELECT statement into a `t:parsed_query/0`."
  @spec parse_select(binary()) :: {:ok, parsed_query()} | {:error, term()}
  def parse_select(sql) do
    normalised = String.trim(sql)

    cond do
      distinct_query?(normalised) -> parse_distinct_select(normalised)
      aggregate_query?(normalised) -> parse_aggregate_select(normalised)
      star_query?(normalised) -> parse_star_select(normalised)
      true -> parse_columns_select(normalised)
    end
  end

  @spec distinct_query?(binary()) :: boolean()
  defp distinct_query?(sql) do
    String.match?(sql, ~r/(?i)^\s*SELECT\s+DISTINCT\s+/)
  end

  @spec star_query?(binary()) :: boolean()
  defp star_query?(sql) do
    String.match?(sql, ~r/(?i)^\s*SELECT\s+\*\s+FROM\s/)
  end

  @spec aggregate_query?(binary()) :: boolean()
  defp aggregate_query?(sql) do
    upper = String.upcase(sql)

    String.contains?(upper, "DATE_BIN") or
      Enum.any?(
        @aggregate_functions ++ @influxql_only_functions,
        &String.contains?(upper, &1 <> "(")
      )
  end

  @spec parse_aggregate_select(binary()) ::
          {:ok, parsed_query()} | {:error, term()}
  defp parse_aggregate_select(sql) do
    with {:ok, columns} <- parse_select_columns(sql),
         {:ok, measurement} <- parse_aggregate_from(sql),
         {:ok, interval_ns} <- resolve_aggregate_interval(sql),
         rest = extract_after_from(sql),
         {:ok, where} <- parse_where(rest) do
      {:ok,
       %{
         measurement: measurement,
         where: where,
         order_by: parse_order_by(rest),
         limit: parse_limit(rest),
         group_by_interval: interval_ns,
         group_by_columns: parse_group_by_columns(sql),
         select_columns: columns,
         distinct_column: nil,
         projection_columns: nil
       }}
    end
  end

  # Extract the bare-column GROUP BY list, e.g. "GROUP BY ticker, holding_type".
  # Returns nil when no GROUP BY exists or when the clause is DATE_BIN(...)
  # (handled separately by resolve_aggregate_interval).
  @spec parse_group_by_columns(binary()) :: [binary()] | nil
  defp parse_group_by_columns(sql) do
    case Regex.run(
           ~r/(?i)GROUP\s+BY\s+(.+?)(?:\s+ORDER|\s+LIMIT|$)/s,
           sql
         ) do
      [_full, columns_str] ->
        if String.match?(columns_str, ~r/^\s*DATE_BIN\s*\(/i) do
          nil
        else
          columns_str
          |> split_top_level_commas()
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> case do
            [] -> nil
            cols -> cols
          end
        end

      _no_match ->
        nil
    end
  end

  # GROUP BY DATE_BIN is optional. Without the clause, return nil so the
  # executor produces a single scalar row. With the clause, propagate any
  # interval-parsing error so malformed intervals still surface.
  @spec resolve_aggregate_interval(binary()) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  defp resolve_aggregate_interval(sql) do
    if String.match?(sql, ~r/(?i)GROUP\s+BY\s+DATE_BIN/) do
      parse_group_by_interval(sql)
    else
      {:ok, nil}
    end
  end

  # Extract the measurement name from: FROM "name" or FROM name
  @spec parse_aggregate_from(binary()) :: {:ok, binary()} | {:error, term()}
  defp parse_aggregate_from(sql) do
    pattern = ~r/(?i)FROM\s+(?:"([^"]+)"|(\S+?))\s*(?:WHERE|GROUP|ORDER|LIMIT|$)/

    case Regex.run(pattern, sql) do
      [_full, quoted, ""] -> {:ok, quoted}
      [_full, "", unquoted] -> {:ok, LineProtocolParser.unescape_measurement(unquoted)}
      [_full, quoted] when quoted != "" -> {:ok, quoted}
      _no_match -> {:error, local_error("unsupported SQL: #{sql}")}
    end
  end

  # Extract everything after FROM <measurement> for WHERE/ORDER/LIMIT parsing
  @spec extract_after_from(binary()) :: binary()
  defp extract_after_from(sql) do
    case Regex.run(~r/(?i)FROM\s+(?:"[^"]+"|[^\s]+)\s*(.*)/s, sql) do
      [_full, rest] -> rest
      _no_match -> ""
    end
  end

  # Parse SELECT columns: DATE_BIN(...) AS alias, AGG(field) AS alias
  @spec parse_select_columns(binary()) ::
          {:ok, [select_column()]} | {:error, term()}
  defp parse_select_columns(sql) do
    case Regex.run(~r/(?i)SELECT\s+(.+?)\s+FROM\s/s, sql) do
      [_full, columns_str] ->
        columns =
          columns_str
          |> split_top_level_commas()
          |> Enum.map(&String.trim/1)
          |> Enum.map(&parse_single_column/1)

        if Enum.any?(columns, &match?({:error, _}, &1)) do
          Enum.find(columns, &match?({:error, _}, &1))
        else
          {:ok, Enum.map(columns, fn {:ok, col} -> col end)}
        end

      _no_match ->
        {:error, local_error("unsupported SQL: #{sql}")}
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
  @spec parse_single_column(binary()) ::
          {:ok, select_column()} | {:error, term()}
  defp parse_single_column(col) do
    cond do
      String.match?(col, ~r/(?i)DATE_BIN\s*\(/) ->
        parse_date_bin_column(col)

      String.match?(col, ~r/(?i)\b(FIRST_VALUE|LAST_VALUE)\s*\(/) ->
        parse_ordered_agg_column(col)

      String.match?(col, ~r/(?i)\b(FIRST|LAST)\s*\(/) ->
        {:error, influxql_selector_error(col)}

      String.match?(col, ~r/(?i)\b(AVG|SUM|COUNT|MIN|MAX)\s*\(/) ->
        parse_agg_column(col)

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

    case Regex.run(count_star, col) do
      [_full, alias_name] ->
        {:ok, {:count_star, alias_name}}

      nil ->
        parse_agg_column_arg(col)
    end
  end

  # Exactly one argument: `AVG(field, other)` is not SQL and the real engine
  # rejects it, so the double must not quietly accept it either.
  @spec parse_agg_column_arg(binary()) ::
          {:ok, select_column()} | {:error, term()}
  defp parse_agg_column_arg(col) do
    one_arg = ~r/(?i)^\s*(AVG|SUM|COUNT|MIN|MAX)\s*\(\s*(\w+)\s*\)\s+AS\s+(\w+)\s*$/

    case Regex.run(one_arg, col) do
      [_full, func, field, alias_name] ->
        agg_atom = func |> String.downcase() |> String.to_existing_atom()
        {:ok, {:aggregate, agg_atom, field, alias_name}}

      _no_match ->
        {:error, local_error("invalid aggregate: #{col}")}
    end
  end

  # Parse GROUP BY DATE_BIN(INTERVAL 'N unit', time) → interval in nanoseconds
  @spec parse_group_by_interval(binary()) ::
          {:ok, pos_integer()} | {:error, term()}
  defp parse_group_by_interval(sql) do
    pattern =
      ~r/(?i)GROUP\s+BY\s+DATE_BIN\s*\(\s*INTERVAL\s+'([^']+)'\s*,\s*time\s*\)/

    case Regex.run(pattern, sql) do
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

  @distinct_pattern ~r/(?i)SELECT\s+DISTINCT\s+(\w+)\s+FROM\s+(?:"([^"]+)"|(\S+))\s*(.*)/s

  @spec parse_distinct_select(binary()) ::
          {:ok, parsed_query()} | {:error, term()}
  defp parse_distinct_select(sql) do
    case Regex.run(@distinct_pattern, sql) do
      [_full, column, quoted, "", rest] ->
        build_distinct_query(column, quoted, rest)

      [_full, column, "", unquoted, rest] ->
        build_distinct_query(column, LineProtocolParser.unescape_measurement(unquoted), rest)

      _no_match ->
        {:error, local_error("unsupported DISTINCT query: #{sql}")}
    end
  end

  @spec build_distinct_query(binary(), binary(), binary()) ::
          {:ok, parsed_query()} | {:error, map()}
  defp build_distinct_query(column, measurement, rest) do
    with {:ok, where} <- parse_where(rest) do
      {:ok,
       %{
         measurement: measurement,
         where: where,
         order_by: nil,
         limit: parse_limit(rest),
         group_by_interval: nil,
         group_by_columns: nil,
         select_columns: nil,
         distinct_column: column,
         projection_columns: nil
       }}
    end
  end

  @spec parse_star_select(binary()) :: {:ok, parsed_query()} | {:error, term()}
  defp parse_star_select(sql) do
    case Regex.run(@measurement_pattern, sql) do
      [_full_match, quoted, "", rest] when quoted != "" ->
        build_star_query(quoted, rest)

      [_full_match, "", unquoted, rest] ->
        build_star_query(LineProtocolParser.unescape_measurement(unquoted), rest)

      [_full_match, quoted, rest] when quoted != "" ->
        build_star_query(quoted, rest)

      _no_match ->
        {:error, local_error("unsupported SQL: #{sql}")}
    end
  end

  @spec build_star_query(binary(), binary()) ::
          {:ok, parsed_query()} | {:error, map()}
  defp build_star_query(measurement, rest) do
    with {:ok, where} <- parse_where(rest) do
      {:ok,
       %{
         measurement: measurement,
         where: where,
         order_by: parse_order_by(rest),
         limit: parse_limit(rest),
         group_by_interval: nil,
         group_by_columns: nil,
         select_columns: nil,
         distinct_column: nil,
         projection_columns: nil
       }}
    end
  end

  @columns_select_pattern ~r/(?i)SELECT\s+(.+?)\s+FROM\s+(?:"([^"]+)"|((?:[^\s\\]|\\.)+))(.*)/s

  @spec parse_columns_select(binary()) ::
          {:ok, parsed_query()} | {:error, term()}
  defp parse_columns_select(sql) do
    case Regex.run(@columns_select_pattern, sql) do
      [_full, columns_str, quoted, "", rest] when quoted != "" ->
        build_columns_query(columns_str, quoted, rest, sql)

      [_full, columns_str, "", unquoted, rest] ->
        build_columns_query(
          columns_str,
          LineProtocolParser.unescape_measurement(unquoted),
          rest,
          sql
        )

      [_full, columns_str, quoted, rest] when quoted != "" ->
        build_columns_query(columns_str, quoted, rest, sql)

      _no_match ->
        {:error, local_error("unsupported SQL: #{sql}")}
    end
  end

  @spec build_columns_query(binary(), binary(), binary(), binary()) ::
          {:ok, parsed_query()} | {:error, term()}
  defp build_columns_query(columns_str, measurement, rest, sql) do
    case parse_projection_columns(columns_str) do
      {:ok, projection} ->
        with {:ok, where} <- parse_where(rest) do
          {:ok,
           %{
             measurement: measurement,
             where: where,
             order_by: parse_order_by(rest),
             limit: parse_limit(rest),
             group_by_interval: nil,
             group_by_columns: nil,
             select_columns: nil,
             distinct_column: nil,
             projection_columns: projection
           }}
        end

      {:error, _reason} ->
        {:error, local_error("unsupported SQL: #{sql}")}
    end
  end

  @spec parse_projection_columns(binary()) ::
          {:ok, [{binary(), binary()}]} | {:error, term()}
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

  # Parse `name` or `name AS alias`, returning `{source, output}`.
  @spec parse_projection_column(binary()) ::
          {:ok, {binary(), binary()}} | {:error, term()}
  defp parse_projection_column(col) do
    case Regex.run(~r/^(\w+)(?:\s+AS\s+(\w+))?$/i, String.trim(col)) do
      [_full, name] -> {:ok, {name, name}}
      [_full, name, alias_name] -> {:ok, {name, alias_name}}
      _no_match -> {:error, local_error("unsupported column: #{col}")}
    end
  end

  @doc "Parses the `WHERE ...` clause (if any) out of the text after `FROM <table>`."
  @spec parse_where(binary()) ::
          {:ok, [where_clause()]} | {:error, map()}
  def parse_where(rest) do
    case Regex.run(~r/(?i)WHERE\s+(.+?)(?:\s+GROUP|\s+ORDER|\s+LIMIT|$)/s, rest) do
      [_full_match, clauses_str] -> parse_where_clauses(clauses_str)
      _no_match -> {:ok, []}
    end
  end

  # Fold each AND-split clause into either an accumulating list or the first
  # error encountered. Unrecognised clauses bubble up as 400 errors rather
  # than being silently dropped (which previously returned wrong rows).
  @spec parse_where_clauses(binary()) ::
          {:ok, [where_clause()]} | {:error, map()}
  defp parse_where_clauses(str) do
    str
    |> String.split(~r/\s+AND\s+/i)
    |> Enum.reduce_while({:ok, []}, fn clause, {:ok, acc} ->
      case parse_single_where_clause(clause) do
        {:ok, condition} -> {:cont, {:ok, [condition | acc]}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, conditions} -> {:ok, Enum.reverse(conditions)}
      {:error, _reason} = err -> err
    end
  end

  # IN / NOT IN must be matched before binary operators because they don't
  # contain any of {=, <, >, !} characters that the binary-op scanner looks
  # for. Order: NOT IN before IN (NOT IN substring contains IN).
  @not_in_pattern ~r/^(\w+)\s+NOT\s+IN\s*\((.*)\)\s*$/is
  @in_pattern ~r/^(\w+)\s+IN\s*\((.*)\)\s*$/is

  @spec parse_single_where_clause(binary()) ::
          {:ok, where_clause()} | {:error, map()}
  defp parse_single_where_clause(clause) do
    trimmed = String.trim(clause)

    cond do
      match = Regex.run(@not_in_pattern, trimmed) ->
        [_full, key, list_str] = match
        {:ok, {:not_in, key, parse_in_values(list_str)}}

      match = Regex.run(@in_pattern, trimmed) ->
        [_full, key, list_str] = match
        {:ok, {:in, key, parse_in_values(list_str)}}

      true ->
        parse_binary_where_clause(trimmed)
    end
  end

  @spec parse_binary_where_clause(binary()) ::
          {:ok, where_clause()} | {:error, map()}
  defp parse_binary_where_clause(trimmed) do
    # Multi-char operators must be tried before their single-char prefixes.
    operators = [{">=", :gte}, {"<=", :lte}, {"!=", :ne}, {">", :gt}, {"<", :lt}, {"=", :eq}]

    result =
      Enum.find_value(operators, fn {op_str, op_atom} ->
        case String.split(trimmed, op_str, parts: 2) do
          [left, right] when left != trimmed ->
            k = String.trim(left)
            v = parse_where_value(String.trim(right))
            {op_atom, k, v}

          _no_match ->
            nil
        end
      end)

    case result do
      nil ->
        {:error, local_error("unsupported WHERE clause: #{trimmed}")}

      condition ->
        {:ok, condition}
    end
  end

  @spec parse_in_values(binary()) :: [term()]
  defp parse_in_values(str) do
    str
    |> split_top_level_commas()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_where_value/1)
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

  @spec parse_order_by(binary()) :: {:time, :asc | :desc} | nil
  defp parse_order_by(rest) do
    case Regex.run(~r/(?i)ORDER\s+BY\s+time\s+(ASC|DESC)/s, rest) do
      [_full_match, direction] ->
        case String.upcase(direction) do
          "ASC" -> {:time, :asc}
          "DESC" -> {:time, :desc}
          _other -> nil
        end

      _no_match ->
        nil
    end
  end

  @spec parse_limit(binary()) :: pos_integer() | nil
  defp parse_limit(rest) do
    case Regex.run(~r/(?i)LIMIT\s+(\d+)/s, rest) do
      [_full_match, n_str] ->
        case Integer.parse(n_str) do
          {n, ""} when n > 0 -> n
          _bad_n -> nil
        end

      _no_match ->
        nil
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

  @spec to_sql_literal(term()) :: binary()
  defp to_sql_literal(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp to_sql_literal(value) when is_binary(value), do: "'#{value}'"
  defp to_sql_literal(value) when is_integer(value), do: Integer.to_string(value)
  defp to_sql_literal(value) when is_float(value), do: Float.to_string(value)
  defp to_sql_literal(true), do: "true"
  defp to_sql_literal(false), do: "false"
  defp to_sql_literal(value), do: inspect(value)

  # Every parser rejection carries this prefix so a consumer reading
  # "unsupported ..." knows the test double, not InfluxDB, refused the query.
  @spec local_error(binary()) :: %{status: 400, body: binary()}
  defp local_error(message), do: %{status: 400, body: "Client.Local: " <> message}
end
