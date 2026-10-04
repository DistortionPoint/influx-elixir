defmodule InfluxElixir.Client.Local.SQLSelect do
  @moduledoc false
  # The select list of an aggregate or grouped query: `DATE_BIN(...) AS alias`,
  # `AGG(expr) AS alias`, the selectors, `first_value` / `last_value`, constants
  # and grouping columns (all verified against InfluxDB 3 Core).
  #
  # A column is read by the shape only it can have, and what the engine refuses
  # it refuses in the engine's words: `AVG(time)`, the InfluxQL-only `FIRST()` /
  # `LAST()`.
  #
  # A column with no alias is named as the engine names it: the function as it
  # was written, in lower case, over the expression with its columns qualified
  # by the table or its alias (`sum(rvt.v * Int64(2))`, `count(*)`,
  # `count(DISTINCT rvt.h)`, `first_value(rvt.v) ORDER BY [rvt.time ASC NULLS
  # LAST]`, `selector_first(rvt.v,rvt.time)[value]`, `date_bin(...)`). A name
  # that depends on which side of a `CROSS JOIN` holds a column is refused by
  # name, and so is a cast, whose place in a name the double does not model.

  alias InfluxElixir.Client.Local.{SQLError, SQLExpr, SQLLiteral, SQLMask, SQLTime}

  @typedoc "Plain aggregates; `:stddev`/`:var` are the sample forms, as in InfluxDB."
  @type aggregate ::
          :avg
          | :sum
          | :count
          | :count_distinct
          | :sum_distinct
          | :min
          | :max
          | :median
          | :stddev
          | :stddev_pop
          | :var
          | :var_pop

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

  # A column name: a word, or a quoted identifier.
  @name ~S{(\w+|"(?:[^"]|"")*")}

  # selector_first|last|min|max(field, time)[['value'|'time']]
  @selector_pattern ~r/(?i)^\s*SELECTOR_(FIRST|LAST|MIN|MAX)\s*\(\s*#{@name}\s*,\s*#{@name}\s*\)\s*(?:\[\s*'(value|time)'\s*\])?\s*$/u

  # first_value(field ORDER BY col [ASC|DESC])  (and last_value).
  # The ORDER BY group is optional in the grammar so a missing one can be
  # reported specifically instead of as a generic parse failure.
  @ordered_agg_pattern ~r/(?i)^\s*(?<func>FIRST_VALUE|LAST_VALUE)\s*\(\s*(?<field>\w+|"(?:[^"]|"")*")\s*(?:ORDER\s+BY\s+(?<ordering>\w+|"(?:[^"]|"")*")(?:\s+(?<direction>ASC|DESC))?\s*)?\)\s*$/u

  @doc """
  Whether a text selects an aggregate or groups: a `DATE_BIN`, a `GROUP BY`
  (a grouped query without an aggregate still gives one row per group), or a
  call of an aggregate or of an InfluxQL-only selector.
  """
  @spec aggregate_query?(binary()) :: boolean()
  def aggregate_query?(sql) do
    masked = SQLMask.mask(sql)

    Regex.match?(~r/(?i)DATE_BIN|\bGROUP\s+BY\b|\bHAVING\b/u, masked) or
      Regex.match?(@aggregate_call, masked) or Regex.match?(@influxql_call, masked)
  end

  @doc "Whether a text calls an aggregate function."
  @spec aggregate_call?(binary()) :: boolean()
  def aggregate_call?(text), do: Regex.match?(@aggregate_call, text)

  @doc "Whether a text calls an InfluxQL-only function (`FIRST`, `LAST`), which SQL does not have."
  @spec influxql_call?(binary()) :: boolean()
  def influxql_call?(text), do: Regex.match?(@influxql_call, SQLMask.mask(text))

  @call_start ~r/(?i)(?<![\w."])(?:#{@aggregate_alternation})\s*\(/u

  @doc """
  The calls of aggregate functions in a text, outermost only, as
  `{start, length}` byte spans: the name, the parenthesised arguments and, for
  a selector, its `['value']` or `['time']` subscript.
  """
  @spec aggregate_spans(binary()) :: [{non_neg_integer(), pos_integer()}]
  def aggregate_spans(text) do
    @call_start
    |> Regex.scan(SQLMask.mask(text), return: :index)
    |> Enum.map(fn [{start, length}] -> {start, length} end)
    |> Enum.reduce({[], 0}, fn {start, length}, {spans, covered} ->
      if start < covered, do: {spans, covered}, else: take_span(text, start, length, spans)
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @typep span :: {non_neg_integer(), pos_integer()}

  @spec take_span(binary(), non_neg_integer(), pos_integer(), [span()]) ::
          {[span()], non_neg_integer()}
  defp take_span(text, start, length, spans) do
    after_open = binary_part(text, start + length, byte_size(text) - start - length)

    case SQLMask.balanced(after_open) do
      {:ok, _inside, tail} ->
        tail = Regex.replace(~r/\A\s*\[\s*'(?:value|time)'\s*\]/u, tail, "")
        stop = byte_size(text) - byte_size(tail)
        {[{start, stop - start} | spans], stop}

      :error ->
        {spans, byte_size(text)}
    end
  end

  @doc """
  One select item parsed as an aggregate item (see `parse_list/2`): the column,
  or the error.
  """
  @spec parse_item(binary(), binary() | nil) :: {:ok, column()} | {:error, term()}
  def parse_item(item, qualifier), do: parse_single_column(item, qualifier)

  @doc """
  The aggregate SELECT list as columns, or the first column's error.
  `qualifier` is the table, or its alias, that names a column in an unaliased
  item's name; `nil` when the table is joined.
  """
  @spec parse_list(binary(), binary() | nil) :: {:ok, [column()]} | {:error, term()}
  def parse_list(columns_str, qualifier \\ nil) do
    columns =
      columns_str
      |> SQLMask.split_commas()
      |> Enum.map(&String.trim/1)
      |> Enum.map(&parse_single_column(&1, qualifier))

    case Enum.find(columns, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(columns, fn {:ok, col} -> col end)}
      error -> error
    end
  end

  @doc """
  A select item as `{body, alias}`: the text before a final `AS name` and the
  name (a quoted one without its quotes), or `{item, nil}` when the item has
  no alias.
  """
  @spec split_alias(binary()) :: {binary(), binary() | nil}
  def split_alias(item) do
    case SQLMask.run(~r/^(.+?)\s+AS\s+(\w+|"(?:[^"]|"")*")\s*$/isu, item) do
      [_full, body, alias_text] -> {String.trim(body), name(alias_text)}
      nil -> implicit_alias(item)
    end
  end

  # Words that go on an expression or end one: the last word of a text is an
  # alias only when it is none of them and the text before it is a whole
  # expression (`n a`, `count(*) c`, `CASE ... END k`; not `n + a`, `n IS NULL`).
  @continuations ~w(AND OR NOT IS IN LIKE ILIKE BETWEEN WHEN THEN ELSE CASE DISTINCT FROM ON BY
    ESCAPE ASC DESC NULLS FIRST LAST INTERVAL OVER FILTER WITHIN GROUP)
  @alias_stops ~w(END NULL TRUE FALSE)

  @spec implicit_alias(binary()) :: {binary(), binary() | nil}
  defp implicit_alias(item) do
    case SQLMask.run(~r/^(.*?[\w)"'\]])\s+([\p{L}_]\w*|"(?:[^"]|"")*")\s*$/su, item) do
      [_full, body, word] ->
        if alias_word?(word) and expression_end?(body),
          do: {String.trim(body), name(word)},
          else: {String.trim(item), nil}

      nil ->
        {String.trim(item), nil}
    end
  end

  @spec alias_word?(binary()) :: boolean()
  defp alias_word?(word), do: String.upcase(word) not in (@continuations ++ @alias_stops)

  # Whether the text ends an expression: its last word is not one that goes
  # on, and it does not end with an operator.
  @spec expression_end?(binary()) :: boolean()
  defp expression_end?(body) do
    last = body |> String.split(~r/[^\w"]+/u, trim: true) |> List.last()

    not (is_nil(last) or
           (Regex.match?(~r/\A\w+\z/u, last) and String.upcase(last) in @continuations))
  end

  @doc "A column name as written (a word, or a quoted identifier) as the name it holds."
  @spec name(binary()) :: binary()
  def name(text) do
    if SQLLiteral.identifier?(text), do: SQLLiteral.identifier_name(text), else: text
  end

  # A constant select item: a number, a string, a boolean, NULL or a `$name`.
  @constant ~r/^(?:-?(?:[0-9]+\.[0-9]*|\.[0-9]+|[0-9]+)(?:[eE][+-]?[0-9]+)?|'(?:[^']|'')*'|true|false|null|\$\w+)$/iu

  @doc """
  A constant select item as `{expression, name}` (`0.0` is `{{:lit, 0.0},
  "Float64(0)"}`), or `nil` when the item is not a constant. A name that
  cannot be written is `nil`.
  """
  @spec constant(binary()) :: {SQLExpr.t(), binary() | nil} | nil
  def constant(body) do
    if Regex.match?(@constant, SQLMask.mask(body)) do
      expr = constant_expr(body)
      {expr, rendered(expr, nil)}
    end
  end

  @spec constant_expr(binary()) :: SQLExpr.t()
  defp constant_expr(body) do
    cond do
      SQLLiteral.string?(body) ->
        {:lit, SQLLiteral.body(body)}

      name = SQLLiteral.param_name(body) ->
        {:param, name}

      true ->
        {:ok, expr} = SQLExpr.parse(body)
        expr
    end
  end

  @spec rendered(SQLExpr.t(), binary() | nil) :: binary() | nil
  defp rendered(expr, qualifier) do
    SQLExpr.render(expr, qualifier, :drop)
  catch
    :unrenderable -> nil
  end

  # Parse a single SELECT column expression
  @spec parse_single_column(binary(), binary() | nil) ::
          {:ok, column()} | {:error, term()}
  defp parse_single_column(col, qualifier) do
    masked = SQLMask.mask(col)
    {body, alias_name} = split_alias(col)

    cond do
      String.match?(masked, ~r/(?i)DATE_BIN\s*\(/u) ->
        parse_date_bin_column(col, body, alias_name, qualifier)

      String.match?(masked, ~r/(?i)\b(FIRST_VALUE|LAST_VALUE)\s*\(/u) ->
        parse_ordered_agg_column(col, body, alias_name, qualifier)

      String.match?(masked, ~r/(?i)\bSELECTOR_(FIRST|LAST|MIN|MAX)\s*\(/u) ->
        parse_selector_column(col, body, alias_name, qualifier)

      match = Regex.run(@influxql_call, masked) ->
        {:error, invalid_function(hd(match))}

      String.match?(masked, ~r/(?i)\b(?:#{@plain_alternation})\s*\(/u) ->
        parse_agg_column(col, body, alias_name, qualifier)

      constant = constant(body) ->
        parse_constant_column(col, constant, alias_name)

      String.match?(body, ~r/^#{@name}$/u) ->
        parse_grouping_column(body, alias_name)

      true ->
        {:error, SQLError.refusal("unsupported column expression: #{col}")}
    end
  end

  # An item with no alias is named by the engine; a name the double cannot
  # write is refused, and an alias spares the question.
  @doc """
  The output name of select item `col`: its `alias_name`, else the name
  `default` writes for it. A `default` that throws `:unrenderable` is a
  refusal by name.
  """
  @spec output_name(binary(), binary() | nil, (-> binary())) :: {:ok, binary()} | {:error, map()}
  def output_name(_col, alias_name, _default) when is_binary(alias_name), do: {:ok, alias_name}

  def output_name(col, nil, default) do
    {:ok, default.()}
  catch
    :unrenderable ->
      {:error,
       SQLError.refusal(
         "the name the engine gives this select item cannot be written here (a column of " <>
           "a joined table); add AS alias: " <> col
       )}
  end

  @spec parse_constant_column(binary(), {SQLExpr.t(), binary() | nil}, binary() | nil) ::
          {:ok, column()} | {:error, map()}
  defp parse_constant_column(col, {expr, default}, alias_name) do
    with {:ok, output} <-
           output_name(col, alias_name, fn -> default || throw(:unrenderable) end) do
      {:ok, {:constant, constant_value(expr), output}}
    end
  end

  @spec constant_value(SQLExpr.t()) :: term()
  defp constant_value({:lit, value}), do: value
  defp constant_value({:uint, value}), do: value
  defp constant_value({:param, _name} = param), do: param

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

  # Parse: first_value(field ORDER BY col [ASC|DESC])  (and last_value).
  #
  # Direction is folded into the aggregate atom at parse time: `:first` always
  # means "the point with the smallest ordering value" and `:last` the largest,
  # so first_value(... DESC) and last_value(... ASC) share one executor.
  #
  # ORDER BY is mandatory. DataFusion returns an arbitrary group member when it
  # is omitted, which the double cannot reproduce — accepting the query would
  # certify a non-deterministic result.
  @spec parse_ordered_agg_column(binary(), binary(), binary() | nil, binary() | nil) ::
          {:ok, column()} | {:error, term()}
  defp parse_ordered_agg_column(col, body, alias_name, qualifier) do
    case Regex.named_captures(@ordered_agg_pattern, body) do
      %{"func" => func, "field" => field, "ordering" => ordering, "direction" => direction}
      when ordering != "" ->
        agg = ordered_agg_end(func, direction)
        {field, ordering} = {name(field), name(ordering)}

        with {:ok, output} <-
               output_name(col, alias_name, fn ->
                 ordered_name(func, field, ordering, direction, qualifier)
               end) do
          {:ok, {:ordered_aggregate, agg, field, ordering, output}}
        end

      %{"func" => func} ->
        {:error,
         SQLError.refusal(
           "#{func}() needs ORDER BY inside the call: InfluxDB v3 returns an " <>
             "arbitrary row from the group without one, which this test double " <>
             "cannot reproduce. Write #{func}(field ORDER BY time): #{col}"
         )}

      nil ->
        {:error, SQLError.refusal("invalid aggregate: #{col}")}
    end
  end

  @spec ordered_name(binary(), binary(), binary(), binary(), binary() | nil) :: binary()
  defp ordered_name(func, field, ordering, direction, qualifier) do
    order =
      if String.upcase(direction) == "DESC", do: "DESC NULLS FIRST", else: "ASC NULLS LAST"

    "#{String.downcase(func)}(#{column_name(field, qualifier)}) ORDER BY " <>
      "[#{column_name(ordering, qualifier)} #{order}]"
  end

  @spec column_name(binary(), binary() | nil) :: binary()
  defp column_name(column, qualifier), do: SQLExpr.render({:field, column}, qualifier, :drop)

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
  @spec parse_grouping_column(binary(), binary() | nil) :: {:ok, column()}
  defp parse_grouping_column(body, alias_name) do
    source = name(body)
    {:ok, {:grouping_column, source, alias_name || source}}
  end

  # Parse: DATE_BIN(INTERVAL 'N unit', time) [AS alias]
  @spec parse_date_bin_column(binary(), binary(), binary() | nil, binary() | nil) ::
          {:ok, column()} | {:error, term()}
  defp parse_date_bin_column(col, body, alias_name, qualifier) do
    pattern = ~r/(?i)^DATE_BIN\s*\(\s*INTERVAL\s+'([^']+)'\s*,\s*time\s*\)$/u

    case Regex.run(pattern, body) do
      [_full, interval] ->
        with {:ok, output} <-
               output_name(col, alias_name, fn -> date_bin_name(interval, qualifier) end) do
          {:ok, {:time_bucket, output}}
        end

      _no_match ->
        {:error, SQLError.refusal("invalid DATE_BIN: #{col}")}
    end
  end

  # The engine writes the interval as months, days and nanoseconds: a unit of
  # days is days, anything shorter nanoseconds (verified).
  @spec date_bin_name(binary(), binary() | nil) :: binary()
  defp date_bin_name(interval, qualifier) do
    {days, nanoseconds} =
      case Regex.run(~r/^\s*([0-9]+)\s+(days?)\s*$/iu, interval) do
        [_full, count, _unit] -> {String.to_integer(count), 0}
        nil -> {0, interval_nanoseconds(interval)}
      end

    interval_text =
      "IntervalMonthDayNano { months: 0, days: #{days}, nanoseconds: #{nanoseconds} }"

    ~s|date_bin(IntervalMonthDayNano("#{interval_text}"),#{column_name("time", qualifier)})|
  end

  @spec interval_nanoseconds(binary()) :: non_neg_integer()
  defp interval_nanoseconds(interval) do
    case SQLTime.interval(interval) do
      {:ok, nanoseconds} -> nanoseconds
      {:error, _reason} -> throw(:unrenderable)
    end
  end

  # Parse: AGG(field) [AS alias].
  # COUNT(*) is special-cased — it counts rows regardless of field nullity
  # (matching real InfluxDB v3 / SQL semantics), so it doesn't fit the
  # one-expression shape used for the other aggregates.
  @spec parse_agg_column(binary(), binary(), binary() | nil, binary() | nil) ::
          {:ok, column()} | {:error, term()}
  defp parse_agg_column(col, body, alias_name, qualifier) do
    count_star = ~r/(?i)^\s*COUNT\s*\(\s*\*\s*\)\s*$/u
    distinct = ~r/(?i)^\s*(COUNT|SUM)\s*\(\s*DISTINCT\s+(.+?)\s*\)\s*$/us

    cond do
      error = time_aggregate_error(body) ->
        {:error, error}

      Regex.match?(count_star, body) ->
        with {:ok, output} <- output_name(col, alias_name, fn -> "count(*)" end) do
          {:ok, {:count_star, output}}
        end

      match = Regex.run(distinct, body) ->
        [_full, func, argument] = match
        distinct_column(col, String.downcase(func), argument, alias_name, qualifier)

      true ->
        parse_agg_column_arg(col, body, alias_name, qualifier)
    end
  end

  # `COUNT(DISTINCT x)` and `SUM(DISTINCT x)`: of a column, of a constant (`1`, `-1`, `NULL`,
  # `true`: one value over any rows, none over none) or of any expression. A leading `+` is
  # the engine's no-op (`+n` is the column `n`).
  @spec distinct_column(binary(), binary(), binary(), binary() | nil, binary() | nil) ::
          {:ok, column()} | {:error, term()}
  defp distinct_column(col, "count", word, alias_name, qualifier) do
    case plus_expression(word) do
      {:ok, {:field, _name} = expr} ->
        if Regex.match?(~r/\A#{@name}\z/u, word),
          do: count_distinct_field(col, word, alias_name, qualifier),
          else: distinct_expression(col, :count_distinct, expr, alias_name, qualifier)

      {:ok, expr} ->
        distinct_expression(col, :count_distinct, expr, alias_name, qualifier)

      {:error, _reason} ->
        {:error, SQLError.refusal("invalid aggregate: #{col}")}
    end
  end

  defp distinct_column(col, "sum", word, alias_name, qualifier) do
    case plus_expression(word) do
      {:ok, expr} -> distinct_expression(col, :sum_distinct, expr, alias_name, qualifier)
      {:error, _reason} -> {:error, SQLError.refusal("invalid aggregate: #{col}")}
    end
  end

  @spec count_distinct_field(binary(), binary(), binary() | nil, binary() | nil) ::
          {:ok, column()} | {:error, term()}
  defp count_distinct_field(col, word, alias_name, qualifier) do
    column = name(word)

    with {:ok, output} <-
           output_name(col, alias_name, fn ->
             "count(DISTINCT #{column_name(column, qualifier)})"
           end) do
      {:ok, {:count_distinct, column, output}}
    end
  end

  @spec distinct_expression(
          binary(),
          :count_distinct | :sum_distinct,
          SQLExpr.t(),
          binary() | nil,
          binary() | nil
        ) :: {:ok, column()} | {:error, term()}
  defp distinct_expression(col, agg, expr, alias_name, qualifier) do
    function = agg |> Atom.to_string() |> String.replace_suffix("_distinct", "")

    with {:ok, output} <-
           output_name(col, alias_name, fn ->
             "#{function}(DISTINCT #{SQLExpr.render(expr, qualifier, :drop)})"
           end) do
      {:ok, {:aggregate, agg, expr, output}}
    end
  end

  # The argument with its leading `+` signs as the unary plus (a number's own sign is part of
  # the number).
  @spec plus_expression(binary()) :: {:ok, SQLExpr.t()} | {:error, term()}
  defp plus_expression(text) do
    {signs, rest} = split_plus(text, 0)

    with {:ok, expr} <- SQLExpr.parse(rest) do
      {:ok, if(number?(expr), do: expr, else: wrap_plus(expr, signs))}
    end
  end

  @spec split_plus(binary(), non_neg_integer()) :: {non_neg_integer(), binary()}
  defp split_plus(text, count) do
    case Regex.run(~r/\A\s*\+(.*)\z/s, text) do
      [_all, rest] -> split_plus(rest, count + 1)
      nil -> {count, String.trim(text)}
    end
  end

  @spec number?(SQLExpr.t()) :: boolean()
  defp number?({:lit, value}), do: is_number(value)
  defp number?({:uint, _value}), do: true
  defp number?(_expr), do: false

  @spec wrap_plus(SQLExpr.t(), non_neg_integer()) :: SQLExpr.t()
  defp wrap_plus(expr, 0), do: expr
  defp wrap_plus(expr, count), do: wrap_plus({:pos, expr}, count - 1)

  # One argument, which may be an arithmetic expression over fields and
  # numeric literals (`SUM(value * value)`), as the real engine allows.
  # `AVG(field, other)` is not SQL: the expression parser rejects the comma.
  @spec parse_agg_column_arg(binary(), binary(), binary() | nil, binary() | nil) ::
          {:ok, column()} | {:error, term()}
  defp parse_agg_column_arg(col, body, alias_name, qualifier) do
    one_arg = ~r/(?i)^\s*(#{@plain_alternation})\s*\((.+)\)\s*$/su

    # `DISTINCT +n` is the engine's `DISTINCT` of `+n`, which reads as the sum of a column
    # `distinct` and `n`: only `COUNT` and `SUM` take a `DISTINCT` (see `distinct_column/5`).
    with [_full, func, expr_str] <- Regex.run(one_arg, body),
         false <- Regex.match?(~r/\A\s*DISTINCT(?![\w$])/iu, expr_str),
         {:ok, expr} <- SQLExpr.parse(expr_str),
         agg = Map.fetch!(@plain_aggregates, String.downcase(func)),
         :ok <- check_time_argument(agg, expr, col),
         {:ok, output} <-
           output_name(col, alias_name, fn ->
             "#{String.downcase(func)}(#{SQLExpr.render(expr, qualifier, :drop)})"
           end) do
      {:ok, {:aggregate, agg, expr, output}}
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

  # Parse: selector_first|last|min|max(field, time)[['value' | 'time']] [AS alias].
  # selector_first/last pick the row with the smallest/largest second
  # argument; selector_min/max pick the row with the smallest/largest field.
  @spec parse_selector_column(binary(), binary(), binary() | nil, binary() | nil) ::
          {:ok, column()} | {:error, term()}
  defp parse_selector_column(col, body, alias_name, qualifier) do
    case Regex.run(@selector_pattern, body) do
      [_full, kind, field, ordering | access] ->
        selector = String.to_existing_atom(String.downcase(kind))
        access = List.first(access, "")
        literal = literal_type(ordering)
        constant = literal_type(field)
        {field, ordering} = {name(field), name(ordering)}

        # A constant argument is the planner's error or the double's refusal (see
        # `selector_error/1`), found once the columns are: the column reads as `time` until
        # then.
        {field, ordering} =
          {if(constant, do: "time", else: field), if(literal, do: "time", else: ordering)}

        with {:ok, output} <-
               output_name(col, alias_name, fn ->
                 selector_name(kind, field, ordering, access, qualifier)
               end) do
          # Without a subscript the engine returns the whole struct.
          kind = if access == "", do: :struct, else: String.to_existing_atom(access)
          {:ok, {:selector, selector, field, ordering, kind, output}}
        end

      _no_match ->
        {:error,
         SQLError.refusal(
           "selector functions are supported as " <>
             "selector_first|last|min|max(field, time)[['value' | 'time']] [AS alias]: #{col}"
         )}
    end
  end

  # The type of an argument written as a constant rather than as a column: an integer is the
  # narrowest of `Int64` and `UInt64` it fits, else a `Float64`, as is a number with an
  # exponent (`1e3`).
  @spec literal_type(binary()) :: binary() | nil
  defp literal_type(text) do
    cond do
      Regex.match?(~r/\A\d+\z/, text) -> integer_type(String.to_integer(text))
      Regex.match?(~r/\A\d+[eE]\d+\z/, text) -> "Float64"
      String.downcase(text) == "null" -> "Null"
      String.downcase(text) in ["true", "false"] -> "Boolean"
      true -> nil
    end
  end

  @spec integer_type(non_neg_integer()) :: binary()
  defp integer_type(number) when number <= 9_223_372_036_854_775_807, do: "Int64"
  defp integer_type(number) when number <= 18_446_744_073_709_551_615, do: "UInt64"
  defp integer_type(_number), do: "Float64"

  @doc """
  The planner's error for a selector whose second argument is a constant, which it raises
  once the table and the columns of the statement are found, or `nil`. A selector over a
  constant first argument is the engine's struct of that constant and the time of a row, and
  which row decides it is not modelled: that is the double's refusal, at the same place.
  """
  @spec selector_error(binary()) :: map() | nil
  def selector_error(columns) do
    masked = SQLMask.mask(columns)

    ~r/(?i)\bSELECTOR_(FIRST|LAST|MIN|MAX)\s*\(\s*#{@name}\s*,\s*(\w+)\s*\)/u
    |> Regex.scan(masked)
    |> Enum.find_value(fn [call, selector, field, ordering] ->
      cond do
        type = literal_type(ordering) ->
          SQLError.planning(
            "selector_#{String.downcase(selector)} second argument must be a timestamp, " <>
              "but got #{type}"
          )

        literal_type(field) ->
          SQLError.refusal(
            "a selector over a constant instead of a column is not modelled: #{call}"
          )

        true ->
          nil
      end
    end)
  end

  @spec selector_name(binary(), binary(), binary(), binary(), binary() | nil) :: binary()
  defp selector_name(kind, field, ordering, access, qualifier) do
    subscript = if access == "", do: "", else: "[#{access}]"

    "selector_#{String.downcase(kind)}(#{column_name(field, qualifier)}," <>
      "#{column_name(ordering, qualifier)})" <> subscript
  end
end
