defmodule InfluxElixir.Client.Local.SQLDmlPlan do
  @moduledoc false
  # Plans an operand of an `UPDATE` as the select item of a query over its table, for
  # `InfluxElixir.Client.Local.SQLDml`: the engine types the values an update assigns as it
  # types a select item, and finds the same errors in them. Only the planning is done (the
  # steps of `InfluxElixir.Client.Local.SQLExecutor` up to the planner's type checks), so no
  # row is read and nothing the engine finds only when it optimizes or runs a plan is raised.

  alias InfluxElixir.Client.Local.{SQLParser, SQLPlan, SQLTyping}

  @uinteger_kind "iox::column_type::field::uinteger"

  @doc """
  `:ok` when the operand `text` plans as a select item over `measurement`, else the error the
  planner finds. `fetch` gives a measurement's points and `kinds` a column's registered kind.
  """
  @spec check(
          binary(),
          binary(),
          (binary() -> {:ok, [map()]} | {:ok, [map()], [binary()]} | :error),
          (binary(), binary() -> binary() | nil)
        ) :: :ok | {:error, term()}
  def check(measurement, text, fetch, kinds) do
    sql = "SELECT " <> text <> " FROM " <> quoted(measurement)
    unsigned? = fn column -> kinds.(measurement, column) == @uinteger_kind end

    # The table is there (the update found it), so its points are what `fetch` gives; the
    # select is of a quoted name, with nothing after it, so it has no error of its own.
    fetched = fetch.(measurement)
    points = if is_tuple(fetched), do: elem(fetched, 1), else: []

    with {:ok, query} <- SQLParser.parse_select(sql),
         {:ok, bound} <- SQLParser.bind(query, %{}) do
      SQLPlan.check(points, SQLTyping.retype(bound, unsigned?), unsigned?)
    end
  end

  @spec quoted(binary()) :: binary()
  defp quoted(name), do: ~s|"| <> String.replace(name, ~s|"|, ~s|""|) <> ~s|"|
end
