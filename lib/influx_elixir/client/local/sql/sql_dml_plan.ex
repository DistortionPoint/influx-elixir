defmodule InfluxElixir.Client.Local.SQLDmlPlan do
  @moduledoc false
  # Plans an operand of an `INSERT` or an `UPDATE` as the select item of a query, for
  # `InfluxElixir.Client.Local.SQLDml`: the engine types the values a statement assigns as it
  # types a select item, and finds the same errors in them. Only the planning is done (the
  # steps of `InfluxElixir.Client.Local.SQLExecutor` up to the planner's type checks), so no
  # row is read. What the engine finds only when it optimizes a plan (`Optimizer rule
  # 'simplify_expressions' failed`: a constant it cannot fold) is not an error of the statement,
  # which it refuses before it optimizes, so that error is let by here.

  alias InfluxElixir.Client.Local.{SQLParser, SQLPlan, SQLTyping}

  @uinteger_kind "iox::column_type::field::uinteger"

  @doc """
  `:ok` when the operand `text` plans as a select item over `measurement` (over nothing when it
  is `nil`, as the cells of a `VALUES` do), else the error the planner finds. `fetch` gives a
  measurement's points and `kinds` a column's registered kind.
  """
  @spec check(
          binary() | nil,
          binary(),
          (binary() -> {:ok, [map()]} | {:ok, [map()], [binary()]} | :error),
          (binary(), binary() -> binary() | nil)
        ) :: :ok | {:error, term()}
  def check(measurement, text, fetch, kinds) do
    sql = "SELECT " <> text <> from(measurement)

    unsigned? = fn column ->
      measurement != nil and kinds.(measurement, column) == @uinteger_kind
    end

    with {:ok, query} <- SQLParser.parse_select(sql),
         {:ok, bound} <- SQLParser.bind(query, %{}) do
      case SQLPlan.check(
             points(measurement, fetch),
             SQLTyping.retype(bound, unsigned?),
             unsigned?
           ) do
        {:error, %{body: "Optimizer rule " <> _rest}} -> :ok
        outcome -> outcome
      end
    end
  end

  # The table is there (the statement found it), so its points are what `fetch` gives; the
  # select is of a quoted name, with nothing after it, so it has no error of its own.
  @spec points(binary() | nil, (binary() -> term())) :: [map()]
  defp points(nil, _fetch), do: []

  defp points(measurement, fetch) do
    fetched = fetch.(measurement)
    if is_tuple(fetched), do: elem(fetched, 1), else: []
  end

  @spec from(binary() | nil) :: binary()
  defp from(nil), do: ""

  defp from(measurement),
    do: " FROM " <> ~s|"| <> String.replace(measurement, ~s|"|, ~s|""|) <> ~s|"|
end
