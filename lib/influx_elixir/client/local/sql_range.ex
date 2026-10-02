defmodule InfluxElixir.Client.Local.SQLRange do
  @moduledoc """
  What a `WHERE` leaves of a scan's ranges, for `InfluxElixir.Client.Local`:
  the failures the engine raises while planning the scan (verified against
  InfluxDB 3 Core).

  The scan's time range is the intersection of the comparisons of `time`
  among the top-level conjuncts of the `WHERE`. When they leave no instant
  (`time > X AND time < X`, `BETWEEN` with its bounds reversed, adjacent
  exclusive bounds: an open range holds nothing between two consecutive
  nanoseconds) the planner fails the query. What the optimizer settles first
  is not an error: two different instants that `time` equals, an instant it
  both equals and differs from, `time IS NULL`, a constant false, and
  `time > '2262-04-11T23:47:16.854775807Z'`, which no instant satisfies and
  answers no rows with or without another bound. An `OR` hides its branches, a `NOT` is pushed
  in, a bound that is NULL says nothing, and `now()` is one instant for the
  whole statement. A `LIMIT 0` plans no scan, and a filter on a CTE that
  aggregates or limits does not reach the table.

  The comparisons of a numeric column with literals that leave it no value
  fail in the engine's interval analysis (see
  `InfluxElixir.Client.Local.SQLBounds`); this module reads each column's
  type once for the whole query.
  """

  alias InfluxElixir.Client.Local.{
    SQLBounds,
    SQLError,
    SQLLimits,
    SQLParser,
    SQLPredicates,
    SQLRow,
    SQLSchema,
    Store
  }

  require SQLLimits

  @int64_max SQLLimits.int64_max()

  @doc """
  The planner's error for a `WHERE` whose `time` conjuncts leave no instant,
  or `:ok`. `pushdown` is whether a filter reaches the table the query reads.
  """
  @spec check_time(SQLParser.parsed_query(), boolean()) :: :ok | {:error, SQLError.t()}
  def check_time(%{limit: 0}, _pushdown), do: :ok
  def check_time(_query, false), do: :ok

  def check_time(query, true) do
    cond do
      not empty_time_range?(query.where) ->
        :ok

      query.cross_join ->
        {:error,
         SQLError.refusal(
           "a CROSS JOIN whose WHERE leaves no instant of time: the engine's answer depends " <>
             "on where it pushes the filter"
         )}

      true ->
        {:error, SQLError.empty_range()}
    end
  end

  @spec empty_time_range?([SQLParser.where_node()]) :: boolean()
  defp empty_time_range?(where) do
    leaves = SQLPredicates.flatten(where, false, time_leaves())
    now = Store.now_ns()
    constraints = Enum.flat_map(leaves, &time_constraints(&1, now))
    equal = for {:eq, instant} <- constraints, do: instant
    different = for {:ne, instant} <- constraints, do: instant

    cond do
      :never in leaves or :never in constraints -> false
      Enum.any?(leaves, &match?({:is_null, "time", _nil}, &1)) -> false
      length(Enum.uniq(equal)) > 1 -> false
      Enum.any?(equal, &(&1 in different)) -> false
      true -> bounds_empty?(constraints, equal)
    end
  end

  # The conjuncts of a conjunction: a predicate, `:never` for a constant
  # false, `:opaque` for what hides the conjuncts (an `OR`, a `NOT` of
  # several). A `NOT` is pushed into a predicate on `time`; any other
  # predicate under a `NOT` says nothing.
  @spec time_leaves() :: SQLPredicates.leaves()
  defp time_leaves do
    %{never: :never, opaque: fn _hidden -> :opaque end, clause: &time_leaf/2}
  end

  @spec time_leaf(SQLParser.where_clause(), boolean()) :: [term()]
  defp time_leaf(clause, false), do: [clause]

  defp time_leaf({op, "time", value}, true) do
    if SQLPredicates.negatable?(op),
      do: [{SQLPredicates.negate_op(op), "time", value}],
      else: [:opaque]
  end

  defp time_leaf(_clause, true), do: [:opaque]

  # The inclusive instants the bounds allow, `time = x` being both.
  @spec bounds_empty?([{atom(), integer()}], [integer()]) :: boolean()
  defp bounds_empty?(constraints, equal) do
    lows = equal ++ for {:lo, instant} <- constraints, do: instant
    highs = equal ++ for {:hi, instant} <- constraints, do: instant

    lows != [] and highs != [] and Enum.max(lows) > Enum.min(highs)
  end

  # `:never` where the comparison holds for no instant and the engine plans
  # no range for it (verified): `time` is greater than no instant past the
  # last one.
  @spec time_constraints(term(), integer()) :: [{atom(), integer()} | :never]
  defp time_constraints({op, "time", value}, now) when op in [:gt, :gte, :lt, :lte, :eq, :ne] do
    case instant(value, now) do
      nil -> []
      @int64_max when op == :gt -> [:never]
      ns -> [bound(op, ns)]
    end
  end

  defp time_constraints({:between, "time", {low, high}}, now),
    do: time_constraints({:gte, "time", low}, now) ++ time_constraints({:lte, "time", high}, now)

  defp time_constraints({:in, "time", [value]}, now),
    do: time_constraints({:eq, "time", value}, now)

  defp time_constraints({:not_in, "time", [value]}, now),
    do: time_constraints({:ne, "time", value}, now)

  defp time_constraints(_leaf, _now), do: []

  @spec bound(atom(), integer()) :: {atom(), integer()}
  defp bound(:gt, ns), do: {:lo, ns + 1}
  defp bound(:gte, ns), do: {:lo, ns}
  defp bound(:lt, ns), do: {:hi, ns - 1}
  defp bound(:lte, ns), do: {:hi, ns}
  defp bound(op, ns), do: {op, ns}

  @spec instant(term(), integer()) :: integer() | nil
  defp instant(ns, _now) when is_integer(ns), do: ns
  defp instant({:now, offset}, now), do: now + offset
  defp instant(_null_or_unread, _now), do: nil

  @doc """
  The engine's error for a `WHERE` whose top-level comparisons leave a
  numeric column no value, or `:ok`. `integer_type` tells an `Int64` column
  from a `UInt64` one, which the stored integers do not; `cte?` is whether
  the query filters a CTE. A `LIMIT 0` plans no scan.
  """
  @spec check_values(
          SQLParser.parsed_query(),
          [SQLRow.point()],
          (binary() -> :int64 | :uint64),
          boolean()
        ) :: :ok | {:error, SQLError.t()}
  def check_values(%{limit: 0}, _points, _integer_type, _cte?), do: :ok
  def check_values(%{where: []}, _points, _integer_type, _cte?), do: :ok

  def check_values(query, points, integer_type, cte?) do
    columns = for column <- SQLSchema.where_refs(query.where), is_binary(column), do: column
    types = column_types(points, Enum.uniq(columns), integer_type)
    SQLBounds.check(query.where, &Map.get(types, &1), cte: cte?)
  end

  # What the interval analysis reads each column as: a float by its values,
  # an integer by the kind the store registered, anything else (a tag, a
  # text or boolean field) as `:other`. One pass over the points reads them
  # all: a column with a tag anywhere is `:other`, else its type is that of
  # its first value.
  @spec column_types([SQLRow.point()], [binary()], (binary() -> :int64 | :uint64)) ::
          %{binary() => SQLBounds.column_type()}
  defp column_types(points, columns, integer_type) do
    Enum.reduce(points, %{}, fn point, types ->
      Enum.reduce(columns, types, &observe(&2, point, &1, integer_type))
    end)
  end

  @spec observe(
          %{binary() => SQLBounds.column_type()},
          SQLRow.point(),
          binary(),
          (binary() -> :int64 | :uint64)
        ) :: %{binary() => SQLBounds.column_type()}
  defp observe(types, point, column, integer_type) do
    cond do
      types[column] == :other -> types
      is_map_key(point.tags, column) -> Map.put(types, column, :other)
      is_map_key(types, column) -> types
      true -> observe_field(types, point.fields, column, integer_type)
    end
  end

  @spec observe_field(
          %{binary() => SQLBounds.column_type()},
          map(),
          binary(),
          (binary() -> :int64 | :uint64)
        ) :: %{binary() => SQLBounds.column_type()}
  defp observe_field(types, fields, column, integer_type) do
    case fields do
      %{^column => nil} -> types
      %{^column => value} -> Map.put(types, column, value_type(value, column, integer_type))
      _missing -> types
    end
  end

  @spec value_type(term(), binary(), (binary() -> :int64 | :uint64)) ::
          SQLBounds.column_type()
  defp value_type(value, _column, _integer_type) when is_float(value), do: :float64
  defp value_type({:u, _value}, _column, _integer_type), do: :uint64
  defp value_type(value, column, integer_type) when is_integer(value), do: integer_type.(column)
  defp value_type(_text_or_boolean, _column, _integer_type), do: :other
end
