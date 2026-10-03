defmodule InfluxElixir.Client.Local.SQLAggExpr do
  @moduledoc false
  # A select item that is an expression of aggregates, of grouped columns, or
  # of both (`sum(n) / count(n)`, `max(x) - min(x)`, `round(avg(x), 2)`,
  # `CASE WHEN count(*) > 3 THEN ... END`, `n + 1` under `GROUP BY n`), and a
  # `HAVING`, for `InfluxElixir.Client.Local` (verified against InfluxDB 3
  # Core).
  #
  # Each call of an aggregate in the text is read as the aggregate item it
  # would be alone (`InfluxElixir.Client.Local.SQLSelect`) and stands in the
  # expression as a column called `__agN__`; the expression is then evaluated
  # for each group over a row that holds the group's first row and, as
  # `__agN__`, the aggregate's value. A null aggregate makes an arithmetic
  # result null (`sum(n) / count(n)` over no row), `count` is never null.
  #
  # An item with no alias is named as the engine names it: the expression with
  # each aggregate written as its own name (`sum(m.n) / count(m.n)`).

  alias InfluxElixir.Client.Local.{SQLError, SQLExpr, SQLLimit, SQLMask, SQLSelect, SQLWhere}

  @typedoc """
  An expression column: the expression with its aggregates as `__agN__`, the
  aggregates by those names, and the output name.
  """
  @type column :: {:expression, SQLExpr.t(), [{binary(), SQLSelect.column()}], binary()}

  @doc """
  The aggregate select list as columns: the items an aggregate query already
  reads (`InfluxElixir.Client.Local.SQLSelect`), and the ones that are
  expressions, or the first item's error.
  """
  @spec parse_list(binary(), binary() | nil) ::
          {:ok, [SQLSelect.column() | column()]} | {:error, term()}
  def parse_list(columns_str, qualifier \\ nil) do
    columns =
      columns_str
      |> SQLMask.split_commas()
      |> Enum.map(&String.trim/1)
      |> Enum.map(&parse_item(&1, qualifier))

    case Enum.find(columns, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(columns, fn {:ok, column} -> column end)}
      error -> error
    end
  end

  @spec parse_item(binary(), binary() | nil) ::
          {:ok, SQLSelect.column() | column()} | {:error, term()}
  defp parse_item(item, qualifier) do
    {body, alias_name} = SQLSelect.split_alias(item)

    if expression?(body),
      do: expression_column(item, body, alias_name, qualifier),
      else: SQLSelect.parse_item(item, qualifier)
  end

  # An item that is more than one aggregate call alone, or a group item that
  # is more than a name: an aggregate in an expression, or an expression.
  @spec expression?(binary()) :: boolean()
  defp expression?(body) do
    masked = SQLMask.mask(body)

    cond do
      Regex.match?(~r/(?i)\bDATE_BIN\s*\(/u, masked) -> false
      SQLSelect.influxql_call?(body) -> false
      SQLSelect.constant(body) -> false
      true -> expression_shape?(body)
    end
  end

  @spec expression_shape?(binary()) :: boolean()
  defp expression_shape?(body) do
    case SQLSelect.aggregate_spans(body) do
      [] -> not Regex.match?(~r/\A(?:\w+|"(?:[^"]|"")*")\z/u, body)
      [{0, length}] -> length != byte_size(body)
      _several -> true
    end
  end

  @spec expression_column(binary(), binary(), binary() | nil, binary() | nil) ::
          {:ok, column()} | {:error, term()}
  defp expression_column(item, body, alias_name, qualifier) do
    with {:ok, text, aggs} <- replace_aggregates(body, qualifier),
         {:ok, expr} <- read(text, item),
         name = fn -> default_name(expr, aggs, qualifier) end,
         {:ok, output} <- SQLSelect.output_name(item, alias_name, name) do
      {:ok, {:expression, expr, aggs, output}}
    end
  end

  @doc """
  An expression text with its aggregates read: the expression over `__agN__`
  columns and the aggregates by those names.
  """
  @spec read_expression(binary(), binary() | nil) ::
          {:ok, SQLExpr.t(), [{binary(), SQLSelect.column()}]} | {:error, term()}
  def read_expression(body, qualifier) do
    with {:ok, text, aggs} <- replace_aggregates(body, qualifier),
         {:ok, expr} <- read(text, body) do
      {:ok, expr, aggs}
    end
  end

  @spec read(binary(), binary()) :: {:ok, SQLExpr.t()} | {:error, term()}
  defp read(text, item) do
    case SQLExpr.parse(text) do
      {:ok, expr} -> {:ok, expr}
      {:error, _reason} -> {:error, SQLError.refusal("unsupported column expression: #{item}")}
    end
  end

  # The text with each aggregate call replaced by its `__agN__` name, and the
  # aggregates read.
  @spec replace_aggregates(binary(), binary() | nil) ::
          {:ok, binary(), [{binary(), SQLSelect.column()}]} | {:error, term()}
  defp replace_aggregates(body, qualifier) do
    spans = SQLSelect.aggregate_spans(body)

    spans
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{start, length}, index}, {:ok, acc} ->
      case SQLSelect.parse_item(binary_part(body, start, length), qualifier) do
        {:ok, column} -> {:cont, {:ok, [{placeholder(index), column} | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, aggs} -> {:ok, substitute(body, spans), Enum.reverse(aggs)}
      {:error, _reason} = error -> error
    end
  end

  @spec substitute(binary(), [{non_neg_integer(), pos_integer()}]) :: binary()
  defp substitute(body, spans) do
    {text, last} =
      spans
      |> Enum.with_index()
      |> Enum.reduce({"", 0}, fn {{start, length}, index}, {acc, from} ->
        {acc <> binary_part(body, from, start - from) <> " " <> placeholder(index) <> " ",
         start + length}
      end)

    text <> binary_part(body, last, byte_size(body) - last)
  end

  @doc "The name an aggregate stands under in an expression."
  @spec placeholder(non_neg_integer()) :: binary()
  def placeholder(index), do: "__ag#{index}__"

  # The engine's name for the expression: the aggregates by their own names.
  @spec default_name(SQLExpr.t(), [{binary(), SQLSelect.column()}], binary() | nil) :: binary()
  defp default_name(expr, aggs, qualifier) do
    names = Map.new(aggs, fn {placeholder, column} -> {placeholder, last(column)} end)
    expr |> named(names) |> SQLExpr.render(qualifier, :drop)
  end

  @spec named(SQLExpr.t(), %{binary() => binary()}) :: SQLExpr.t()
  defp named({:field, name} = field, names) when is_binary(name) do
    case names do
      %{^name => text} -> {:raw, text}
      _plain -> field
    end
  end

  defp named(expr, names), do: SQLExpr.map_children(expr, &named(&1, names))

  @typedoc """
  A `HAVING`: its condition over `__agN__` columns (and the group's columns and
  the select list's names), and the aggregates by those names.
  """
  @type having_t :: %{
          nodes: [SQLWhere.node_t()],
          aggs: [{binary(), SQLSelect.column()}]
        }

  @having ~r/(?i)\bHAVING\s+(.+?)(?:\s+ORDER\b|\s+#{SQLLimit.start_source()}|\s*$)/su

  @doc """
  The `HAVING` of the text after the table, with `groups` the `GROUP BY` items
  (`nil` for none). A condition that is no comparison (a bare aggregate), and a
  `HAVING` with no group and no aggregate, are refused by name: the engine's
  error for them words the condition as it prints it.
  """
  @spec having(
          binary(),
          binary() | nil,
          [binary() | {:expr, SQLExpr.t()}] | nil,
          [SQLSelect.column() | column()]
        ) :: {:ok, having_t() | nil} | {:error, term()}
  def having(rest, qualifier, groups, select_columns) do
    case SQLMask.run(@having, rest) do
      nil ->
        {:ok, nil}

      [_full, text] ->
        with {:ok, replaced, aggs} <- replace_aggregates(text, qualifier),
             {:ok, nodes} <- SQLWhere.nodes("WHERE " <> replaced),
             :ok <- check_having(nodes, aggs, groups, select_columns, text) do
          {:ok, %{nodes: nodes, aggs: aggs}}
        end
    end
  end

  @spec check_having(
          [SQLWhere.node_t()],
          [{binary(), SQLSelect.column()}],
          term(),
          [SQLSelect.column() | column()],
          binary()
        ) :: :ok | {:error, SQLError.t()}
  defp check_having(nodes, aggs, groups, select_columns, text) do
    outputs = for column <- select_columns, elem(column, 0) != :grouping_column, do: last(column)
    named? = Enum.any?(SQLWhere.conjunction_columns(nodes), &(&1 in outputs))

    cond do
      Enum.any?(nodes, &match?({:truthy, _column, _nil}, &1)) ->
        {:error,
         SQLError.refusal("a HAVING that is a column or an aggregate, not a comparison: #{text}")}

      aggs == [] and is_nil(groups) and not named? ->
        {:error,
         SQLError.refusal(
           "a HAVING with no GROUP BY and no aggregate: the engine's error words the " <>
             "condition as it prints it: #{text}"
         )}

      true ->
        :ok
    end
  end

  @doc "The columns an expression column reads outside its aggregates."
  @spec plain_columns(SQLExpr.t()) :: [binary()]
  def plain_columns(expr) do
    for name <- SQLExpr.columns(expr), is_binary(name), not placeholder?(name), do: name
  end

  @doc "Whether a column name is one of the aggregates' names."
  @spec placeholder?(binary()) :: boolean()
  def placeholder?(name), do: Regex.match?(~r/\A__ag\d+__\z/, name)

  @spec last(tuple()) :: term()
  defp last(tuple), do: elem(tuple, tuple_size(tuple) - 1)
end
