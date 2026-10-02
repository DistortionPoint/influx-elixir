defmodule InfluxElixir.Client.Local.SQLSelect do
  @moduledoc """
  The select list of an aggregate or grouped query: `DATE_BIN(...) AS alias`,
  `AGG(expr) AS alias`, the selectors, `first_value` / `last_value`, constants
  and grouping columns (all verified against InfluxDB 3 Core).

  A column is read by the shape only it can have, and what the engine refuses
  it refuses in the engine's words: `AVG(time)`, the InfluxQL-only `FIRST()` /
  `LAST()`, an aggregate with no alias.
  """

  alias InfluxElixir.Client.Local.{SQLError, SQLExpr, SQLLiteral, SQLMask}

  @typedoc "Plain aggregates; `:stddev`/`:var` are the sample forms, as in InfluxDB."
  @type aggregate ::
          :avg | :sum | :count | :min | :max | :median | :stddev | :stddev_pop | :var | :var_pop

  @typedoc "One column of an aggregate or grouped select list."
  @type column ::
          {:time_bucket, binary()}
          | {:aggregate, aggregate(), SQLExpr.t(), binary()}
          | {:count_star, binary()}
          | {:count_distinct, binary(), binary()}
          | {:ordered_aggregate, :first | :last, binary(), binary(), binary()}
          | {:selector, :first | :last | :min | :max, binary(), binary(),
             :value | :time | :struct, binary()}
          | {:grouping_column, binary(), binary()}
          | {:constant, term(), binary()}

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
  @aggregate_call ~r/(?i)(?:#{@aggregate_alternation})\s*\(/u
  @influxql_call ~r/(?i)\b(?:#{Enum.join(Map.keys(@influxql_only_functions), "|")})\s*\(/u

  # selector_first|last|min|max(field, time)[['value'|'time']] AS alias
  @selector_pattern ~r/(?i)^\s*SELECTOR_(FIRST|LAST|MIN|MAX)\s*\(\s*(\w+)\s*,\s*(\w+)\s*\)\s*(?:\[\s*'(value|time)'\s*\])?\s+AS\s+(\w+)\s*$/u

  # first_value(field ORDER BY col [ASC|DESC]) AS alias  (and last_value).
  # The ORDER BY group is optional in the grammar so a missing one can be
  # reported specifically instead of as a generic parse failure.
  @ordered_agg_pattern ~r/(?i)^\s*(FIRST_VALUE|LAST_VALUE)\s*\(\s*(\w+)\s*(?:ORDER\s+BY\s+(\w+)(?:\s+(ASC|DESC))?\s*)?\)\s+AS\s+(\w+)\s*$/u

  @doc """
  Whether a text selects an aggregate or groups: a `DATE_BIN`, a `GROUP BY`
  (a grouped query without an aggregate still gives one row per group), or a
  call of an aggregate or of an InfluxQL-only selector.
  """
  @spec aggregate_query?(binary()) :: boolean()
  def aggregate_query?(sql) do
    masked = SQLMask.mask(sql)

    Regex.match?(~r/(?i)DATE_BIN|\bGROUP\s+BY\b/u, masked) or
      Regex.match?(@aggregate_call, masked) or Regex.match?(@influxql_call, masked)
  end

  @doc "Whether a text calls an aggregate function."
  @spec aggregate_call?(binary()) :: boolean()
  def aggregate_call?(text), do: Regex.match?(@aggregate_call, text)

  @doc "The aggregate SELECT list as columns, or the first column's error."
  @spec parse_list(binary()) :: {:ok, [column()]} | {:error, term()}
  def parse_list(columns_str) do
    columns =
      columns_str
      |> SQLMask.split_commas()
      |> Enum.map(&String.trim/1)
      |> Enum.map(&parse_single_column/1)

    case Enum.find(columns, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(columns, fn {:ok, col} -> col end)}
      error -> error
    end
  end

  # Parse a single SELECT column expression
  # A constant in the select list (`0.0 AS volume`, `'x' AS label`) needs an
  # alias: DataFusion names an unaliased one after its own rendering
  # (`Int64(1)`), which the double will not guess.
  @constant_column ~r/^\s*(-?[0-9]+(?:\.[0-9]+)?|'(?:[^']|'')*'|\$\w+)\s+AS\s+(\w+)\s*$/iu

  @doc "A constant select item (`0.0 AS volume`) as `[full, literal, alias]`, or `nil`."
  @spec constant_column(binary()) :: [binary()] | nil
  def constant_column(col), do: Regex.run(@constant_column, col)

  @spec parse_single_column(binary()) ::
          {:ok, column()} | {:error, term()}
  defp parse_single_column(col) do
    masked = SQLMask.mask(col)

    cond do
      String.match?(masked, ~r/(?i)DATE_BIN\s*\(/u) ->
        parse_date_bin_column(col)

      String.match?(masked, ~r/(?i)\b(FIRST_VALUE|LAST_VALUE)\s*\(/u) ->
        parse_ordered_agg_column(col)

      String.match?(masked, ~r/(?i)\bSELECTOR_(FIRST|LAST|MIN|MAX)\s*\(/u) ->
        parse_selector_column(col)

      match = Regex.run(@influxql_call, masked) ->
        {:error, invalid_function(hd(match))}

      String.match?(masked, ~r/(?i)\b(?:#{@plain_alternation})\s*\(/u) ->
        parse_agg_column(col)

      match = Regex.run(@constant_column, col) ->
        [_full, literal, alias_name] = match
        {:ok, {:constant, SQLLiteral.value(literal), alias_name}}

      String.match?(col, ~r/^\s*\w+(\s+AS\s+\w+)?\s*$/iu) ->
        parse_grouping_column(col)

      true ->
        {:error, SQLError.refusal("unsupported column expression: #{col}")}
    end
  end

  # FIRST()/LAST() are InfluxQL selectors, not SQL functions: the engine
  # fails planning, suggesting some other function by edit distance. The
  # double names one, always the same.
  @spec invalid_function(binary()) :: map()
  defp invalid_function(call) do
    name = call |> String.replace(~r/\s*\($/u, "") |> String.downcase()

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
          {:ok, column()} | {:error, term()}
  defp parse_ordered_agg_column(col) do
    case Regex.run(@ordered_agg_pattern, col) do
      [_full, func, field, ordering, direction, alias_name] when ordering != "" ->
        agg = ordered_agg_end(func, direction)
        {:ok, {:ordered_aggregate, agg, field, ordering, alias_name}}

      [_full, func, _field, "", _direction, _alias] ->
        {:error,
         SQLError.refusal(
           "#{func}() needs ORDER BY inside the call: InfluxDB v3 returns an " <>
             "arbitrary row from the group without one, which this test double " <>
             "cannot reproduce. Write #{func}(field ORDER BY time): #{col}"
         )}

      _no_match ->
        {:error, SQLError.refusal("invalid aggregate: #{col}")}
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
          {:ok, column()} | {:error, term()}
  defp parse_grouping_column(col) do
    case Regex.run(~r/^(\w+)(?:\s+AS\s+(\w+))?$/iu, String.trim(col)) do
      [_full, name] -> {:ok, {:grouping_column, name, name}}
      [_full, name, alias_name] -> {:ok, {:grouping_column, name, alias_name}}
      _no_match -> {:error, SQLError.refusal("invalid column: #{col}")}
    end
  end

  # Parse: DATE_BIN(INTERVAL 'N unit', time) AS alias
  @spec parse_date_bin_column(binary()) ::
          {:ok, column()} | {:error, term()}
  defp parse_date_bin_column(col) do
    pattern =
      ~r/(?i)DATE_BIN\s*\(\s*INTERVAL\s+'([^']+)'\s*,\s*time\s*\)\s+AS\s+(\w+)/u

    case Regex.run(pattern, col) do
      [_full, _interval, alias_name] ->
        {:ok, {:time_bucket, alias_name}}

      _no_match ->
        {:error, SQLError.refusal("invalid DATE_BIN: #{col}")}
    end
  end

  # Parse: AGG(field) AS alias.
  # COUNT(*) is special-cased — it counts rows regardless of field nullity
  # (matching real InfluxDB v3 / SQL semantics), so it doesn't fit the
  # `\w+`-inside-parens shape used for the other aggregates.
  @spec parse_agg_column(binary()) ::
          {:ok, column()} | {:error, term()}
  defp parse_agg_column(col) do
    count_star =
      ~r/(?i)^\s*COUNT\s*\(\s*\*\s*\)\s+AS\s+(\w+)\s*$/u

    count_distinct =
      ~r/(?i)^\s*COUNT\s*\(\s*DISTINCT\s+(\w+)\s*\)\s+AS\s+(\w+)\s*$/u

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
          {:ok, column()} | {:error, term()}
  defp parse_agg_column_arg(col) do
    one_arg = ~r/(?i)^\s*(#{@plain_alternation})\s*\((.+)\)\s+AS\s+(\w+)\s*$/su

    with [_full, func, expr_str, alias_name] <- Regex.run(one_arg, col),
         {:ok, expr} <- SQLExpr.parse(expr_str),
         agg = Map.fetch!(@plain_aggregates, String.downcase(func)),
         :ok <- check_time_argument(agg, expr, col) do
      {:ok, {:aggregate, agg, expr, alias_name}}
    else
      {:error, %{status: 400}} = error -> error
      _no_match -> {:error, SQLError.refusal("invalid aggregate: #{col}")}
    end
  end

  # `time` is a Timestamp column. DataFusion computes MIN, MAX and COUNT over
  # it but fails planning for AVG, SUM and the statistics, in the words
  # `time_aggregate_error/1` reproduces. Arithmetic on it
  # (`MAX(time - 1)`: "Cannot coerce arithmetic expression Timestamp(ns) -
  # Int64 to valid types") is the executor's plan-time type check, in the
  # engine's words.
  @spec check_time_argument(aggregate(), SQLExpr.t(), binary()) :: :ok | {:error, term()}
  defp check_time_argument(agg, {:field, "time"}, _col) when agg in [:min, :max, :count],
    do: :ok

  defp check_time_argument(_agg, expr, col) do
    if expr == {:field, "time"} do
      {:error,
       SQLError.refusal(
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
           Regex.run(~r/(?i)^\s*(#{@plain_alternation})\s*\(\s*time\s*\)/u, col),
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
  @spec parse_selector_column(binary()) :: {:ok, column()} | {:error, term()}
  defp parse_selector_column(col) do
    case Regex.run(@selector_pattern, col) do
      [_full, kind, field, ordering, access, alias_name] ->
        selector = String.to_existing_atom(String.downcase(kind))
        # Without a subscript the engine returns the whole struct.
        access = if access == "", do: :struct, else: String.to_existing_atom(access)
        {:ok, {:selector, selector, field, ordering, access, alias_name}}

      _no_match ->
        {:error,
         SQLError.refusal(
           "selector functions are supported as " <>
             "selector_first|last|min|max(field, time)[['value' | 'time']] AS alias: #{col}"
         )}
    end
  end
end
