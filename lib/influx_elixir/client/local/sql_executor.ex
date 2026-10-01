defmodule InfluxElixir.Client.Local.SQLExecutor do
  @moduledoc """
  Executes a parsed SQL query for `InfluxElixir.Client.Local`.

  Takes the `t:InfluxElixir.Client.Local.SQLParser.parsed_query/0` the parser
  produced and a function that fetches a measurement's points, and returns
  rows in the shape InfluxDB 3's JSON responses have: string keys, `time` as a
  `DateTime`, null columns omitted. Every rule the double enforces about what
  the engine returns — null omission, DataFusion's comparison and cast
  semantics, schema errors for unknown columns, the failure shape of a cast
  that cannot be performed — lives here; storage, profiles and the other query
  languages stay in `Client.Local`.

  Pure over the points it is given: no ETS, no connection state.
  """

  alias InfluxElixir.Client.Local.{Format, LineProtocolParser, SQLFunctions, SQLParser, Store}

  @typedoc "A stored point, as `InfluxElixir.Client.Local` keeps it."
  @type point :: LineProtocolParser.point()

  @typedoc "Fetches a measurement's points, or `:error` when there is no such measurement."
  @type fetch :: (binary() -> {:ok, [point()]} | :error)

  # The order an ascending sort (and `first_value`/`last_value`) puts nulls in.
  @ascending {:asc, :nulls_last}

  @doc false
  @spec nanoseconds_to_datetime(integer() | nil) :: DateTime.t() | nil
  def nanoseconds_to_datetime(nil), do: nil
  def nanoseconds_to_datetime(ns), do: DateTime.from_unix!(ns, :nanosecond)

  # CTEs run first, in order, each over the store or an earlier CTE; their
  # rows become the points the next query reads (a CTE shadows a measurement
  # of the same name, as in SQL).
  @doc """
  Runs a parsed query. `fetch` returns a measurement's points, or `:error`
  when the measurement does not exist; CTEs shadow it by name.
  """
  @spec run(SQLParser.parsed_query(), fetch()) :: [map()] | {:error, term()}
  def run(query, fetch) do
    query.ctes
    |> Enum.reduce_while({:ok, %{}}, fn {name, cte_query}, {:ok, sources} ->
      case select(cte_query, fetch, sources) do
        {:error, _reason} = error ->
          {:halt, error}

        {:ok, rows, source} ->
          columns = output_columns(cte_query, source)
          {:cont, {:ok, Map.put(sources, name, rows_to_points(name, rows, columns))}}
      end
    end)
    |> case do
      {:ok, sources} -> execute_select(query, fetch, sources)
      {:error, _reason} = error -> error
    end
  end

  @spec execute_select(SQLParser.parsed_query(), fetch(), %{binary() => [point()]}) ::
          [map()] | {:error, term()}
  defp execute_select(query, fetch, cte_sources) do
    case select(query, fetch, cte_sources) do
      {:ok, rows, _source} -> rows
      {:error, _reason} = error -> error
    end
  end

  # The rows, with the points they were read from (after any join, before
  # WHERE): a CTE has the schema of its source, not of the rows it kept.
  @spec select(SQLParser.parsed_query(), fetch(), %{binary() => [point()]}) ::
          {:ok, [map()], [point()]} | {:error, term()}
  defp select(%{measurement: m} = query, fetch, cte_sources) do
    with {:ok, points} <- source_points(fetch, m, cte_sources),
         {:ok, joined} <- cross_join(fetch, points, query, cte_sources),
         :ok <- check_query_columns(joined, query),
         :ok <- check_plan(joined, query),
         :ok <- check_grouping_columns(query),
         {:ok, filtered} <- apply_where(joined, query.where) do
      {:ok, query_rows(filtered, query), joined}
    else
      :error -> {:error, table_not_found(m)}
      {:error, _reason} = error -> error
    end
  catch
    # Errors only discoverable per value (a LIKE over a number, a CAST that
    # cannot be performed) are thrown from the evaluator and become the
    # engine's error here.
    {:query_error, error} -> {:error, error}
  end

  @spec query_rows([point()], SQLParser.parsed_query()) :: [map()]
  defp query_rows(points, query) do
    cond do
      query.distinct_columns ->
        execute_distinct_query(points, query)

      query.select_columns ->
        execute_aggregate_query(points, query)

      query.projection_columns ->
        execute_projection_query(points, query)

      true ->
        points
        |> apply_order_by(query.order_by)
        |> distinct_on(query.distinct_on, & &1)
        |> apply_limit(query.limit, query.offset)
        |> Enum.map(&point_to_row/1)
    end
  end

  @spec source_points(fetch(), binary(), %{binary() => [point()]}) ::
          {:ok, [point()]} | :error
  defp source_points(fetch, measurement, cte_sources) do
    case Map.fetch(cte_sources, measurement) do
      {:ok, points} -> {:ok, points}
      :error -> fetch.(measurement)
    end
  end

  # `FROM w CROSS JOIN ref`: every left point paired with every right point,
  # the right side's columns merged in as fields. Qualifiers were dropped
  # at parse time, so a column present on both sides cannot be told apart
  # any more. The engine refuses an unqualified reference to such a column
  # (the first one its planner meets: WHERE, then the select list, then the
  # rest) and the double does too; a query that names none of them is fine
  # on the engine. `SELECT *` would return each shared column twice, which
  # a row map cannot hold, so that is refused by name. Both sides carry
  # `time`. Rows are the left side's measurement and timestamp.
  @spec cross_join(fetch(), [point()], SQLParser.parsed_query(), %{binary() => [point()]}) ::
          {:ok, [point()]} | {:error, term()}
  defp cross_join(_fetch, points, %{cross_join: nil}, _cte_sources), do: {:ok, points}

  defp cross_join(fetch, points, %{cross_join: {right_name, _aliases}} = query, cte_sources) do
    with {:ok, right_points} <- fetch_source(fetch, right_name, cte_sources),
         :ok <- check_join_collisions(points, right_points, query) do
      {:ok,
       for left <- points, right <- right_points do
         %{
           left
           | tags: Map.merge(left.tags, right.tags),
             fields: Map.merge(left.fields, right.fields)
         }
       end}
    end
  end

  @spec fetch_source(fetch(), binary(), %{binary() => [point()]}) ::
          {:ok, [point()]} | {:error, term()}
  defp fetch_source(fetch, name, cte_sources) do
    case source_points(fetch, name, cte_sources) do
      {:ok, points} -> {:ok, points}
      :error -> {:error, table_not_found(name)}
    end
  end

  @spec check_join_collisions([point()], [point()], SQLParser.parsed_query()) ::
          :ok | {:error, term()}
  defp check_join_collisions(left, right, query) do
    right_columns = right |> point_columns() |> maybe_add_time(right)
    shared = MapSet.intersection(left |> point_columns() |> maybe_add_time(left), right_columns)
    references = where_refs(query.where) ++ referenced_columns(query)

    cond do
      MapSet.size(shared) == 0 ->
        :ok

      ambiguous = Enum.find(references, &MapSet.member?(shared, &1)) ->
        {:error,
         %{
           status: 500,
           body: "Schema error: Ambiguous reference to unqualified field #{ambiguous}"
         }}

      star?(query) ->
        {:error,
         local_refusal(
           "SELECT * over a CROSS JOIN whose sides share #{Enum.join(Enum.sort(shared), ", ")} " <>
             "returns each twice, which a row map cannot hold; name the columns"
         )}

      true ->
        :ok
    end
  end

  @spec star?(SQLParser.parsed_query()) :: boolean()
  defp star?(query),
    do:
      is_nil(query.distinct_columns) and is_nil(query.select_columns) and
        is_nil(query.projection_columns)

  @spec local_refusal(binary()) :: %{status: 400, body: binary()}
  defp local_refusal(reason), do: %{status: 400, body: "Client.Local: " <> reason}

  @spec point_columns([point()]) :: MapSet.t(binary())
  defp point_columns(points) do
    Enum.reduce(points, MapSet.new(), fn point, acc ->
      MapSet.union(acc, point_columns_of(point))
    end)
  end

  @spec point_columns_of(point()) :: MapSet.t(binary())
  defp point_columns_of(point) do
    MapSet.new(Map.keys(point.tags) ++ Map.keys(point.fields))
  end

  @spec maybe_add_time(MapSet.t(binary()), [point()]) :: MapSet.t(binary())
  defp maybe_add_time(columns, points) do
    if Enum.any?(points, &(not is_nil(&1.timestamp))),
      do: MapSet.put(columns, "time"),
      else: columns
  end

  # A column the query names that no row has — in SELECT, an aggregate,
  # WHERE, GROUP BY, ORDER BY or DISTINCT — is the engine's schema error
  # ("No field named prod"), not an empty or unsorted result. The usual
  # cause is a typo or a forgotten pair of quotes around a string literal.
  # With no rows the schema is unknown, so nothing is checked.
  @spec check_query_columns([point()], SQLParser.parsed_query()) :: :ok | {:error, term()}
  defp check_query_columns([], _query), do: :ok

  defp check_query_columns([first | _rest] = points, query) do
    # Almost every query names only columns the first row has, so that row
    # answers first; the full scan (every row's columns) runs only when a
    # name is missing there, which is also when the error message needs it.
    first_row_columns = first |> point_columns_of() |> MapSet.put("time")

    case Enum.reject(referenced_columns(query), &MapSet.member?(first_row_columns, &1)) do
      [] -> :ok
      candidates -> check_against_all_rows(points, candidates)
    end
  end

  @spec check_against_all_rows([point()], [binary()]) :: :ok | {:error, term()}
  defp check_against_all_rows(points, candidates) do
    known = points |> point_columns() |> MapSet.put("time")

    case Enum.reject(candidates, &MapSet.member?(known, &1)) do
      [] ->
        :ok

      [missing | _rest] ->
        {:error,
         %{
           status: 500,
           body:
             "Schema error: No field named #{missing}. Valid fields are " <>
               Enum.join(Enum.sort(known), ", ") <> "."
         }}
    end
  end

  # The engine checks an expression's types when it plans the query, so a
  # wrong one fails it even when no row would reach it: a function's
  # arguments, an arithmetic operator's operands, a negation, an aggregate's
  # argument, the operand of a LIKE or a regex. Its planner reads WHERE,
  # then the select list, then ORDER BY, and within a term the innermost
  # part first.
  @spec check_plan([point()], SQLParser.parsed_query()) :: :ok | {:error, map()}
  defp check_plan(points, query) do
    contexts = [
      where: plan_items(query.where),
      select: select_items(query),
      order_by: plan_items(Enum.map(query.order_by, &elem(&1, 0)))
    ]

    case for({context, items} <- contexts, item <- items, do: {context, item}) do
      [] -> :ok
      checks -> check_items(checks, column_types(points, plan_columns(checks)))
    end
  end

  @spec select_items(SQLParser.parsed_query()) :: [term()]
  defp select_items(query) do
    projected = Enum.flat_map(query.projection_columns || [], &plan_items(elem(&1, 0)))

    aggregated =
      Enum.flat_map(query.select_columns || [], fn
        {:aggregate, agg, expr, _alias} -> plan_items(expr) ++ [{:aggregate, agg, expr}]
        _other -> []
      end)

    projected ++ aggregated
  end

  # Every part of a term the planner types, the innermost first.
  @spec plan_items(term()) :: [term()]
  defp plan_items({:call, _function, args} = call), do: plan_items(args) ++ [call]
  defp plan_items({:op, _op, left, right} = op), do: plan_items(left) ++ plan_items(right) ++ [op]
  defp plan_items({:neg, inner} = neg), do: plan_items(inner) ++ [neg]

  defp plan_items({kind, left, rest}) when kind in [:like, :not_like, :regex, :not_regex] do
    operand = pattern_operand(left)
    plan_items(operand) ++ [{:pattern, kind, operand, rest}]
  end

  defp plan_items(terms) when is_list(terms), do: Enum.flat_map(terms, &plan_items/1)
  defp plan_items(term) when is_tuple(term), do: term |> Tuple.to_list() |> plan_items()
  defp plan_items(_other), do: []

  @spec pattern_operand(SQLParser.operand()) :: SQLParser.expr()
  defp pattern_operand({:expr, expr}), do: expr
  defp pattern_operand(column), do: {:field, column}

  @spec plan_columns([{SQLFunctions.context(), term()}]) :: [binary()]
  defp plan_columns(checks),
    do: Enum.flat_map(checks, fn {_context, item} -> expr_fields(item) end)

  @spec check_items([{SQLFunctions.context(), term()}], %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp check_items(checks, columns) do
    Enum.reduce_while(checks, :ok, fn {context, item}, :ok ->
      case check_item(item, context, columns) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @numeric ~w(Int64 UInt64 Float64)

  @spec check_item(term(), SQLFunctions.context(), %{binary() => binary()}) ::
          :ok | {:error, map()}
  defp check_item({:call, function, args}, context, columns),
    do: SQLFunctions.check(function, Enum.map(args, &SQLFunctions.type_of(&1, columns)), context)

  defp check_item({:op, op, left, right}, context, columns) do
    case {SQLFunctions.type_of(left, columns), SQLFunctions.type_of(right, columns)} do
      {left_type, right_type}
      when is_binary(left_type) and is_binary(right_type) and
             not (left_type in @numeric and right_type in @numeric) ->
        planning_error(
          "Cannot coerce arithmetic expression #{left_type} #{operator(op)} #{right_type} " <>
            "to valid types",
          context
        )

      _typed_or_unknown ->
        :ok
    end
  end

  # The engine words a negation the same wherever it stands.
  defp check_item({:neg, inner}, _context, columns) do
    case SQLFunctions.type_of(inner, columns) do
      type when type in [nil, "Timestamp(ns)" | @numeric] ->
        :ok

      _not_numeric ->
        planning_error("Negation only supports numeric, interval and timestamp types", :select)
    end
  end

  defp check_item({:aggregate, agg, expr}, _context, columns) do
    case SQLFunctions.type_of(expr, columns) do
      nil -> :ok
      type -> aggregate_refusal(agg, type)
    end
  end

  defp check_item({:pattern, kind, expr, rest}, context, columns) do
    case SQLFunctions.type_of(expr, columns) do
      type when type in ["Boolean" | @numeric] ->
        planning_error(pattern_error(kind, type, rest), context)

      _text_or_unknown ->
        :ok
    end
  end

  @spec operator(atom()) :: binary()
  defp operator(:rem), do: "%"
  defp operator(op), do: Atom.to_string(op)

  # In WHERE and ORDER BY the planner's message is wrapped by the type
  # coercion pass; in the select list it is not.
  @spec planning_error(binary(), SQLFunctions.context()) :: {:error, map()}
  defp planning_error(message, :select),
    do: {:error, %{status: 400, body: "Error during planning: " <> message}}

  defp planning_error(message, _where_or_order_by),
    do:
      {:error,
       %{status: 400, body: "type_coercion\ncaused by\nError during planning: " <> message}}

  @spec pattern_error(atom(), binary(), term()) :: binary()
  defp pattern_error(kind, type, _rest) when kind in [:like, :not_like],
    do: "There isn't a common type to coerce #{type} and Utf8 in LIKE expression"

  defp pattern_error(_kind, type, {_regex, op}),
    do: "Cannot infer common argument type for regex operation #{type} #{op} Utf8"

  # COUNT, MIN and MAX take any type; the others need a number. DataFusion
  # words each family differently (verified against Core).
  @spec aggregate_refusal(SQLParser.aggregate(), binary()) :: :ok | {:error, map()}
  defp aggregate_refusal(agg, _type) when agg in [:count, :min, :max], do: :ok
  defp aggregate_refusal(_agg, type) when type in @numeric, do: :ok

  defp aggregate_refusal(agg, type) do
    name = Atom.to_string(agg)

    planning_error(
      aggregate_head(agg, type) <>
        " No function matches the given name and argument types '#{name}(#{type})'. " <>
        "You might need to add explicit type casts.\n\tCandidate functions:\n\t" <>
        aggregate_candidate(agg),
      :select
    )
  end

  @spec aggregate_head(SQLParser.aggregate(), binary()) :: binary()
  defp aggregate_head(:sum, type) do
    "Execution error: Function 'sum' user-defined coercion failed with " <>
      ~s|"Execution error: Sum not supported for #{unwrapped(type)}"|
  end

  defp aggregate_head(:avg, type) do
    "Execution error: Function 'avg' user-defined coercion failed with " <>
      ~s|"Error during planning: Avg does not support inputs of type #{unwrapped(type)}."|
  end

  defp aggregate_head(agg, type),
    do: "Function '#{agg}' expects NativeType::Numeric but received NativeType::#{native(type)}"

  @spec aggregate_candidate(SQLParser.aggregate()) :: binary()
  defp aggregate_candidate(agg) when agg in [:sum, :avg], do: "#{agg}(UserDefined)"
  defp aggregate_candidate(agg), do: "#{agg}(Numeric(1))"

  # A tag is dictionary encoded; the engine's messages name the type inside.
  @spec unwrapped(binary()) :: binary()
  defp unwrapped("Dictionary(Int32, Utf8)"), do: "Utf8"
  defp unwrapped(type), do: type

  @spec native(binary()) :: binary()
  defp native("Utf8"), do: "String"
  defp native("Dictionary(Int32, Utf8)"), do: "String"
  defp native("Timestamp(ns)"), do: "Timestamp(Nanosecond, None)"
  defp native(type), do: type

  # The Arrow type of the columns the checks name, as the engine has them: a
  # tag is dictionary encoded, a field typed by its values, `time` a
  # timestamp. A type is read from the first point that has the column, and
  # the scan stops once every column is known: typing every column of every
  # point was O(points x columns). A column no point has stays unknown, and
  # an unknown type is never refused.
  @spec column_types([point()], [binary()]) :: %{binary() => binary()}
  defp column_types(points, wanted) do
    pending = wanted |> MapSet.new() |> MapSet.delete("time")
    find_types(points, pending, %{"time" => time_type(points)})
  end

  # `time` is a timestamp unless a CTE gave it another type.
  @spec time_type([point()]) :: binary()
  defp time_type([%{fields: %{"time" => value}} | _rest]),
    do: arrow_type(value) || "Timestamp(ns)"

  defp time_type(_points), do: "Timestamp(ns)"

  @spec find_types([point()], MapSet.t(binary()), %{binary() => binary()}) ::
          %{binary() => binary()}
  defp find_types([], _pending, found), do: found

  defp find_types([point | rest], pending, found) do
    {pending, found} =
      Enum.reduce(pending, {pending, found}, fn column, {open, known} ->
        case column_type(point, column) do
          nil -> {open, known}
          type -> {MapSet.delete(open, column), Map.put(known, column, type)}
        end
      end)

    if MapSet.size(pending) == 0, do: found, else: find_types(rest, pending, found)
  end

  @spec column_type(point(), binary()) :: binary() | nil
  defp column_type(point, column) do
    case point.tags do
      %{^column => _value} -> "Dictionary(Int32, Utf8)"
      _no_tag -> arrow_type(Map.get(point.fields, column))
    end
  end

  @spec arrow_type(term()) :: binary() | nil
  defp arrow_type(nil), do: nil
  defp arrow_type(value) when is_boolean(value), do: "Boolean"
  defp arrow_type(value) when is_integer(value), do: "Int64"
  defp arrow_type(value) when is_float(value), do: "Float64"
  defp arrow_type(_string), do: "Utf8"

  # A projected plain column in an aggregate query must be grouped: the
  # engine fails planning otherwise. Its message lists what does satisfy
  # the requirement: the GROUP BY terms, then the aggregates in select
  # order, each as the planner prints it.
  @spec check_grouping_columns(SQLParser.parsed_query()) :: :ok | {:error, term()}
  defp check_grouping_columns(%{select_columns: nil}), do: :ok

  defp check_grouping_columns(query) do
    grouped = query.group_by_columns || []

    ungrouped =
      Enum.find_value(query.select_columns, fn
        {:grouping_column, source, _alias} -> if source in grouped, do: nil, else: source
        _other -> nil
      end)

    case ungrouped do
      nil -> :ok
      column -> {:error, ungrouped_error(query, column)}
    end
  end

  @spec ungrouped_error(SQLParser.parsed_query(), binary()) :: map()
  defp ungrouped_error(query, column) do
    case satisfying_terms(query) do
      {:ok, terms} ->
        %{
          status: 400,
          body:
            "Error during planning: Column in SELECT must be in GROUP BY or an aggregate " <>
              "function: While expanding wildcard, column \"#{query.measurement}.#{column}\" " <>
              "must appear in the GROUP BY clause or must be part of an aggregate function, " <>
              "currently only \"#{Enum.join(terms, ", ")}\" appears in the SELECT clause " <>
              "satisfies this requirement"
        }

      :unrenderable ->
        local_refusal(
          "column \"#{column}\" must appear in the GROUP BY clause or be part of an " <>
            "aggregate function; the double cannot print this query's terms as the " <>
            "engine's error does"
        )
    end
  end

  @day_ns 86_400_000_000_000

  @spec satisfying_terms(SQLParser.parsed_query()) :: {:ok, [binary()]} | :unrenderable
  defp satisfying_terms(%{cross_join: nil, measurement: table} = query) do
    columns = Enum.map(query.group_by_columns || [], &"#{table}.#{&1}")

    with {:ok, groups} <- group_terms(query.group_by_interval, columns, table),
         {:ok, aggregates} <- aggregate_terms(query.select_columns, table) do
      {:ok, groups ++ aggregates}
    end
  end

  # The qualifier of a column of a joined query depends on its side.
  defp satisfying_terms(_joined_query), do: :unrenderable

  # DATE_BIN prints its interval as months, days and nanoseconds. The double
  # keeps nanoseconds only, so a whole number of days (which the engine may
  # hold as days) and a DATE_BIN beside other terms (their order is lost)
  # are not printed.
  @spec group_terms(non_neg_integer() | nil, [binary()], binary()) ::
          {:ok, [binary()]} | :unrenderable
  defp group_terms(nil, columns, _table), do: {:ok, columns}
  defp group_terms(_interval_ns, [_column | _rest], _table), do: :unrenderable
  defp group_terms(interval_ns, [], _table) when rem(interval_ns, @day_ns) == 0, do: :unrenderable

  defp group_terms(interval_ns, [], table) do
    interval = "IntervalMonthDayNano { months: 0, days: 0, nanoseconds: #{interval_ns} }"
    {:ok, [~s|date_bin(IntervalMonthDayNano("#{interval}"),#{table}.time)|]}
  end

  @spec aggregate_terms([SQLParser.select_column()], binary()) ::
          {:ok, [binary()]} | :unrenderable
  defp aggregate_terms(select_columns, table) do
    terms = Enum.map(select_columns, &aggregate_term(&1, table))

    if :unrenderable in terms,
      do: :unrenderable,
      else: {:ok, Enum.reject(terms, &is_nil/1)}
  end

  @spec aggregate_term(SQLParser.select_column(), binary()) :: binary() | nil | :unrenderable
  defp aggregate_term({:count_star, _alias}, _table), do: "count(Int64(1))"

  defp aggregate_term({:count_distinct, column, _alias}, table),
    do: "count(DISTINCT #{table}.#{column})"

  defp aggregate_term({:aggregate, agg, expr, _alias}, table) do
    "#{agg}(#{render_expr(expr, table)})"
  catch
    :unrenderable -> :unrenderable
  end

  # The first or last in an order cannot be told from the other written
  # with the opposite direction (the parser folds them), and a selector
  # prints its access.
  defp aggregate_term({:ordered_aggregate, _agg, _field, _ordering, _alias}, _table),
    do: :unrenderable

  defp aggregate_term({:selector, _kind, _field, _ordering, _access, _alias}, _table),
    do: :unrenderable

  defp aggregate_term(_group_or_constant, _table), do: nil

  # An expression as the planner prints it: columns qualified, literals with
  # their type, operators infix and unparenthesised.
  @spec render_expr(SQLParser.expr(), binary()) :: binary()
  defp render_expr({:field, name}, table), do: "#{table}.#{name}"
  defp render_expr({:lit, value}, _table) when is_integer(value), do: "Int64(#{value})"

  defp render_expr({:lit, value}, _table) when is_float(value),
    do: "Float64(#{Format.render_decimal(value)})"

  defp render_expr({:lit, value}, _table) when is_binary(value), do: ~s|Utf8("#{value}")|

  defp render_expr({:op, op, left, right}, table),
    do: "#{render_expr(left, table)} #{operator(op)} #{render_expr(right, table)}"

  defp render_expr({:neg, inner}, table), do: "(- #{render_expr(inner, table)})"

  defp render_expr({:call, function, args}, table),
    do: "#{function}(#{Enum.map_join(args, ",", &render_expr(&1, table))})"

  # A CAST is simplified away or kept depending on the types.
  defp render_expr({:cast, _inner, _type}, _table), do: throw(:unrenderable)

  # Every source column the query refers to. ORDER BY may name an output
  # alias instead, which is not a source column.
  @spec referenced_columns(SQLParser.parsed_query()) :: [binary()]
  defp referenced_columns(query) do
    aliases = if query.distinct_on, do: [], else: output_aliases(query)

    order_by_refs =
      Enum.flat_map(query.order_by, fn
        {{:expr, expr}, _direction} -> expr_fields(expr)
        {column, _direction} -> if column in aliases, do: [], else: [column]
      end)

    Enum.flat_map(query.projection_columns || [], &projection_refs/1) ++
      Enum.flat_map(query.select_columns || [], &select_column_refs/1) ++
      where_refs(query.where) ++
      (query.group_by_columns || []) ++
      (query.distinct_columns || []) ++
      (query.distinct_on || []) ++
      order_by_refs
  end

  @spec output_aliases(SQLParser.parsed_query()) :: [binary()]
  defp output_aliases(query) do
    Enum.map(query.projection_columns || [], fn {_source, output} -> output end) ++
      Enum.map(query.select_columns || [], &elem(&1, tuple_size(&1) - 1)) ++
      (query.distinct_columns || [])
  end

  @spec projection_refs(SQLParser.projection()) :: [binary()]
  defp projection_refs({source, _output}) when is_binary(source), do: [source]
  defp projection_refs({expr, _output}), do: expr_fields(expr)

  @spec select_column_refs(SQLParser.select_column()) :: [binary()]
  defp select_column_refs({:time_bucket, _alias}), do: ["time"]
  defp select_column_refs({:aggregate, _agg, expr, _alias}), do: expr_fields(expr)
  defp select_column_refs({:count_star, _alias}), do: []
  defp select_column_refs({:count_distinct, column, _alias}), do: [column]

  defp select_column_refs({:ordered_aggregate, _agg, field, ordering, _alias}),
    do: [field, ordering]

  defp select_column_refs({:selector, _kind, field, ordering, _access, _alias}),
    do: [field, ordering]

  defp select_column_refs({:grouping_column, source, _alias}), do: [source]
  defp select_column_refs({:constant, _value, _alias}), do: []

  @spec where_refs([SQLParser.where_node()]) :: [binary()]
  defp where_refs(nodes) do
    Enum.flat_map(nodes, fn
      {:or, branches} -> Enum.flat_map(branches, &where_refs/1)
      {:not, conjunction} -> where_refs(conjunction)
      {_op, left, right} when is_binary(left) -> [left | expr_fields(right)]
      {_op, left, right} -> expr_fields(left) ++ expr_fields(right)
    end)
  end

  @spec expr_fields(term()) :: [binary()]
  defp expr_fields({:expr, expr}), do: expr_fields(expr)
  defp expr_fields({:field, name}), do: [name]
  defp expr_fields({:op, _op, left, right}), do: expr_fields(left) ++ expr_fields(right)
  defp expr_fields({:cast, inner, _type}), do: expr_fields(inner)
  defp expr_fields({:call, _function, args}), do: expr_fields(args)
  defp expr_fields(items) when is_list(items), do: Enum.flat_map(items, &expr_fields/1)
  defp expr_fields({:neg, inner}), do: expr_fields(inner)
  defp expr_fields({:aggregate, _agg, expr}), do: expr_fields(expr)
  defp expr_fields({:pattern, _kind, expr, _rest}), do: expr_fields(expr)
  defp expr_fields(_other), do: []

  # The columns a query's rows are made of, whether or not any row has a
  # value for them: a column that is null in every row is still in the
  # schema the next query reads.
  @spec output_columns(SQLParser.parsed_query(), [point()]) :: [binary()]
  defp output_columns(%{distinct_columns: columns}, _source) when is_list(columns), do: columns

  defp output_columns(%{select_columns: columns}, _source) when is_list(columns),
    do: Enum.map(columns, &elem(&1, tuple_size(&1) - 1))

  defp output_columns(%{projection_columns: columns}, _source) when is_list(columns),
    do: Enum.map(columns, fn {_source, output} -> output end)

  defp output_columns(_select_star, source), do: source |> point_columns() |> MapSet.to_list()

  # A CTE's output rows, read back as points: every column but a timestamp
  # `time` is a field (tag/field is a storage distinction the next query
  # cannot see), and a column the row has no value for is a null field. A
  # `time` that is not a timestamp (`SELECT s AS time`) is a field too.
  @spec rows_to_points(binary(), [map()], [binary()]) :: [point()]
  defp rows_to_points(name, rows, columns) do
    nulls = for column <- columns, column != "time", into: %{}, do: {column, nil}

    Enum.map(rows, fn row ->
      {timestamp, fields} =
        case row do
          %{"time" => %DateTime{} = time} ->
            {DateTime.to_unix(time, :nanosecond), Map.delete(row, "time")}

          _no_timestamp ->
            {nil, row}
        end

      %{measurement: name, tags: %{}, fields: Map.merge(nulls, fields), timestamp: timestamp}
    end)
  end

  # SELECT col, expr AS alias, ...: rows are projected first so ORDER BY can
  # name a projected alias (`ORDER BY mid DESC`) as well as any source column.
  @spec execute_projection_query([point()], SQLParser.parsed_query()) :: [map()]
  defp execute_projection_query(points, query) do
    projection = query.projection_columns

    points
    |> Enum.map(fn point -> {point, project_point(point, projection)} end)
    |> order_projected(query.order_by, projection)
    |> distinct_on(query.distinct_on, fn {point, _row} -> point end)
    |> apply_limit(query.limit, query.offset)
    |> Enum.map(fn {_point, row} -> row end)
  end

  # DISTINCT ON: the first row per distinct key, in the order ORDER BY left
  # them; rows missing a key column share the null key. The key is read
  # from the source point, so an ON column need not be selected.
  @spec distinct_on([item], [binary()] | nil, (item -> point())) :: [item] when item: term()
  defp distinct_on(items, nil, _point_of), do: items

  defp distinct_on(items, columns, point_of) do
    {kept, _seen} =
      Enum.reduce(items, {[], MapSet.new()}, fn item, {kept, seen} ->
        point = point_of.(item)
        key = Enum.map(columns, &sort_value(point, &1))

        if MapSet.member?(seen, key),
          do: {kept, seen},
          else: {[item | kept], MapSet.put(seen, key)}
      end)

    Enum.reverse(kept)
  end

  @spec order_projected([{point(), map()}], SQLParser.order_by(), [SQLParser.projection()]) ::
          [{point(), map()}]
  defp order_projected(pairs, [], _projection), do: pairs

  # A key that is the point's own time (`time`, or an alias of it) sorts on
  # the stored nanoseconds: the projected DateTime has microsecond
  # precision, so points less than a microsecond apart would tie and keep
  # insertion order, where the engine orders them by time (verified).
  defp order_projected(pairs, order_by, projection) do
    outputs = Enum.map(projection, fn {_source, output} -> output end)

    keys =
      Enum.map(order_by, fn
        {{:expr, expr}, direction} ->
          {fn {point, _row} -> eval_expr(expr, point) end, direction}

        {column, direction} ->
          cond do
            {"time", column} in projection or (column == "time" and column not in outputs) ->
              {fn {point, _row} -> sort_value(point, "time") end, direction}

            column in outputs ->
              {fn {_point, row} -> Map.get(row, column) end, direction}

            true ->
              {fn {point, _row} -> sort_value(point, column) end, direction}
          end
      end)

    sort_by_keys(pairs, keys)
  end

  # Stable multi-key sort with a direction per key; `DateTime`s compare
  # chronologically and nil (an omitted column) sorts first.
  #
  # Each item's key values are read once, not on every comparison: with two
  # keys over 100k rows that was millions of key-function calls (a
  # `DISTINCT ON (k) ... ORDER BY k, time DESC` took 630 ms).
  @spec sort_by_keys([term()], [{(term() -> term()), SQLParser.direction()}]) :: [term()]
  # One key, the common case (`ORDER BY time`): its key functions are cheap
  # field reads, and building a decorated list costs more than it saves.
  defp sort_by_keys(items, [{key_fn, direction}]) do
    placement = null_placement(direction)
    Enum.sort(items, fn a, b -> value_before?(key_fn.(a), key_fn.(b), placement) != :after end)
  end

  defp sort_by_keys(items, keys) do
    placements = Enum.map(keys, fn {_key_fn, direction} -> null_placement(direction) end)

    items
    |> Enum.map(fn item ->
      {Enum.map(keys, fn {key_fn, _direction} -> key_fn.(item) end), item}
    end)
    |> Enum.sort(fn {a, _item_a}, {b, _item_b} -> values_before?(a, b, placements) end)
    |> Enum.map(fn {_values, item} -> item end)
  end

  @spec values_before?([term()], [term()], [{:asc | :desc, :nulls_first | :nulls_last}]) ::
          boolean()
  defp values_before?([], [], []), do: true

  defp values_before?([x | xs], [y | ys], [placement | rest]) do
    case value_before?(x, y, placement) do
      :tie -> values_before?(xs, ys, rest)
      order -> order == :before
    end
  end

  # One key's order: `:before`, `:after` or `:tie`. Nulls sort last
  # ascending and first descending unless the query says NULLS FIRST /
  # LAST — DataFusion's rule (verified). Term order put a nil before every
  # string and between `false` and `true`.
  @spec value_before?(term(), term(), {:asc | :desc, :nulls_first | :nulls_last}) ::
          :before | :after | :tie
  defp value_before?(x, y, {dir, nulls}) do
    cond do
      is_nil(x) and is_nil(y) -> :tie
      is_nil(x) -> if nulls == :nulls_first, do: :before, else: :after
      is_nil(y) -> if nulls == :nulls_last, do: :before, else: :after
      value_order(x, y) and value_order(y, x) -> :tie
      value_order(x, y) == (dir == :asc) -> :before
      true -> :after
    end
  end

  @spec null_placement(SQLParser.direction()) :: {:asc | :desc, :nulls_first | :nulls_last}
  defp null_placement(:asc), do: {:asc, :nulls_last}
  defp null_placement(:desc), do: {:desc, :nulls_first}
  defp null_placement({dir, nulls}), do: {dir, nulls}

  # The same shape and wording the real engine returns for a missing table
  # (HTTP 400, planning error), so consumer code matching `%{status: 400}`
  # can be exercised against the double.
  @spec table_not_found(binary()) :: %{status: 400, body: binary()}
  defp table_not_found(measurement) do
    %{
      status: 400,
      body: "Error during planning: table 'public.iox.#{measurement}' not found"
    }
  end

  @spec project_point(point(), [SQLParser.projection()]) :: map()
  defp project_point(point, projection) do
    Enum.reduce(projection, %{}, fn
      {source, output}, acc when is_binary(source) ->
        put_column(acc, output, column_value(point, source))

      {expr, output}, acc ->
        put_column(acc, output, eval_expr(expr, point))
    end)
  end

  # InfluxDB 3 omits a null column from the row entirely (verified on both
  # the JSON and JSONL formats), so a nil never becomes a key here.
  @spec put_column(map(), binary(), term()) :: map()
  defp put_column(row, _key, nil), do: row
  defp put_column(row, key, value), do: Map.put(row, key, value)

  # SELECT DISTINCT a[, b ...]: one row per distinct combination, sorted
  # unless ORDER BY (one of the selected columns) says otherwise. A
  # combination whose columns are all null is a row too (`%{}`), as the
  # engine returns it (verified).
  @spec execute_distinct_query([point()], SQLParser.parsed_query()) :: [map()]
  defp execute_distinct_query(points, query) do
    columns = query.distinct_columns

    points
    |> Enum.map(fn point -> Enum.map(columns, &column_value(point, &1)) end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn values ->
      columns
      |> Enum.zip(values)
      |> Enum.reduce(%{}, fn {column, value}, row -> put_column(row, column, value) end)
    end)
    |> apply_order_by_rows(query.order_by, nil)
    |> apply_limit(query.limit, query.offset)
  end

  # A column as a row carries it: `time` as a DateTime, a tag or field as
  # stored. A tag wins over a field of the same name; `false` is a value, not
  # a missing one. A CTE column named `time` that is not a timestamp is a
  # field and is read as one.
  @spec column_value(point(), binary()) :: term()
  defp column_value(point, "time") do
    case point.fields do
      %{"time" => value} -> value
      _no_time_field -> nanoseconds_to_datetime(point.timestamp)
    end
  end

  defp column_value(point, column) do
    case point.tags do
      %{^column => value} -> value
      _no_tag -> Map.get(point.fields, column)
    end
  end

  # What a point sorts, groups and picks on for a column: `time` by its
  # stored nanoseconds (a DateTime has only microseconds), anything else by
  # its value. A null sorts last ascending and first descending.
  @spec sort_value(point(), binary()) :: term()
  defp sort_value(%{fields: %{"time" => value}}, "time"), do: value
  defp sort_value(point, "time"), do: point.timestamp
  defp sort_value(point, column), do: column_value(point, column)

  @spec execute_aggregate_query([point()], SQLParser.parsed_query()) :: [map()]
  defp execute_aggregate_query(points, %{group_by_interval: nil, group_by_columns: nil} = query) do
    # Scalar aggregate: all filtered points form a single bucket. Always
    # produce one row, even when no points matched (so COUNT returns 0).
    [aggregate_one_bucket(points, query.select_columns)]
  end

  # One group per (DATE_BIN bucket, grouping-column values) — either part
  # may be absent. `GROUP BY DATE_BIN(...), host` gives a row per bucket per
  # host, as the engine does (verified).
  defp execute_aggregate_query(points, query) do
    interval_ns = query.group_by_interval
    columns = query.group_by_columns || []
    time_alias = if interval_ns, do: find_time_bucket_alias(query.select_columns)

    points
    |> Enum.group_by(fn point ->
      {bucket_start(point, interval_ns), Enum.map(columns, &sort_value(point, &1))}
    end)
    |> Enum.map(fn {{bucket_ts, _values}, bucket_points} ->
      reduce_aggregate_columns(query.select_columns, bucket_points, bucket_ts)
    end)
    |> apply_order_by_rows(query.order_by, time_alias)
    |> apply_limit(query.limit, query.offset)
  end

  # The start of the point's DATE_BIN bucket (nil when there is no bucket).
  # Times before the epoch floor (-5 ns is in the bucket that starts before
  # 1970). An interval of zero is the engine closing the connection on the
  # first row it bins (verified); with no rows it answers none.
  @spec bucket_start(point(), non_neg_integer() | nil) :: integer() | nil
  defp bucket_start(_point, nil), do: nil
  defp bucket_start(_point, 0), do: connection_closed()
  defp bucket_start(%{timestamp: nil}, _interval_ns), do: 0

  defp bucket_start(%{timestamp: ts}, interval_ns),
    do: Integer.floor_div(ts, interval_ns) * interval_ns

  # Compute aggregates over a single (un-bucketed) set of points. Used for
  # scalar aggregates (no GROUP BY DATE_BIN) — always yields exactly one row.
  @spec aggregate_one_bucket([point()], [SQLParser.select_column()]) :: map()
  defp aggregate_one_bucket(points, columns) do
    reduce_aggregate_columns(columns, points, nil)
  end

  @spec reduce_aggregate_columns(
          [SQLParser.select_column()],
          [point()],
          integer() | nil
        ) :: map()
  # Null results (an aggregate over no values, a sample statistic of one
  # value, a missing grouping value) are omitted from the row, as the real
  # engine does; COUNT is 0, never null.
  defp reduce_aggregate_columns(columns, points, bucket_ts) do
    Enum.reduce(columns, %{}, fn
      {:time_bucket, alias_name}, row ->
        put_column(row, alias_name, nanoseconds_to_datetime(bucket_ts))

      {:grouping_column, source, alias_name}, row ->
        # All points in a column-grouped bucket share the same value for
        # this column; sample from the first point.
        value =
          case points do
            [first | _rest] -> column_value(first, source)
            [] -> nil
          end

        put_column(row, alias_name, value)

      {:aggregate, agg, expr, alias_name}, row ->
        values = points |> Enum.map(&eval_expr(expr, &1)) |> Enum.reject(&is_nil/1)
        put_column(row, alias_name, compute_aggregate(agg, values))

      {:count_star, alias_name}, row ->
        # COUNT(*) — every matching row counts, regardless of field nullity.
        put_column(row, alias_name, length(points))

      {:constant, value, alias_name}, row ->
        put_column(row, alias_name, value)

      {:count_distinct, column, alias_name}, row ->
        distinct =
          points
          |> Enum.map(&column_value(&1, column))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        put_column(row, alias_name, length(distinct))

      {:ordered_aggregate, agg, field, ordering, alias_name}, row ->
        put_column(row, alias_name, compute_ordered_aggregate(agg, field, ordering, points))

      {:selector, kind, field, ordering, access, alias_name}, row ->
        put_column(row, alias_name, compute_selector(kind, field, ordering, access, points))
    end)
  end

  # Evaluates an aggregate argument for one point. A missing field or a
  # non-numeric operand makes the value null, which the aggregate skips.
  # `time` is the point's timestamp; the parser only lets it reach MIN, MAX
  # and COUNT, the aggregates DataFusion accepts over a Timestamp.
  @spec eval_expr(SQLParser.expr(), point()) ::
          number() | binary() | boolean() | DateTime.t() | nil
  defp eval_expr({:field, name}, point), do: column_value(point, name)
  defp eval_expr({:lit, value}, _point), do: value
  defp eval_expr({:cast, inner, type}, point), do: cast(eval_expr(inner, point), type)

  defp eval_expr({:call, function, args}, point),
    do: SQLFunctions.call(function, Enum.map(args, &eval_expr(&1, point)))

  defp eval_expr({:neg, inner}, point) do
    case eval_expr(inner, point) do
      value when is_number(value) -> -value
      _null -> nil
    end
  end

  defp eval_expr({:op, op, left, right}, point) do
    with l when is_number(l) <- eval_expr(left, point),
         r when is_number(r) <- eval_expr(right, point) do
      arithmetic(op, l, r)
    else
      _non_number -> nil
    end
  end

  # CAST as DataFusion performs it: text to a number only when the whole
  # string is one ("2.5" is not an integer), a float to an integer by
  # truncation, a number or boolean to text by rendering (a float as the
  # engine writes it, `5000.0` and never `5.0e3`; a boolean to a number as 0
  # or 1). Null stays null. A cast that cannot be performed — text that is
  # not a number, a timestamp — fails the query on the engine mid-response:
  # InfluxDB 3 Core closes the connection, which `Client.HTTP` reports as a
  # transport error, so the double reports the same shape.
  @spec cast(term(), SQLParser.cast_type()) :: term()
  defp cast(nil, _type), do: nil
  defp cast(value, :integer) when is_integer(value), do: value
  defp cast(value, :integer) when is_float(value), do: trunc(value)
  defp cast(value, :integer) when is_boolean(value), do: if(value, do: 1, else: 0)
  defp cast(value, :float) when is_float(value), do: value
  defp cast(value, :float) when is_integer(value), do: value * 1.0
  defp cast(value, :float) when is_boolean(value), do: if(value, do: 1.0, else: 0.0)
  defp cast(value, :string) when is_binary(value), do: value
  defp cast(value, :string) when is_float(value), do: Format.render_float(value)
  defp cast(value, :string) when is_integer(value), do: Integer.to_string(value)
  defp cast(value, :string) when is_boolean(value), do: Atom.to_string(value)

  defp cast(value, :integer) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _not_an_integer -> connection_closed()
    end
  end

  defp cast(value, :float) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {f, ""} -> f
      _not_a_number -> connection_closed()
    end
  end

  defp cast(_value, _type), do: connection_closed()

  # The shape Client.HTTP gives a query the engine fails mid-response (and
  # Format gives a nested value in CSV), so code matching on it holds
  # against both clients.
  @spec connection_closed() :: no_return()
  defp connection_closed,
    do: throw({:query_error, {:connection_error, %Mint.TransportError{reason: :closed}}})

  @spec arithmetic(:+ | :- | :* | :/ | :rem, number(), number()) :: number() | nil
  defp arithmetic(:+, l, r), do: l + r
  defp arithmetic(:-, l, r), do: l - r
  defp arithmetic(:*, l, r), do: l * r
  # DataFusion divides two integers as integers (3 / 2 = 1), so the double
  # must not promote to float. Dividing an integer by the integer zero makes
  # the engine close the connection mid-response (verified), as an
  # impossible CAST does. A float divided by zero is refused by name (see
  # `float_by_zero/0`).
  defp arithmetic(:/, l, 0) when is_integer(l), do: connection_closed()
  defp arithmetic(:/, _l, zero) when zero in [0, +0.0, -0.0], do: float_by_zero()
  defp arithmetic(:/, l, r) when is_integer(l) and is_integer(r), do: div(l, r)
  defp arithmetic(:/, l, r), do: l / r
  # `%` takes the dividend's sign (-4 % 3 = -1) and works on floats
  # (-3.25 % 2 = -1.25), as DataFusion's does (verified). Its zero divisor
  # behaves as `/`'s.
  defp arithmetic(:rem, l, 0) when is_integer(l), do: connection_closed()
  defp arithmetic(:rem, _l, zero) when zero in [0, +0.0, -0.0], do: float_by_zero()
  defp arithmetic(:rem, l, r) when is_integer(l) and is_integer(r), do: rem(l, r)
  defp arithmetic(:rem, l, r), do: :math.fmod(l / 1, r / 1)

  # A float divided by zero is IEEE infinity or NaN on the engine: it shows
  # as null in a response, but compares as a number (`WHERE v / 0.0 > 1`
  # keeps every row; verified), which a null cannot. Elixir floats hold
  # neither, so the double refuses by name rather than answer wrongly.
  @spec float_by_zero() :: no_return()
  defp float_by_zero do
    throw(
      {:query_error,
       %{
         status: 400,
         body:
           "Client.Local: a float divided by zero is IEEE infinity or NaN on the engine, " <>
             "which the double cannot hold"
       }}
    )
  end

  @spec compute_aggregate(SQLParser.aggregate(), [number() | DateTime.t()]) ::
          number() | DateTime.t() | nil
  defp compute_aggregate(:count, vals), do: length(vals)
  defp compute_aggregate(_agg, []), do: nil
  defp compute_aggregate(:avg, vals), do: Enum.sum(vals) / length(vals)
  defp compute_aggregate(:sum, vals), do: Enum.sum(vals)
  # MIN/MAX also run over `time`, so the comparison must be DateTime-aware.
  defp compute_aggregate(:min, vals), do: Enum.min(vals, &value_order/2)
  defp compute_aggregate(:max, vals), do: Enum.max(vals, fn a, b -> value_order(b, a) end)
  defp compute_aggregate(:median, vals), do: median(vals)
  # Sample forms need at least two values, exactly as the real engine
  # (STDDEV of one row is null); population forms are defined for one.
  defp compute_aggregate(:var, [_one]), do: nil
  defp compute_aggregate(:stddev, [_one]), do: nil
  defp compute_aggregate(:var, vals), do: sum_of_squares(vals) / (length(vals) - 1)
  defp compute_aggregate(:stddev, vals), do: :math.sqrt(compute_aggregate(:var, vals))
  defp compute_aggregate(:var_pop, vals), do: sum_of_squares(vals) / length(vals)
  defp compute_aggregate(:stddev_pop, vals), do: :math.sqrt(compute_aggregate(:var_pop, vals))

  # DataFusion's median: the middle value, or for an even count the mean of
  # the two middle values — computed in the column's type, so two integers
  # average with integer division (median of 1 and 4 is 2, not 2.5).
  @spec median([number()]) :: number()
  defp median(vals) do
    sorted = Enum.sort(vals)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      low = Enum.at(sorted, mid - 1)
      high = Enum.at(sorted, mid)
      if is_integer(low) and is_integer(high), do: div(low + high, 2), else: (low + high) / 2
    end
  end

  @spec sum_of_squares([number()]) :: float()
  defp sum_of_squares(vals) do
    mean = Enum.sum(vals) / length(vals)
    Enum.reduce(vals, 0.0, fn v, acc -> acc + (v - mean) * (v - mean) end)
  end

  # selector_first/last pick by the ordering column, selector_min/max by the
  # field itself; `['value']` returns the field, `['time']` the row's time.
  @spec compute_selector(
          :first | :last | :min | :max,
          binary(),
          binary(),
          :value | :time | :struct,
          [point()]
        ) :: term() | nil
  defp compute_selector(kind, field, ordering, access, points) do
    candidates = Enum.reject(points, &is_nil(Map.get(&1.fields, field)))

    picked =
      case {kind, candidates} do
        {_kind, []} -> nil
        {:first, pts} -> pick_by_order(:first, pts, ordering)
        {:last, pts} -> pick_by_order(:last, pts, ordering)
        {:min, pts} -> Enum.min_by(pts, &Map.get(&1.fields, field))
        {:max, pts} -> Enum.max_by(pts, &Map.get(&1.fields, field))
      end

    case {picked, access} do
      {nil, _access} ->
        nil

      {point, :value} ->
        Map.get(point.fields, field)

      {point, :time} ->
        nanoseconds_to_datetime(point.timestamp)

      # The engine's struct (verified): `%{"time" => ..., "value" => ...}`.
      {point, :struct} ->
        %{
          "time" => nanoseconds_to_datetime(point.timestamp),
          "value" => Map.get(point.fields, field)
        }
    end
  end

  # Ordered aggregates: return the field value from the point that comes
  # first (`:first`) or last (`:last`) in the ordering column's ascending
  # order. `first_value(x ORDER BY c DESC)` is the parser's `:last`: a null
  # ordering value sorts last ascending (first descending), as in ORDER BY.
  @spec compute_ordered_aggregate(
          :first | :last,
          binary(),
          binary(),
          [point()]
        ) :: term() | nil
  defp compute_ordered_aggregate(_agg, _field, _ordering, []), do: nil

  defp compute_ordered_aggregate(agg, field, ordering, points) do
    agg |> pick_by_order(points, ordering) |> column_value(field)
  end

  # A single pass for the extreme element; sorting the whole bucket to take
  # its head was O(n log n) per aggregate column. Ties resolve to the first
  # point in scan (insertion) order, as the stable sort did.
  @spec pick_by_order(:first | :last, [point(), ...], binary()) :: point()
  defp pick_by_order(:first, points, ordering) do
    Enum.min_by(points, &sort_value(&1, ordering), fn a, b ->
      value_before?(a, b, @ascending) != :after
    end)
  end

  defp pick_by_order(:last, points, ordering) do
    Enum.max_by(points, &sort_value(&1, ordering), fn a, b ->
      value_before?(b, a, @ascending) != :after
    end)
  end

  # Find the alias of the time_bucket column from select_columns
  @spec find_time_bucket_alias([SQLParser.select_column()]) :: binary() | nil
  defp find_time_bucket_alias(columns) do
    Enum.find_value(columns, fn
      {:time_bucket, alias_name} -> alias_name
      _other -> nil
    end)
  end

  # Order aggregate result rows by any output column. `ORDER BY time` on a
  # DATE_BIN query refers to the bucket, whatever its alias.
  @spec apply_order_by_rows([map()], SQLParser.order_by(), binary() | nil) :: [map()]
  defp apply_order_by_rows(rows, [], _time_alias), do: rows

  defp apply_order_by_rows(rows, order_by, time_alias) do
    keys =
      Enum.map(order_by, fn {column, direction} ->
        key = if column == "time" and time_alias, do: time_alias, else: column
        {&Map.get(&1, key), direction}
      end)

    sort_by_keys(rows, keys)
  end

  # DateTime structs must be compared chronologically; everything else uses
  # term order (nil, an omitted column, sorts first).
  @spec value_order(term(), term()) :: boolean()
  defp value_order(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) != :gt
  defp value_order(a, b), do: a <= b

  # Per-value failures (a LIKE over a number, a CAST that cannot be
  # performed) are thrown from the evaluator and caught in execute_select/4.
  @spec apply_where([point()], [SQLParser.where_node()]) :: {:ok, [point()]}
  defp apply_where(points, []), do: {:ok, points}

  defp apply_where(points, conjunction) do
    {:ok, Enum.filter(points, &matches_all?(&1, conjunction))}
  end

  @doc "Whether a point satisfies a parsed `WHERE` conjunction (also used by `DELETE`)."
  @spec matches_all?(point(), [SQLParser.where_node()]) :: boolean()
  def matches_all?(point, conjunction), do: eval_all(point, conjunction) == true

  # SQL's three-valued logic: a comparison with a null operand is unknown
  # (nil), AND is false if any part is false, OR is true if any part is
  # true, NOT of unknown is unknown, and a row is kept only when true.
  # Two-valued evaluation kept rows where `NOT (rack = '1')` had no rack.
  @spec eval_all(point(), [SQLParser.where_node()]) :: boolean() | nil
  defp eval_all(point, conjunction) do
    Enum.reduce_while(conjunction, true, fn node, acc ->
      case eval_node(point, node) do
        false -> {:halt, false}
        nil -> {:cont, nil}
        true -> {:cont, acc}
      end
    end)
  end

  @spec eval_node(point(), SQLParser.where_node()) :: boolean() | nil
  defp eval_node(point, {:or, branches}) do
    Enum.reduce_while(branches, false, fn branch, acc ->
      case eval_all(point, branch) do
        true -> {:halt, true}
        nil -> {:cont, nil}
        false -> {:cont, acc}
      end
    end)
  end

  defp eval_node(point, {:not, conjunction}) do
    case eval_all(point, conjunction) do
      nil -> nil
      value -> not value
    end
  end

  defp eval_node(point, clause), do: matches_condition?(point, clause)

  @spec matches_condition?(point(), SQLParser.where_clause()) :: boolean() | nil
  defp matches_condition?(point, {:truthy, column, _nil}) do
    case column_value(point, column) do
      value when is_boolean(value) or is_nil(value) ->
        value

      other ->
        throw({:query_error, %{status: 400, body: non_boolean_predicate(point, column, other)}})
    end
  end

  defp matches_condition?(point, {:between, "time", {low, high}}) do
    ts = point.timestamp
    not is_nil(ts) and ts >= to_nanoseconds(low) and ts <= to_nanoseconds(high)
  end

  defp matches_condition?(point, {:not_between, "time", range}),
    do: not matches_condition?(point, {:between, "time", range})

  # SQL's three-valued logic: a null bound makes its comparison unknown,
  # and `AND` of an unknown is false only if the other side is false
  # (`v BETWEEN NULL AND 5` keeps no row; `v NOT BETWEEN NULL AND 5` keeps
  # the rows above 5).
  defp matches_condition?(point, {:between, left, {low, high}}) do
    case left_value(point, left) do
      nil -> nil
      actual -> both(compare3(actual, :gte, low), compare3(actual, :lte, high))
    end
  end

  defp matches_condition?(point, {:not_between, key, range}) do
    case matches_condition?(point, {:between, key, range}) do
      nil -> nil
      value -> not value
    end
  end

  defp matches_condition?(point, {:like, left, regex}) do
    case left_value(point, left) do
      nil -> nil
      text when is_binary(text) -> Regex.match?(regex, text)
      other -> throw({:query_error, %{status: 400, body: like_type_error(other)}})
    end
  end

  defp matches_condition?(point, {:regex, left, {regex, op}}) do
    case left_value(point, left) do
      nil -> nil
      text when is_binary(text) -> Regex.match?(regex, text)
      other -> throw({:query_error, %{status: 400, body: regex_type_error(other, op)}})
    end
  end

  defp matches_condition?(point, {:not_regex, left, {regex, op}}) do
    case left_value(point, left) do
      nil -> nil
      text when is_binary(text) -> not Regex.match?(regex, text)
      other -> throw({:query_error, %{status: 400, body: regex_type_error(other, op)}})
    end
  end

  defp matches_condition?(point, {:not_like, left, regex}) do
    case left_value(point, left) do
      nil -> nil
      text when is_binary(text) -> not Regex.match?(regex, text)
      other -> throw({:query_error, %{status: 400, body: like_type_error(other)}})
    end
  end

  defp matches_condition?(point, {:in, "time", values}) do
    point_in_time_set?(point, values)
  end

  defp matches_condition?(point, {:not_in, "time", values}) do
    not point_in_time_set?(point, values)
  end

  # A null in the list (or a null parameter) makes a miss unknown, not
  # false: `v NOT IN (1, NULL)` keeps nothing.
  defp matches_condition?(point, {:in, key, values}) do
    case left_value(point, key) do
      nil -> nil
      actual -> in_list(actual, Enum.map(values, &right_value(point, &1)))
    end
  end

  defp matches_condition?(point, {:not_in, key, values}) do
    case matches_condition?(point, {:in, key, values}) do
      nil -> nil
      value -> not value
    end
  end

  defp matches_condition?(point, {:is_null, key, _nil}), do: is_nil(left_value(point, key))

  defp matches_condition?(point, {:is_not_null, key, _nil}),
    do: not is_nil(left_value(point, key))

  defp matches_condition?(point, {op, "time", value}) do
    compare(point.timestamp, op, to_nanoseconds(value))
  end

  defp matches_condition?(point, {op, left, right}) do
    case {left_value(point, left), right_value(point, right)} do
      {nil, _right} -> nil
      {_left, nil} -> nil
      {l, r} -> compare(l, op, r)
    end
  end

  # DataFusion refuses a non-boolean column as a filter at planning.
  @spec non_boolean_predicate(point(), binary(), term()) :: binary()
  defp non_boolean_predicate(point, column, value) do
    "Error during planning: Cannot create filter with non-boolean predicate " <>
      "'#{point.measurement}.#{column}' returning #{arrow_type(value)}"
  end

  # The left operand is a column name or an arithmetic expression; the right
  # one is a literal unless the parser tagged it as an expression.
  @spec left_value(point(), SQLParser.operand()) :: term()
  defp left_value(point, {:expr, expr}), do: eval_expr(expr, point)
  defp left_value(point, key), do: column_value(point, key)

  @spec right_value(point(), term()) :: term()
  defp right_value(point, {:expr, expr}), do: eval_expr(expr, point)
  defp right_value(_point, literal), do: literal

  @spec in_list(term(), [term()]) :: boolean() | nil
  defp in_list(actual, candidates) do
    cond do
      Enum.any?(candidates, &(not is_nil(&1) and compare(actual, :eq, &1))) -> true
      Enum.any?(candidates, &is_nil/1) -> nil
      true -> false
    end
  end

  @spec compare3(term(), atom(), term()) :: boolean() | nil
  defp compare3(_actual, _op, nil), do: nil
  defp compare3(actual, op, value), do: compare(actual, op, value)

  @spec both(boolean() | nil, boolean() | nil) :: boolean() | nil
  defp both(false, _other), do: false
  defp both(_other, false), do: false
  defp both(nil, _other), do: nil
  defp both(_other, nil), do: nil
  defp both(true, true), do: true

  @spec point_in_time_set?(point(), [term()]) :: boolean()
  defp point_in_time_set?(point, values) do
    ts = point.timestamp
    Enum.any?(values, fn v -> ts == to_nanoseconds(v) end)
  end

  # The parser has already turned every `time` comparand into nanoseconds or
  # a `now()` offset; `now()` is resolved here, at execution, as the engine
  # does.
  @spec to_nanoseconds(SQLParser.time_value()) :: integer()
  defp to_nanoseconds(value) when is_integer(value), do: value
  defp to_nanoseconds({:now, offset_ns}), do: Store.now_ns() + offset_ns

  # A regular expression against a non-string column (verified). The planner
  # finds this first (`check_item/3`) when it knows the column's type; this
  # is the answer when it only learns it from a value.
  @spec regex_type_error(term(), binary()) :: binary()
  defp regex_type_error(value, op) do
    "type_coercion\ncaused by\nError during planning: " <>
      pattern_error(:regex, arrow_type(value), {nil, op})
  end

  # DataFusion: "There isn't a common type to coerce Float64 and Utf8 in
  # LIKE expression", naming the column's real type.
  @spec like_type_error(term()) :: binary()
  defp like_type_error(value) do
    "type_coercion\ncaused by\nError during planning: " <>
      pattern_error(:like, arrow_type(value), nil)
  end

  # Both nil-actual (missing column) and nil-value (unparseable comparand)
  # short-circuit to false. Without this guard, Elixir term ordering would
  # silently produce wrong results (e.g. `5 > nil` is `true`).
  #
  # A string literal against a non-string column compares the column's text
  # rendering, which is what DataFusion does (it casts the numeric side to
  # Utf8): `amount >= '1000.00'` is lexical, so 500.0 matches. The double
  # reproduces that so a test written against it fails the same way
  # production would.
  #
  # The other way round — a string column against a numeric literal — the
  # engine keeps the column as text and renders the literal (`rack = 2`
  # matches the tag "2"; `rack > 3` is lexical, so "10" does not match), so
  # the literal is rendered here too.
  @spec compare(term(), atom(), term()) :: boolean()
  defp compare(nil, _op, _value), do: false
  defp compare(_actual, _op, nil), do: false

  defp compare(actual, op, value) when is_binary(value) and not is_binary(actual),
    do: compare(text(actual), op, value)

  defp compare(actual, op, value) when is_binary(actual) and is_number(value),
    do: compare(actual, op, text(value))

  defp compare(actual, :eq, value), do: actual == value
  defp compare(actual, :ne, value), do: actual != value
  defp compare(actual, :gt, value), do: actual > value
  defp compare(actual, :lt, value), do: actual < value
  defp compare(actual, :gte, value), do: actual >= value
  defp compare(actual, :lte, value), do: actual <= value

  # A number as DataFusion casts it to text: a float as the engine writes it
  # (`5000.0`, not Erlang's `5.0e3`).
  @spec text(term()) :: binary()
  defp text(value) when is_float(value), do: Format.render_float(value)
  defp text(value), do: to_string(value)

  # ORDER BY any column on raw rows: `time` sorts by timestamp, anything
  # else by the tag/field value (nil first, as the real engine sorts nulls).
  @spec apply_order_by([point()], SQLParser.order_by()) :: [point()]
  defp apply_order_by(points, []), do: points

  # `time` sorts on the stored nanoseconds, as in `order_projected/3`.
  defp apply_order_by(points, order_by) do
    keys =
      Enum.map(order_by, fn
        {{:expr, expr}, direction} -> {&eval_expr(expr, &1), direction}
        {column, direction} -> {&sort_value(&1, column), direction}
      end)

    sort_by_keys(points, keys)
  end

  # OFFSET skips first, then LIMIT takes, whichever order they were written.
  @spec apply_limit([term()], non_neg_integer() | nil, non_neg_integer() | nil) :: [term()]
  defp apply_limit(items, limit, offset) do
    items
    |> Enum.drop(offset || 0)
    |> then(fn skipped -> if limit, do: Enum.take(skipped, limit), else: skipped end)
  end

  @spec point_to_row(point()) :: map()
  # `time` is a DateTime (microsecond precision), as on the HTTP and Flight
  # transports, so consumer code sees one type whichever client is configured.
  defp point_to_row(point) do
    row =
      for {key, value} <- Map.merge(point.fields, point.tags),
          value != nil,
          into: %{},
          do: {key, value}

    put_column(row, "time", column_value(point, "time"))
  end
end
