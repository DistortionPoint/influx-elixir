defmodule InfluxElixir.Client.Local.SQLClauses do
  @moduledoc """
  The `GROUP BY` and `ORDER BY` clauses of a SQL text, as DataFusion reads
  them (verified against InfluxDB 3 Core).

  `GROUP BY 1`, `ORDER BY 2 DESC` and `GROUP BY bucket` (a select alias) are
  rewritten to the select items they name before anything else reads the
  clauses: a position becomes the item's expression in GROUP BY and its
  output name in ORDER BY, an alias in GROUP BY becomes its expression. A
  position outside the select list is the engine's planning error.

  A `GROUP BY` item that is a `DATE_BIN(...)` sets the bucket interval; the
  others are grouping columns, and the two combine (`GROUP BY DATE_BIN(...),
  host`: one row per bucket per host).
  """

  alias InfluxElixir.Client.Local.{
    SQLError,
    SQLExpr,
    SQLLimit,
    SQLLiteral,
    SQLMask,
    SQLSelect,
    SQLTime
  }

  @typedoc "`:asc` / `:desc` (nulls last / first), or a direction with explicit NULLS placement."
  @type direction :: :asc | :desc | {:asc | :desc, :nulls_first | :nulls_last}

  @typedoc "`ORDER BY` terms in order; a target is `time`, a column, an output alias or an expression."
  @type order_by :: [{binary() | {:expr, SQLExpr.t()}, direction()}]

  @limit_start SQLLimit.start_source()

  @group_clause ~r/(?i)(\bGROUP\s+BY\s+)(.+?)(?=\s+ORDER\b|\s+#{@limit_start}|\s*$)/su
  @order_clause ~r/(?i)(\bORDER\s+BY\s+)(.+?)(?=\s+#{@limit_start}|\s*$)/su

  @doc """
  Rewrites the positions and select aliases of the clauses in `rest`, the
  text after the table, to the items they name. `columns` is the select list;
  `namer` gives the output name of an item without an alias, or `nil`
  when the double cannot write it (the item then stands for itself).
  """
  @spec resolve_references(binary(), binary(), (binary() -> binary() | nil)) ::
          {:ok, binary()} | {:error, SQLError.t()}
  def resolve_references(columns, rest, namer) do
    items =
      columns
      |> SQLMask.split_commas()
      |> Enum.map(&(&1 |> String.trim() |> select_item(namer)))

    with {:ok, rest} <- rewrite_clause(rest, @group_clause, &group_term(&1, items)) do
      rewrite_clause(rest, @order_clause, &order_term(&1, items))
    end
  end

  # {expression, output name} of one select item.
  @spec select_item(binary(), (binary() -> binary() | nil)) :: {binary(), binary()}
  defp select_item(item, namer) do
    case SQLSelect.split_alias(item) do
      {expr, alias_name} when is_binary(alias_name) -> {expr, alias_name}
      {_item, nil} -> {item, namer.(item) || item}
    end
  end

  # An output name as a term of a clause: bare when it is one word, else
  # quoted.
  @spec identifier_text(binary()) :: binary()
  defp identifier_text(name) do
    if Regex.match?(~r/\A[\p{L}_][\p{L}\p{N}_]*\z/u, name),
      do: name,
      else: ~s|"#{String.replace(name, ~s("), ~s(""))}"|
  end

  @spec rewrite_clause(binary(), Regex.t(), (binary() -> {:ok, binary()} | {:error, map()})) ::
          {:ok, binary()} | {:error, map()}
  defp rewrite_clause(rest, pattern, rewrite_term) do
    case Regex.run(pattern, SQLMask.mask(rest), return: :index) do
      [{start, len}, {_kw_start, kw_len}, {_list_start, _list_len}] ->
        clause = binary_part(rest, start, len)
        keyword = binary_part(clause, 0, kw_len)
        list = binary_part(clause, kw_len, len - kw_len)

        list
        |> SQLMask.split_commas()
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
      case SQLMask.run(~r/^(.+?)\s+(ASC|DESC)$/isu, term) do
        [_full, target, direction] -> {target, " " <> direction}
        nil -> {term, ""}
      end

    case positional(target, items) do
      {:ok, {_expr, name}} -> {:ok, identifier_text(name) <> direction}
      :not_positional -> {:ok, aggregate_term(target, items, direction) || term}
      error -> error
    end
  end

  # An aggregate in ORDER BY that the select list also holds is that item
  # (`ORDER BY sum(v)` after `sum(v) AS total` sorts by `total`).
  @spec aggregate_term(binary(), [{binary(), binary()}], binary()) :: binary() | nil
  defp aggregate_term(target, items, direction) do
    if SQLSelect.aggregate_call?(target) do
      Enum.find_value(items, fn {expr, name} ->
        if squeeze(expr) == squeeze(target), do: identifier_text(name) <> direction
      end)
    end
  end

  @spec squeeze(binary()) :: binary()
  defp squeeze(text), do: String.replace(text, ~r/\s+/u, "")

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

  # The GROUP BY items, after positions and aliases were resolved. A
  # `DATE_BIN(...)` item sets the bucket interval; the others are grouping
  # columns, and the two combine (`GROUP BY DATE_BIN(...), host`: one row
  # per bucket per host, verified).
  @spec group_by_items(binary()) :: [binary()]
  defp group_by_items(sql) do
    case SQLMask.run(@group_clause, sql) do
      [_full, _keyword, list] ->
        list |> SQLMask.split_commas() |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      nil ->
        []
    end
  end

  @spec date_bin_item?(binary()) :: boolean()
  defp date_bin_item?(item), do: Regex.match?(~r/^DATE_BIN\s*\(/iu, item)

  @doc """
  The bare-column `GROUP BY` items of a statement (a quoted name as the name
  it holds), or `nil` when there are none.
  """
  @spec group_columns(binary()) :: [binary()] | nil
  def group_columns(sql) do
    case sql |> group_by_items() |> Enum.reject(&date_bin_item?/1) do
      [] -> nil
      columns -> Enum.map(columns, &SQLSelect.name/1)
    end
  end

  @doc """
  The `GROUP BY DATE_BIN` bucket of a statement in nanoseconds, or `nil`.
  The `DATE_BIN` is optional: without it the executor groups by columns or
  produces a single scalar row; a malformed interval still surfaces.
  """
  @spec interval(binary()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def interval(sql) do
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

  @doc """
  Checks the `DATE_BIN`s of a select list against the `GROUP BY` bucket
  (`group_interval`, in nanoseconds): each must be that bucket, or the double
  refuses the query by name.
  """
  @spec check_date_bins(binary(), non_neg_integer() | nil) :: :ok | {:error, map()}
  def check_date_bins(columns, group_interval) do
    columns
    |> SQLMask.split_commas()
    |> Enum.flat_map(&date_bin_interval/1)
    |> Enum.reduce_while(:ok, fn interval, :ok ->
      case SQLTime.interval(interval) do
        {:ok, ns} when ns == group_interval -> {:cont, :ok}
        {:ok, _ns} -> {:halt, {:error, SQLError.refusal(@date_bin_mismatch <> columns)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec date_bin_interval(binary()) :: [binary()]
  defp date_bin_interval(column) do
    case SQLMask.run(~r/(?i)DATE_BIN\s*\(\s*INTERVAL\s+'([^']+)'/u, column) do
      [_full, interval] -> [interval]
      nil -> []
    end
  end

  # DATE_BIN(INTERVAL 'N unit', time) → the interval in nanoseconds
  @spec parse_group_by_interval(binary()) ::
          {:ok, pos_integer()} | {:error, term()}
  defp parse_group_by_interval(item) do
    pattern =
      ~r/(?i)^DATE_BIN\s*\(\s*INTERVAL\s+'([^']+)'\s*,\s*time\s*\)$/u

    case Regex.run(pattern, item) do
      [_full, interval_str] -> SQLTime.interval(interval_str)
      _no_match -> {:error, SQLError.refusal("missing GROUP BY DATE_BIN")}
    end
  end

  @doc """
  The `ORDER BY a [ASC|DESC][, b [ASC|DESC] ...]` terms of the text after
  the table. A target may be a column, `time`, an output alias (the
  `DATE_BIN` alias, say) or an expression (`CAST(level AS INTEGER) DESC`); a
  target the expression parser cannot read is left as a column name so the
  schema check names it. The direction defaults to ascending, as in SQL.
  """
  @spec order_by(binary()) :: order_by()
  def order_by(rest) do
    case SQLMask.run(~r/(?i)ORDER\s+BY\s+(.+?)\s*(?:\b#{@limit_start}.*)?$/su, rest) do
      [_full_match, list] ->
        list
        |> SQLMask.split_commas()
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&parse_order_term/1)

      _no_match ->
        []
    end
  end

  @spec parse_order_term(binary()) :: {binary() | {:expr, SQLExpr.t()}, :asc | :desc}
  # `[ASC|DESC] [NULLS FIRST|LAST]`. Without NULLS, DataFusion puts nulls
  # last ascending and first descending (verified); the direction then
  # stays a bare atom and the executor applies that default.
  defp parse_order_term(term) do
    case SQLMask.run(~r/^(.+?)(?:\s+(ASC|DESC))?(?:\s+NULLS\s+(FIRST|LAST))?$/isu, term) do
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

  @spec order_target(binary()) :: binary() | {:expr, SQLExpr.t()}
  defp order_target(target) do
    cond do
      Regex.match?(~r/^\w+$/u, target) -> target
      SQLLiteral.identifier?(target) -> SQLLiteral.identifier_name(target)
      true -> order_expression(target)
    end
  end

  @spec order_expression(binary()) :: binary() | {:expr, SQLExpr.t()}
  defp order_expression(target) do
    case SQLExpr.parse(target) do
      {:ok, expr} -> {:expr, expr}
      {:error, _reason} -> target
    end
  end

  @spec direction_atom(binary()) :: :asc | :desc
  defp direction_atom(direction) do
    if String.upcase(direction) == "DESC", do: :desc, else: :asc
  end
end
